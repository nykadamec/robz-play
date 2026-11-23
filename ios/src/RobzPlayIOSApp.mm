// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play Native iOS / iPadOS Client
// - PS5 & PS4 Remote Play protocol via chiaki-lib (Discovery, Registration, Wakeup, Session)
// - Hardware H.265 / H.264 decoding via VideoToolbox (VTDecompressionSession -> CVPixelBuffer NV12)
// - Native Apple Metal + MPSGraph RIFE 30 -> 60 FPS Frame Generation (rife-v4.6 & rife-v4.25-lite)
// - Zero-copy Metal NV12 BT.709 + Contrast Adaptive Sharpening (CAS) renderer
// - Native GameController (DualSense / MFi / Xbox) + On-Screen Touch DualSense overlay

#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <VideoToolbox/VideoToolbox.h>
#import <GameController/GameController.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

#include <arpa/inet.h>
#include <chiaki/common.h>
#include <chiaki/controller.h>
#include <chiaki/discovery.h>
#include <chiaki/discoveryservice.h>
#include <chiaki/log.h>
#include <chiaki/regist.h>
#include <chiaki/session.h>
#include <chiaki/base64.h>

#include "robzfg/dedup.h"
#include "robzfg/frame.h"
#include "robzfg/rife_interpolator.h"
#include "rife_metal.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <deque>
#include <mutex>
#include <string>
#include <vector>

#include <execinfo.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <unistd.h>

namespace
{

static const char *const kIosDisplayShaderSource = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 uv;
};

struct CasParams {
    float sharpness;
    float pad0;
    float tx;
    float ty;
};

vertex VertexOut robzVertex(uint vid [[vertex_id]]) {
    const float2 pos[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    const float2 uvs[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    VertexOut out;
    out.position = float4(pos[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
}

static float3 nv12SampleBT709(texture2d<float, access::sample> yTex,
                              texture2d<float, access::sample> uvTex,
                              sampler s, float2 uv) {
    float y = yTex.sample(s, uv).r;
    float2 cbcr = uvTex.sample(s, uv).rg - float2(128.0 / 255.0);
    float Y = max(0.0, (y - (16.0 / 255.0)) * (255.0 / 219.0));
    float Cb = cbcr.x * (255.0 / 224.0);
    float Cr = cbcr.y * (255.0 / 224.0);
    float r = Y + 1.5748 * Cr;
    float g = Y - 0.1873 * Cb - 0.4681 * Cr;
    float b = Y + 1.8556 * Cb;
    return saturate(float3(r, g, b));
}

fragment float4 robzFragment(VertexOut in [[stage_in]],
                             texture2d<float, access::sample> yTex [[texture(0)]],
                             texture2d<float, access::sample> uvTex [[texture(1)]],
                             constant CasParams &cas [[buffer(0)]]) {
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
    float3 c = nv12SampleBT709(yTex, uvTex, s, in.uv);
    if (cas.sharpness > 0.001) {
        float2 d = float2(cas.tx, cas.ty);
        float3 n = nv12SampleBT709(yTex, uvTex, s, in.uv + float2(0.0, -d.y));
        float3 so = nv12SampleBT709(yTex, uvTex, s, in.uv + float2(0.0, d.y));
        float3 w = nv12SampleBT709(yTex, uvTex, s, in.uv + float2(-d.x, 0.0));
        float3 e = nv12SampleBT709(yTex, uvTex, s, in.uv + float2(d.x, 0.0));
        float3 minRGB = min(c, min(min(n, so), min(w, e)));
        float3 maxRGB = max(c, max(max(n, so), max(w, e)));
        float3 amp = saturate(min(minRGB, 1.0 - maxRGB) / max(maxRGB, float3(1e-4)));
        float3 weight = -sqrt(amp) * mix(0.125, 0.2, cas.sharpness);
        c = saturate((c + (n + so + w + e) * weight) / (1.0 + 4.0 * weight));
    }
    return float4(c, 1.0);
}
)MSL";

struct Nv12OwnedFrame
{
	int width = 0;
	int height = 0;
	std::vector<uint8_t> y;
	std::vector<uint8_t> uv;

	void allocate(int w, int h)
	{
		if(width == w && height == h && y.size() == (size_t)w * h && uv.size() == (size_t)w * (h / 2))
			return;
		width = w;
		height = h;
		y.resize((size_t)w * h);
		uv.resize((size_t)w * (h / 2));
	}

	robzfg::Nv12View view() const
	{
		robzfg::Nv12View v{};
		v.y = y.data();
		v.uv = uv.data();
		v.width = width;
		v.height = height;
		v.y_stride = width;
		v.uv_stride = width;
		return v;
	}

	robzfg::Nv12Mut mutView()
	{
		robzfg::Nv12Mut m{};
		m.y = y.data();
		m.uv = uv.data();
		m.width = width;
		m.height = height;
		m.y_stride = width;
		m.uv_stride = width;
		return m;
	}
};

// Generates a 1280x720 or 1920x1080 30 FPS NV12 moving game-like test frame + static HUD overlay
static void fillSyntheticGameFrame(Nv12OwnedFrame &frame, int w, int h, int frameIndex)
{
	frame.allocate(w, h);
	const float phase = frameIndex * 0.085f;
	const int objX = (int)((0.5f + 0.34f * std::sin(phase)) * w);
	const int objY = (int)((0.52f + 0.22f * std::cos(phase * 0.8f)) * h);
	const int obj2X = (int)((0.5f - 0.30f * std::cos(phase * 1.15f)) * w);
	const int obj2Y = (int)((0.45f + 0.25f * std::sin(phase * 0.9f)) * h);
	const int scrollX = (frameIndex * 18) % 96;

	for(int y = 0; y < h; y++)
	{
		uint8_t *yRow = frame.y.data() + (size_t)y * w;
		const bool isHudBar = (y < 44 || y > h - 52);
		for(int x = 0; x < w; x++)
		{
			if(isHudBar)
			{
				// Static HUD bar (tests protect_static)
				bool tick = ((x % 64) < 3) && (y > 12 && y < 32);
				yRow[x] = tick ? 220 : 28;
				continue;
			}
			int bg = 36 + ((y * 70) / h);
			if(((x + scrollX) % 96) < 3 || ((y + (scrollX / 2)) % 96) < 3)
				bg += 34;

			int dx1 = x - objX;
			int dy1 = y - objY;
			if(dx1 * dx1 + dy1 * dy1 < (h / 9) * (h / 9))
			{
				bg = 218 - ((dx1 * dx1 + dy1 * dy1) * 90) / ((h / 9) * (h / 9));
			}
			else if(std::abs(x - obj2X) < (w / 14) && std::abs(y - obj2Y) < (h / 10))
			{
				bool border = (std::abs(x - obj2X) > (w / 14) - 6) || (std::abs(y - obj2Y) > (h / 10) - 6);
				bg = border ? 235 : 145;
			}
			yRow[x] = (uint8_t)std::clamp(bg, 16, 235);
		}
	}

	for(int cy = 0; cy < h / 2; cy++)
	{
		uint8_t *uvRow = frame.uv.data() + (size_t)cy * w;
		const int y = cy * 2;
		const bool isHudBar = (y < 44 || y > h - 52);
		for(int cx = 0; cx < w / 2; cx++)
		{
			const int x = cx * 2;
			uint8_t cb = 128;
			uint8_t cr = 128;
			if(!isHudBar)
			{
				int dx1 = x - objX;
				int dy1 = y - objY;
				if(dx1 * dx1 + dy1 * dy1 < (h / 9) * (h / 9))
				{
					cb = 92;
					cr = 188; // warm Robz orange accent (#E4845E)
				}
				else if(std::abs(x - obj2X) < (w / 14) && std::abs(y - obj2Y) < (h / 10))
				{
					cb = 165;
					cr = 104; // cool cyan/green accent
				}
			}
			uvRow[cx * 2 + 0] = cb;
			uvRow[cx * 2 + 1] = cr;
		}
	}
}

struct DiscoveredHostItem
{
	std::string hostAddr;
	std::string hostName;
	std::string hostId;
	bool isPS5 = true;
	bool isReady = false;
};

} // namespace

// ============================================================================
// User-accessible file log (Documents/robzplay.log)
// - visible in the Files app (On My iPhone -> Robz Play) via UIFileSharingEnabled
// - viewable / shareable in-app via the top-bar "Log" button
// - captures chiaki-lib logs, stdout/stderr and crash backtraces
// ============================================================================

namespace
{

static std::mutex g_logMutex;
static NSString *g_logPath = nil;
static NSString *g_logPrevPath = nil;
static char g_logPathC[1024] = {0}; // async-signal-safe copy for the crash handler
static int g_origStdoutFd = -1;
static int g_origStderrFd = -1;
static const unsigned long long kLogMaxBytes = 2ULL * 1024ULL * 1024ULL;
static const NSUInteger kLogViewerMaxBytes = 256 * 1024;

static NSString *robzLogFilePath() { return g_logPath; }
static NSString *robzLogPrevFilePath() { return g_logPrevPath; }

// Caller must hold g_logMutex.
static void robzLogAppendLocked(NSString *text)
{
	if(!g_logPath || text.length == 0)
		return;
	NSFileManager *fm = [NSFileManager defaultManager];
	NSDictionary *attrs = [fm attributesOfItemAtPath:g_logPath error:nil];
	if(attrs && attrs.fileSize > kLogMaxBytes)
	{
		[fm removeItemAtPath:g_logPrevPath error:nil];
		[fm moveItemAtPath:g_logPath toPath:g_logPrevPath error:nil];
	}
	if(![fm fileExistsAtPath:g_logPath])
		[fm createFileAtPath:g_logPath contents:nil attributes:nil];
	NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:g_logPath];
	if(!fh)
		return;
	[fh seekToEndOfFile];
	[fh writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
	[fh closeFile];
}

static void robzLogLine(NSString *msg)
{
	if(!msg)
		return;
	static NSDateFormatter *fmt = nil;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		fmt = [[NSDateFormatter alloc] init];
		fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
		fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
	});
	std::lock_guard<std::mutex> lock(g_logMutex);
	NSString *line = [NSString stringWithFormat:@"%@ %@\n", [fmt stringFromDate:[NSDate date]], msg];
	robzLogAppendLocked(line);
	// Echo to the original stderr (Xcode console) without re-entering the pipe capture.
	if(g_origStderrFd >= 0)
		dprintf(g_origStderrFd, "%s", line.UTF8String);
}

// ---- stdout / stderr capture (printf, NSLog, library diagnostics) ----

struct RobzStdioTee
{
	int readFd;
	int origFd;
};

static void *robzStdioTeeMain(void *arg)
{
	RobzStdioTee *tee = (RobzStdioTee *)arg;
	char buf[4096];
	ssize_t n;
	while((n = read(tee->readFd, buf, sizeof(buf))) > 0)
	{
		write(tee->origFd, buf, (size_t)n);
		@autoreleasepool {
			NSString *s = [[NSString alloc] initWithBytes:buf length:(NSUInteger)n encoding:NSUTF8StringEncoding];
			if(s)
			{
				std::lock_guard<std::mutex> lock(g_logMutex);
				robzLogAppendLocked(s);
			}
		}
	}
	delete tee;
	return nullptr;
}

static void robzCaptureFd(int fd, int *origOut)
{
	int fds[2];
	if(pipe(fds) != 0)
		return;
	int orig = dup(fd);
	if(orig < 0)
	{
		close(fds[0]);
		close(fds[1]);
		return;
	}
	dup2(fds[1], fd);
	close(fds[1]);
	*origOut = orig;
	RobzStdioTee *tee = new RobzStdioTee{ fds[0], orig };
	pthread_t thread;
	if(pthread_create(&thread, nullptr, robzStdioTeeMain, tee) == 0)
		pthread_detach(thread);
	else
		delete tee;
}

// ---- Crash capture (best effort, async-signal-safe file writes) ----

static void robzSignalHandler(int sig)
{
	const char *name = "UNKNOWN";
	switch(sig)
	{
		case SIGSEGV: name = "SIGSEGV"; break;
		case SIGABRT: name = "SIGABRT"; break;
		case SIGBUS:  name = "SIGBUS";  break;
		case SIGILL:  name = "SIGILL";  break;
		case SIGFPE:  name = "SIGFPE";  break;
		case SIGTRAP: name = "SIGTRAP"; break;
	}
	if(g_logPathC[0])
	{
		int fd = open(g_logPathC, O_WRONLY | O_APPEND | O_CREAT, 0644);
		if(fd >= 0)
		{
			static const char hdr[] = "\n!!! CRASH: signal ";
			static const char mid[] = " !!!\n";
			write(fd, hdr, sizeof(hdr) - 1);
			write(fd, name, strlen(name));
			write(fd, mid, sizeof(mid) - 1);
			void *bt[64];
			int n = backtrace(bt, 64);
			backtrace_symbols_fd(bt, n, fd);
			close(fd);
		}
	}
	signal(sig, SIG_DFL);
	raise(sig);
}

static void robzUncaughtExceptionHandler(NSException *exception)
{
	NSString *msg = [NSString stringWithFormat:@"!!! UNCAUGHT EXCEPTION: %@ — %@\n%@",
		exception.name, exception.reason,
		[exception.callStackSymbols componentsJoinedByString:@"\n"]];
	std::lock_guard<std::mutex> lock(g_logMutex);
	robzLogAppendLocked(msg);
}

static void robzInitLogging()
{
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
		[[NSFileManager defaultManager] createDirectoryAtPath:docs withIntermediateDirectories:YES attributes:nil error:nil];
		g_logPath = [docs stringByAppendingPathComponent:@"robzplay.log"];
		g_logPrevPath = [docs stringByAppendingPathComponent:@"robzplay-prev.log"];
		strlcpy(g_logPathC, g_logPath.fileSystemRepresentation, sizeof(g_logPathC));

		robzCaptureFd(STDOUT_FILENO, &g_origStdoutFd);
		robzCaptureFd(STDERR_FILENO, &g_origStderrFd);
		setvbuf(stdout, nullptr, _IOLBF, 0);

		NSSetUncaughtExceptionHandler(&robzUncaughtExceptionHandler);
		signal(SIGSEGV, robzSignalHandler);
		signal(SIGABRT, robzSignalHandler);
		signal(SIGBUS, robzSignalHandler);
		signal(SIGILL, robzSignalHandler);
		signal(SIGFPE, robzSignalHandler);
		signal(SIGTRAP, robzSignalHandler);

		UIDevice *dev = [UIDevice currentDevice];
		NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"?";
		robzLogLine([NSString stringWithFormat:@"=== Robz Play %@ launched · %@ · iOS %@ · screen %.0fx%.0f @%.0fx ===",
			version, dev.model, dev.systemVersion,
			UIScreen.mainScreen.bounds.size.width, UIScreen.mainScreen.bounds.size.height,
			UIScreen.mainScreen.scale]);
	});
}

