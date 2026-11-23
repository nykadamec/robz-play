// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play - frame generation stage of the stream pipeline.

#include "framegen.h"

#include <robzfg/dedup.h>
#include <robzfg/rife_interpolator.h>

#include <chiaki/time.h>

extern "C" {
#include <libavutil/frame.h>
#include <libavutil/pixfmt.h>
}

#include <QFont>
#include <QFontMetrics>
#include <QImage>
#include <QLoggingCategory>
#include <QPainter>

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstring>

#ifdef _WIN32
#include <windows.h>
#include <timeapi.h>
#ifndef CREATE_WAITABLE_TIMER_HIGH_RESOLUTION
#define CREATE_WAITABLE_TIMER_HIGH_RESOLUTION 0x00000002
#endif
#elif defined(__APPLE__)
#include <pthread/qos.h>
#endif

Q_LOGGING_CATEGORY(robzFrameGen, "robzplay.framegen", QtInfoMsg);

namespace
{

// At most this many frames are generated between two real ones (30 fps -> 120 fps).
const int MAX_INTERMEDIATES = 3;
// The number of frames to generate follows the average time between real frames, measured
// in output intervals: 2 intervals leave room for one generated frame, 4 for three. The
// count only changes once the average has clearly left its current value, so network
// jitter does not switch generation on and off.
const double CADENCE_HYSTERESIS = 0.35;
const double CADENCE_TRACKING = 0.1;
const unsigned int CADENCE_MIN_SAMPLES = 6;
// Gaps outside this range say nothing about the cadence: a burst, a hitch or a loading pause.
const double MIN_PLAUSIBLE_GAP_US = 3000.0;
const double MAX_PLAUSIBLE_GAP_US = 120000.0;
// A single gap longer than this is a hitch: nothing sensible fits in between.
const double MAX_GENERATE_GAP_US = 70000.0;
// More than this many frames waiting means the GPU cannot keep up: stop generating until it drains.
const size_t MAX_QUEUE_DEPTH = 3;
// Generating all the frames of one interval may take at most this share of the interval.
const double MAX_GENERATE_LOAD = 0.8;
// The output timeline follows the arrival times of real frames only this fast, so network
// jitter is averaged out instead of being passed on to the screen.
const double TIMELINE_TRACKING = 0.15;
// Time set aside for synthesizing a frame before it is due; grows with the measured cost.
const double MIN_GENERATE_BUDGET_US = 6000.0;
// A change this large between two real frames is a cut, not motion: do not blend across it.
const double SCENE_CUT_MEAN_DIFF = 35.0;
const double SCENE_CUT_CHANGED_RATIO = 0.75;

bool isSupportedFormat(const AVFrame *frame)
{
	if(!frame || frame->hw_frames_ctx)
		return false;
	if(frame->format != AV_PIX_FMT_NV12 && frame->format != AV_PIX_FMT_YUV420P && frame->format != AV_PIX_FMT_YUVJ420P)
		return false;
	return frame->width > 0 && frame->height > 0 && (frame->width % 4) == 0 && (frame->height % 2) == 0;
}

robzfg::ColorInfo colorInfoOf(const AVFrame *frame)
{
	robzfg::ColorInfo color;
	color.full_range = frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P;
	const bool bt601 = frame->colorspace == AVCOL_SPC_BT470BG || frame->colorspace == AVCOL_SPC_SMPTE170M
		|| (frame->colorspace == AVCOL_SPC_UNSPECIFIED && frame->height < 720);
	color.matrix = bt601 ? robzfg::ColorMatrix::BT601 : robzfg::ColorMatrix::BT709;
	return color;
}

AVFrame *allocLike(const AVFrame *src)
{
	AVFrame *frame = av_frame_alloc();
	if(!frame)
		return nullptr;
	frame->format = src->format;
	frame->width = src->width;
	frame->height = src->height;
	if(av_frame_get_buffer(frame, 0) < 0 || av_frame_copy_props(frame, src) < 0)
	{
		av_frame_free(&frame);
		return nullptr;
	}
	return frame;
}

} // namespace

struct FrameGenStage::Engine
{
	robzfg::RifeInterpolator rife;
	robzfg::DuplicateDetector dedup;
	bool ok = false;
	// recent averages: any generated frame, the first frame of a pair (the one that includes
	// the motion estimate), and the further frames of a pair (built from the same estimate)
	double generate_ms_avg = 0.0;
	double first_ms_avg = 0.0;
	double rest_ms_avg = 0.0;
	// how long after a real frame arrived its first generated frame was ready: everything
	// in between counts (waiting for the worker, recognising repeats, upload, synthesis)
	double ready_delay_ms_avg = 0.0;
	// the very first runs are slow (pipelines and buffers are still being set up) and say
	// nothing about the steady cost: they are not measured
	int warmup_left = 4;
	// Auto-Scale: count consecutive frames exceeding the GPU time budget before stepping down
	int slow_streak = 0;

