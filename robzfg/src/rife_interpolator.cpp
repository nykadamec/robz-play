// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - RIFE v4 frame interpolation on the GPU (ncnn / Vulkan).
//
// The inference setup follows rife-ncnn-vulkan (Copyright (c) 2020 nihui, MIT License),
// reworked for live video:
//  - frames enter and leave as NV12 and never take an RGB round trip: the network only
//    estimates motion and a blend mask, the picture itself is sampled from the two
//    source frames in their native form (see shaders/robzfg_synthesize.comp)
//  - the network can run at a fraction of the picture size, which is what makes 1080p
//    fit into a few milliseconds
//  - the previous frame stays on the GPU, so each source frame is uploaded once

#include "robzfg/rife_interpolator.h"
#ifdef __APPLE__
#include "rife_metal.h"
#endif

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <map>
#include <mutex>
#include <sstream>

#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#include <command.h>
#include <gpu.h>
#include <net.h>
#include <pipeline.h>

#include "warp_layer.h"

#include "rife_v4_timestep.comp.h"
#include "robzfg_nv12_to_net.comp.h"
#include "robzfg_synthesize.comp.h"

namespace robzfg
{

namespace
{

const char *const FIELDS_BLOB = "robzfg_fields";

std::once_flag gpu_instance_once;

void ensureGpuInstance()
{
	// The instance lives for the whole process: tearing it down while other
	// Vulkan users are still alive is not worth the risk.
	std::call_once(gpu_instance_once, []() { ncnn::create_gpu_instance(); });
}

void setError(std::string *error, const std::string &message)
{
	if(error)
		*error = message;
}

// Opens a file whose path is UTF-8. The C library of Windows takes paths in the ANSI code
// page, which cannot spell every folder name (a user called "bahadır" on an English
// Windows), so there the path goes through UTF-16. A path that is not UTF-8 after all - one
// typed on the command line of the lab tool - is opened as it was given.
FILE *openUtf8(const std::string &path, const char *mode)
{
#ifdef _WIN32
	const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, nullptr, 0);
	if(length > 0)
	{
		std::wstring wide(static_cast<size_t>(length), L'\0');
		MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path.c_str(), -1, &wide[0], length);
		const std::wstring wide_mode(mode, mode + strlen(mode));
		if(FILE *file = _wfopen(wide.c_str(), wide_mode.c_str()))
			return file;
	}
#endif
	return fopen(path.c_str(), mode);
}

int paddingForModel(const std::string &model_dir)
{
	if(model_dir.find("rife-v4.25-lite") != std::string::npos)
		return 128;
	if(model_dir.find("rife-v4.25") != std::string::npos || model_dir.find("rife-v4.26") != std::string::npos)
		return 64;
	return 32;
}

struct ParamLayer
{
	std::string type;
	std::string name;
	std::vector<std::string> bottoms;
	std::vector<std::string> tops;
	std::string line;
	bool removed = false;
};