// chiaki-lib log sink -> timestamped lines in robzplay.log
static void iosChiakiLogCb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	robzLogLine([NSString stringWithFormat:@"[chiaki:%c] %s", chiaki_log_level_char(level), msg ? msg : ""]);
}

} // namespace

// ============================================================================
// In-app Log Viewer (view / share / clear)
// ============================================================================

@interface RobzLogViewController : UIViewController
@end

@implementation RobzLogViewController
{
	UITextView *_textView;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.title = @"Robz Play Log";
	self.navigationItem.prompt = @"Files → On My iPhone → Robz Play · or tap „Save to Files…“";
	self.view.backgroundColor = [UIColor colorWithRed:0.067 green:0.067 blue:0.063 alpha:1.0];

	self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
																						  target:self action:@selector(onDone)];
	UIBarButtonItem *shareItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemAction
																			   target:self action:@selector(onShare:)];
	UIBarButtonItem *refreshItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
																				 target:self action:@selector(onRefresh)];
	self.navigationItem.rightBarButtonItems = @[shareItem, refreshItem];

	UIBarButtonItem *exportItem = [[UIBarButtonItem alloc] initWithTitle:@"Save to Files…" style:UIBarButtonItemStylePlain
																  target:self action:@selector(onExport)];
	UIBarButtonItem *clearItem = [[UIBarButtonItem alloc] initWithTitle:@"Clear Log" style:UIBarButtonItemStylePlain
																 target:self action:@selector(onClear)];
	clearItem.tintColor = [UIColor systemRedColor];
	UIBarButtonItem *flex = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil];
	self.toolbarItems = @[flex, exportItem, flex, clearItem, flex];
	self.navigationController.toolbarHidden = NO;

	_textView = [[UITextView alloc] initWithFrame:self.view.bounds];
	_textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_textView.editable = NO;
	_textView.backgroundColor = [UIColor clearColor];
	_textView.textColor = [UIColor colorWithWhite:0.85 alpha:1.0];
	_textView.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
	_textView.alwaysBounceVertical = YES;
	[self.view addSubview:_textView];

	[self onRefresh];
}