	// What generating `count` frames for one pair is expected to cost, in ms.
	double pairCostMs(int count) const
	{
		if(count <= 0 || first_ms_avg <= 0.0)
			return 0.0;
		// until further frames have been measured, assume they are cheap and find out
		const double rest = rest_ms_avg > 0.0 ? rest_ms_avg : first_ms_avg * 0.25;
		return first_ms_avg + (count - 1) * rest;
	}
};

// ---------------------------------------------------------------------------- Waiter

void FrameGenStage::Waiter::open()
{
#ifdef _WIN32
	event = CreateEventW(nullptr, FALSE, FALSE, nullptr);
	timer = CreateWaitableTimerExW(nullptr, nullptr, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
	if(!timer) // before Windows 10 1803
		timer = CreateWaitableTimerW(nullptr, TRUE, nullptr);
#endif
}

void FrameGenStage::Waiter::close()
{
#ifdef _WIN32
	if(event)
		CloseHandle((HANDLE)event);
	if(timer)
		CloseHandle((HANDLE)timer);
	event = nullptr;
	timer = nullptr;
#endif
}

void FrameGenStage::Waiter::signal()
{
#ifdef _WIN32
	if(event)
		SetEvent((HANDLE)event);
#else
	condition.notify_all();
#endif
}

void FrameGenStage::Waiter::wait(std::unique_lock<std::mutex> &lock, uint64_t timeout_us)
{
#ifdef _WIN32
	lock.unlock();
	if(timeout_us < 300 || !event || !timer)
	{
		// too short to sleep through reliably
		SwitchToThread();
	}
	else
	{
		LARGE_INTEGER due;
		due.QuadPart = -(LONGLONG)(timeout_us * 10); // relative, in 100 ns units
		SetWaitableTimer((HANDLE)timer, &due, 0, nullptr, nullptr, FALSE);
		HANDLE handles[2] = {(HANDLE)event, (HANDLE)timer};
		if(WaitForMultipleObjects(2, handles, FALSE, INFINITE) == WAIT_OBJECT_0)
			CancelWaitableTimer((HANDLE)timer);
	}
	lock.lock();
#else
	condition.wait_for(lock, std::chrono::microseconds(timeout_us));
#endif
}

// ---------------------------------------------------------------------------- lifecycle

FrameGenStage::FrameGenStage(QObject *parent) : QObject(parent)
{
	poll_timer.setInterval(250);
	connect(&poll_timer, &QTimer::timeout, this, [this]() {
		if(status_dirty.exchange(false))
			emit stateChanged();
		emit statsChanged();
	});
}

FrameGenStage::~FrameGenStage()
{
	stop();
}

QString FrameGenStage::status() const
{
	std::lock_guard<std::mutex> lock(status_mutex);
	return QString::fromStdString(status_text);
}

void FrameGenStage::setStatus(const std::string &text)
{
	{
		std::lock_guard<std::mutex> lock(status_mutex);
		if(status_text == text)
			return;
		status_text = text;
	}
	status_dirty.store(true);
}

void FrameGenStage::start(const Config &new_config, PresentFn present_fn)
{
	stop();
	config = new_config;
	present = std::move(present_fn);
	stop_requested = false;
	presenter_stop = false;
	engine_ready.store(false);
	stats_unique.store(0);
	stats_presented.store(0);
	stat_source_fps.store(0.0);
	stat_output_fps.store(0.0);
	stat_generate_ms.store(0.0);
	setStatus(config.enabled ? "loading" : "off");
#ifdef _WIN32
	timeBeginPeriod(1);
#endif
	work_waiter.open();
	present_waiter.open();
	running.store(true);
	presenter = std::thread([this]() { presenterMain(); });
	worker = std::thread([this]() { workerMain(); });
	poll_timer.start();
	emit stateChanged();
}

void FrameGenStage::stop()
{
	if(!running.load())
		return;
	// the worker first: it is the one that still feeds the presenter
	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		stop_requested = true;
	}
	work_waiter.signal();
	if(worker.joinable())
		worker.join();
	{
		std::lock_guard<std::mutex> lock(schedule_mutex);
		presenter_stop = true;
	}
	present_waiter.signal();
	if(presenter.joinable())
		presenter.join();
	running.store(false);
	poll_timer.stop();
	work_waiter.close();
	present_waiter.close();
#ifdef _WIN32
	timeEndPeriod(1);
#endif
	setStatus("off");
	status_dirty.store(false);
	emit stateChanged();
}