// A RIFE v4 flownet ends with
//     warped0 = Warp(img0, flow[0:2])      warped1 = Warp(img1, flow[2:4])
//     out0 = warped0 * mask + warped1 * (1 - mask)
// i.e. it produces a picture at network resolution. Robz Play builds the picture itself at
// full resolution, so this cuts those layers off and exposes [flow0, flow1, mask] as one
// 5-channel blob instead. Works on the graph's structure, not on blob names, which differ
// from model to model.
bool rewriteParamForFields(const std::string &text, std::string &rewritten, std::string *error)
{
	std::istringstream in(text);
	std::string magic;
	std::string counts;
	if(!std::getline(in, magic) || !std::getline(in, counts))
	{
		setError(error, "flownet.param is too short");
		return false;
	}
	int layer_count = 0;
	int blob_count = 0;
	{
		std::istringstream cs(counts);
		cs >> layer_count >> blob_count;
	}

	std::vector<ParamLayer> layers;
	std::map<std::string, int> producer;
	std::string line;
	while(std::getline(in, line))
	{
		if(!line.empty() && line.back() == '\r')
			line.pop_back();
		if(line.find_first_not_of(" \t") == std::string::npos)
			continue;
		std::istringstream ls(line);
		ParamLayer layer;
		int bottom_count = 0;
		int top_count = 0;
		ls >> layer.type >> layer.name >> bottom_count >> top_count;
		if(!ls)
		{
			setError(error, "could not parse flownet.param");
			return false;
		}
		layer.bottoms.resize(bottom_count);
		layer.tops.resize(top_count);
		for(std::string &name : layer.bottoms)
			ls >> name;
		for(std::string &name : layer.tops)
			ls >> name;
		layer.line = line;
		for(const std::string &name : layer.tops)
			producer[name] = (int)layers.size();
		layers.push_back(layer);
	}

	auto producerOf = [&](const std::string &blob) -> int {
		auto it = producer.find(blob);
		return it == producer.end() ? -1 : it->second;
	};

	const int out_index = producerOf("out0");
	if(out_index < 0 || layers[out_index].bottoms.size() != 2)
	{
		setError(error, "unsupported model: no two-input layer produces out0");
		return false;
	}

	std::string flow0;
	std::string flow1;
	std::string mask;
	layers[out_index].removed = true;
	for(const std::string &term : layers[out_index].bottoms)
	{
		const int mul_index = producerOf(term);
		if(mul_index < 0 || layers[mul_index].bottoms.size() != 2)
		{
			setError(error, "unsupported model: unexpected layer before out0");
			return false;
		}
		ParamLayer &mul = layers[mul_index];
		int warp_index = -1;
		std::string weight;
		for(const std::string &bottom : mul.bottoms)
		{
			const int index = producerOf(bottom);
			if(index >= 0 && layers[index].type == "rife.Warp")
				warp_index = index;
			else
				weight = bottom;
		}
		if(warp_index < 0 || weight.empty() || layers[warp_index].bottoms.size() != 2)
		{
			setError(error, "unsupported model: final blend does not use rife.Warp");
			return false;
		}
		const int weight_index = producerOf(weight);
		if(weight_index < 0)
		{
			setError(error, "unsupported model: blend weight has no producer");
			return false;
		}
		const std::string &flow = layers[warp_index].bottoms[1];
		if(layers[weight_index].type == "BinaryOp")
		{
			// (1 - mask): this term belongs to frame 1
			flow1 = flow;
			layers[weight_index].removed = true;
		}
		else
		{
			flow0 = flow;
			mask = weight;
		}
		mul.removed = true;
		layers[warp_index].removed = true;
	}
	if(flow0.empty() || flow1.empty() || mask.empty())
	{
		setError(error, "unsupported model: could not find flow and mask outputs");
		return false;
	}

	int kept = 0;
	std::ostringstream body;
	for(const ParamLayer &layer : layers)
	{
		if(layer.removed)
			continue;
		body << layer.line << "\n";
		kept++;
	}
	body << "Concat robzfg_fields_concat 3 1 " << flow0 << " " << flow1 << " " << mask << " " << FIELDS_BLOB << " 0=0\n";
	kept++;

	std::ostringstream out;
	// blob_count is an upper bound for ncnn; one blob was added, six were dropped
	out << magic << "\n" << kept << " " << (blob_count + 1) << "\n" << body.str();
	rewritten = out.str();
	(void)layer_count;
	return true;
}

ncnn::Pipeline *createPipeline(const ncnn::VulkanDevice *vkdev, const char *source, int source_size, const ncnn::Option &opt)
{
	std::vector<uint32_t> spirv;
	if(ncnn::compile_spirv_module(source, source_size, opt, spirv) != 0)
		return nullptr;
	std::vector<ncnn::vk_specialization_type> specializations(0);
	ncnn::Pipeline *pipeline = new ncnn::Pipeline(vkdev);
	pipeline->set_optimal_local_size_xyz(8, 8, 1);
	pipeline->create(spirv.data(), spirv.size() * 4, specializations);
	return pipeline;
}

// Dispatch size helper: ncnn takes the work-group counts from a VkMat's shape.
ncnn::VkMat dispatchShape(int w, int h)
{
	ncnn::VkMat shape;
	shape.w = w;
	shape.h = h;
	shape.c = 1;
	return shape;
}