- (void)onDone
{
	[self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onRefresh
{
	NSData *data = [NSData dataWithContentsOfFile:robzLogFilePath()];
	NSString *text = nil;
	if(data)
	{
		NSUInteger offset = 0;
		if(data.length > kLogViewerMaxBytes)
		{
			offset = data.length - kLogViewerMaxBytes;
			const uint8_t *bytes = (const uint8_t *)data.bytes;
			while(offset < data.length && bytes[offset] != '\n')
				offset++;
			if(offset < data.length)
				offset++;
		}
		text = [[NSString alloc] initWithBytes:(const uint8_t *)data.bytes + offset
										length:data.length - offset
									  encoding:NSUTF8StringEncoding];
		if(offset > 0)
			text = [NSString stringWithFormat:@"… (showing last %lu KB of the log — share for the full file)\n%@",
				(unsigned long)(kLogViewerMaxBytes / 1024), text ?: @""];
	}
	_textView.text = text.length > 0 ? text : @"(log is empty)";
	if(_textView.text.length > 0)
		[_textView scrollRangeToVisible:NSMakeRange(_textView.text.length - 1, 1)];
}

- (void)onShare:(UIBarButtonItem *)sender
{
	NSString *path = robzLogFilePath();
	if(!path || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return;
	UIActivityViewController *activity = [[UIActivityViewController alloc]
		initWithActivityItems:@[[NSURL fileURLWithPath:path]] applicationActivities:nil];
	activity.popoverPresentationController.barButtonItem = sender;
	[self presentViewController:activity animated:YES completion:nil];
}

- (void)onExport
{
	NSString *path = robzLogFilePath();
	if(!path || ![[NSFileManager defaultManager] fileExistsAtPath:path])
		return;
	// Explicit export works even when the app's Documents folder is not visible
	// under "On My iPhone" in the Files app (sideloader / cache quirks).
	UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc]
		initForExportingURLs:@[[NSURL fileURLWithPath:path]] asCopy:YES];
	[self presentViewController:picker animated:YES completion:nil];
}

- (void)onClear
{
	NSFileManager *fm = [NSFileManager defaultManager];
	[fm removeItemAtPath:robzLogFilePath() error:nil];
	[fm removeItemAtPath:robzLogPrevFilePath() error:nil];
	robzLogLine(@"Log cleared by user");
	[self onRefresh];
}

@end

// ============================================================================
// Main View Controller
// ============================================================================

@interface RobzPlayViewController : UIViewController <MTKViewDelegate>
@end

@implementation RobzPlayViewController
{
	id<MTLDevice> _device;
	id<MTLCommandQueue> _commandQueue;
	id<MTLRenderPipelineState> _renderPSO;
	id<MTLTexture> _yTexture;
	id<MTLTexture> _uvTexture;
	int _texWidth;
	int _texHeight;

	MTKView *_mtkView;
	UILabel *_telemetryLabel;
	UILabel *_statusLabel;
	UISegmentedControl *_modeSegment;
	UISegmentedControl *_modelSegment;
	UISegmentedControl *_flowSegment;
	UIButton *_selfTestBtn;
	UIButton *_connectBtn;
	UIButton *_registerBtn;
	UIButton *_touchPadToggleBtn;
	UITextField *_ipField;
	UITextField *_registKeyField;
	UITextField *_morningField;
	UIView *_controlPanel;
	UIView *_touchOverlay;

	std::unique_ptr<robzfg::MetalRifeBackend> _rife;
	robzfg::DuplicateDetector _dedup;
	dispatch_queue_t _rifeQueue;
	std::atomic<bool> _rifeBusy;
	bool _rifeReady;
	bool _frameGenEnabled;
	int _flowDivisor;
	std::string _selectedModelName;

	// Live FrameGen pipeline state
	std::mutex _frameMutex;
	Nv12OwnedFrame _realFrame;
	Nv12OwnedFrame _interpFrame;
	Nv12OwnedFrame _displayFrame;
	bool _hasRealFrame;
	bool _hasInterpFrame;
	bool _showInterpNext;
	double _lastInterpMs;
	double _smoothedInterpMs;
	int _outputFramesCount;
	std::chrono::steady_clock::time_point _fpsWindowStart;
	double _currentOutputFps;

	// Self-test 30->60 FPS generator
	bool _selfTestRunning;
	NSTimer *_selfTestTimer;
	int _selfTestFrameIdx;

	// Chiaki Remote Play state
	ChiakiLog _chiakiLog;
	ChiakiDiscoveryService _discoveryService;
	bool _discoveryRunning;
	std::mutex _hostsMutex;
	std::vector<DiscoveredHostItem> _discoveredHosts;

	ChiakiSession _session;
	bool _sessionActive;
	ChiakiControllerState _controllerState;

	// Hardware VideoToolbox H.265 / H.264 decoder
	VTDecompressionSessionRef _vtSession;
	CMVideoFormatDescriptionRef _vtFormatDesc;
	std::vector<uint8_t> _vps;
	std::vector<uint8_t> _sps;
	std::vector<uint8_t> _pps;
}

- (void)viewDidLoad
{
	[super viewDidLoad];
	self.view.backgroundColor = [UIColor colorWithRed:0.067 green:0.067 blue:0.063 alpha:1.0]; // #111110

	_device = MTLCreateSystemDefaultDevice();
	_commandQueue = [_device newCommandQueue];
	_rifeQueue = dispatch_queue_create("com.robzplay.ios.rife", DISPATCH_QUEUE_SERIAL);
	_frameGenEnabled = true;
	_flowDivisor = 3; // Auto on Apple Silicon (1/3 scale)
	_selectedModelName = "rife_v4_6";
	_fpsWindowStart = std::chrono::steady_clock::now();
	chiaki_controller_state_set_idle(&_controllerState);
	chiaki_log_init(&_chiakiLog, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, iosChiakiLogCb, NULL);
	robzLogLine([NSString stringWithFormat:@"Metal device: %s", _device ? _device.name.UTF8String : "(none)"]);

	[self setupMetalPipeline];
	[self setupUI];
	[self reloadRifeBackend];
	[self setupGameControllers];

	// Start with an initial synthetic frame so viewport is immediately populated
	fillSyntheticGameFrame(_displayFrame, 1280, 720, 0);
	[self uploadFrameToTextures:_displayFrame];
}

- (void)setupMetalPipeline
{
	if(!_device)
		return;
	NSError *err = nil;
	NSString *src = [NSString stringWithUTF8String:kIosDisplayShaderSource];
	id<MTLLibrary> lib = [_device newLibraryWithSource:src options:nil error:&err];
	if(!lib)
		return;
	MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
	desc.vertexFunction = [lib newFunctionWithName:@"robzVertex"];
	desc.fragmentFunction = [lib newFunctionWithName:@"robzFragment"];
	desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
	_renderPSO = [_device newRenderPipelineStateWithDescriptor:desc error:&err];
}

- (std::string)modelPathForName:(const std::string &)name
{
	NSString *bundlePath = [[NSBundle mainBundle] resourcePath];
	NSString *candidate = [bundlePath stringByAppendingPathComponent:
		[NSString stringWithFormat:@"models/%s", name.c_str()]];
	return std::string(candidate.UTF8String);
}

- (void)reloadRifeBackend
{
	std::lock_guard<std::mutex> lock(_frameMutex);
	_rife.reset(new robzfg::MetalRifeBackend());
	_rifeReady = false;
	_hasInterpFrame = false;

	robzfg::RifeInterpolator::Config cfg{};
	cfg.model_dir = [self modelPathForName:_selectedModelName];
	cfg.flow_divisor = _flowDivisor;
	cfg.protect_static = true;
	cfg.sharp_sampling = true;

	std::string err;
	if(_rife->init(cfg, &err))
	{
		_rifeReady = true;
		_statusLabel.text = [NSString stringWithFormat:@"GPU Ready: %s · Model: %s (1/%d flow)",
			_rife->gpuName().c_str(), _selectedModelName.c_str(), _flowDivisor];
		robzLogLine([NSString stringWithFormat:@"RIFE ready: %s · model %s · flow 1/%d",
			_rife->gpuName().c_str(), _selectedModelName.c_str(), _flowDivisor]);
	}
	else
	{
		_statusLabel.text = [NSString stringWithFormat:@"RIFE init error: %s", err.c_str()];
		robzLogLine([NSString stringWithFormat:@"RIFE INIT ERROR (model %s): %s",
			_selectedModelName.c_str(), err.c_str()]);
	}
}

- (void)setupUI
{
	// 1. Metal Viewport (full screen background)
	_mtkView = [[MTKView alloc] initWithFrame:self.view.bounds device:_device];
	_mtkView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_mtkView.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
	_mtkView.preferredFramesPerSecond = 60;
	_mtkView.paused = NO;
	_mtkView.enableSetNeedsDisplay = NO;
	_mtkView.delegate = self;
	[self.view addSubview:_mtkView];

	// 2. Top Telemetry & Status HUD Bar
	UIView *topBar = [[UIView alloc] initWithFrame:CGRectMake(16, 16, self.view.bounds.size.width - 32, 62)];
	topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleBottomMargin;
	topBar.backgroundColor = [UIColor colorWithRed:0.08 green:0.08 blue:0.075 alpha:0.86];
	topBar.layer.cornerRadius = 14.0;
	topBar.layer.borderWidth = 1.0;
	topBar.layer.borderColor = [UIColor colorWithRed:0.894 green:0.518 blue:0.369 alpha:0.45].CGColor;
	[self.view addSubview:topBar];

	_telemetryLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, topBar.bounds.size.width - 206, 24)];
	_telemetryLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_telemetryLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightBold];
	_telemetryLabel.textColor = [UIColor colorWithRed:0.894 green:0.518 blue:0.369 alpha:1.0]; // #E4845E
	_telemetryLabel.text = @"ROBZ PLAY iOS · 30 → 60 FPS GPU FRAMEGEN";
	[topBar addSubview:_telemetryLabel];

	_statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(14, 32, topBar.bounds.size.width - 206, 20)];
	_statusLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
	_statusLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
	_statusLabel.textColor = [UIColor colorWithWhite:0.78 alpha:1.0];
	_statusLabel.text = @"Initializing Apple Metal + MPSGraph...";
	[topBar addSubview:_statusLabel];

	UIButton *logBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	logBtn.frame = CGRectMake(topBar.bounds.size.width - 190, 13, 64, 36);
	logBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	logBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.21 blue:0.20 alpha:1.0];
	logBtn.layer.cornerRadius = 8.0;
	[logBtn setTitle:@"Log" forState:UIControlStateNormal];
	[logBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	logBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	[logBtn addTarget:self action:@selector(onShowLog) forControlEvents:UIControlEventTouchUpInside];
	[topBar addSubview:logBtn];

	UIButton *togglePanelBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	togglePanelBtn.frame = CGRectMake(topBar.bounds.size.width - 118, 13, 104, 36);
	togglePanelBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
	togglePanelBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.21 blue:0.20 alpha:1.0];
	togglePanelBtn.layer.cornerRadius = 8.0;
	[togglePanelBtn setTitle:@"Menu / HUD" forState:UIControlStateNormal];
	[togglePanelBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	togglePanelBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	[togglePanelBtn addTarget:self action:@selector(onToggleControlPanel) forControlEvents:UIControlEventTouchUpInside];
	[topBar addSubview:togglePanelBtn];

	// 3. Control & Connection Card
	CGFloat panelW = std::min((CGFloat)480.0, self.view.bounds.size.width - 32);
	_controlPanel = [[UIView alloc] initWithFrame:CGRectMake(16, 88, panelW, 340)];
	_controlPanel.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
	_controlPanel.backgroundColor = [UIColor colorWithRed:0.09 green:0.09 blue:0.085 alpha:0.92];
	_controlPanel.layer.cornerRadius = 16.0;
	_controlPanel.layer.borderWidth = 1.0;
	_controlPanel.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
	[self.view addSubview:_controlPanel];

	// FrameGen Mode Segment
	_modeSegment = [[UISegmentedControl alloc] initWithItems:@[@"60 FPS FrameGen", @"Stream Only (30)"]];
	_modeSegment.frame = CGRectMake(14, 14, panelW - 28, 32);
	_modeSegment.selectedSegmentIndex = 0;
	[_modeSegment addTarget:self action:@selector(onConfigChanged) forControlEvents:UIControlEventValueChanged];
	[_controlPanel addSubview:_modeSegment];

	// RIFE Model Segment
	_modelSegment = [[UISegmentedControl alloc] initWithItems:@[@"RIFE v4.6 (Fast)", @"RIFE v4.25-lite (Crisp)"]];
	_modelSegment.frame = CGRectMake(14, 54, panelW - 28, 32);
	_modelSegment.selectedSegmentIndex = 0;
	[_modelSegment addTarget:self action:@selector(onConfigChanged) forControlEvents:UIControlEventValueChanged];
	[_controlPanel addSubview:_modelSegment];

	// Flow Divisor Segment
	_flowSegment = [[UISegmentedControl alloc] initWithItems:@[@"Auto (1/3)", @"Low (1/4)", @"Balanced (1/2)"]];
	_flowSegment.frame = CGRectMake(14, 94, panelW - 28, 32);
	_flowSegment.selectedSegmentIndex = 0;
	[_flowSegment addTarget:self action:@selector(onConfigChanged) forControlEvents:UIControlEventValueChanged];
	[_controlPanel addSubview:_flowSegment];

	// Live 30->60 FPS Self-Test Benchmark Button
	_selfTestBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_selfTestBtn.frame = CGRectMake(14, 136, panelW - 28, 40);
	_selfTestBtn.backgroundColor = [UIColor colorWithRed:0.894 green:0.518 blue:0.369 alpha:1.0];
	_selfTestBtn.layer.cornerRadius = 10.0;
	[_selfTestBtn setTitle:@"▶ Start 30 → 60 FPS GPU FrameGen Live Test" forState:UIControlStateNormal];
	[_selfTestBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	_selfTestBtn.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightBold];
	[_selfTestBtn addTarget:self action:@selector(onToggleSelfTest) forControlEvents:UIControlEventTouchUpInside];
	[_controlPanel addSubview:_selfTestBtn];

	// PS5 / PS4 Console IP + Credentials fields
	_ipField = [self makeTextFieldWithFrame:CGRectMake(14, 186, (panelW - 36) * 0.55, 36)
								placeholder:@"PS5 / PS4 IP (e.g. 192.168.1.50)"];
	[_controlPanel addSubview:_ipField];

	_registKeyField = [self makeTextFieldWithFrame:CGRectMake(22 + (panelW - 36) * 0.55, 186, (panelW - 36) * 0.45, 36)
									   placeholder:@"Regist Key (hex)"];
	[_controlPanel addSubview:_registKeyField];

	_morningField = [self makeTextFieldWithFrame:CGRectMake(14, 228, panelW - 28, 36)
									 placeholder:@"RP-Key / Morning (Base64 from paired console)"];
	[_controlPanel addSubview:_morningField];

	// Load saved console fields
	NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
	if([defs stringForKey:@"ps_ip"]) _ipField.text = [defs stringForKey:@"ps_ip"];
	if([defs stringForKey:@"ps_regist_key"]) _registKeyField.text = [defs stringForKey:@"ps_regist_key"];
	if([defs stringForKey:@"ps_morning"]) _morningField.text = [defs stringForKey:@"ps_morning"];

	CGFloat btnW = (panelW - 44) / 3.0;
	_connectBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_connectBtn.frame = CGRectMake(14, 276, btnW, 42);
	_connectBtn.backgroundColor = [UIColor colorWithRed:0.553 green:0.710 blue:0.502 alpha:1.0]; // #8DB580
	_connectBtn.layer.cornerRadius = 10.0;
	[_connectBtn setTitle:@"Connect PS5" forState:UIControlStateNormal];
	[_connectBtn setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
	_connectBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightBold];
	[_connectBtn addTarget:self action:@selector(onConnectConsole) forControlEvents:UIControlEventTouchUpInside];
	[_controlPanel addSubview:_connectBtn];

	_registerBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_registerBtn.frame = CGRectMake(22 + btnW, 276, btnW, 42);
	_registerBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.21 blue:0.20 alpha:1.0];
	_registerBtn.layer.cornerRadius = 10.0;
	[_registerBtn setTitle:@"Pair with PIN" forState:UIControlStateNormal];
	[_registerBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_registerBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	[_registerBtn addTarget:self action:@selector(onPairConsoleDialog) forControlEvents:UIControlEventTouchUpInside];
	[_controlPanel addSubview:_registerBtn];

	_touchPadToggleBtn = [UIButton buttonWithType:UIButtonTypeSystem];
	_touchPadToggleBtn.frame = CGRectMake(30 + btnW * 2, 276, btnW, 42);
	_touchPadToggleBtn.backgroundColor = [UIColor colorWithRed:0.22 green:0.21 blue:0.20 alpha:1.0];
	_touchPadToggleBtn.layer.cornerRadius = 10.0;
	[_touchPadToggleBtn setTitle:@"Touch Pad" forState:UIControlStateNormal];
	[_touchPadToggleBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	_touchPadToggleBtn.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
	[_touchPadToggleBtn addTarget:self action:@selector(onToggleTouchOverlay) forControlEvents:UIControlEventTouchUpInside];
	[_controlPanel addSubview:_touchPadToggleBtn];

	[self setupTouchControllerOverlay];
}

- (UITextField *)makeTextFieldWithFrame:(CGRect)frame placeholder:(NSString *)placeholder
{
	UITextField *tf = [[UITextField alloc] initWithFrame:frame];
	tf.backgroundColor = [UIColor colorWithWhite:0.15 alpha:1.0];
	tf.textColor = [UIColor whiteColor];
	tf.font = [UIFont systemFontOfSize:13];
	tf.layer.cornerRadius = 8.0;
	tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
	tf.leftViewMode = UITextFieldViewModeAlways;
	tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:placeholder
		attributes:@{NSForegroundColorAttributeName: [UIColor colorWithWhite:0.55 alpha:1.0]}];
	tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
	tf.autocorrectionType = UITextAutocorrectionTypeNo;
	return tf;
}