void FrameGenStage::runSelfTest(const Config &test_config, std::function<void()> on_presented)
{
	auto presented = std::make_shared<std::atomic<int>>(0);
	start(test_config, [presented, on_presented](ChiakiFfmpegFrame frame, int32_t, qint64) {
		presented->fetch_add(1);
		if(on_presented)
			on_presented();
		av_frame_free(&frame.frame);
	});

	// a bright bar sweeping across a 1080p picture, one new frame every 1/30 s for 8 s,
	// fed from its own thread so the cadence does not depend on how busy the UI is
	auto index = std::make_shared<std::atomic<int>>(0);
	auto feeder = std::make_shared<std::thread>([this, index]() {
		const auto wait_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(15);
		while(!engine_ready.load() && running.load() && std::chrono::steady_clock::now() < wait_deadline)
			std::this_thread::sleep_for(std::chrono::milliseconds(20));
		const auto begin = std::chrono::steady_clock::now();
		for(int i = 0; i < 240; i++)
		{
			const auto target = begin + std::chrono::microseconds((int64_t)i * 1000000 / 30);
			while(std::chrono::steady_clock::now() < target)
				std::this_thread::sleep_for(std::chrono::microseconds(500));
			AVFrame *frame = av_frame_alloc();
			frame->format = AV_PIX_FMT_NV12;
			frame->width = 1920;
			frame->height = 1080;
			if(av_frame_get_buffer(frame, 0) < 0)
			{
				av_frame_free(&frame);
				continue;
			}
			const int bar = (i * 24) % (frame->width - 200);
			for(int y = 0; y < frame->height; y++)
			{
				uint8_t *row = frame->data[0] + (size_t)y * frame->linesize[0];
				memset(row, 40 + (y * 100) / frame->height, (size_t)frame->width);
				memset(row + bar, 220, 200);
			}
			for(int y = 0; y < frame->height / 2; y++)
				memset(frame->data[1] + (size_t)y * frame->linesize[1], 128, (size_t)frame->width);
			frame->colorspace = AVCOL_SPC_BT709;
			frame->color_range = AVCOL_RANGE_MPEG;
			ChiakiFfmpegFrame chiaki_frame = {};
			chiaki_frame.frame = frame;
			chiaki_frame.pts = i / 30.0;
			chiaki_frame.duration = 1.0 / 30.0;
			index->fetch_add(1);
			submit(chiaki_frame, 0, static_cast<qint64>(chiaki_time_now_monotonic_us()));
		}
	});

	auto check_timer = new QTimer(this);
	connect(check_timer, &QTimer::timeout, this, [this, check_timer, feeder, index, presented]() {
		if(index->load() < 220 && running.load())
			return;
		check_timer->stop();
		check_timer->deleteLater();
		// sample the counters while frames are still flowing, then let the feeder finish
		const QString final_status = status();
		const double fps_in = sourceFps();
		const double fps_out = outputFps();
		const double generate_ms = generateMs();
		if(feeder->joinable())
			feeder->join();
		fprintf(stderr, "Robz Play frame generation self-test: status \"%s\", %d frames in, %d frames out, "
			"%.1f fps in, %.1f fps out, %.2f ms per generated frame\n",
			final_status.toUtf8().constData(), index->load(), presented->load(), fps_in, fps_out, generate_ms);
		fflush(stderr);
		stop();
	});
	check_timer->start(200);
}

void FrameGenStage::submit(ChiakiFfmpegFrame frame, int32_t frames_lost, qint64 delivery_us)
{
	if(!frame.frame)
		return;
	if(!running.load())
	{
		av_frame_free(&frame.frame);
		return;
	}
	if(!engine_ready.load())
	{
		// still loading the model, or it could not be loaded: show the frame as it is
		// instead of letting frames pile up behind the load
		stats_unique.fetch_add(1);
		stats_presented.fetch_add(1);
		present(frame, frames_lost, delivery_us);
		return;
	}
	Item item;
	item.frame = frame;
	item.frames_lost = frames_lost;
	item.delivery_us = delivery_us;
	item.arrival_us = chiaki_time_now_monotonic_us();
	{
		std::lock_guard<std::mutex> lock(queue_mutex);
		queue.push_back(item);
	}
	work_waiter.signal();
}

// ---------------------------------------------------------------------------- presenter

void FrameGenStage::presenterMain()
{
#if defined(__APPLE__)
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
	std::unique_lock<std::mutex> lock(schedule_mutex);
	while(!presenter_stop)
	{
		if(scheduled.empty())
		{
			present_waiter.wait(lock, 250000);
			continue;
		}
		const uint64_t now = chiaki_time_now_monotonic_us();
		const uint64_t due = scheduled.front().due_us;
		if(due > now)
		{
			present_waiter.wait(lock, due - now);
			continue;
		}
		Item item = scheduled.front().item;
		scheduled.pop_front();
		lock.unlock();
		stats_presented.fetch_add(1);
		present(item.frame, item.frames_lost, static_cast<qint64>(now));
		lock.lock();
	}
	// shutting down: nothing waiting is shown any more
	for(Scheduled &entry : scheduled)
		av_frame_free(&entry.item.frame.frame);
	scheduled.clear();
}