// One source frame as it lives on the GPU.
struct GpuFrame
{
	ncnn::VkMat y;   // luma bytes, packed in 32-bit words
	ncnn::VkMat uv;  // interleaved chroma bytes, packed in 32-bit words
	ncnn::VkMat net; // RGB tensor at network resolution
	bool valid = false;

	void release()
	{
		y.release();
		uv.release();
		net.release();
		valid = false;
	}
};

} // namespace

struct RifeInterpolator::Impl
{
	bool inited = false;
	std::string gpu_name;
#ifdef __APPLE__
	std::unique_ptr<MetalRifeBackend> metal;
	bool use_metal = false;
#endif

	ncnn::VulkanDevice *vkdev = nullptr;
	ncnn::Net flownet;
	ncnn::Option opt;
	ncnn::VkAllocator *blob_allocator = nullptr;
	ncnn::VkAllocator *staging_allocator = nullptr;
	ncnn::Pipeline *nv12_to_net = nullptr;
	ncnn::Pipeline *synthesize = nullptr;
	ncnn::Pipeline *timestep_fill = nullptr;
	int padding = 32;
	int divisor = 2;
	bool protect_static = true;
	bool sharp_sampling = true;
	size_t tensor_elemsize = 4u;

	// current stream format
	int w = 0;
	int h = 0;
	int nw = 0; // network size without padding
	int nh = 0;
	int wp = 0; // network size with padding
	int hp = 0;
	ColorInfo color;

	// newest frame, waiting on the CPU until the next GPU submission
	std::vector<uint32_t> pending_y;
	std::vector<uint32_t> pending_uv;
	bool pending = false;

	GpuFrame prev;
	GpuFrame cur;

	// motion field of the current pair, kept so several frames can be built from it
	ncnn::VkMat fields;
	float fields_time = -1.f;
	bool fields_valid = false;

	// reusable GPU buffers (timestep input + synthesized NV12 outputs)
	ncnn::VkMat timestep_gpu;
	float timestep_value = -1.f;
	ncnn::VkMat out_y_gpu;
	ncnn::VkMat out_uv_gpu;
	bool pending_direct = false;

	std::vector<uint32_t> out_y;
	std::vector<uint32_t> out_uv;

	~Impl()
	{
		releaseFrames();
		// the net owns layers that reference the device; clear it before the pipelines
		flownet.clear();
		delete nv12_to_net;
		delete synthesize;
		delete timestep_fill;
		if(vkdev)
		{
			if(blob_allocator)
				vkdev->reclaim_blob_allocator(blob_allocator);
			if(staging_allocator)
				vkdev->reclaim_staging_allocator(staging_allocator);
		}
	}

	void releaseFrames()
	{
		prev.release();
		cur.release();
		pending = false;
		pending_direct = false;
		timestep_gpu.release();
		timestep_value = -1.f;
		out_y_gpu.release();
		out_uv_gpu.release();
		dropFields();
	}

	void dropFields()
	{
		fields.release();
		fields_time = -1.f;
		fields_valid = false;
	}

	// Records "upload the pending NV12 frame and prepare its network tensor" into `cur`.
	bool recordPendingUpload(ncnn::VkCompute &cmd)
	{
		if(!pending_direct)
		{
			ncnn::Mat y_cpu(w * h / 4, (void *)pending_y.data(), (size_t)4u);
			ncnn::Mat uv_cpu(w * h / 8, (void *)pending_uv.data(), (size_t)4u);
			cur.release();
			cmd.record_clone(y_cpu, cur.y, opt);
			cmd.record_clone(uv_cpu, cur.uv, opt);
		}
		if(cur.net.empty() || cur.net.dims != 3 || cur.net.w != wp || cur.net.h != hp || cur.net.c != 3 || cur.net.elemsize != tensor_elemsize)
			cur.net.create(wp, hp, 3, tensor_elemsize, 1, blob_allocator);
		if(cur.y.empty() || cur.uv.empty() || cur.net.empty())
		{
			cur.release();
			pending_direct = false;
			return false;
		}

		std::vector<ncnn::VkMat> bindings(3);
		bindings[0] = cur.y;
		bindings[1] = cur.uv;
		bindings[2] = cur.net;

		std::vector<ncnn::vk_constant_type> constants(10);
		constants[0].i = w;
		constants[1].i = h;
		constants[2].i = nw;
		constants[3].i = nh;
		constants[4].i = cur.net.w;
		constants[5].i = cur.net.h;
		constants[6].i = (int)cur.net.cstep;
		constants[7].i = divisor;
		constants[8].i = color.full_range ? 1 : 0;
		constants[9].i = color.matrix == ColorMatrix::BT709 ? 0 : 1;

		cmd.record_pipeline(nv12_to_net, bindings, constants, dispatchShape(wp, hp));

		pending = false;
		pending_direct = false;
		cur.valid = true;
		return true;
	}
};