- (void)setupTouchControllerOverlay
{
	_touchOverlay = [[UIView alloc] initWithFrame:self.view.bounds];
	_touchOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_touchOverlay.userInteractionEnabled = YES;
	_touchOverlay.hidden = YES;
	[self.view insertSubview:_touchOverlay belowSubview:_controlPanel];

	// Left D-Pad cluster
	[self addPadButton:@"▲" mask:CHIAKI_CONTROLLER_BUTTON_DPAD_UP    frame:CGRectMake(74, self.view.bounds.size.height - 170, 52, 52) left:YES];
	[self addPadButton:@"▼" mask:CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN  frame:CGRectMake(74, self.view.bounds.size.height - 74,  52, 52) left:YES];
	[self addPadButton:@"◀" mask:CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT  frame:CGRectMake(22, self.view.bounds.size.height - 122, 52, 52) left:YES];
	[self addPadButton:@"▶" mask:CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT frame:CGRectMake(126, self.view.bounds.size.height - 122, 52, 52) left:YES];
	[self addPadButton:@"L1" mask:CHIAKI_CONTROLLER_BUTTON_L1        frame:CGRectMake(24, self.view.bounds.size.height - 235, 72, 42) left:YES];

	// Right Action buttons (△ ○ ✕ □)
	CGFloat rx = self.view.bounds.size.width - 126;
	[self addPadButton:@"△" mask:CHIAKI_CONTROLLER_BUTTON_PYRAMID frame:CGRectMake(rx, self.view.bounds.size.height - 170, 52, 52) left:NO];
	[self addPadButton:@"✕" mask:CHIAKI_CONTROLLER_BUTTON_CROSS   frame:CGRectMake(rx, self.view.bounds.size.height - 74,  52, 52) left:NO];
	[self addPadButton:@"□" mask:CHIAKI_CONTROLLER_BUTTON_BOX     frame:CGRectMake(rx - 52, self.view.bounds.size.height - 122, 52, 52) left:NO];
	[self addPadButton:@"○" mask:CHIAKI_CONTROLLER_BUTTON_MOON    frame:CGRectMake(rx + 52, self.view.bounds.size.height - 122, 52, 52) left:NO];
	[self addPadButton:@"R1" mask:CHIAKI_CONTROLLER_BUTTON_R1     frame:CGRectMake(self.view.bounds.size.width - 96, self.view.bounds.size.height - 235, 72, 42) left:NO];
}