// Puts a frame on the output timeline. Due times never run backwards, so frames always
// leave in the order they were scheduled.
void FrameGenStage::schedule(Item &item, uint64_t due_us)
{
	if(!item.frame.frame)
		return;
	item.frames_lost += carried_frames_lost;
	carried_frames_lost = 0;
	if(due_us < last_due_us)
		due_us = last_due_us;
	last_due_us = due_us;
	Scheduled entry;
	entry.item = item;
	entry.due_us = due_us;
	item.frame.frame = nullptr;
	{
		std::lock_guard<std::mutex> lock(schedule_mutex);
		scheduled.push_back(entry);
	}
	present_waiter.signal();
}

void FrameGenStage::scheduleNow(Item &item)
{
	schedule(item, chiaki_time_now_monotonic_us());
}

// Everything still waiting goes out right away, in order, and the timeline starts over:
// used whenever the stage stops generating (pass-through, a hitch, an error).
void FrameGenStage::flushSchedule()
{
	const uint64_t now = chiaki_time_now_monotonic_us();
	{
		std::lock_guard<std::mutex> lock(schedule_mutex);
		for(Scheduled &entry : scheduled)
			entry.due_us = std::min(entry.due_us, now);
	}
	last_due_us = std::min(last_due_us, now);
	timeline_valid = false;
	present_waiter.signal();
}

// ---------------------------------------------------------------------------- worker

void FrameGenStage::workerMain()
{
#if defined(__APPLE__)
	pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
#endif
	engine.reset(new Engine);
	timeline_valid = false;
	last_due_us = 0;
	last_unique_us = 0;
	cadence_us = 0.0;
	cadence_samples = 0;
	intermediates = 0;
	carried_frames_lost = 0;
	stats_window_start_us = chiaki_time_now_monotonic_us();

	if(config.enabled)
	{
		robzfg::RifeInterpolator::Config rife_config;
		// UTF-8: the model sits beside the executable, in a folder any user name can be part of
		rife_config.model_dir = config.model_dir.toUtf8().toStdString();
#ifdef __APPLE__
		// flow_divisor == 0 means Auto: start at 3 (640x384 on 1080p) on Apple Silicon so
		// 30->60 FPS stays comfortably inside the 80% frame budget from frame 1 while
		// leaving GPU headroom for Retina display rendering.
		rife_config.flow_divisor = (config.flow_divisor == 0) ? 3 : config.flow_divisor;
		rife_config.sharp_sampling = false;
#else
		// flow_divisor == 0 means Auto: start at Balanced (2) and step down if needed
		rife_config.flow_divisor = (config.flow_divisor == 0) ? 2 : config.flow_divisor;
#endif
		rife_config.protect_static = config.protect_static;
		std::string error;
		const auto begin = std::chrono::steady_clock::now();
		engine->ok = engine->rife.init(rife_config, &error);
		const double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
		if(engine->ok)
		{
			qCInfo(robzFrameGen).nospace() << "Frame generation ready on " << QString::fromStdString(engine->rife.gpuName())
				<< " in " << qRound(ms) << " ms (model " << config.model_dir << ", flow divisor " << config.flow_divisor
				<< ", target " << config.target_fps << " fps)";
			setStatus("waiting for video");
			engine_ready.store(true);
		}
		else
		{
			qCWarning(robzFrameGen) << "Frame generation unavailable:" << QString::fromStdString(error);
			setStatus("unavailable: " + error);
		}
	}

	std::unique_lock<std::mutex> lock(queue_mutex);
	while(!stop_requested)
	{
		if(queue.empty())
		{
			work_waiter.wait(lock, 250000);
			lock.unlock();
			publishStats();
			lock.lock();
			continue;
		}
		Item item = queue.front();
		queue.pop_front();
		const bool overloaded = queue.size() >= MAX_QUEUE_DEPTH;
		lock.unlock();
		if(overloaded)
		{
			// falling behind: show frames as they are until the queue is short again
			flushSchedule();
			if(engine->ok)
			{
				if((config.auto_scale || config.flow_divisor == 0) && engine->warmup_left == 0 && engine->rife.flowDivisor() < 4)
				{
					const int prev_div = engine->rife.flowDivisor();
					const int next_div = prev_div + 1;
					if(engine->rife.setFlowDivisor(next_div))
					{
						qCInfo(robzFrameGen).nospace() << "Auto-Scale (overload): stepping flow_divisor "
							<< prev_div << " -> " << next_div;
						engine->first_ms_avg = 0.0;
						engine->rest_ms_avg = 0.0;
						engine->generate_ms_avg = 0.0;
						engine->warmup_left = 3;
						engine->slow_streak = 0;
					}
				}
				else
				{
					engine->rife.reset();
				}
				engine->dedup.reset();
			}
			last_unique_us = 0;
			cadence_samples = 0;
			intermediates = 0;
			stats_unique.fetch_add(1);
			scheduleNow(item);
		}
		else
			process(item);
		publishStats();
		lock.lock();
	}

	engine_ready.store(false);
	// shutting down: nothing queued is shown any more
	std::deque<Item> leftover;
	leftover.swap(queue);
	lock.unlock();
	for(Item &item : leftover)
		av_frame_free(&item.frame.frame);
	av_frame_free(&compare_prev);
	engine.reset();
}