RifeInterpolator::RifeInterpolator() : d(new Impl) {}

RifeInterpolator::~RifeInterpolator() = default;

std::vector<GpuDevice> RifeInterpolator::enumerateGpus()
{
#ifdef __APPLE__
	if(MetalRifeBackend::isEnabled())
	{
		std::vector<GpuDevice> metal_devices = MetalRifeBackend::enumerateGpus();
		if(!metal_devices.empty())
			return metal_devices;
	}
#endif
	ensureGpuInstance();
	std::vector<GpuDevice> devices;
	const int count = ncnn::get_gpu_count();
	for(int i = 0; i < count; i++)
	{
		const ncnn::GpuInfo &info = ncnn::get_gpu_info(i);
		GpuDevice device;
		device.index = i;
		device.name = info.device_name();
		device.discrete = info.type() == 0;
		devices.push_back(device);
	}
	return devices;
}

bool RifeInterpolator::init(const Config &config, std::string *error)
{
	if(d->inited)
	{
		setError(error, "already initialised");
		return false;
	}
	if(config.flow_divisor != 1 && config.flow_divisor != 2 && config.flow_divisor != 3 && config.flow_divisor != 4)
	{
		setError(error, "flow_divisor must be 1, 2, 3 or 4");
		return false;
	}

#ifdef __APPLE__
	if(MetalRifeBackend::isEnabled())
	{
		auto metal = std::make_unique<MetalRifeBackend>();
		std::string metal_error;
		if(metal->init(config, &metal_error))
		{
			d->metal = std::move(metal);
			d->use_metal = true;
			d->divisor = config.flow_divisor;
			d->gpu_name = d->metal->gpuName();
			d->inited = true;
			return true;
		}
		if(error)
			*error = metal_error;
	}
#endif

	ensureGpuInstance();
	const int gpu_count = ncnn::get_gpu_count();
	if(gpu_count <= 0)
	{
		setError(error, "no Vulkan capable GPU found");
		return false;
	}

	int gpu_index = config.gpu_index;
	if(gpu_index < 0 || gpu_index >= gpu_count)
	{
		gpu_index = ncnn::get_default_gpu_index();
		for(int i = 0; i < gpu_count; i++)
		{
			if(ncnn::get_gpu_info(i).type() == 0)
			{
				gpu_index = i;
				break;
			}
		}
	}

	d->vkdev = ncnn::get_gpu_device(gpu_index);
	if(!d->vkdev)
	{
		setError(error, "could not open the Vulkan device");
		return false;
	}
	d->gpu_name = ncnn::get_gpu_info(gpu_index).device_name();

	ncnn::Option opt;
	opt.num_threads = 1;
	opt.use_vulkan_compute = true;
	opt.use_fp16_packed = true;
	opt.use_fp16_storage = true;
#ifdef __APPLE__
	opt.use_fp16_arithmetic = true;
#else
	opt.use_fp16_arithmetic = false;
#endif
	opt.use_int8_storage = true;

	d->flownet.opt = opt;
	d->flownet.set_vulkan_device(d->vkdev);
	d->flownet.register_custom_layer("rife.Warp", createWarpLayer);

	const std::string param_path = config.model_dir + "/flownet.param";
	const std::string model_path = config.model_dir + "/flownet.bin";
	std::string param_text;
	{
		FILE *file = openUtf8(param_path, "rb");
		if(!file)
		{
			setError(error, "could not open " + param_path);
			return false;
		}
		char chunk[65536];
		size_t got = 0;
		while((got = fread(chunk, 1, sizeof(chunk), file)) > 0)
			param_text.append(chunk, got);
		fclose(file);
	}
	std::string rewritten;
	if(!rewriteParamForFields(param_text, rewritten, error))
		return false;
	if(d->flownet.load_param_mem(rewritten.c_str()) != 0)
	{
		setError(error, "could not load " + param_path);
		return false;
	}
	{
		FILE *file = openUtf8(model_path, "rb");
		const int loaded = file ? d->flownet.load_model(file) : -1;
		if(file)
			fclose(file);
		if(loaded != 0)
		{
			setError(error, "could not load " + model_path);
			return false;
		}
	}

	// the net may have switched options off that the device does not support
	d->opt = d->flownet.opt;
	d->tensor_elemsize = d->opt.use_fp16_storage ? 2u : 4u;
	d->padding = config.padding > 0 ? config.padding : paddingForModel(config.model_dir);
	d->divisor = config.flow_divisor;
	d->protect_static = config.protect_static;
	d->sharp_sampling = config.sharp_sampling;

	d->blob_allocator = d->vkdev->acquire_blob_allocator();
	d->staging_allocator = d->vkdev->acquire_staging_allocator();
	d->opt.blob_vkallocator = d->blob_allocator;
	d->opt.workspace_vkallocator = d->blob_allocator;
	d->opt.staging_vkallocator = d->staging_allocator;

	d->nv12_to_net = createPipeline(d->vkdev, robzfg_nv12_to_net_comp_data, (int)sizeof(robzfg_nv12_to_net_comp_data) - 1, d->opt);
	d->synthesize = createPipeline(d->vkdev, robzfg_synthesize_comp_data, (int)sizeof(robzfg_synthesize_comp_data) - 1, d->opt);
	d->timestep_fill = createPipeline(d->vkdev, rife_v4_timestep_comp_data, (int)sizeof(rife_v4_timestep_comp_data) - 1, d->opt);
	if(!d->nv12_to_net || !d->synthesize || !d->timestep_fill)
	{
		setError(error, "could not compile the frame generation shaders");
		return false;
	}

	d->inited = true;
	return true;
}