- (void)addPadButton:(NSString *)title mask:(uint32_t)mask frame:(CGRect)frame left:(BOOL)isLeft
{
	UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
	b.frame = frame;
	b.autoresizingMask = UIViewAutoresizingFlexibleTopMargin | (isLeft ? UIViewAutoresizingFlexibleRightMargin : UIViewAutoresizingFlexibleLeftMargin);
	b.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.65];
	b.layer.cornerRadius = frame.size.height * 0.5;
	b.layer.borderWidth = 1.2;
	b.layer.borderColor = [UIColor colorWithRed:0.894 green:0.518 blue:0.369 alpha:0.65].CGColor;
	[b setTitle:title forState:UIControlStateNormal];
	[b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
	b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightBold];
	b.tag = (NSInteger)mask;
	[b addTarget:self action:@selector(onVirtualButtonDown:) forControlEvents:UIControlEventTouchDown];
	[b addTarget:self action:@selector(onVirtualButtonUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
	[_touchOverlay addSubview:b];
}

- (void)onVirtualButtonDown:(UIButton *)sender
{
	_controllerState.buttons |= (uint32_t)sender.tag;
	if(_sessionActive)
		chiaki_session_set_controller_state(&_session, &_controllerState);
}

- (void)onVirtualButtonUp:(UIButton *)sender
{
	_controllerState.buttons &= ~(uint32_t)sender.tag;
	if(_sessionActive)
		chiaki_session_set_controller_state(&_session, &_controllerState);
}

- (void)onToggleControlPanel
{
	[self.view endEditing:YES];
	_controlPanel.hidden = !_controlPanel.hidden;
}

- (void)onShowLog
{
	[self.view endEditing:YES];
	RobzLogViewController *logVC = [[RobzLogViewController alloc] init];
	UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:logVC];
	nav.modalPresentationStyle = UIModalPresentationFullScreen;
	nav.navigationBar.barStyle = UIBarStyleBlack;
	nav.navigationBar.translucent = NO;
	nav.toolbar.barStyle = UIBarStyleBlack;
	nav.toolbar.translucent = NO;
	[self presentViewController:nav animated:YES completion:nil];
}

- (void)onToggleTouchOverlay
{
	_touchOverlay.hidden = !_touchOverlay.hidden;
}

- (void)onConfigChanged
{
	_frameGenEnabled = (_modeSegment.selectedSegmentIndex == 0);
	std::string newModel = (_modelSegment.selectedSegmentIndex == 0) ? "rife_v4_6" : "rife_v4_25_lite";
	int newDiv = 3;
	if(_flowSegment.selectedSegmentIndex == 1) newDiv = 4;
	else if(_flowSegment.selectedSegmentIndex == 2) newDiv = 2;

	robzLogLine([NSString stringWithFormat:@"Config changed: framegen=%d model=%s flow=1/%d",
		(int)_frameGenEnabled, newModel.c_str(), newDiv]);

	if(newModel != _selectedModelName)
	{
		_selectedModelName = newModel;
		_flowDivisor = newDiv;
		dispatch_async(_rifeQueue, ^{
			@autoreleasepool {
				[self reloadRifeBackend];
			}
		});
	}
	else if(newDiv != _flowDivisor)
	{
		_flowDivisor = newDiv;
		dispatch_async(_rifeQueue, ^{
			@autoreleasepool {
				std::lock_guard<std::mutex> lock(self->_frameMutex);
				if(self->_rife)
					self->_rife->setFlowDivisor(self->_flowDivisor);
			}
		});
		_statusLabel.text = [NSString stringWithFormat:@"GPU Ready: %s · Model: %s (1/%d flow)",
			_rife ? _rife->gpuName().c_str() : "Metal", _selectedModelName.c_str(), _flowDivisor];
	}
}

// ============================================================================
// Live 30 -> 60 FPS GPU Self-Test Benchmark
// ============================================================================

- (void)onToggleSelfTest
{
	if(_selfTestRunning)
	{
		[_selfTestTimer invalidate];
		_selfTestTimer = nil;
		_selfTestRunning = false;
		[_selfTestBtn setTitle:@"▶ Start 30 → 60 FPS GPU FrameGen Live Test" forState:UIControlStateNormal];
		robzLogLine(@"Self-test stopped");
		return;
	}

	robzLogLine(@"Self-test started (synthetic 30 FPS source)");
	_selfTestRunning = true;
	_selfTestFrameIdx = 0;
	[_selfTestBtn setTitle:@"■ Stop 30 → 60 FPS GPU FrameGen Live Test" forState:UIControlStateNormal];

	// Push 30 FPS source frames (every 33.33 ms)
	_selfTestTimer = [NSTimer scheduledTimerWithTimeInterval:(1.0 / 30.0)
													  target:self
													selector:@selector(onSelfTestTick)
													userInfo:nil
													 repeats:YES];
}

- (void)onSelfTestTick
{
	Nv12OwnedFrame src;
	fillSyntheticGameFrame(src, 1280, 720, _selfTestFrameIdx++);
	[self ingestSourceFrame:src];
}

- (void)ingestSourceFrame:(const Nv12OwnedFrame &)src
{
	{
		std::lock_guard<std::mutex> lock(_frameMutex);
		_realFrame = src;
		_hasRealFrame = true;
	}

	if(!_frameGenEnabled || _rifeBusy.exchange(true))
		return;

	Nv12OwnedFrame srcCopy = src;
	dispatch_async(_rifeQueue, ^{
		@autoreleasepool {
			Nv12OwnedFrame localInterp;
			double elapsedMs = 0.0;
			bool ok = false;
			{
				std::lock_guard<std::mutex> lock(self->_frameMutex);
				if(self->_rife && self->_rifeReady)
				{
					robzfg::ColorInfo color{};
					color.matrix = robzfg::ColorMatrix::BT709;
					color.full_range = false;
					std::string err;
					if(self->_rife->push(srcCopy.view(), color, &err) && self->_rife->ready())
					{
						localInterp.allocate(srcCopy.width, srcCopy.height);
						robzfg::InterpolateTiming timing{};
						if(self->_rife->interpolate(0.5f, localInterp.mutView(), &timing, &err, 0.5f))
						{
							elapsedMs = timing.total_ms;
							ok = true;
						}
					}
				}
			}
			if(ok)
			{
				std::lock_guard<std::mutex> lock(self->_frameMutex);
				self->_interpFrame = std::move(localInterp);
				self->_hasInterpFrame = true;
				self->_showInterpNext = true;
				self->_lastInterpMs = elapsedMs;
				self->_smoothedInterpMs = (self->_smoothedInterpMs <= 0.0)
					? elapsedMs
					: (self->_smoothedInterpMs * 0.85 + elapsedMs * 0.15);
			}
			self->_rifeBusy.store(false);
		}
	});
}