void FrameGenStage::publishStats()
{
	const uint64_t now = chiaki_time_now_monotonic_us();
	const uint64_t elapsed = now - stats_window_start_us;
	if(elapsed < 500000)
		return;
	const double seconds = elapsed / 1000000.0;
	stat_source_fps.store(stats_unique.exchange(0) / seconds);
	stat_output_fps.store(stats_presented.exchange(0) / seconds);
	stat_generate_ms.store(engine ? engine->generate_ms_avg : 0.0);
	stats_window_start_us = now;
}

void FrameGenStage::process(Item &item)
{
	AVFrame *frame = item.frame.frame;

	if(!config.enabled || !engine->ok || !isSupportedFormat(frame))
	{
		if(config.enabled && engine->ok)
			setStatus(frame->hw_frames_ctx ? "passing through (frame stayed on the GPU)" : "passing through (pixel format not supported yet, e.g. HDR)");
		flushSchedule();
		stats_unique.fetch_add(1);
		scheduleNow(item);
		return;
	}

	const int w = frame->width;
	const int h = frame->height;
	const bool planar = frame->format != AV_PIX_FMT_NV12;

	robzfg::Nv12View view;
	view.width = w;
	view.height = h;
	view.y = frame->data[0];
	view.y_stride = frame->linesize[0];
	if(planar)
	{
		// software decoders deliver three planes; the engine wants Cb and Cr interleaved
		scratch_uv.resize((size_t)w * h / 2);
		for(int row = 0; row < h / 2; row++)
		{
			const uint8_t *u = frame->data[1] + (size_t)row * frame->linesize[1];
			const uint8_t *v = frame->data[2] + (size_t)row * frame->linesize[2];
			uint8_t *dst = scratch_uv.data() + (size_t)row * w;
			for(int x = 0; x < w / 2; x++)
			{
				dst[2 * x] = u[x];
				dst[2 * x + 1] = v[x];
			}
		}
		view.uv = scratch_uv.data();
		view.uv_stride = w;
	}
	else
	{
		view.uv = frame->data[1];
		view.uv_stride = frame->linesize[1];
	}

	const robzfg::FrameDifference diff = engine->dedup.measure(view);
	if(engine->dedup.classify(diff))
	{
		// a repeat of the frame we already have: the console had nothing new to send
		carried_frames_lost += item.frames_lost;
		av_frame_free(&item.frame.frame);
		return;
	}
	engine->dedup.accept(view);
	stats_unique.fetch_add(1);

	// How fast real frames arrive decides how many frames go in between.
	const double target_interval_us = 1000000.0 / (config.target_fps >= 100 ? 120.0 : 60.0);
	const double gap_us = last_unique_us ? (double)(item.arrival_us - last_unique_us) : 0.0;
	last_unique_us = item.arrival_us;
	if(gap_us >= MIN_PLAUSIBLE_GAP_US && gap_us <= MAX_PLAUSIBLE_GAP_US)
	{
		cadence_us = cadence_samples ? cadence_us + (gap_us - cadence_us) * CADENCE_TRACKING : gap_us;
		cadence_samples++;
	}
	else if(gap_us > MAX_PLAUSIBLE_GAP_US)
	{
		// a long pause: whatever came before says nothing about what follows
		cadence_samples = 0;
		intermediates = 0;
	}
	if(cadence_samples >= CADENCE_MIN_SAMPLES)
	{
		const double ratio = cadence_us / target_interval_us;
		if(std::abs(ratio - (double)(intermediates + 1)) > CADENCE_HYSTERESIS)
			intermediates = std::max(0, std::min(MAX_INTERMEDIATES, (int)std::lround(ratio) - 1));
	}

	// Never take on more than the GPU can finish inside one interval.
	// Smart Auto-Scale: if enabled (or flow_divisor == 0 "Auto") and the GPU is exceeding
	// the frame budget, step down motion resolution (1 -> 2 -> 3 -> 4) dynamically to lock 60/120 FPS.
	const double budget_ms = (cadence_us * MAX_GENERATE_LOAD) / 1000.0;
	if((config.auto_scale || config.flow_divisor == 0) && engine->warmup_left == 0 && engine->first_ms_avg > 0.0)
	{
		const double cost_ms = engine->pairCostMs(intermediates > 0 ? intermediates : 1);
		if(cost_ms > budget_ms && engine->rife.flowDivisor() < 4)
		{
			engine->slow_streak++;
			if(engine->slow_streak >= 6)
			{
				const int prev_div = engine->rife.flowDivisor();
				const int next_div = prev_div < 4 ? prev_div + 1 : 4;
				if(engine->rife.setFlowDivisor(next_div))
				{
					qCInfo(robzFrameGen).nospace() << "Auto-Scale: GPU took " << cost_ms << " ms (budget "
						<< budget_ms << " ms), stepping flow_divisor " << prev_div << " -> " << next_div;
					engine->first_ms_avg = 0.0;
					engine->rest_ms_avg = 0.0;
					engine->generate_ms_avg = 0.0;
					engine->warmup_left = 3;
					engine->slow_streak = 0;
				}
			}
		}
		else
		{
			engine->slow_streak = 0;
		}
	}

	int count = intermediates;
	bool reduced = false;
	while(count > 1 && engine->pairCostMs(count) * 1000.0 > cadence_us * MAX_GENERATE_LOAD)
	{
		count = (count - 1) / 2; // 3 -> 1
		reduced = true;
	}

	const bool scene_cut = diff.comparable && diff.mean_abs_diff > SCENE_CUT_MEAN_DIFF && diff.changed_ratio > SCENE_CUT_CHANGED_RATIO;

	std::string error;
	if(!engine->rife.push(view, colorInfoOf(frame), &error))
	{
		qCWarning(robzFrameGen) << "Frame generation push failed:" << QString::fromStdString(error);
		flushSchedule();
		scheduleNow(item);
		return;
	}

	const bool gap_fits = gap_us > 0.0 && gap_us <= MAX_GENERATE_GAP_US;
	// ROBZPLAY_FRAMEGEN_TRACE=1 prints one line per real frame: what arrived and what was decided
	static const bool trace = qEnvironmentVariableIsSet("ROBZPLAY_FRAMEGEN_TRACE");
	if(trace)
		fprintf(stderr, "[framegen] gap %.1f ms cadence %.1f ms (%u samples) wanted %d using %d first %.1f rest %.1f ms diff %.2f cut %d ready %d\n",
			gap_us / 1000.0, cadence_us / 1000.0, cadence_samples, intermediates, count, engine->first_ms_avg, engine->rest_ms_avg,
			diff.mean_abs_diff, scene_cut ? 1 : 0, engine->rife.ready() ? 1 : 0);
	if(count <= 0 || !gap_fits || scene_cut || !engine->rife.ready())
	{
		if(cadence_samples >= CADENCE_MIN_SAMPLES && intermediates == 0)
			setStatus(config.target_fps >= 100 ? "passing through (source already near 120 fps)" : "passing through (source already near 60 fps)");
		flushSchedule();
		av_frame_free(&compare_prev);
		scheduleNow(item);
		return;
	}

	// Comparison view: the left half keeps the previous real frame until this one is due,
	// as the stream would show it without frame generation.
	const bool compare = compare_split.load();
	AVFrame *compare_cur = compare ? av_frame_clone(frame) : nullptr;
	if(!compare)
		av_frame_free(&compare_prev);
	const int compare_left_fps = cadence_us > 0.0 ? (int)std::lround(1000000.0 / cadence_us) : 0;
	const int compare_right_fps = cadence_us > 0.0 ? (int)std::lround(1000000.0 * (count + 1) / cadence_us) : 0;

	// Output timeline. With n generated frames the interval is cut into n + 1 steps. The
	// first generated frame is due one budget after the real frame arrived - the time it
	// has been taking to get that frame ready, plus a margin - and the real frame itself n
	// steps later. Following that target only gradually keeps the cadence even when frames
	// arrive unevenly.
	const double step_us = cadence_us / (count + 1);
	const double budget_us = std::min(cadence_us * 0.5,
		std::max(MIN_GENERATE_BUDGET_US, engine->ready_delay_ms_avg * 1000.0 * 1.15 + 1000.0));
	const double wanted_due_us = (double)item.arrival_us + budget_us + step_us * count;
	const double predicted_due_us = timeline_real_due_us + cadence_us;
	if(timeline_valid && std::abs(wanted_due_us - predicted_due_us) < cadence_us)
		timeline_real_due_us = predicted_due_us + (wanted_due_us - predicted_due_us) * TIMELINE_TRACKING;
	else
		timeline_real_due_us = wanted_due_us;
	timeline_valid = true;

	const double real_duration = item.frame.duration;
	const double real_pts = item.frame.pts;
	int32_t lost_for_first = item.frames_lost;
	item.frames_lost = 0;

	for(int k = 1; k <= count; k++)
	{
		const float t = (float)k / (float)(count + 1);
		AVFrame *mid = allocLike(frame);
		if(!mid)
			break;

		robzfg::Nv12Mut out;
		out.width = w;
		out.height = h;
		out.y = mid->data[0];
		out.y_stride = mid->linesize[0];
		if(planar)
		{
			scratch_out_uv.resize((size_t)w * h / 2);
			out.uv = scratch_out_uv.data();
			out.uv_stride = w;
		}
		else
		{
			out.uv = mid->data[1];
			out.uv_stride = mid->linesize[1];
		}

		robzfg::InterpolateTiming timing;
		// one motion estimate per pair, made for the middle of the interval
		if(!engine->rife.interpolate(t, out, &timing, &error, 0.5f))
		{
			qCWarning(robzFrameGen) << "Frame generation failed:" << QString::fromStdString(error);
			av_frame_free(&mid);
			break;
		}
		if(planar)
		{
			for(int row = 0; row < h / 2; row++)
			{
				const uint8_t *src = scratch_out_uv.data() + (size_t)row * w;
				uint8_t *u = mid->data[1] + (size_t)row * mid->linesize[1];
				uint8_t *v = mid->data[2] + (size_t)row * mid->linesize[2];
				for(int x = 0; x < w / 2; x++)
				{
					u[x] = src[2 * x];
					v[x] = src[2 * x + 1];
				}
			}
		}
		if(engine->warmup_left > 0)
			engine->warmup_left--;
		else
		{
			auto track = [&timing](double &average) {
				average = average > 0.0 ? average * 0.9 + timing.total_ms * 0.1 : timing.total_ms;
			};
			track(engine->generate_ms_avg);
			track(k == 1 ? engine->first_ms_avg : engine->rest_ms_avg);
			if(k == 1)
			{
				const double delay_ms = (double)(chiaki_time_now_monotonic_us() - item.arrival_us) / 1000.0;
				engine->ready_delay_ms_avg = engine->ready_delay_ms_avg > 0.0
					? engine->ready_delay_ms_avg * 0.9 + delay_ms * 0.1 : delay_ms;
			}
		}

		if(compare)
		{
			if(compare_prev)
				copyLeftHalf(mid, compare_prev);
			drawCompare(mid, compare_left_fps, compare_right_fps);
		}

		Item generated;
		generated.frame.frame = mid;
		generated.frame.duration = real_duration / (count + 1);
		generated.frame.pts = real_pts - real_duration * (1.0 - t);
		generated.frame.recovered = false;
		generated.frames_lost = lost_for_first;
		generated.delivery_us = item.delivery_us;
		lost_for_first = 0;
		schedule(generated, (uint64_t)(timeline_real_due_us - step_us * (count + 1 - k)));
	}

	item.frames_lost = lost_for_first;
	item.frame.duration = real_duration / (count + 1);
	if(compare && av_frame_make_writable(item.frame.frame) >= 0)
		drawCompare(item.frame.frame, compare_left_fps, compare_right_fps);
	av_frame_free(&compare_prev);
	compare_prev = compare_cur;
	schedule(item, (uint64_t)timeline_real_due_us);
	setStatus(reduced ? "generating (GPU too slow for the full target, generating fewer frames)" : "generating");
}