bool RifeInterpolator::initialized() const
{
	return d->inited;
}

std::string RifeInterpolator::gpuName() const
{
	return d->gpu_name;
}

void RifeInterpolator::reset()
{
#ifdef __APPLE__
	if(d->use_metal)
	{
		d->metal->reset();
		return;
	}
#endif
	d->releaseFrames();
}

bool RifeInterpolator::setFlowDivisor(int flow_divisor)
{
#ifdef __APPLE__
	if(d->use_metal)
	{
		if(!d->metal->setFlowDivisor(flow_divisor))
			return false;
		d->divisor = flow_divisor;
		return true;
	}
#endif
	if(flow_divisor != 1 && flow_divisor != 2 && flow_divisor != 3 && flow_divisor != 4)
		return false;
	if(d->divisor == flow_divisor)
		return true;
	d->divisor = flow_divisor;
	d->releaseFrames();
	if(d->w > 0 && d->h > 0)
	{
		d->nw = (d->w + d->divisor - 1) / d->divisor;
		d->nh = (d->h + d->divisor - 1) / d->divisor;
		d->wp = (d->nw + d->padding - 1) / d->padding * d->padding;
		d->hp = (d->nh + d->padding - 1) / d->padding * d->padding;
	}
	return true;
}

int RifeInterpolator::flowDivisor() const
{
	return d->divisor;
}

bool RifeInterpolator::ready() const
{
#ifdef __APPLE__
	if(d->use_metal)
		return d->inited && d->metal->ready();
#endif
	return d->inited && d->prev.valid && (d->cur.valid || d->pending);
}