// ============================================================================
// Physical DualSense / MFi Controller Mapping (GameController.framework)
// ============================================================================

- (void)setupGameControllers
{
	[[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(onControllerConnected:)
												 name:GCControllerDidConnectNotification
											   object:nil];
	for(GCController *ctrl in [GCController controllers])
		[self bindController:ctrl];
}

- (void)onControllerConnected:(NSNotification *)note
{
	GCController *ctrl = (GCController *)note.object;
	[self bindController:ctrl];
}

- (void)bindController:(GCController *)ctrl
{
	GCExtendedGamepad *gp = ctrl.extendedGamepad;
	if(!gp)
		return;
	__weak RobzPlayViewController *weakSelf = self;
	gp.valueChangedHandler = ^(GCExtendedGamepad *gamepad, GCControllerElement *element) {
		RobzPlayViewController *strongSelf = weakSelf;
		if(!strongSelf)
			return;
		[strongSelf updateFromGamepad:gamepad];
	};
}

- (void)updateFromGamepad:(GCExtendedGamepad *)gp
{
	uint32_t btns = 0;
	if(gp.buttonA.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_CROSS;
	if(gp.buttonB.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_MOON;
	if(gp.buttonX.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_BOX;
	if(gp.buttonY.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_PYRAMID;
	if(gp.dpad.up.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_DPAD_UP;
	if(gp.dpad.down.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_DPAD_DOWN;
	if(gp.dpad.left.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_DPAD_LEFT;
	if(gp.dpad.right.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_DPAD_RIGHT;
	if(gp.leftShoulder.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_L1;
	if(gp.rightShoulder.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_R1;
	if(gp.leftThumbstickButton.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_L3;
	if(gp.rightThumbstickButton.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_R3;
	if(gp.buttonMenu.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_OPTIONS;
	if(gp.buttonOptions.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_SHARE;
	if(gp.buttonHome.pressed) btns |= CHIAKI_CONTROLLER_BUTTON_PS;

	_controllerState.buttons = btns;
	_controllerState.l2_state = (uint8_t)std::clamp((int)(gp.leftTrigger.value * 255.0f), 0, 255);
	_controllerState.r2_state = (uint8_t)std::clamp((int)(gp.rightTrigger.value * 255.0f), 0, 255);
	_controllerState.left_x = (int16_t)std::clamp((int)(gp.leftThumbstick.xAxis.value * 32767.0f), -32768, 32767);
	_controllerState.left_y = (int16_t)std::clamp((int)(-gp.leftThumbstick.yAxis.value * 32767.0f), -32768, 32767);
	_controllerState.right_x = (int16_t)std::clamp((int)(gp.rightThumbstick.xAxis.value * 32767.0f), -32768, 32767);
	_controllerState.right_y = (int16_t)std::clamp((int)(-gp.rightThumbstick.yAxis.value * 32767.0f), -32768, 32767);

	if(_sessionActive)
		chiaki_session_set_controller_state(&_session, &_controllerState);
}

// ============================================================================
// PS5 & PS4 LAN Discovery + Registration + Remote Play Session (chiaki-lib)
// ============================================================================

static void iosDiscoveryServiceCb(ChiakiDiscoveryHost *hosts, size_t hosts_count, void *user)
{
	@autoreleasepool {
		RobzPlayViewController *vc = (__bridge RobzPlayViewController *)user;
		[vc onDiscoveredHosts:hosts count:hosts_count];
	}
}

- (void)startDiscoveryService
{
	if(_discoveryRunning)
		return;
	ChiakiDiscoveryServiceOptions opts{};
	opts.hosts_max = 16;
	opts.host_drop_pings = 3;
	opts.ping_ms = 2500;
	opts.ping_initial_ms = 500;
	opts.cb = iosDiscoveryServiceCb;
	opts.cb_user = (__bridge void *)self;

	struct sockaddr_in addr{};
	addr.sin_len = sizeof(addr);
	addr.sin_family = AF_INET;
	addr.sin_port = htons(CHIAKI_DISCOVERY_PORT_PS5);
	addr.sin_addr.s_addr = htonl(INADDR_BROADCAST);
	opts.send_addr = (struct sockaddr_storage *)&addr;
	opts.send_addr_size = sizeof(addr);

	if(chiaki_discovery_service_init(&_discoveryService, &opts, &_chiakiLog) == CHIAKI_ERR_SUCCESS)
	{
		_discoveryRunning = true;
		robzLogLine(@"LAN discovery service started");
	}
	else
		robzLogLine(@"LAN discovery service failed to start");
}

- (void)onDiscoveredHosts:(ChiakiDiscoveryHost *)hosts count:(size_t)count
{
	std::string firstIp;
	std::string firstName;
	std::string summary;
	{
		std::lock_guard<std::mutex> lock(_hostsMutex);
		_discoveredHosts.clear();
		for(size_t i = 0; i < count; i++)
		{
			DiscoveredHostItem item;
			if(hosts[i].host_addr) item.hostAddr = hosts[i].host_addr;
			if(hosts[i].host_name) item.hostName = hosts[i].host_name;
			if(hosts[i].host_id) item.hostId = hosts[i].host_id;
			item.isPS5 = chiaki_discovery_host_is_ps5(&hosts[i]);
			item.isReady = (hosts[i].state == CHIAKI_DISCOVERY_HOST_STATE_READY);
			_discoveredHosts.push_back(item);
			if(firstIp.empty() && !item.hostAddr.empty())
			{
				firstIp = item.hostAddr;
				firstName = item.hostName;
			}
			summary += item.hostName + "(" + item.hostAddr + (item.isReady ? ",ready" : ",standby") + ") ";
		}
	}
	static std::string s_lastDiscoverySummary;
	if(summary != s_lastDiscoverySummary)
	{
		s_lastDiscoverySummary = summary;
		robzLogLine([NSString stringWithFormat:@"Discovered %zu host(s): %s", count, summary.c_str()]);
	}
	if(!firstIp.empty())
	{
		dispatch_async(dispatch_get_main_queue(), ^{
			if(self->_ipField.text.length == 0)
				self->_ipField.text = [NSString stringWithUTF8String:firstIp.c_str()];
			self->_statusLabel.text = [NSString stringWithFormat:@"Discovered %s (%s) on LAN",
				firstName.c_str(), firstIp.c_str()];
		});
	}
}

static void iosRegistCb(ChiakiRegistEvent *event, void *user)
{
	@autoreleasepool {
		RobzPlayViewController *vc = (__bridge RobzPlayViewController *)user;
		[vc handleRegistEvent:event];
	}
}

- (void)onPairConsoleDialog
{
	[self.view endEditing:YES];
	UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Pair PS5 / PS4 Console"
																   message:@"Enter your 8-byte PSN Account ID (Base64) and 8-digit Remote Play PIN shown on your PlayStation."
															preferredStyle:UIAlertControllerStyleAlert];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"PSN Account ID (Base64, e.g. 12 chars)";
	}];
	[alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
		tf.placeholder = @"8-digit PIN (e.g. 12345678)";
		tf.keyboardType = UIKeyboardTypeNumberPad;
	}];
	[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
	[alert addAction:[UIAlertAction actionWithTitle:@"Register PS5" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
		NSString *accB64 = alert.textFields[0].text ?: @"";
		NSString *pinStr = alert.textFields[1].text ?: @"";
		[self startConsoleRegistrationWithAccountB64:accB64 pin:(uint32_t)[pinStr integerValue] isPS5:YES];
	}]];
	[self presentViewController:alert animated:YES completion:nil];
}

- (void)startConsoleRegistrationWithAccountB64:(NSString *)accB64 pin:(uint32_t)pin isPS5:(BOOL)isPS5
{
	NSString *ip = _ipField.text ?: @"";
	if(ip.length == 0)
	{
		_statusLabel.text = @"Enter console IP first.";
		return;
	}
	uint8_t accountId[CHIAKI_PSN_ACCOUNT_ID_SIZE] = {0};
	size_t outSize = sizeof(accountId);
	chiaki_base64_decode(accB64.UTF8String, accB64.length, accountId, &outSize);

	ChiakiRegistInfo info{};
	info.host = ip.UTF8String;
	info.broadcast = false;
	info.target = isPS5 ? CHIAKI_TARGET_PS5_1 : CHIAKI_TARGET_PS4_10;
	info.pin = pin;
	info.psn_online_id = NULL;
	memcpy(info.psn_account_id, accountId, CHIAKI_PSN_ACCOUNT_ID_SIZE);

	robzLogLine([NSString stringWithFormat:@"Registration attempt: host=%@ target=%s pin=%u", ip, isPS5 ? "PS5" : "PS4", pin]);
	static ChiakiRegist sRegist;
	if(chiaki_regist_start(&sRegist, &_chiakiLog, &info, iosRegistCb, (__bridge void *)self) == CHIAKI_ERR_SUCCESS)
		_statusLabel.text = @"Registering with console...";
	else
	{
		_statusLabel.text = @"Failed to start registration.";
		robzLogLine(@"chiaki_regist_start failed");
	}
}

- (void)handleRegistEvent:(ChiakiRegistEvent *)event
{
	if(!event)
		return;
	if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS && event->registered_host)
	{
		robzLogLine(@"Console registration succeeded (paired)");
		char morningB64[64] = {0};
		chiaki_base64_encode(event->registered_host->rp_key, sizeof(event->registered_host->rp_key), morningB64, sizeof(morningB64));
		NSString *rk = [NSString stringWithUTF8String:event->registered_host->rp_regist_key];
		NSString *mk = [NSString stringWithUTF8String:morningB64];
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_registKeyField.text = rk;
			self->_morningField.text = mk;
			[[NSUserDefaults standardUserDefaults] setObject:rk forKey:@"ps_regist_key"];
			[[NSUserDefaults standardUserDefaults] setObject:mk forKey:@"ps_morning"];
			self->_statusLabel.text = @"Console paired successfully! Ready to connect.";
		});
	}
	else if(event->type == CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED)
	{
		robzLogLine(@"Console registration FAILED (check PIN & Account ID)");
		dispatch_async(dispatch_get_main_queue(), ^{
			self->_statusLabel.text = @"Console pairing failed (check PIN & Account ID).";
		});
	}
}

static bool iosVideoSampleCb(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	@autoreleasepool {
		(void)frames_lost;
		(void)frame_recovered;
		RobzPlayViewController *vc = (__bridge RobzPlayViewController *)user;
		return [vc decodeVideoSample:buf size:buf_size];
	}
}

static void iosSessionEventCb(ChiakiEvent *event, void *user)
{
	@autoreleasepool {
		RobzPlayViewController *vc = (__bridge RobzPlayViewController *)user;
		if(!event)
			return;
		if(event->type == CHIAKI_EVENT_CONNECTED)
		{
			robzLogLine(@"Remote Play session CONNECTED");
			dispatch_async(dispatch_get_main_queue(), ^{
				vc->_statusLabel.text = @"Connected to PlayStation Remote Play (1080p)";
				vc->_controlPanel.hidden = YES;
			});
		}
		else if(event->type == CHIAKI_EVENT_QUIT)
		{
			robzLogLine([NSString stringWithFormat:@"Remote Play session QUIT: %s%s%s",
				chiaki_quit_reason_string(event->quit.reason),
				event->quit.reason_str ? " — " : "",
				event->quit.reason_str ?: ""]);
			dispatch_async(dispatch_get_main_queue(), ^{
				vc->_sessionActive = false;
				[vc->_connectBtn setTitle:@"Connect PS5" forState:UIControlStateNormal];
				vc->_statusLabel.text = @"Remote Play session ended.";
			});
		}
	}
}

- (void)onConnectConsole
{
	[self.view endEditing:YES];
	if(_sessionActive)
	{
		chiaki_session_stop(&_session);
		chiaki_session_join(&_session);
		chiaki_session_fini(&_session);
		_sessionActive = false;
		[_connectBtn setTitle:@"Connect PS5" forState:UIControlStateNormal];
		_statusLabel.text = @"Disconnected.";
		return;
	}

	NSString *ip = _ipField.text ?: @"";
	NSString *rk = _registKeyField.text ?: @"";
	NSString *mk = _morningField.text ?: @"";
	if(ip.length == 0 || rk.length == 0 || mk.length == 0)
	{
		_statusLabel.text = @"Enter IP, Regist Key, and RP-Key (or tap Pair with PIN).";
		return;
	}

	[[NSUserDefaults standardUserDefaults] setObject:ip forKey:@"ps_ip"];
	[[NSUserDefaults standardUserDefaults] setObject:rk forKey:@"ps_regist_key"];
	[[NSUserDefaults standardUserDefaults] setObject:mk forKey:@"ps_morning"];

	if(_selfTestRunning)
		[self onToggleSelfTest];

	ChiakiConnectInfo info{};
	info.ps5 = true;
	info.host = ip.UTF8String;
	strncpy(info.regist_key, rk.UTF8String, sizeof(info.regist_key) - 1);
	size_t morningLen = sizeof(info.morning);
	chiaki_base64_decode(mk.UTF8String, mk.length, info.morning, &morningLen);
	info.video_profile.width = 1920;
	info.video_profile.height = 1080;
	info.video_profile.max_fps = 60;
	info.video_profile.bitrate = 50000;
	info.video_profile.codec = CHIAKI_CODEC_H265;
	info.video_profile_auto_downgrade = true;
	info.enable_keyboard = false;
	info.enable_dualsense = true;
	info.holepunch_session = NULL;
	info.auto_regist = false;

	robzLogLine([NSString stringWithFormat:@"Connect attempt: host=%@ 1920x1080@60 H265 50 Mbps", ip]);
	if(chiaki_session_init(&_session, &info, &_chiakiLog) != CHIAKI_ERR_SUCCESS)
	{
		_statusLabel.text = @"Failed to initialize ChiakiSession.";
		robzLogLine(@"chiaki_session_init failed");
		return;
	}
	chiaki_session_set_event_cb(&_session, iosSessionEventCb, (__bridge void *)self);
	chiaki_session_set_video_sample_cb(&_session, iosVideoSampleCb, (__bridge void *)self);

	if(chiaki_session_start(&_session) == CHIAKI_ERR_SUCCESS)
	{
		_sessionActive = true;
		[_connectBtn setTitle:@"Disconnect" forState:UIControlStateNormal];
		_statusLabel.text = [NSString stringWithFormat:@"Connecting to %@...", ip];
	}
	else
	{
		chiaki_session_fini(&_session);
		_statusLabel.text = @"Failed to start Remote Play session.";
		robzLogLine(@"chiaki_session_start failed");
	}
}

// ============================================================================
// VideoToolbox Hardware H.265 Decoder Callback
// ============================================================================

static void vtDecodeOutputCb(void *decompressionOutputRefCon,
							 void *sourceFrameRefCon,
							 OSStatus status,
							 VTDecodeInfoFlags infoFlags,
							 CVImageBufferRef imageBuffer,
							 CMTime presentationTimeStamp,
							 CMTime presentationDuration)
{
	(void)sourceFrameRefCon;
	(void)infoFlags;
	(void)presentationTimeStamp;
	(void)presentationDuration;
	if(status != noErr || !imageBuffer)
		return;
	RobzPlayViewController *vc = (__bridge RobzPlayViewController *)decompressionOutputRefCon;
	[vc handleDecodedPixelBuffer:imageBuffer];
}

- (void)handleDecodedPixelBuffer:(CVPixelBufferRef)pixelBuffer
{
	CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
	const int w = (int)CVPixelBufferGetWidth(pixelBuffer);
	const int h = (int)CVPixelBufferGetHeight(pixelBuffer);
	const uint8_t *ySrc = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);
	const uint8_t *uvSrc = (const uint8_t *)CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);
	const size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
	const size_t uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);

	if(ySrc && uvSrc && w > 0 && h > 0)
	{
		robzfg::Nv12View rawView{};
		rawView.y = ySrc;
		rawView.uv = uvSrc;
		rawView.width = w;
		rawView.height = h;
		rawView.y_stride = (int)yStride;
		rawView.uv_stride = (int)uvStride;

		// Skip duplicate 60 Hz container repeats from 30 FPS console games
		const bool isDup = _dedup.classify(_dedup.measure(rawView));
		if(!isDup)
		{
			_dedup.accept(rawView);
			Nv12OwnedFrame copy;
			copy.allocate(w, h);
			for(int r = 0; r < h; r++)
				memcpy(copy.y.data() + (size_t)r * w, ySrc + (size_t)r * yStride, (size_t)w);
			for(int r = 0; r < h / 2; r++)
				memcpy(copy.uv.data() + (size_t)r * w, uvSrc + (size_t)r * uvStride, (size_t)w);
			[self ingestSourceFrame:copy];
		}
	}
	CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
}

- (bool)decodeVideoSample:(const uint8_t *)buf size:(size_t)size
{
	// Extract HEVC parameter sets (VPS=32, SPS=33, PPS=34) and slice NALs from Annex-B stream
	if(!buf || size < 5)
		return false;

	std::vector<std::pair<const uint8_t *, size_t>> nals;
	size_t i = 0;
	while(i + 3 < size)
	{
		size_t scLen = 0;
		if(buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) scLen = 3;
		else if(i + 4 < size && buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 0 && buf[i + 3] == 1) scLen = 4;
		if(scLen == 0) { i++; continue; }
		size_t nalStart = i + scLen;
		size_t j = nalStart;
		while(j + 3 < size)
		{
			if(buf[j] == 0 && buf[j + 1] == 0 && (buf[j + 2] == 1 || (j + 3 < size && buf[j + 2] == 0 && buf[j + 3] == 1)))
				break;
			j++;
		}
		if(j + 3 >= size) j = size;
		if(j > nalStart)
			nals.push_back({ buf + nalStart, j - nalStart });
		i = j;
	}

	bool paramChanged = false;
	std::vector<uint8_t> avccData;
	for(const auto &nal : nals)
	{
		const uint8_t nalType = (nal.first[0] >> 1) & 0x3f;
		if(nalType == 32) { _vps.assign(nal.first, nal.first + nal.second); paramChanged = true; }
		else if(nalType == 33) { _sps.assign(nal.first, nal.first + nal.second); paramChanged = true; }
		else if(nalType == 34) { _pps.assign(nal.first, nal.first + nal.second); paramChanged = true; }
		else if(nalType <= 21)
		{
			uint32_t lenBE = htonl((uint32_t)nal.second);
			size_t oldSz = avccData.size();
			avccData.resize(oldSz + 4 + nal.second);
			memcpy(avccData.data() + oldSz, &lenBE, 4);
			memcpy(avccData.data() + oldSz + 4, nal.first, nal.second);
		}
	}

	if((paramChanged || !_vtSession) && !_vps.empty() && !_sps.empty() && !_pps.empty())
	{
		if(_vtSession) { VTDecompressionSessionInvalidate(_vtSession); CFRelease(_vtSession); _vtSession = NULL; }
		if(_vtFormatDesc) { CFRelease(_vtFormatDesc); _vtFormatDesc = NULL; }

		const uint8_t *paramPtrs[3] = { _vps.data(), _sps.data(), _pps.data() };
		const size_t paramSizes[3] = { _vps.size(), _sps.size(), _pps.size() };
		OSStatus fmtStatus = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 3, paramPtrs, paramSizes, 4, NULL, &_vtFormatDesc);
		if(fmtStatus == noErr)
		{
			NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
									 (id)kCVPixelBufferMetalCompatibilityKey: @YES };
			VTDecompressionOutputCallbackRecord cb = { vtDecodeOutputCb, (__bridge void *)self };
			OSStatus vtStatus = VTDecompressionSessionCreate(kCFAllocatorDefault, _vtFormatDesc, NULL, (__bridge CFDictionaryRef)attrs, &cb, &_vtSession);
			if(vtStatus == noErr)
				robzLogLine(@"VideoToolbox H.265 decoder created");
			else
				robzLogLine([NSString stringWithFormat:@"VTDecompressionSessionCreate FAILED: %d", (int)vtStatus]);
		}
		else
			robzLogLine([NSString stringWithFormat:@"CMVideoFormatDescriptionCreateFromHEVCParameterSets FAILED: %d", (int)fmtStatus]);
	}

	if(_vtSession && _vtFormatDesc && !avccData.empty())
	{
		CMBlockBufferRef blockBuf = NULL;
		if(CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avccData.data(), avccData.size(),
											  kCFAllocatorNull, NULL, 0, avccData.size(), 0, &blockBuf) == kCMBlockBufferNoErr)
		{
			CMSampleBufferRef sampleBuf = NULL;
			const size_t sampleSize = avccData.size();
			if(CMSampleBufferCreateReady(kCFAllocatorDefault, blockBuf, _vtFormatDesc, 1, 0, NULL, 1, &sampleSize, &sampleBuf) == noErr)
			{
				VTDecodeInfoFlags flagsOut = 0;
				VTDecompressionSessionDecodeFrame(_vtSession, sampleBuf, 0, NULL, &flagsOut);
				CFRelease(sampleBuf);
			}
			CFRelease(blockBuf);
		}
	}
	return true;
}

// ============================================================================
// 60 Hz Metal Renderer (alternates interpolated t=0.5 and real source frames)
// ============================================================================

- (void)uploadFrameToTextures:(const Nv12OwnedFrame &)frame
{
	if(!_device || frame.width <= 0 || frame.height <= 0)
		return;
	if(_texWidth != frame.width || _texHeight != frame.height || !_yTexture || !_uvTexture)
	{
		_texWidth = frame.width;
		_texHeight = frame.height;
		MTLTextureDescriptor *yDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
																						 width:(NSUInteger)_texWidth
																						height:(NSUInteger)_texHeight
																					 mipmapped:NO];
		yDesc.usage = MTLTextureUsageShaderRead;
		_yTexture = [_device newTextureWithDescriptor:yDesc];

		MTLTextureDescriptor *uvDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
																						  width:(NSUInteger)(_texWidth / 2)
																						 height:(NSUInteger)(_texHeight / 2)
																					  mipmapped:NO];
		uvDesc.usage = MTLTextureUsageShaderRead;
		_uvTexture = [_device newTextureWithDescriptor:uvDesc];
	}
	[_yTexture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)_texWidth, (NSUInteger)_texHeight)
				 mipmapLevel:0
				   withBytes:frame.y.data()
				 bytesPerRow:(NSUInteger)_texWidth];
	[_uvTexture replaceRegion:MTLRegionMake2D(0, 0, (NSUInteger)(_texWidth / 2), (NSUInteger)(_texHeight / 2))
				  mipmapLevel:0
					withBytes:frame.uv.data()
				  bytesPerRow:(NSUInteger)_texWidth];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size
{
	(void)view;
	(void)size;
}