// ---------------------------------------------------------------------------- comparison view

void FrameGenStage::setCompareLabels(const QString &left_label, const QString &right_label)
{
	std::lock_guard<std::mutex> lock(compare_label_mutex);
	compare_left_label = left_label;
	compare_right_label = right_label;
}

void FrameGenStage::copyLeftHalf(AVFrame *dst, const AVFrame *src)
{
	if(!dst || !src || dst->format != src->format || dst->width != src->width || dst->height != src->height)
		return;
	const int w = dst->width;
	const int h = dst->height;
	const int half = (w / 2) & ~3;
	for(int y = 0; y < h; y++)
		memcpy(dst->data[0] + (size_t)y * dst->linesize[0], src->data[0] + (size_t)y * src->linesize[0], (size_t)half);
	if(dst->format == AV_PIX_FMT_NV12)
	{
		for(int y = 0; y < h / 2; y++)
			memcpy(dst->data[1] + (size_t)y * dst->linesize[1], src->data[1] + (size_t)y * src->linesize[1], (size_t)half);
	}
	else
	{
		for(int plane = 1; plane <= 2; plane++)
			for(int y = 0; y < h / 2; y++)
				memcpy(dst->data[plane] + (size_t)y * dst->linesize[plane], src->data[plane] + (size_t)y * src->linesize[plane], (size_t)half / 2);
	}
}