bool RifeInterpolator::push(const Nv12View &frame, const ColorInfo &color, std::string *error)
{
#ifdef __APPLE__
	if(d->use_metal)
		return d->metal->push(frame, color, error);
#endif
	if(!d->inited)
	{
		setError(error, "not initialised");
		return false;
	}
	if(!frame.valid() || (frame.width % 4) != 0 || (frame.height % 2) != 0)
	{
		setError(error, "unsupported frame size (width must be a multiple of 4, height a multiple of 2)");
		return false;
	}

	if(frame.width != d->w || frame.height != d->h || color != d->color)
	{
		d->releaseFrames();
		d->w = frame.width;
		d->h = frame.height;
		d->nw = (d->w + d->divisor - 1) / d->divisor;
		d->nh = (d->h + d->divisor - 1) / d->divisor;
		d->wp = (d->nw + d->padding - 1) / d->padding * d->padding;
		d->hp = (d->nh + d->padding - 1) / d->padding * d->padding;
		d->color = color;
		d->pending_y.assign((size_t)d->w * d->h / 4, 0);
		d->pending_uv.assign((size_t)d->w * d->h / 8, 0);
		d->out_y.assign((size_t)d->w * d->h / 4, 0);
		d->out_uv.assign((size_t)d->w * d->h / 8, 0);
	}

	// A frame that was pushed but never used still has to reach the GPU: it is the next "previous".
	if(d->pending)
	{
		ncnn::VkCompute cmd(d->vkdev);
		if(!d->recordPendingUpload(cmd) || cmd.submit_and_wait() != 0)
		{
			d->releaseFrames();
			setError(error, "GPU upload failed");
			return false;
		}
	}

	if(d->cur.valid)
		std::swap(d->prev, d->cur);
	d->cur.valid = false;
	d->dropFields(); // a new pair needs a new motion estimate

	const int y_words = d->w * d->h / 4;
	const int uv_words = d->w * d->h / 8;
	if(d->cur.y.empty() || d->cur.y.dims != 1 || d->cur.y.w != y_words || d->cur.y.elemsize != 4u)
		d->cur.y.create(y_words, (size_t)4u, 1, d->blob_allocator);
	if(d->cur.uv.empty() || d->cur.uv.dims != 1 || d->cur.uv.w != uv_words || d->cur.uv.elemsize != 4u)
		d->cur.uv.create(uv_words, (size_t)4u, 1, d->blob_allocator);

	const bool direct_upload = !d->cur.y.empty() && !d->cur.uv.empty()
		&& d->cur.y.allocator && d->cur.y.allocator->mappable
		&& d->cur.uv.allocator && d->cur.uv.allocator->mappable;
	if(direct_upload)
	{
		uint8_t *dst_y = static_cast<uint8_t *>(d->cur.y.mapped_ptr());
		if(frame.y_stride == d->w)
			memcpy(dst_y, frame.y, (size_t)d->w * d->h);
		else
			for(int row = 0; row < d->h; row++)
				memcpy(dst_y + (size_t)row * d->w, frame.y + (size_t)row * frame.y_stride, (size_t)d->w);

		uint8_t *dst_uv = static_cast<uint8_t *>(d->cur.uv.mapped_ptr());
		if(frame.uv_stride == d->w)
			memcpy(dst_uv, frame.uv, (size_t)d->w * (d->h / 2));
		else
			for(int row = 0; row < d->h / 2; row++)
				memcpy(dst_uv + (size_t)row * d->w, frame.uv + (size_t)row * frame.uv_stride, (size_t)d->w);

		d->cur.y.allocator->flush(d->cur.y.data);
		d->cur.uv.allocator->flush(d->cur.uv.data);
		d->cur.y.data->access_flags = VK_ACCESS_HOST_WRITE_BIT;
		d->cur.y.data->stage_flags = VK_PIPELINE_STAGE_HOST_BIT;
		d->cur.uv.data->access_flags = VK_ACCESS_HOST_WRITE_BIT;
		d->cur.uv.data->stage_flags = VK_PIPELINE_STAGE_HOST_BIT;
		d->pending = true;
		d->pending_direct = true;
		return true;
	}

	d->cur.release();
	uint8_t *dst_y = (uint8_t *)d->pending_y.data();
	if(frame.y_stride == d->w)
		memcpy(dst_y, frame.y, (size_t)d->w * d->h);
	else
		for(int row = 0; row < d->h; row++)
			memcpy(dst_y + (size_t)row * d->w, frame.y + (size_t)row * frame.y_stride, (size_t)d->w);
	uint8_t *dst_uv = (uint8_t *)d->pending_uv.data();
	if(frame.uv_stride == d->w)
		memcpy(dst_uv, frame.uv, (size_t)d->w * (d->h / 2));
	else
		for(int row = 0; row < d->h / 2; row++)
			memcpy(dst_uv + (size_t)row * d->w, frame.uv + (size_t)row * frame.uv_stride, (size_t)d->w);
	d->pending = true;
	d->pending_direct = false;
	return true;
}