- (void)drawInMTKView:(MTKView *)view
{
	bool drewNewFrame = false;
	{
		std::lock_guard<std::mutex> lock(_frameMutex);
		if(_hasInterpFrame && _showInterpNext)
		{
			[self uploadFrameToTextures:_interpFrame];
			_showInterpNext = false;
			drewNewFrame = true;
		}
		else if(_hasRealFrame)
		{
			[self uploadFrameToTextures:_realFrame];
			_hasRealFrame = false;
			drewNewFrame = true;
		}
	}

	if(drewNewFrame)
	{
		_outputFramesCount++;
		auto now = std::chrono::steady_clock::now();
		double elapsed = std::chrono::duration<double>(now - _fpsWindowStart).count();
		if(elapsed >= 0.5)
		{
			_currentOutputFps = _outputFramesCount / elapsed;
			_outputFramesCount = 0;
			_fpsWindowStart = now;
			_telemetryLabel.text = [NSString stringWithFormat:@"ROBZ PLAY iOS · %.1f FPS · RIFE %.2f ms · %s (1/%d)",
				_currentOutputFps, _smoothedInterpMs, _selectedModelName.c_str(), _flowDivisor];
		}
	}

	id<CAMetalDrawable> drawable = view.currentDrawable;
	MTLRenderPassDescriptor *rpd = view.currentRenderPassDescriptor;
	if(!drawable || !rpd || !_renderPSO || !_yTexture || !_uvTexture)
		return;

	id<MTLCommandBuffer> cmd = [_commandQueue commandBuffer];
	id<MTLRenderCommandEncoder> enc = [cmd renderCommandEncoderWithDescriptor:rpd];
	[enc setRenderPipelineState:_renderPSO];
	[enc setFragmentTexture:_yTexture atIndex:0];
	[enc setFragmentTexture:_uvTexture atIndex:1];
	struct { float sharpness; float pad0; float tx; float ty; } cas = {
		0.45f,
		0.0f,
		_texWidth > 0 ? (1.0f / (float)_texWidth) : (1.0f / 1920.0f),
		_texHeight > 0 ? (1.0f / (float)_texHeight) : (1.0f / 1080.0f)
	};
	[enc setFragmentBytes:&cas length:sizeof(cas) atIndex:0];
	[enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
	[enc endEncoding];
	[cmd presentDrawable:drawable];
	[cmd commit];
}

@end

// ============================================================================
// UIApplicationDelegate & main()
// ============================================================================

@interface RobzPlayAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation RobzPlayAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	(void)application;
	(void)launchOptions;
	robzInitLogging();
	[[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
													  object:nil
													   queue:[NSOperationQueue mainQueue]
												  usingBlock:^(NSNotification *note) {
		robzLogLine(@"App terminating (clean exit)");
	}];
	return YES;
}

@end

// ============================================================================
// UIWindowSceneDelegate — required by the iOS 26+ SDK (UIScene life cycle).
// Without it UIKit aborts the app at launch ("UIScene life cycle is required
// for apps built with this SDK") -> white screen + crash.
// ============================================================================

@interface RobzPlaySceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation RobzPlaySceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions
{
	(void)session;
	(void)connectionOptions;
	UIWindowScene *windowScene = (UIWindowScene *)scene;
	self.window = [[UIWindow alloc] initWithWindowScene:windowScene];
	self.window.rootViewController = [[RobzPlayViewController alloc] init];
	[self.window makeKeyAndVisible];
	robzLogLine(@"Window scene connected");
}

@end

int main(int argc, char *argv[])
{
	@autoreleasepool
	{
		return UIApplicationMain(argc, argv, nil, NSStringFromClass([RobzPlayAppDelegate class]));
	}
}