// Draws the dividing line and the two labels into the picture itself, so they also show in
// a recording (OBS).
void FrameGenStage::drawCompare(AVFrame *frame, int left_fps, int right_fps)
{
	const int w = frame->width;
	const int h = frame->height;
	const bool nv12 = frame->format == AV_PIX_FMT_NV12;
	QString left_text;
	QString right_text;
	{
		std::lock_guard<std::mutex> lock(compare_label_mutex);
		left_text = compare_left_label.arg(left_fps);
		right_text = compare_right_label.arg(right_fps);
	}

	// a label as a coverage bitmap, rendered once per text and picture size
	auto render = [h](LabelBitmap &bitmap, const QString &text) {
		if(bitmap.text == text && bitmap.frame_height == h)
			return;
		QFont font;
		font.setBold(true);
		font.setPixelSize(std::max(14, h / 30));
		const QFontMetrics metrics(font);
		const int pad = std::max(8, h / 90);
		bitmap.width = (metrics.horizontalAdvance(text) + 2 * pad + 3) & ~3;
		bitmap.height = ((metrics.height() + 2 * pad) + 1) & ~1;
		QImage image(bitmap.width, bitmap.height, QImage::Format_Grayscale8);
		image.fill(0);
		QPainter painter(&image);
		painter.setRenderHint(QPainter::TextAntialiasing);
		painter.setFont(font);
		painter.setPen(Qt::white);
		painter.drawText(QRect(0, 0, bitmap.width, bitmap.height), Qt::AlignCenter, text);
		painter.end();
		bitmap.coverage.resize((size_t)bitmap.width * bitmap.height);
		for(int y = 0; y < bitmap.height; y++)
			memcpy(bitmap.coverage.data() + (size_t)y * bitmap.width, image.constScanLine(y), (size_t)bitmap.width);
		bitmap.text = text;
		bitmap.frame_height = h;
	};
	render(compare_left_bitmap, left_text);
	render(compare_right_bitmap, right_text);

	// white text on a dark, colourless box
	auto blit = [&](const LabelBitmap &bitmap, int x0, int y0) {
		x0 &= ~1;
		y0 &= ~1;
		for(int y = 0; y < bitmap.height && y0 + y < h; y++)
		{
			uint8_t *row = frame->data[0] + (size_t)(y0 + y) * frame->linesize[0];
			const uint8_t *cov = bitmap.coverage.data() + (size_t)y * bitmap.width;
			for(int x = 0; x < bitmap.width && x0 + x < w; x++)
			{
				const int dimmed = 16 + (row[x0 + x] - 16) * 30 / 100;
				row[x0 + x] = (uint8_t)(dimmed + (235 - dimmed) * cov[x] / 255);
			}
		}
		for(int y = 0; y < bitmap.height / 2 && y0 / 2 + y < h / 2; y++)
		{
			if(nv12)
			{
				uint8_t *uv = frame->data[1] + (size_t)(y0 / 2 + y) * frame->linesize[1];
				for(int x = x0; x < std::min(w, x0 + bitmap.width); x++)
					uv[x] = (uint8_t)(128 + (uv[x] - 128) * 30 / 100);
			}
			else
			{
				for(int plane = 1; plane <= 2; plane++)
				{
					uint8_t *c = frame->data[plane] + (size_t)(y0 / 2 + y) * frame->linesize[plane];
					for(int x = x0 / 2; x < std::min(w / 2, (x0 + bitmap.width) / 2); x++)
						c[x] = (uint8_t)(128 + (c[x] - 128) * 30 / 100);
				}
			}
		}
	};
	const int margin = std::max(12, h / 40);
	blit(compare_left_bitmap, margin, margin);
	blit(compare_right_bitmap, w / 2 + margin, margin);

	// the dividing line
	const int line = std::max(2, (h / 360) & ~1);
	const int x_start = (w / 2 - line / 2) & ~1;
	for(int y = 0; y < h; y++)
		memset(frame->data[0] + (size_t)y * frame->linesize[0] + x_start, 235, (size_t)line);
	for(int y = 0; y < h / 2; y++)
	{
		if(nv12)
			memset(frame->data[1] + (size_t)y * frame->linesize[1] + x_start, 128, (size_t)line);
		else
			for(int plane = 1; plane <= 2; plane++)
				memset(frame->data[plane] + (size_t)y * frame->linesize[plane] + x_start / 2, 128, (size_t)std::max(1, line / 2));
	}
}