bool RifeInterpolator::interpolate(float t, const Nv12Mut &out, InterpolateTiming *timing, std::string *error, float field_time)
{
#ifdef __APPLE__
	if(d->use_metal)
		return d->metal->interpolate(t, out, timing, error, field_time);
#endif
	const auto start = std::chrono::steady_clock::now();

	if(!ready())
	{
		setError(error, "two frames are needed before interpolating");
		return false;
	}
	if(!out.valid() || out.width != d->w || out.height != d->h)
	{
		setError(error, "output frame does not match the stream size");
		return false;
	}
	if(!(t > 0.f && t < 1.f))
	{
		setError(error, "t must be between 0 and 1");
		return false;
	}

	ncnn::VkCompute cmd(d->vkdev);

	if(d->pending && !d->recordPendingUpload(cmd))
	{
		d->releaseFrames();
		setError(error, "GPU upload failed");
		return false;
	}

	// Motion estimate: reuse the one of this pair when it was made for the wanted time.
	const float wanted_field_time = (field_time > 0.f && field_time < 1.f) ? field_time : t;
	if(!d->fields_valid || std::abs(d->fields_time - wanted_field_time) > 0.0001f)
	{
		d->dropFields();

		const bool timestep_reallocated = d->timestep_gpu.empty() || d->timestep_gpu.dims != 3
			|| d->timestep_gpu.w != d->wp || d->timestep_gpu.h != d->hp || d->timestep_gpu.c != 1
			|| d->timestep_gpu.elemsize != d->tensor_elemsize;
		if(timestep_reallocated)
			d->timestep_gpu.create(d->wp, d->hp, 1, d->tensor_elemsize, 1, d->blob_allocator);
		if(d->timestep_gpu.empty())
		{
			setError(error, "GPU allocation failed");
			return false;
		}
		if(timestep_reallocated || std::abs(d->timestep_value - wanted_field_time) > 0.0001f)
		{
			std::vector<ncnn::VkMat> bindings(1);
			bindings[0] = d->timestep_gpu;

			std::vector<ncnn::vk_constant_type> constants(4);
			constants[0].i = d->timestep_gpu.w;
			constants[1].i = d->timestep_gpu.h;
			constants[2].i = (int)d->timestep_gpu.cstep;
			constants[3].f = wanted_field_time;

			cmd.record_pipeline(d->timestep_fill, bindings, constants, d->timestep_gpu);
			d->timestep_value = wanted_field_time;
		}

		ncnn::Extractor ex = d->flownet.create_extractor();
		ex.set_blob_vkallocator(d->blob_allocator);
		ex.set_workspace_vkallocator(d->blob_allocator);
		ex.set_staging_vkallocator(d->staging_allocator);

		ex.input("in0", d->prev.net);
		ex.input("in1", d->cur.net);
		ex.input("in2", d->timestep_gpu);
		if(ex.extract(FIELDS_BLOB, d->fields, cmd) != 0 || d->fields.empty())
		{
			d->dropFields();
			setError(error, "RIFE inference failed");
			return false;
		}
		if(d->fields.c != 5 || d->fields.elempack != 1)
		{
			d->dropFields();
			setError(error, "unexpected flow output layout");
			return false;
		}
		d->fields_time = wanted_field_time;
		d->fields_valid = true;
	}
	const ncnn::VkMat &fields = d->fields;

	const int y_words = d->w * d->h / 4;
	const int uv_words = d->w * d->h / 8;
	if(d->out_y_gpu.empty() || d->out_y_gpu.dims != 1 || d->out_y_gpu.w != y_words || d->out_y_gpu.elemsize != 4u)
		d->out_y_gpu.create(y_words, (size_t)4u, 1, d->blob_allocator);
	if(d->out_uv_gpu.empty() || d->out_uv_gpu.dims != 1 || d->out_uv_gpu.w != uv_words || d->out_uv_gpu.elemsize != 4u)
		d->out_uv_gpu.create(uv_words, (size_t)4u, 1, d->blob_allocator);
	if(d->out_y_gpu.empty() || d->out_uv_gpu.empty())
	{
		setError(error, "GPU allocation failed");
		return false;
	}
	{
		std::vector<ncnn::VkMat> bindings(7);
		bindings[0] = fields;
		bindings[1] = d->prev.y;
		bindings[2] = d->prev.uv;
		bindings[3] = d->cur.y;
		bindings[4] = d->cur.uv;
		bindings[5] = d->out_y_gpu;
		bindings[6] = d->out_uv_gpu;

		std::vector<ncnn::vk_constant_type> constants(11);
		constants[0].i = d->w;
		constants[1].i = d->h;
		constants[2].i = d->nw;
		constants[3].i = d->nh;
		constants[4].i = fields.w;
		constants[5].i = (int)fields.cstep;
		constants[6].i = d->divisor;
		constants[7].f = t;
		constants[8].i = d->protect_static ? 1 : 0;
		constants[9].f = d->fields_time;
		constants[10].i = d->sharp_sampling ? 1 : 0;

		cmd.record_pipeline(d->synthesize, bindings, constants, dispatchShape(d->w / 4, d->h));
	}

	const bool direct_readback = d->out_y_gpu.allocator && d->out_y_gpu.allocator->mappable && d->out_y_gpu.allocator->cached
		&& d->out_uv_gpu.allocator && d->out_uv_gpu.allocator->mappable && d->out_uv_gpu.allocator->cached;

	ncnn::Mat y_cpu;
	ncnn::Mat uv_cpu;
	if(!direct_readback)
	{
		y_cpu = ncnn::Mat(y_words, (void *)d->out_y.data(), (size_t)4u);
		uv_cpu = ncnn::Mat(uv_words, (void *)d->out_uv.data(), (size_t)4u);
		cmd.record_clone(d->out_y_gpu, y_cpu, d->opt);
		cmd.record_clone(d->out_uv_gpu, uv_cpu, d->opt);
	}

	if(cmd.submit_and_wait() != 0)
	{
		d->releaseFrames();
		setError(error, "GPU submission failed");
		return false;
	}

	const uint8_t *src_y = nullptr;
	const uint8_t *src_uv = nullptr;
	if(direct_readback)
	{
		d->out_y_gpu.allocator->invalidate(d->out_y_gpu.data);
		d->out_uv_gpu.allocator->invalidate(d->out_uv_gpu.data);
		src_y = static_cast<const uint8_t *>(d->out_y_gpu.mapped_ptr());
		src_uv = static_cast<const uint8_t *>(d->out_uv_gpu.mapped_ptr());
	}
	else
	{
		src_y = static_cast<const uint8_t *>(y_cpu.data);
		src_uv = static_cast<const uint8_t *>(uv_cpu.data);
	}
	if(!src_y || !src_uv)
	{
		setError(error, "GPU download failed");
		return false;
	}
	if(out.y_stride == d->w)
		memcpy(out.y, src_y, (size_t)d->w * d->h);
	else
		for(int row = 0; row < d->h; row++)
			memcpy(out.y + (size_t)row * out.y_stride, src_y + (size_t)row * d->w, (size_t)d->w);
	if(out.uv_stride == d->w)
		memcpy(out.uv, src_uv, (size_t)d->w * (d->h / 2));
	else
		for(int row = 0; row < d->h / 2; row++)
			memcpy(out.uv + (size_t)row * out.uv_stride, src_uv + (size_t)row * d->w, (size_t)d->w);

	if(timing)
		timing->total_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
	return true;
}

} // namespace robzfg
