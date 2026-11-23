// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - Apple Metal + MPSGraph backend for RIFE v4.

#ifdef __APPLE__

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalPerformanceShaders/MetalPerformanceShaders.h>
#import <MetalPerformanceShadersGraph/MetalPerformanceShadersGraph.h>

#include "rife_metal.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <map>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <datareader.h>
#include <mat.h>
#include <modelbin.h>

namespace robzfg
{

namespace
{

void setError(std::string *error, const std::string &message)
{
	if(error)
		*error = message;
}

int paddingForModel(const std::string &model_dir)
{
	if(model_dir.find("rife-v4.25-lite") != std::string::npos)
		return 128;
	if(model_dir.find("rife-v4.25") != std::string::npos || model_dir.find("rife-v4.26") != std::string::npos)
		return 64;
	return 32;
}

struct TensorShape3
{
	int c = 0;
	int h = 0;
	int w = 0;
};

struct ParamLayer
{
	std::string type;
	std::string name;
	std::vector<std::string> bottoms;
	std::vector<std::string> tops;
	std::unordered_map<int, std::string> scalars;
	std::unordered_map<int, std::vector<std::string>> arrays;
	std::vector<uint16_t> weights_fp16;
	std::vector<uint16_t> bias_fp16;
	int in_channels = 0;
	int out_channels = 0;
	int kernel_w = 0;
	int kernel_h = 0;
	bool removed = false;

	int getInt(int key, int def = 0) const
	{
		auto it = scalars.find(key);
		if(it == scalars.end())
			return def;
		return std::atoi(it->second.c_str());
	}

	float getFloat(int key, float def = 0.0f) const
	{
		auto it = scalars.find(key);
		if(it == scalars.end())
			return def;
		return std::strtof(it->second.c_str(), nullptr);
	}

	std::vector<int> getIntArray(int key) const
	{
		std::vector<int> out;
		auto it = arrays.find(key);
		if(it == arrays.end())
			return out;
		out.reserve(it->second.size());
		for(const std::string &s : it->second)
			out.push_back(std::atoi(s.c_str()));
		return out;
	}

	std::vector<float> getFloatArray(int key) const
	{
		std::vector<float> out;
		auto it = arrays.find(key);
		if(it == arrays.end())
			return out;
		out.reserve(it->second.size());
		for(const std::string &s : it->second)
			out.push_back(std::strtof(s.c_str(), nullptr));
		return out;
	}
};

struct ParsedModel
{
	std::vector<ParamLayer> layers;
	std::string flow0;
	std::string flow1;
	std::string mask;
};

void floatToHalfBuffer(const float *src, size_t count, std::vector<uint16_t> &dst)
{
	dst.resize(count);
	__fp16 *hptr = reinterpret_cast<__fp16 *>(dst.data());
	for(size_t i = 0; i < count; i++)
		hptr[i] = static_cast<__fp16>(src[i]);
}

void transposeOIHWtoIOHWToHalf(const float *src, int out_c, int in_c, int k_area, std::vector<uint16_t> &dst)
{
	dst.resize(static_cast<size_t>(out_c) * in_c * k_area);
	__fp16 *hptr = reinterpret_cast<__fp16 *>(dst.data());
	for(int ic = 0; ic < in_c; ic++)
	{
		for(int oc = 0; oc < out_c; oc++)
		{
			const float *src_kernel = src + (static_cast<size_t>(oc) * in_c + ic) * k_area;
			__fp16 *dst_kernel = hptr + (static_cast<size_t>(ic) * out_c + oc) * k_area;
			for(int k = 0; k < k_area; k++)
				dst_kernel[k] = static_cast<__fp16>(src_kernel[k]);
		}
	}
}

bool loadRifeModel(const std::string &param_path, const std::string &bin_path, ParsedModel &model, std::string *error)
{
	FILE *pfile = fopen(param_path.c_str(), "rb");
	if(!pfile)
	{
		setError(error, "could not open " + param_path);
		return false;
	}
	std::string param_text;
	{
		char chunk[65536];
		size_t got = 0;
		while((got = fread(chunk, 1, sizeof(chunk), pfile)) > 0)
			param_text.append(chunk, got);
		fclose(pfile);
	}

	std::istringstream in(param_text);
	std::string magic;
	std::string counts;
	if(!std::getline(in, magic) || !std::getline(in, counts))
	{
		setError(error, "flownet.param is too short");
		return false;
	}

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
		layer.bottoms.resize(static_cast<size_t>(bottom_count));
		layer.tops.resize(static_cast<size_t>(top_count));
		for(std::string &name : layer.bottoms)
			ls >> name;
		for(std::string &name : layer.tops)
			ls >> name;

		std::string kv;
		while(ls >> kv)
		{
			const size_t eq = kv.find('=');
			if(eq == std::string::npos)
				continue;
			const int key = std::atoi(kv.substr(0, eq).c_str());
			const std::string val = kv.substr(eq + 1);
			if(key <= -23300)
			{
				std::vector<std::string> items;
				std::istringstream vs(val);
				std::string part;
				bool first = true;
				while(std::getline(vs, part, ','))
				{
					if(first)
					{
						first = false;
						continue;
					}
					items.push_back(part);
				}
				layer.arrays[key] = std::move(items);
			}
			else
			{
				layer.scalars[key] = val;
			}
		}

		for(const std::string &name : layer.tops)
			producer[name] = static_cast<int>(model.layers.size());
		model.layers.push_back(std::move(layer));
	}

	// Cut final RGB blend / warp layers so we expose [flow0, flow1, mask].
	auto producerOf = [&](const std::string &blob) -> int {
		auto it = producer.find(blob);
		return it == producer.end() ? -1 : it->second;
	};

	const int out_index = producerOf("out0");
	if(out_index < 0 || model.layers[static_cast<size_t>(out_index)].bottoms.size() != 2)
	{
		setError(error, "unsupported model: no two-input layer produces out0");
		return false;
	}
	model.layers[static_cast<size_t>(out_index)].removed = true;
	for(const std::string &term : model.layers[static_cast<size_t>(out_index)].bottoms)
	{
		const int mul_index = producerOf(term);
		if(mul_index < 0 || model.layers[static_cast<size_t>(mul_index)].bottoms.size() != 2)
		{
			setError(error, "unsupported model: unexpected layer before out0");
			return false;
		}
		ParamLayer &mul = model.layers[static_cast<size_t>(mul_index)];
		int warp_index = -1;
		std::string weight;
		for(const std::string &bottom : mul.bottoms)
		{
			const int index = producerOf(bottom);
			if(index >= 0 && model.layers[static_cast<size_t>(index)].type == "rife.Warp")
				warp_index = index;
			else
				weight = bottom;
		}
		if(warp_index < 0 || weight.empty() || model.layers[static_cast<size_t>(warp_index)].bottoms.size() != 2)
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
		const std::string &flow = model.layers[static_cast<size_t>(warp_index)].bottoms[1];
		if(model.layers[static_cast<size_t>(weight_index)].type == "BinaryOp")
		{
			model.flow1 = flow;
			model.layers[static_cast<size_t>(weight_index)].removed = true;
		}
		else
		{
			model.flow0 = flow;
			model.mask = weight;
		}
		mul.removed = true;
		model.layers[static_cast<size_t>(warp_index)].removed = true;
	}
	if(model.flow0.empty() || model.flow1.empty() || model.mask.empty())
	{
		setError(error, "unsupported model: could not find flow and mask outputs");
		return false;
	}

	// Track channel counts and load weights in sequential layer order from flownet.bin.
	FILE *bfile = fopen(bin_path.c_str(), "rb");
	if(!bfile)
	{
		setError(error, "could not open " + bin_path);
		return false;
	}
	ncnn::DataReaderFromStdio dr(bfile);
	ncnn::ModelBinFromDataReader mb(dr);

	std::unordered_map<std::string, int> blob_channels;
	blob_channels["in0"] = 3;
	blob_channels["in1"] = 3;
	blob_channels["in2"] = 1;

	bool ok = true;
	for(ParamLayer &layer : model.layers)
	{
		if(layer.type == "Input")
		{
			if(layer.tops.size() == 1 && blob_channels.find(layer.tops[0]) == blob_channels.end())
				blob_channels[layer.tops[0]] = 3;
			continue;
		}
		if(layer.type == "MemoryData")
		{
			const int mw = layer.getInt(0, 0);
			const int mh = layer.getInt(1, 0);
			const int mc = layer.getInt(2, 0);
			const int load_type = layer.getInt(21, 1);
			layer.out_channels = (mc > 0) ? mc : 1;
			layer.kernel_h = (mh > 0) ? mh : 1;
			layer.kernel_w = (mw > 0) ? mw : 1;
			const int count = layer.out_channels * layer.kernel_h * layer.kernel_w;
			ncnn::Mat m = mb.load(count, load_type);
			if(m.empty() || m.elemsize != 4u)
			{
				setError(error, "failed to load MemoryData for " + layer.name);
				ok = false;
				break;
			}
			floatToHalfBuffer(static_cast<const float *>(m.data), static_cast<size_t>(count), layer.weights_fp16);
			if(layer.tops.size() == 1)
				blob_channels[layer.tops[0]] = layer.out_channels;
			continue;
		}
		if(layer.type == "Split")
		{
			const int c = blob_channels[layer.bottoms[0]];
			for(const std::string &top : layer.tops)
				blob_channels[top] = c;
			continue;
		}
		if(layer.type == "Concat")
		{
			const int axis = layer.getInt(0, 0);
			int c = 0;
			if(axis == 0)
			{
				for(const std::string &b : layer.bottoms)
					c += blob_channels[b];
			}
			else
			{
				c = blob_channels[layer.bottoms[0]];
			}
			blob_channels[layer.tops[0]] = c;
			continue;
		}
		if(layer.type == "Crop")
		{
			const int in_c = blob_channels[layer.bottoms[0]];
			int out_c = in_c;
			const std::vector<int> starts = layer.getIntArray(-23309);
			const std::vector<int> ends = layer.getIntArray(-23310);
			const std::vector<int> axes = layer.getIntArray(-23311);
			for(size_t i = 0; i < axes.size(); i++)
			{
				if(axes[i] == 0 && i < starts.size() && i < ends.size())
				{
					int s = starts[i];
					int e = ends[i];
					if(s < 0)
						s += in_c;
					if(e == -233 || e > in_c)
						e = in_c;
					else if(e < 0)
						e += in_c;
					out_c = e - s;
				}
			}
			blob_channels[layer.tops[0]] = out_c;
			continue;
		}
		if(layer.type == "PixelShuffle")
		{
			const int in_c = blob_channels[layer.bottoms[0]];
			const int factor = layer.getInt(0, 1);
			blob_channels[layer.tops[0]] = in_c / (factor * factor);
			continue;
		}
		if(layer.type == "Convolution" || layer.type == "Deconvolution")
		{
			const int in_c = blob_channels[layer.bottoms[0]];
			const int out_c = layer.getInt(0, 0);
			const int kw = layer.getInt(1, 0);
			const int kh = layer.getInt(11, kw);
			const int bias_term = layer.getInt(5, 0);
			const int weight_size = layer.getInt(6, 0);
			const int groups = layer.getInt(7, 1);

			if(out_c <= 0 || kw <= 0 || kh <= 0 || weight_size <= 0 || groups <= 0)
			{
				setError(error, "unsupported conv parameter in " + layer.name);
				ok = false;
				break;
			}
			if(in_c * out_c * kw * kh / groups != weight_size)
			{
				setError(error, "weight shape mismatch in " + layer.name);
				ok = false;
				break;
			}

			ncnn::Mat w = mb.load(weight_size, 0);
			if(w.empty() || w.elemsize != 4u)
			{
				setError(error, "failed to load weights for " + layer.name);
				ok = false;
				break;
			}
			layer.in_channels = in_c;
			layer.out_channels = out_c;
			layer.kernel_w = kw;
			layer.kernel_h = kh;

			const float *wptr = static_cast<const float *>(w.data);
			if(layer.type == "Deconvolution")
			{
				if(groups != 1)
				{
					setError(error, "grouped Deconvolution not supported in " + layer.name);
					ok = false;
					break;
				}
				transposeOIHWtoIOHWToHalf(wptr, out_c, in_c, kw * kh, layer.weights_fp16);
			}
			else
			{
				floatToHalfBuffer(wptr, static_cast<size_t>(weight_size), layer.weights_fp16);
			}

			if(bias_term != 0)
			{
				ncnn::Mat b = mb.load(out_c, 1);
				if(b.empty() || b.elemsize != 4u)
				{
					setError(error, "failed to load bias for " + layer.name);
					ok = false;
					break;
				}
				floatToHalfBuffer(static_cast<const float *>(b.data), static_cast<size_t>(out_c), layer.bias_fp16);
			}

			blob_channels[layer.tops[0]] = out_c;
			continue;
		}
		if(layer.type == "Interp" || layer.type == "ReLU" || layer.type == "Sigmoid"
			|| layer.type == "BinaryOp" || layer.type == "Eltwise" || layer.type == "rife.Warp")
		{
			blob_channels[layer.tops[0]] = blob_channels[layer.bottoms[0]];
			continue;
		}

		setError(error, "unsupported layer type in flownet.param: " + layer.type);
		ok = false;
		break;
	}

	fclose(bfile);
	return ok;
}

const char *const ROBZFG_METAL_SHADER_SOURCE = R"MSL(
#include <metal_stdlib>
using namespace metal;

struct TimestepParams
{
    int wp;
    int hp;
    float t;
};

struct WarpParams
{
    int w;
    int h;
    int c;
    int cstep;
};

struct Nv12ToNetParams
{
    int w;
    int h;
    int nw;
    int nh;
    int outw;
    int outh;
    int outcstep;
    int k;
    int full_range;
    int matrix; // 0 = BT.709, 1 = BT.601
};

struct SynthesizeParams
{
    int w;
    int h;
    int nw;
    int nh;
    int tw;
    int tcstep;
    int k;
    float t;
    int protect_static;
    float field_t;
    int bicubic;
};

kernel void fill_timestep(
    device half *out [[buffer(0)]],
    constant TimestepParams &p [[buffer(1)]],
    uint2 gid [[thread_position_in_grid]])
{
    if ((int)gid.x >= p.wp || (int)gid.y >= p.hp)
        return;
    out[(int)gid.y * p.wp + (int)gid.x] = half(p.t);
}

kernel void rife_warp2d(
    device const half *img [[buffer(0)]],
    device const half *flow [[buffer(1)]],
    device half *out [[buffer(2)]],
    constant WarpParams &p [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    int gx = (int)gid.x;
    int gy = (int)gid.y;
    if (gx >= p.w || gy >= p.h)
        return;

    int idx = gy * p.w + gx;
    float fx = float(flow[idx]);
    float fy = float(flow[p.cstep + idx]);
    float sx = float(gx) + fx;
    float sy = float(gy) + fy;

    int ix = (int)floor(sx);
    int iy = (int)floor(sy);
    int x0 = clamp(ix, 0, p.w - 1);
    int y0 = clamp(iy, 0, p.h - 1);
    int x1 = clamp(ix + 1, 0, p.w - 1);
    int y1 = clamp(iy + 1, 0, p.h - 1);

    float a = sx - float(ix);
    float b = sy - float(iy);
    float w00 = (1.0f - a) * (1.0f - b);
    float w01 = a * (1.0f - b);
    float w10 = (1.0f - a) * b;
    float w11 = a * b;

    int o00 = y0 * p.w + x0;
    int o01 = y0 * p.w + x1;
    int o10 = y1 * p.w + x0;
    int o11 = y1 * p.w + x1;

    for (int c = 0; c < p.c; c++)
    {
        int base = c * p.cstep;
        float v = float(img[base + o00]) * w00 + float(img[base + o01]) * w01
                + float(img[base + o10]) * w10 + float(img[base + o11]) * w11;
        out[base + idx] = half(v);
    }
}

inline float load_y_net(device const uchar *y_data, int w, int h, int x, int y)
{
    x = min(x, w - 1);
    y = min(y, h - 1);
    return float(y_data[y * w + x]);
}

inline float2 load_uv_net(device const uchar2 *uv_data, int cw, int cx, int cy)
{
    uchar2 v = uv_data[cy * cw + cx];
    return float2(float(v.x), float(v.y));
}

kernel void nv12_to_net(
    device const uchar *y_data [[buffer(0)]],
    device const uchar2 *uv_data [[buffer(1)]],
    device half *top_blob_data [[buffer(2)]],
    constant Nv12ToNetParams &p [[buffer(3)]],
    uint2 gid [[thread_position_in_grid]])
{
    int gx = (int)gid.x;
    int gy = (int)gid.y;
    if (gx >= p.outw || gy >= p.outh)
        return;

    int gi = gy * p.outw + gx;
    if (gx >= p.nw || gy >= p.nh)
    {
        top_blob_data[gi] = half(0.0f);
        top_blob_data[p.outcstep + gi] = half(0.0f);
        top_blob_data[2 * p.outcstep + gi] = half(0.0f);
        return;
    }

    float yv = 0.0f;
    for (int by = 0; by < p.k; by++)
        for (int bx = 0; bx < p.k; bx++)
            yv += load_y_net(y_data, p.w, p.h, gx * p.k + bx, gy * p.k + by);
    yv /= float(p.k * p.k);

    int cw = p.w / 2;
    int ch = p.h / 2;
    float centre = float(p.k - 1) * 0.5f;
    float fx = (float(gx * p.k) + centre) * 0.5f;
    float fy = (float(gy * p.k) + centre - 0.5f) * 0.5f;
    int cx0 = (int)floor(fx);
    int cy0 = (int)floor(fy);
    float ax = fx - float(cx0);
    float ay = fy - float(cy0);
    int cx1 = clamp(cx0 + 1, 0, cw - 1);
    int cy1 = clamp(cy0 + 1, 0, ch - 1);
    cx0 = clamp(cx0, 0, cw - 1);
    cy0 = clamp(cy0, 0, ch - 1);
    float2 uv = mix(mix(load_uv_net(uv_data, cw, cx0, cy0), load_uv_net(uv_data, cw, cx1, cy0), ax),
                    mix(load_uv_net(uv_data, cw, cx0, cy1), load_uv_net(uv_data, cw, cx1, cy1), ax), ay);

    float yn;
    float cb;
    float cr;
    if (p.full_range != 0)
    {
        yn = yv / 255.0f;
        cb = (uv.x - 128.0f) / 255.0f;
        cr = (uv.y - 128.0f) / 255.0f;
    }
    else
    {
        yn = (yv - 16.0f) / 219.0f;
        cb = (uv.x - 128.0f) / 224.0f;
        cr = (uv.y - 128.0f) / 224.0f;
    }

    float3 rgb;
    if (p.matrix == 0)
        rgb = float3(yn + 1.5748f * cr, yn - 0.187324f * cb - 0.468124f * cr, yn + 1.8556f * cb);
    else
        rgb = float3(yn + 1.402f * cr, yn - 0.344136f * cb - 0.714136f * cr, yn + 1.772f * cb);
    rgb = clamp(rgb, 0.0f, 1.0f);

    top_blob_data[gi] = half(rgb.x);
    top_blob_data[p.outcstep + gi] = half(rgb.y);
    top_blob_data[2 * p.outcstep + gi] = half(rgb.z);
}

constant float STATIC_MARGIN = 4.0f;
constant float STATIC_RANGE = 6.0f;
constant float STATIC_LEVEL = 3.0f;
constant float STATIC_LEVEL_RANGE = 5.0f;

inline float read_f(device const half *field_data, constant SynthesizeParams &p, int c, int x, int y)
{
    return float(field_data[c * p.tcstep + y * p.tw + x]);
}

inline void read_field(device const half *field_data, constant SynthesizeParams &p,
                       float2 pos, thread float2 &f0, thread float2 &f1, thread float &m)
{
    float2 n = (pos + 0.5f) / float(p.k) - 0.5f;
    n = clamp(n, float2(0.0f), float2(float(p.nw - 1), float(p.nh - 1)));
    int2 i0 = int2(floor(n));
    float2 a = n - float2(i0);
    int2 i1 = min(i0 + int2(1), int2(p.nw - 1, p.nh - 1));

    float v[5];
    for (int c = 0; c < 5; c++)
    {
        v[c] = mix(mix(read_f(field_data, p, c, i0.x, i0.y), read_f(field_data, p, c, i1.x, i0.y), a.x),
                   mix(read_f(field_data, p, c, i0.x, i1.y), read_f(field_data, p, c, i1.x, i1.y), a.x), a.y);
    }
    float scale = float(p.k);
    f0 = float2(v[0], v[1]) * scale;
    f1 = float2(v[2], v[3]) * scale;
    m = clamp(v[4], 0.0f, 1.0f);
}

inline void sample_field(device const half *field_data, constant SynthesizeParams &p,
                         float2 pos, thread float2 &f0, thread float2 &f1, thread float &m)
{
    read_field(field_data, p, pos, f0, f1, m);
    float dt = p.t - p.field_t;
    if (abs(dt) < 0.0001f)
        return;

    float2 shift = dt * (f1 - f0);
    float2 g0;
    float2 g1;
    float gm;
    read_field(field_data, p, pos - shift, g0, g1, gm);
    f0 = g0 - shift;
    f1 = g1 - shift;
    float w0 = gm * (1.0f - p.t);
    float w1 = (1.0f - gm) * p.t;
    m = (w0 + w1) > 0.00001f ? w0 / (w0 + w1) : 0.5f;
}

inline float y_at(device const uchar *y_data, int w, int h, int x, int y)
{
    return float(y_data[clamp(y, 0, h - 1) * w + clamp(x, 0, w - 1)]);
}

inline float2 uv_at(device const uchar2 *uv_data, int w, int h, int cx, int cy)
{
    int cw = w / 2;
    int ch = h / 2;
    uchar2 v = uv_data[clamp(cy, 0, ch - 1) * cw + clamp(cx, 0, cw - 1)];
    return float2(float(v.x), float(v.y));
}

inline float4 cubic_weights(float f)
{
    float f2 = f * f;
    float f3 = f2 * f;
    return float4(-0.5f * f3 + f2 - 0.5f * f,
                  1.5f * f3 - 2.5f * f2 + 1.0f,
                  -1.5f * f3 + 2.0f * f2 + 0.5f * f,
                  0.5f * f3 - 0.5f * f2);
}

inline float sample_luma(device const uchar *y_data, constant SynthesizeParams &p, float2 pos)
{
    int2 i = int2(floor(pos));
    float2 a = pos - float2(i);
    if (p.bicubic == 0)
    {
        return mix(mix(y_at(y_data, p.w, p.h, i.x, i.y), y_at(y_data, p.w, p.h, i.x + 1, i.y), a.x),
                   mix(y_at(y_data, p.w, p.h, i.x, i.y + 1), y_at(y_data, p.w, p.h, i.x + 1, i.y + 1), a.x), a.y);
    }
    float4 wx = cubic_weights(a.x);
    float4 wy = cubic_weights(a.y);
    float lo = 255.0f;
    float hi = 0.0f;
    float sum = 0.0f;
    for (int dy = -1; dy <= 2; dy++)
    {
        float row = 0.0f;
        for (int dx = -1; dx <= 2; dx++)
        {
            float v = y_at(y_data, p.w, p.h, i.x + dx, i.y + dy);
            row += wx[dx + 1] * v;
            if (dx >= 0 && dx <= 1 && dy >= 0 && dy <= 1)
            {
                lo = min(lo, v);
                hi = max(hi, v);
            }
        }
        sum += wy[dy + 1] * row;
    }
    return clamp(sum, lo, hi);
}

inline float2 sample_chroma(device const uchar2 *uv_data, int w, int h, float2 pos)
{
    float2 c = float2(pos.x * 0.5f, (pos.y - 0.5f) * 0.5f);
    int2 i = int2(floor(c));
    float2 a = c - float2(i);
    return mix(mix(uv_at(uv_data, w, h, i.x, i.y), uv_at(uv_data, w, h, i.x + 1, i.y), a.x),
               mix(uv_at(uv_data, w, h, i.x, i.y + 1), uv_at(uv_data, w, h, i.x + 1, i.y + 1), a.x), a.y);
}

inline uint to_byte(float v)
{
    return uint(clamp(floor(v + 0.5f), 0.0f, 255.0f));
}

inline float static_weight(device const uchar *y0_data, device const uchar *y1_data, constant SynthesizeParams &p,
                           float2 pos, float2 f0, float2 f1, float centre_a, float centre_b)
{
    if (p.protect_static == 0)
        return 0.0f;
    float2 df = f1 - f0;
    if (dot(f0, f0) < 0.16f && dot(f1, f1) < 0.16f && dot(df, df) < 0.24f)
        return 0.0f;

    int2 base = int2(floor(pos + 0.5f));
    float unchanged = 1.0f - clamp((abs(centre_a - centre_b) - STATIC_LEVEL) / STATIC_LEVEL_RANGE, 0.0f, 1.0f);
    if (unchanged <= 0.0f)
        return 0.0f;

    const int2 taps[5] = { int2(0, 0), int2(-1, 0), int2(1, 0), int2(0, -1), int2(0, 1) };
    int2 moved0 = int2(floor(pos + f0 + 0.5f));
    int2 moved1 = int2(floor(pos + f1 + 0.5f));
    int2 travel = int2(floor(df + 0.5f));
    float weight_sum = 0.0f;
    float along_motion = 0.0f;
    float in_place = 0.0f;
    float carried = 0.0f;
    for (int i = 0; i < 5; i++)
    {
        int2 q = base + taps[i];
        float a = (i == 0) ? centre_a : y_at(y0_data, p.w, p.h, q.x, q.y);
        float b = (i == 0) ? centre_b : y_at(y1_data, p.w, p.h, q.x, q.y);
        float difference = abs(a - b);
        float weight = (i == 0) ? 1.0f : 1.0f - clamp((difference - STATIC_LEVEL) / STATIC_LEVEL_RANGE, 0.0f, 1.0f);
        if (weight <= 0.0f)
            continue;
        weight_sum += weight;
        in_place += weight * difference;
        along_motion += weight * abs(y_at(y0_data, p.w, p.h, moved0.x + taps[i].x, moved0.y + taps[i].y)
                                     - y_at(y1_data, p.w, p.h, moved1.x + taps[i].x, moved1.y + taps[i].y));
        carried += weight * 0.5f * (abs(a - y_at(y1_data, p.w, p.h, q.x + travel.x, q.y + travel.y))
                                    + abs(b - y_at(y0_data, p.w, p.h, q.x - travel.x, q.y - travel.y)));
    }
    float against_motion = max(along_motion, carried) / weight_sum;
    float better = clamp(((against_motion - in_place / weight_sum) - STATIC_MARGIN) / STATIC_RANGE, 0.0f, 1.0f);
    float supported = clamp(weight_sum - 1.0f, 0.0f, 1.0f);
    return better * unchanged * supported;
}

kernel void robzfg_synthesize(
    device const half *field_data [[buffer(0)]],
    device const uchar *y0_data [[buffer(1)]],
    device const uchar2 *uv0_data [[buffer(2)]],
    device const uchar *y1_data [[buffer(3)]],
    device const uchar2 *uv1_data [[buffer(4)]],
    device uint *oy_data [[buffer(5)]],
    device uint *ouv_data [[buffer(6)]],
    constant SynthesizeParams &p [[buffer(7)]],
    uint2 gid [[thread_position_in_grid]])
{
    int gx = (int)gid.x;
    int gy = (int)gid.y;

    int words_per_row = p.w / 4;
    if (gx >= words_per_row || gy >= p.h)
        return;

    int x0 = gx * 4;
    device const uint *y0_words = reinterpret_cast<device const uint *>(y0_data);
    device const uint *y1_words = reinterpret_cast<device const uint *>(y1_data);
    uint y0_word = y0_words[gy * words_per_row + gx];
    uint y1_word = y1_words[gy * words_per_row + gx];

    float2 c_f0_0 = float2(0.0f);
    float2 c_f1_0 = float2(0.0f);
    float c_m_0 = 0.5f;
    float c_sw_0 = 0.0f;
    float2 c_f0_1 = float2(0.0f);
    float2 c_f1_1 = float2(0.0f);
    float c_m_1 = 0.5f;
    float c_sw_1 = 0.0f;

    uint yword = 0u;
    for (int i = 0; i < 4; i++)
    {
        float2 pos = float2(float(x0 + i), float(gy));
        float2 f0;
        float2 f1;
        float m;
        sample_field(field_data, p, pos, f0, f1, m);
        float v = sample_luma(y0_data, p, pos + f0) * m + sample_luma(y1_data, p, pos + f1) * (1.0f - m);
        float a0 = float((y0_word >> uint(i * 8)) & 0xFFu);
        float b0 = float((y1_word >> uint(i * 8)) & 0xFFu);
        float still = mix(a0, b0, p.t);
        float sw = static_weight(y0_data, y1_data, p, pos, f0, f1, a0, b0);
        v = mix(v, still, sw);
        yword |= to_byte(v) << uint(i * 8);
        if (i == 0)
        {
            c_f0_0 = f0;
            c_f1_0 = f1;
            c_m_0 = m;
            c_sw_0 = sw;
        }
        else if (i == 2)
        {
            c_f0_1 = f0;
            c_f1_1 = f1;
            c_m_1 = m;
            c_sw_1 = sw;
        }
    }
    oy_data[gy * words_per_row + gx] = yword;

    if ((gy & 1) == 0)
    {
        int cy = gy / 2;
        device const uint *uv0_words = reinterpret_cast<device const uint *>(uv0_data);
        device const uint *uv1_words = reinterpret_cast<device const uint *>(uv1_data);
        uint uv0_word = uv0_words[cy * words_per_row + gx];
        uint uv1_word = uv1_words[cy * words_per_row + gx];
        uint uvword = 0u;
        for (int j = 0; j < 2; j++)
        {
            float2 pos = float2(float(x0 + j * 2), float(gy) + 0.5f);
            float2 f0 = (j == 0) ? c_f0_0 : c_f0_1;
            float2 f1 = (j == 0) ? c_f1_0 : c_f1_1;
            float m = (j == 0) ? c_m_0 : c_m_1;
            float sw = (j == 0) ? c_sw_0 : c_sw_1;
            float2 uv = sample_chroma(uv0_data, p.w, p.h, pos + f0) * m
                      + sample_chroma(uv1_data, p.w, p.h, pos + f1) * (1.0f - m);
            uint shift = uint(j * 16);
            float2 uv0_s = float2(float((uv0_word >> shift) & 0xFFu), float((uv0_word >> (shift + 8u)) & 0xFFu));
            float2 uv1_s = float2(float((uv1_word >> shift) & 0xFFu), float((uv1_word >> (shift + 8u)) & 0xFFu));
            float2 still = mix(uv0_s, uv1_s, p.t);
            uv = mix(uv, still, sw);
            uvword |= to_byte(uv.x) << uint(j * 16);
            uvword |= to_byte(uv.y) << uint(j * 16 + 8);
        }
        ouv_data[cy * words_per_row + gx] = uvword;
    }
}
)MSL";

struct TimestepParams
{
	int32_t wp;
	int32_t hp;
	float t;
};

struct WarpParams
{
	int32_t w;
	int32_t h;
	int32_t c;
	int32_t cstep;
};

struct Nv12ToNetParams
{
	int32_t w;
	int32_t h;
	int32_t nw;
	int32_t nh;
	int32_t outw;
	int32_t outh;
	int32_t outcstep;
	int32_t k;
	int32_t full_range;
	int32_t matrix;
};

struct SynthesizeParams
{
	int32_t w;
	int32_t h;
	int32_t nw;
	int32_t nh;
	int32_t tw;
	int32_t tcstep;
	int32_t k;
	float t;
	int32_t protect_static;
	float field_t;
	int32_t bicubic;
};

struct MetalGpuFrame
{
	id<MTLBuffer> y_buf = nil;
	id<MTLBuffer> uv_buf = nil;
	id<MTLBuffer> net_buf = nil;
	MPSGraphTensorData *net_data = nil;
	bool valid = false;

	void release()
	{
		y_buf = nil;
		uv_buf = nil;
		net_buf = nil;
		net_data = nil;
		valid = false;
	}
};

MPSGraphTensor *applyActivation(MPSGraph *g, MPSGraphTensor *x, int act_type, float alpha)
{
	switch(act_type)
	{
	case 0:
		return x;
	case 1:
		return [g reLUWithTensor:x name:nil];
	case 2:
		return [g leakyReLUWithTensor:x alpha:(double)alpha name:nil];
	case 4:
		return [g sigmoidWithTensor:x name:nil];
	default:
		return nil;
	}
}

struct WarpOp
{
	std::string img_blob;
	std::string flow_blob;
	std::string out_blob;
	int c = 0;
	int h = 0;
	int w = 0;
	size_t flow_offset_bytes = 0;
};

struct PipelineStep
{
	bool is_warp = false;
	MPSGraphExecutable *exec = nil;
	std::vector<std::string> ordered_feed_blobs;
	std::vector<std::string> output_blobs;
	std::vector<WarpOp> warps;
};

struct CompiledPipeline
{
	std::vector<PipelineStep> steps;
	std::unordered_map<std::string, id<MTLBuffer>> inter_bufs;
	std::unordered_map<std::string, MPSGraphTensorData *> inter_data;

	~CompiledPipeline()
	{
		for(PipelineStep &s : steps)
			s.exec = nil;
		steps.clear();
		for(auto &kv : inter_data)
			kv.second = nil;
		inter_data.clear();
		for(auto &kv : inter_bufs)
			kv.second = nil;
		inter_bufs.clear();
	}
};

struct OpNode
{
	int layer_idx = -1;
	bool is_final_concat = false;
	std::vector<std::string> bottoms;
	std::string top;
};

bool computeOpShape(const ParamLayer &layer, const std::unordered_map<std::string, TensorShape3> &shapes,
	const std::vector<std::string> &bottoms, TensorShape3 &out_shape, std::string *error)
{
	if(layer.type == "MemoryData")
	{
		out_shape = { layer.out_channels, layer.kernel_h, layer.kernel_w };
		return true;
	}
	if(layer.type == "Concat")
	{
		const int axis = layer.getInt(0, 0);
		out_shape = shapes.at(bottoms[0]);
		int accum = 0;
		for(const std::string &b : bottoms)
		{
			const TensorShape3 &bs = shapes.at(b);
			if(axis == 0)
				accum += bs.c;
			else if(axis == 1)
				accum += bs.h;
			else
				accum += bs.w;
		}
		if(axis == 0)
			out_shape.c = accum;
		else if(axis == 1)
			out_shape.h = accum;
		else
			out_shape.w = accum;
		return true;
	}
	if(layer.type == "Interp")
	{
		const TensorShape3 &in_s = shapes.at(bottoms[0]);
		const int resize_type = layer.getInt(0, 0);
		if(resize_type != 1 && resize_type != 2)
		{
			setError(error, "unsupported Interp resize_type in " + layer.name);
			return false;
		}
		int out_h = layer.getInt(3, 0);
		int out_w = layer.getInt(4, 0);
		if(out_h <= 0 || out_w <= 0)
		{
			out_h = static_cast<int>(in_s.h * layer.getFloat(1, 1.0f));
			out_w = static_cast<int>(in_s.w * layer.getFloat(2, 1.0f));
		}
		out_shape = { in_s.c, out_h, out_w };
		return true;
	}
	if(layer.type == "Convolution" || layer.type == "Deconvolution")
	{
		const TensorShape3 &in_s = shapes.at(bottoms[0]);
		const int out_c = layer.out_channels;
		const int kw = layer.kernel_w;
		const int kh = layer.kernel_h;
		const int dil_w = layer.getInt(2, 1);
		const int dil_h = layer.getInt(12, dil_w);
		const int stride_w = layer.getInt(3, 1);
		const int stride_h = layer.getInt(13, stride_w);
		const int pad_l = layer.getInt(4, 0);
		const int pad_t = layer.getInt(14, pad_l);
		const int pad_r = layer.getInt(15, pad_l);
		const int pad_b = layer.getInt(16, pad_t);
		if(pad_l < 0 || pad_t < 0 || pad_r < 0 || pad_b < 0)
		{
			setError(error, "negative SAME padding not supported in Metal backend for " + layer.name);
			return false;
		}
		const int k_ext_h = dil_h * (kh - 1) + 1;
		const int k_ext_w = dil_w * (kw - 1) + 1;
		const int out_h = (layer.type == "Deconvolution")
			? ((in_s.h - 1) * stride_h - pad_t - pad_b + k_ext_h)
			: ((in_s.h + pad_t + pad_b - k_ext_h) / stride_h + 1);
		const int out_w = (layer.type == "Deconvolution")
			? ((in_s.w - 1) * stride_w - pad_l - pad_r + k_ext_w)
			: ((in_s.w + pad_l + pad_r - k_ext_w) / stride_w + 1);
		out_shape = { out_c, out_h, out_w };
		return true;
	}
	if(layer.type == "PixelShuffle")
	{
		const TensorShape3 &in_s = shapes.at(bottoms[0]);
		const int factor = layer.getInt(0, 1);
		out_shape = { in_s.c / (factor * factor), in_s.h * factor, in_s.w * factor };
		return true;
	}
	if(layer.type == "Crop")
	{
		TensorShape3 s = shapes.at(bottoms[0]);
		const std::vector<int> starts = layer.getIntArray(-23309);
		const std::vector<int> ends = layer.getIntArray(-23310);
		const std::vector<int> axes = layer.getIntArray(-23311);
		for(size_t i = 0; i < axes.size(); i++)
		{
			const int ax = axes[i];
			const int dim_size = (ax == 0) ? s.c : (ax == 1 ? s.h : s.w);
			int st = i < starts.size() ? starts[i] : 0;
			int en = i < ends.size() ? ends[i] : dim_size;
			if(st < 0)
				st += dim_size;
			if(en == -233 || en > dim_size)
				en = dim_size;
			else if(en < 0)
				en += dim_size;
			const int len = en - st;
			if(ax == 0)
				s.c = len;
			else if(ax == 1)
				s.h = len;
			else
				s.w = len;
		}
		out_shape = s;
		return true;
	}
	if(layer.type == "ReLU" || layer.type == "Sigmoid" || layer.type == "BinaryOp"
		|| layer.type == "Eltwise" || layer.type == "rife.Warp")
	{
		out_shape = shapes.at(bottoms[0]);
		return true;
	}
	setError(error, "unsupported layer type in MPSGraph builder: " + layer.type);
	return false;
}

bool emitGraphOp(MPSGraph *g, const OpNode &node, const ParsedModel &model,
	const std::unordered_map<std::string, TensorShape3> &all_shapes,
	std::unordered_map<std::string, MPSGraphTensor *> &tensors, std::string *error)
{
	if(node.is_final_concat)
	{
		NSMutableArray<MPSGraphTensor *> *arr = [NSMutableArray arrayWithCapacity:node.bottoms.size()];
		for(const std::string &b : node.bottoms)
			[arr addObject:tensors.at(b)];
		tensors[node.top] = [g concatTensors:arr dimension:1 name:@"robzfg_fields"];
		return true;
	}

	const ParamLayer &layer = model.layers[static_cast<size_t>(node.layer_idx)];
	if(layer.type == "MemoryData")
	{
		NSData *data = [NSData dataWithBytes:layer.weights_fp16.data()
									  length:layer.weights_fp16.size() * sizeof(uint16_t)];
		tensors[node.top] = [g constantWithData:data
										  shape:@[@1, @(layer.out_channels), @(layer.kernel_h), @(layer.kernel_w)]
									   dataType:MPSDataTypeFloat16];
		return true;
	}
	if(layer.type == "Concat")
	{
		const int axis = layer.getInt(0, 0);
		NSMutableArray<MPSGraphTensor *> *arr = [NSMutableArray arrayWithCapacity:node.bottoms.size()];
		for(const std::string &b : node.bottoms)
			[arr addObject:tensors.at(b)];
		tensors[node.top] = [g concatTensors:arr dimension:(NSInteger)(axis + 1) name:nil];
		return true;
	}

	if(layer.type == "Interp")
	{
		const TensorShape3 &in_s = all_shapes.at(node.bottoms[0]);
		const TensorShape3 &out_s = all_shapes.at(node.top);
		MPSGraphTensor *src = tensors.at(node.bottoms[0]);
		const int resize_type = layer.getInt(0, 0);
		const int align_corner = layer.getInt(6, 0);
		if(out_s.h == in_s.h && out_s.w == in_s.w)
		{
			tensors[node.top] = src;
			return true;
		}
		const MPSGraphResizeMode mode = (resize_type == 2) ? MPSGraphResizeBilinear : MPSGraphResizeNearest;
		tensors[node.top] = [g resizeTensor:src
									   size:@[@(out_s.h), @(out_s.w)]
									   mode:mode
							   centerResult:(align_corner == 0)
							   alignCorners:(align_corner != 0)
									 layout:MPSGraphTensorNamedDataLayoutNCHW
									   name:nil];
		return true;
	}

	if(layer.type == "Convolution" || layer.type == "Deconvolution")
	{
		const TensorShape3 &in_s = all_shapes.at(node.bottoms[0]);
		const TensorShape3 &out_s = all_shapes.at(node.top);
		MPSGraphTensor *src = tensors.at(node.bottoms[0]);
		const int out_c = layer.out_channels;
		const int kw = layer.kernel_w;
		const int kh = layer.kernel_h;
		const int dil_w = layer.getInt(2, 1);
		const int dil_h = layer.getInt(12, dil_w);
		const int stride_w = layer.getInt(3, 1);
		const int stride_h = layer.getInt(13, stride_w);
		const int pad_l = layer.getInt(4, 0);
		const int pad_t = layer.getInt(14, pad_l);
		const int pad_r = layer.getInt(15, pad_l);
		const int pad_b = layer.getInt(16, pad_t);
		const int groups = layer.getInt(7, 1);
		const int act_type = layer.getInt(9, 0);
		const std::vector<float> act_params = layer.getFloatArray(-23310);
		const float act_alpha = act_params.empty() ? 0.0f : act_params[0];

		MPSGraphConvolution2DOpDescriptor *desc = [MPSGraphConvolution2DOpDescriptor
			descriptorWithStrideInX:(NSUInteger)stride_w
						  strideInY:(NSUInteger)stride_h
					dilationRateInX:(NSUInteger)dil_w
					dilationRateInY:(NSUInteger)dil_h
							 groups:(NSUInteger)groups
						paddingLeft:(NSUInteger)pad_l
					   paddingRight:(NSUInteger)pad_r
						 paddingTop:(NSUInteger)pad_t
					  paddingBottom:(NSUInteger)pad_b
					   paddingStyle:MPSGraphPaddingStyleExplicit
						 dataLayout:MPSGraphTensorNamedDataLayoutNCHW
					  weightsLayout:MPSGraphTensorNamedDataLayoutOIHW];

		NSData *w_data = [NSData dataWithBytes:layer.weights_fp16.data()
										length:layer.weights_fp16.size() * sizeof(uint16_t)];
		MPSGraphTensor *out = nil;
		if(layer.type == "Deconvolution")
		{
			MPSGraphTensor *w_tensor = [g constantWithData:w_data
													 shape:@[@(in_s.c), @(out_c), @(kh), @(kw)]
												  dataType:MPSDataTypeFloat16];
			out = [g convolutionTranspose2DWithSourceTensor:src
											  weightsTensor:w_tensor
												outputShape:@[@1, @(out_c), @(out_s.h), @(out_s.w)]
												 descriptor:desc
													   name:nil];
		}
		else
		{
			MPSGraphTensor *w_tensor = [g constantWithData:w_data
													 shape:@[@(out_c), @(in_s.c / groups), @(kh), @(kw)]
												  dataType:MPSDataTypeFloat16];
			out = [g convolution2DWithSourceTensor:src
									 weightsTensor:w_tensor
										descriptor:desc
											  name:nil];
		}

		if(!layer.bias_fp16.empty())
		{
			NSData *b_data = [NSData dataWithBytes:layer.bias_fp16.data()
											length:layer.bias_fp16.size() * sizeof(uint16_t)];
			MPSGraphTensor *b_tensor = [g constantWithData:b_data
													 shape:@[@1, @(out_c), @1, @1]
												  dataType:MPSDataTypeFloat16];
			out = [g additionWithPrimaryTensor:out secondaryTensor:b_tensor name:nil];
		}

		out = applyActivation(g, out, act_type, act_alpha);
		if(!out)
		{
			setError(error, "unsupported activation type in " + layer.name);
			return false;
		}
		tensors[node.top] = out;
		return true;
	}

	if(layer.type == "PixelShuffle")
	{
		MPSGraphTensor *src = tensors.at(node.bottoms[0]);
		const int factor = layer.getInt(0, 1);
		const int mode = layer.getInt(1, 0);
		tensors[node.top] = [g depthToSpace2DTensor:src
										  widthAxis:3
										 heightAxis:2
										  depthAxis:1
										  blockSize:(NSUInteger)factor
							   usePixelShuffleOrder:(mode == 0)
											   name:nil];
		return true;
	}

	if(layer.type == "Crop")
	{
		TensorShape3 s = all_shapes.at(node.bottoms[0]);
		MPSGraphTensor *cur = tensors.at(node.bottoms[0]);
		const std::vector<int> starts = layer.getIntArray(-23309);
		const std::vector<int> ends = layer.getIntArray(-23310);
		const std::vector<int> axes = layer.getIntArray(-23311);
		for(size_t i = 0; i < axes.size(); i++)
		{
			const int ax = axes[i];
			const int dim_size = (ax == 0) ? s.c : (ax == 1 ? s.h : s.w);
			int st = i < starts.size() ? starts[i] : 0;
			int en = i < ends.size() ? ends[i] : dim_size;
			if(st < 0)
				st += dim_size;
			if(en == -233 || en > dim_size)
				en = dim_size;
			else if(en < 0)
				en += dim_size;
			const int len = en - st;
			if(st != 0 || len != dim_size)
				cur = [g sliceTensor:cur dimension:(NSUInteger)(ax + 1) start:(NSInteger)st length:(NSInteger)len name:nil];
			if(ax == 0)
				s.c = len;
			else if(ax == 1)
				s.h = len;
			else
				s.w = len;
		}
		tensors[node.top] = cur;
		return true;
	}

	if(layer.type == "ReLU")
	{
		const float slope = layer.getFloat(0, 0.0f);
		MPSGraphTensor *src = tensors.at(node.bottoms[0]);
		tensors[node.top] = (slope == 0.0f)
			? [g reLUWithTensor:src name:nil]
			: [g leakyReLUWithTensor:src alpha:(double)slope name:nil];
		return true;
	}

	if(layer.type == "Sigmoid")
	{
		tensors[node.top] = [g sigmoidWithTensor:tensors.at(node.bottoms[0]) name:nil];
		return true;
	}

	if(layer.type == "BinaryOp")
	{
		const int op_type = layer.getInt(0, 0);
		const int with_scalar = layer.getInt(1, 0);
		const float b_val = layer.getFloat(2, 0.0f);
		MPSGraphTensor *a = tensors.at(node.bottoms[0]);
		MPSGraphTensor *b = (with_scalar != 0)
			? [g constantWithScalar:(double)b_val shape:@[@1, @1, @1, @1] dataType:MPSDataTypeFloat16]
			: tensors.at(node.bottoms[1]);

		MPSGraphTensor *out = nil;
		switch(op_type)
		{
		case 0:
			out = [g additionWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 1:
			out = [g subtractionWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 2:
			out = [g multiplicationWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 3:
			out = [g divisionWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 4:
			out = [g maximumWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 5:
			out = [g minimumWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 6:
			out = [g powerWithPrimaryTensor:a secondaryTensor:b name:nil];
			break;
		case 7:
			out = [g subtractionWithPrimaryTensor:b secondaryTensor:a name:nil];
			break;
		case 8:
			out = [g divisionWithPrimaryTensor:b secondaryTensor:a name:nil];
			break;
		default:
			setError(error, "unsupported BinaryOp type in " + layer.name);
			return false;
		}
		tensors[node.top] = out;
		return true;
	}

	if(layer.type == "Eltwise")
	{
		const int op_type = layer.getInt(0, 0);
		const std::vector<float> coeffs = layer.getFloatArray(-23301);
		auto termAt = [&](size_t idx) -> MPSGraphTensor * {
			MPSGraphTensor *t = tensors.at(node.bottoms[idx]);
			if(op_type == 1 && idx < coeffs.size() && coeffs[idx] != 1.0f)
			{
				MPSGraphTensor *c = [g constantWithScalar:(double)coeffs[idx] shape:@[@1, @1, @1, @1] dataType:MPSDataTypeFloat16];
				t = [g multiplicationWithPrimaryTensor:t secondaryTensor:c name:nil];
			}
			return t;
		};
		MPSGraphTensor *acc = termAt(0);
		for(size_t i = 1; i < node.bottoms.size(); i++)
		{
			MPSGraphTensor *rhs = termAt(i);
			if(op_type == 0)
				acc = [g multiplicationWithPrimaryTensor:acc secondaryTensor:rhs name:nil];
			else if(op_type == 1)
				acc = [g additionWithPrimaryTensor:acc secondaryTensor:rhs name:nil];
			else
				acc = [g maximumWithPrimaryTensor:acc secondaryTensor:rhs name:nil];
		}
		tensors[node.top] = acc;
		return true;
	}

	setError(error, "unexpected op in MPSGraph stage: " + layer.type);
	return false;
}

std::unique_ptr<CompiledPipeline> compilePipelineForSize(id<MTLDevice> device, const ParsedModel &model,
	int wp, int hp, std::string *error)
{
	@autoreleasepool
	{
		std::unordered_map<std::string, std::string> canonical;
		std::unordered_map<std::string, TensorShape3> all_shapes;
		canonical["in0"] = "in0";
		canonical["in1"] = "in1";
		canonical["in2"] = "in2";
		all_shapes["in0"] = { 3, hp, wp };
		all_shapes["in1"] = { 3, hp, wp };
		all_shapes["in2"] = { 1, hp, wp };

		auto canonOf = [&](const std::string &name) -> std::string {
			auto it = canonical.find(name);
			return it != canonical.end() ? it->second : name;
		};

		std::unordered_set<std::string> available = { "in0", "in1", "in2" };
		std::vector<OpNode> nodes;

		for(size_t i = 0; i < model.layers.size(); i++)
		{
			const ParamLayer &layer = model.layers[i];
			if(layer.removed)
				continue;
			if(layer.type == "Input")
			{
				if(layer.tops.size() == 1)
				{
					canonical[layer.tops[0]] = layer.tops[0];
					if(all_shapes.find(layer.tops[0]) == all_shapes.end())
						all_shapes[layer.tops[0]] = { 3, hp, wp };
					available.insert(layer.tops[0]);
				}
				continue;
			}
			if(layer.type == "Split")
			{
				const std::string src = canonOf(layer.bottoms[0]);
				for(const std::string &top : layer.tops)
					canonical[top] = src;
				continue;
			}
			if(layer.tops.size() != 1)
			{
				setError(error, "unexpected multi-output layer in flownet: " + layer.name);
				return nullptr;
			}

			OpNode node;
			node.layer_idx = static_cast<int>(i);
			node.top = layer.tops[0];
			node.bottoms.reserve(layer.bottoms.size());
			for(const std::string &b : layer.bottoms)
				node.bottoms.push_back(canonOf(b));
			canonical[node.top] = node.top;

			TensorShape3 out_s;
			if(!computeOpShape(layer, all_shapes, node.bottoms, out_s, error))
				return nullptr;
			all_shapes[node.top] = out_s;
			nodes.push_back(std::move(node));
		}

		OpNode final_node;
		final_node.is_final_concat = true;
		final_node.bottoms = { canonOf(model.flow0), canonOf(model.flow1), canonOf(model.mask) };
		final_node.top = "robzfg_fields";
		canonical["robzfg_fields"] = "robzfg_fields";
		all_shapes["robzfg_fields"] = { 5, hp, wp };
		nodes.push_back(std::move(final_node));

		// Zero-copy channel-slice aliasing for rife.Warp flow inputs (avoids materializing slice buffers).
		std::unordered_map<std::string, std::pair<std::string, int>> crop_alias;
		for(const OpNode &n : nodes)
		{
			if(n.is_final_concat)
				continue;
			const ParamLayer &layer = model.layers[static_cast<size_t>(n.layer_idx)];
			if(layer.type == "Crop")
			{
				const std::vector<int> starts = layer.getIntArray(-23309);
				const std::vector<int> axes = layer.getIntArray(-23311);
				if(axes.size() == 1 && axes[0] == 0 && starts.size() == 1)
				{
					const TensorShape3 &base_s = all_shapes.at(n.bottoms[0]);
					int st = starts[0];
					if(st < 0)
						st += base_s.c;
					if(st >= 0 && st < base_s.c)
					{
						std::string base_blob = n.bottoms[0];
						auto cit = crop_alias.find(base_blob);
						if(cit != crop_alias.end())
						{
							st += cit->second.second;
							base_blob = cit->second.first;
						}
						crop_alias[n.top] = { base_blob, st };
					}
				}
			}
		}

		std::unordered_map<std::string, size_t> warp_flow_offset;
		for(OpNode &n : nodes)
		{
			if(!n.is_final_concat && model.layers[static_cast<size_t>(n.layer_idx)].type == "rife.Warp")
			{
				auto it = crop_alias.find(n.bottoms[1]);
				if(it != crop_alias.end())
				{
					const TensorShape3 &base_s = all_shapes.at(it->second.first);
					n.bottoms[1] = it->second.first;
					warp_flow_offset[n.top] = static_cast<size_t>(it->second.second) * base_s.h * base_s.w * sizeof(uint16_t);
				}
			}
		}

		{
			std::unordered_map<std::string, size_t> top_to_node;
			for(size_t i = 0; i < nodes.size(); i++)
				top_to_node[nodes[i].top] = i;

			std::vector<bool> live(nodes.size(), false);
			std::vector<size_t> worklist;
			worklist.push_back(nodes.size() - 1);
			live[nodes.size() - 1] = true;
			while(!worklist.empty())
			{
				const size_t idx = worklist.back();
				worklist.pop_back();
				for(const std::string &b : nodes[idx].bottoms)
				{
					auto it = top_to_node.find(b);
					if(it != top_to_node.end() && !live[it->second])
					{
						live[it->second] = true;
						worklist.push_back(it->second);
					}
				}
			}

			std::vector<OpNode> live_nodes;
			live_nodes.reserve(nodes.size());
			for(size_t i = 0; i < nodes.size(); i++)
			{
				if(live[i])
					live_nodes.push_back(std::move(nodes[i]));
			}
			nodes = std::move(live_nodes);
		}

		struct Wave
		{
			bool is_warp = false;
			std::vector<size_t> node_indices;
		};
		std::vector<Wave> waves;
		std::vector<bool> scheduled(nodes.size(), false);
		size_t remaining = nodes.size();

		while(remaining > 0)
		{
			bool made_progress = false;
			Wave gw{ false, {} };
			bool added = true;
			while(added)
			{
				added = false;
				for(size_t i = 0; i < nodes.size(); i++)
				{
					if(scheduled[i])
						continue;
					const OpNode &n = nodes[i];
					if(!n.is_final_concat && model.layers[static_cast<size_t>(n.layer_idx)].type == "rife.Warp")
						continue;
					bool deps_ready = true;
					for(const std::string &b : n.bottoms)
					{
						if(available.find(b) == available.end())
						{
							deps_ready = false;
							break;
						}
					}
					if(deps_ready)
					{
						scheduled[i] = true;
						remaining--;
						available.insert(n.top);
						gw.node_indices.push_back(i);
						added = true;
					}
				}
			}
			if(!gw.node_indices.empty())
			{
				made_progress = true;
				waves.push_back(std::move(gw));
			}

			Wave ww{ true, {} };
			for(size_t i = 0; i < nodes.size(); i++)
			{
				if(scheduled[i])
					continue;
				const OpNode &n = nodes[i];
				if(n.is_final_concat || model.layers[static_cast<size_t>(n.layer_idx)].type != "rife.Warp")
					continue;
				bool deps_ready = true;
				for(const std::string &b : n.bottoms)
				{
					if(available.find(b) == available.end())
					{
						deps_ready = false;
						break;
					}
				}
				if(deps_ready)
				{
					scheduled[i] = true;
					remaining--;
					available.insert(n.top);
					ww.node_indices.push_back(i);
				}
			}
			if(!ww.node_indices.empty())
			{
				made_progress = true;
				waves.push_back(std::move(ww));
			}

			if(!made_progress)
			{
				std::string detail = "cyclic or disconnected flownet graph:";
				for(size_t i = 0; i < nodes.size(); i++)
				{
					if(scheduled[i])
						continue;
					const OpNode &n = nodes[i];
					detail += " [" + (n.is_final_concat ? std::string("robzfg_fields") : model.layers[static_cast<size_t>(n.layer_idx)].name) + " needs";
					for(const std::string &b : n.bottoms)
					{
						if(available.find(b) == available.end())
							detail += " " + b;
					}
					detail += "]";
					break;
				}
				setError(error, detail);
				return nullptr;
			}
		}

		std::unordered_set<std::string> cross_step_blobs;
		cross_step_blobs.insert("robzfg_fields");
		for(const Wave &w : waves)
		{
			std::unordered_set<std::string> produced;
			for(size_t idx : w.node_indices)
				produced.insert(nodes[idx].top);
			for(size_t idx : w.node_indices)
			{
				for(const std::string &b : nodes[idx].bottoms)
				{
					if(produced.find(b) == produced.end())
						cross_step_blobs.insert(b);
				}
			}
		}

		auto pipeline = std::make_unique<CompiledPipeline>();
		for(const std::string &blob : cross_step_blobs)
		{
			if(blob == "in0" || blob == "in1" || blob == "in2" || blob == "robzfg_fields")
				continue;
			const TensorShape3 &s = all_shapes.at(blob);
			const size_t bytes = static_cast<size_t>(s.c) * s.h * s.w * sizeof(uint16_t);
			id<MTLBuffer> buf = [device newBufferWithLength:bytes options:MTLResourceStorageModePrivate];
			if(!buf)
			{
				setError(error, "Metal intermediate buffer allocation failed");
				return nullptr;
			}
			MPSGraphTensorData *td = [[MPSGraphTensorData alloc] initWithMTLBuffer:buf
																			  shape:@[@1, @(s.c), @(s.h), @(s.w)]
																		   dataType:MPSDataTypeFloat16];
			pipeline->inter_bufs[blob] = buf;
			pipeline->inter_data[blob] = td;
		}

		MPSGraphDevice *gdev = [MPSGraphDevice deviceWithMTLDevice:device];
		MPSGraphCompilationDescriptor *cd = [[MPSGraphCompilationDescriptor alloc] init];
		cd.optimizationLevel = MPSGraphOptimizationLevel1;
		cd.waitForCompilationCompletion = YES;

		for(const Wave &w : waves)
		{
			PipelineStep step;
			if(w.is_warp)
			{
				step.is_warp = true;
				for(size_t idx : w.node_indices)
				{
					const OpNode &n = nodes[idx];
					const TensorShape3 &s = all_shapes.at(n.bottoms[0]);
					auto off_it = warp_flow_offset.find(n.top);
					const size_t off = (off_it != warp_flow_offset.end()) ? off_it->second : 0u;
					step.warps.push_back({ n.bottoms[0], n.bottoms[1], n.top, s.c, s.h, s.w, off });
				}
				pipeline->steps.push_back(std::move(step));
				continue;
			}

			step.is_warp = false;
			std::unordered_set<std::string> produced;
			for(size_t idx : w.node_indices)
				produced.insert(nodes[idx].top);

			std::vector<std::string> feed_blobs;
			std::unordered_set<std::string> seen_feeds;
			for(size_t idx : w.node_indices)
			{
				const OpNode &n = nodes[idx];
				if(cross_step_blobs.find(n.top) != cross_step_blobs.end())
					step.output_blobs.push_back(n.top);
				for(const std::string &b : n.bottoms)
				{
					if(produced.find(b) == produced.end() && seen_feeds.insert(b).second)
						feed_blobs.push_back(b);
				}
			}

			MPSGraph *g = [[MPSGraph alloc] init];
			std::unordered_map<std::string, MPSGraphTensor *> tensors;
			std::unordered_map<const void *, std::string> ph_to_blob;
			NSMutableDictionary<MPSGraphTensor *, MPSGraphShapedType *> *feeds = [NSMutableDictionary dictionary];

			for(const std::string &b : feed_blobs)
			{
				const TensorShape3 &s = all_shapes.at(b);
				MPSShape *sh = @[@1, @(s.c), @(s.h), @(s.w)];
				MPSGraphTensor *ph = [g placeholderWithShape:sh
													dataType:MPSDataTypeFloat16
														name:[NSString stringWithUTF8String:b.c_str()]];
				tensors[b] = ph;
				feeds[ph] = [[MPSGraphShapedType alloc] initWithShape:sh dataType:MPSDataTypeFloat16];
				ph_to_blob[(__bridge const void *)ph] = b;
			}

			for(size_t idx : w.node_indices)
			{
				if(!emitGraphOp(g, nodes[idx], model, all_shapes, tensors, error))
					return nullptr;
			}

			NSMutableArray<MPSGraphTensor *> *targets = [NSMutableArray arrayWithCapacity:step.output_blobs.size()];
			for(const std::string &out_blob : step.output_blobs)
				[targets addObject:tensors.at(out_blob)];

			MPSGraphExecutable *exec = [g compileWithDevice:gdev
													  feeds:feeds
											  targetTensors:targets
										   targetOperations:nil
									  compilationDescriptor:cd];
			if(!exec)
			{
				setError(error, "MPSGraph stage compilation failed");
				return nullptr;
			}
			exec.options = MPSGraphOptionsNone;

			step.ordered_feed_blobs.reserve(exec.feedTensors.count);
			for(MPSGraphTensor *ft in exec.feedTensors)
			{
				auto it = ph_to_blob.find((__bridge const void *)ft);
				if(it != ph_to_blob.end())
				{
					step.ordered_feed_blobs.push_back(it->second);
				}
				else
				{
					setError(error, "unexpected feedTensor order mapping in MPSGraphExecutable");
					return nullptr;
				}
			}
			step.exec = exec;
			pipeline->steps.push_back(std::move(step));
		}

		return pipeline;
	}
}

void copyPlane(uint8_t *dst, const uint8_t *src, int dst_stride, int src_stride, int width, int rows)
{
	if(dst_stride == width && src_stride == width)
	{
		memcpy(dst, src, static_cast<size_t>(width) * rows);
		return;
	}
	for(int row = 0; row < rows; row++)
		memcpy(dst + static_cast<size_t>(row) * dst_stride, src + static_cast<size_t>(row) * src_stride, static_cast<size_t>(width));
}

} // namespace

struct MetalRifeBackend::Impl
{
	bool inited = false;
	std::string gpu_name;

	id<MTLDevice> device = nil;
	id<MTLCommandQueue> queue = nil;
	id<MTLComputePipelineState> pso_fill_timestep = nil;
	id<MTLComputePipelineState> pso_warp2d = nil;
	id<MTLComputePipelineState> pso_nv12_to_net = nil;
	id<MTLComputePipelineState> pso_synthesize = nil;

	ParsedModel model;
	std::unordered_map<uint64_t, std::unique_ptr<CompiledPipeline>> pipeline_cache;
	CompiledPipeline *current_pipeline = nullptr;

	int padding = 32;
	int divisor = 2;
	bool protect_static = true;
	bool sharp_sampling = true;

	int w = 0;
	int h = 0;
	int nw = 0;
	int nh = 0;
	int wp = 0;
	int hp = 0;
	ColorInfo color;

	MetalGpuFrame prev;
	MetalGpuFrame cur;
	bool pending = false;

	id<MTLBuffer> timestep_buf = nil;
	MPSGraphTensorData *timestep_data = nil;
	float timestep_value = -1.f;
	bool timestep_valid = false;

	id<MTLBuffer> fields_buf = nil;
	MPSGraphTensorData *fields_data = nil;
	float fields_time = -1.f;
	bool fields_valid = false;

	id<MTLBuffer> out_y_buf = nil;
	id<MTLBuffer> out_uv_buf = nil;

	~Impl()
	{
		releaseFrames();
		current_pipeline = nullptr;
		pipeline_cache.clear();
		pso_fill_timestep = nil;
		pso_warp2d = nil;
		pso_nv12_to_net = nil;
		pso_synthesize = nil;
		queue = nil;
		device = nil;
	}

	void dropFields()
	{
		fields_time = -1.f;
		fields_valid = false;
	}

	void releaseFrames()
	{
		prev.release();
		cur.release();
		pending = false;
		timestep_buf = nil;
		timestep_data = nil;
		timestep_value = -1.f;
		timestep_valid = false;
		fields_buf = nil;
		fields_data = nil;
		out_y_buf = nil;
		out_uv_buf = nil;
		dropFields();
	}

	bool ensurePipeline(std::string *error)
	{
		if(wp <= 0 || hp <= 0)
			return false;
		const uint64_t key = (static_cast<uint64_t>(static_cast<uint32_t>(wp)) << 32) | static_cast<uint32_t>(hp);
		auto it = pipeline_cache.find(key);
		if(it != pipeline_cache.end())
		{
			current_pipeline = it->second.get();
			return true;
		}
		std::unique_ptr<CompiledPipeline> p = compilePipelineForSize(device, model, wp, hp, error);
		if(!p)
			return false;
		current_pipeline = p.get();
		pipeline_cache[key] = std::move(p);
		return true;
	}

	bool ensureWorkingBuffers(std::string *error)
	{
		const size_t ts_bytes = static_cast<size_t>(hp) * wp * sizeof(uint16_t);
		if(!timestep_buf || timestep_buf.length != ts_bytes)
		{
			timestep_buf = [device newBufferWithLength:ts_bytes options:MTLResourceStorageModePrivate];
			if(!timestep_buf)
			{
				setError(error, "Metal timestep buffer allocation failed");
				return false;
			}
			timestep_data = [[MPSGraphTensorData alloc] initWithMTLBuffer:timestep_buf
																	 shape:@[@1, @1, @(hp), @(wp)]
																  dataType:MPSDataTypeFloat16];
			timestep_valid = false;
		}

		const size_t field_bytes = 5u * static_cast<size_t>(hp) * wp * sizeof(uint16_t);
		if(!fields_buf || fields_buf.length != field_bytes)
		{
			fields_buf = [device newBufferWithLength:field_bytes options:MTLResourceStorageModePrivate];
			if(!fields_buf)
			{
				setError(error, "Metal fields buffer allocation failed");
				return false;
			}
			fields_data = [[MPSGraphTensorData alloc] initWithMTLBuffer:fields_buf
																   shape:@[@1, @5, @(hp), @(wp)]
																dataType:MPSDataTypeFloat16];
			dropFields();
		}

		const size_t y_bytes = static_cast<size_t>(w) * h;
		const size_t uv_bytes = static_cast<size_t>(w) * (h / 2);
		if(!out_y_buf || out_y_buf.length != y_bytes)
			out_y_buf = [device newBufferWithLength:y_bytes options:MTLResourceStorageModeShared];
		if(!out_uv_buf || out_uv_buf.length != uv_bytes)
			out_uv_buf = [device newBufferWithLength:uv_bytes options:MTLResourceStorageModeShared];
		if(!out_y_buf || !out_uv_buf)
		{
			setError(error, "Metal output buffer allocation failed");
			return false;
		}
		return true;
	}

	bool ensureFrameBuffers(MetalGpuFrame &frame, std::string *error)
	{
		const size_t y_bytes = static_cast<size_t>(w) * h;
		const size_t uv_bytes = static_cast<size_t>(w) * (h / 2);
		const size_t net_bytes = 3u * static_cast<size_t>(hp) * wp * sizeof(uint16_t);
		if(!frame.y_buf || frame.y_buf.length != y_bytes)
			frame.y_buf = [device newBufferWithLength:y_bytes options:MTLResourceStorageModeShared];
		if(!frame.uv_buf || frame.uv_buf.length != uv_bytes)
			frame.uv_buf = [device newBufferWithLength:uv_bytes options:MTLResourceStorageModeShared];
		if(!frame.net_buf || frame.net_buf.length != net_bytes)
		{
			frame.net_buf = [device newBufferWithLength:net_bytes options:MTLResourceStorageModePrivate];
			if(frame.net_buf)
			{
				frame.net_data = [[MPSGraphTensorData alloc] initWithMTLBuffer:frame.net_buf
																		shape:@[@1, @3, @(hp), @(wp)]
																	 dataType:MPSDataTypeFloat16];
			}
		}
		if(!frame.y_buf || !frame.uv_buf || !frame.net_buf || !frame.net_data)
		{
			frame.release();
			setError(error, "Metal frame buffer allocation failed");
			return false;
		}
		return true;
	}

	void encodeNv12ToNet(id<MTLCommandBuffer> cmd, MetalGpuFrame &frame)
	{
		id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
		Nv12ToNetParams params{};
		params.w = w;
		params.h = h;
		params.nw = nw;
		params.nh = nh;
		params.outw = wp;
		params.outh = hp;
		params.outcstep = wp * hp;
		params.k = divisor;
		params.full_range = color.full_range ? 1 : 0;
		params.matrix = (color.matrix == ColorMatrix::BT709) ? 0 : 1;

		[enc setComputePipelineState:pso_nv12_to_net];
		[enc setBuffer:frame.y_buf offset:0 atIndex:0];
		[enc setBuffer:frame.uv_buf offset:0 atIndex:1];
		[enc setBuffer:frame.net_buf offset:0 atIndex:2];
		[enc setBytes:&params length:sizeof(params) atIndex:3];
		[enc dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(wp), static_cast<NSUInteger>(hp), 1)
			threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
		[enc endEncoding];

		pending = false;
		frame.valid = true;
	}
};

MetalRifeBackend::MetalRifeBackend() : d(new Impl) {}

MetalRifeBackend::~MetalRifeBackend() = default;

bool MetalRifeBackend::isEnabled()
{
	const char *env = std::getenv("ROBZFG_USE_VULKAN");
	return !(env && env[0] && env[0] != '0');
}

std::vector<GpuDevice> MetalRifeBackend::enumerateGpus()
{
	@autoreleasepool
	{
		std::vector<GpuDevice> devices;
		NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
		id<MTLDevice> def = MTLCreateSystemDefaultDevice();
		if(all.count == 0 && def)
		{
			GpuDevice gd;
			gd.index = 0;
			gd.name = std::string(def.name.UTF8String) + " (Metal)";
			gd.discrete = !def.hasUnifiedMemory;
			devices.push_back(gd);
			return devices;
		}
		for(NSUInteger i = 0; i < all.count; i++)
		{
			id<MTLDevice> dev = all[i];
			GpuDevice gd;
			gd.index = static_cast<int>(i);
			gd.name = std::string(dev.name.UTF8String) + " (Metal)";
			gd.discrete = !dev.hasUnifiedMemory;
			devices.push_back(gd);
		}
		return devices;
	}
}

bool MetalRifeBackend::init(const RifeInterpolator::Config &config, std::string *error)
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

	@autoreleasepool
	{
		NSArray<id<MTLDevice>> *all = MTLCopyAllDevices();
		id<MTLDevice> selected = nil;
		if(config.gpu_index >= 0 && static_cast<NSUInteger>(config.gpu_index) < all.count)
		{
			selected = all[static_cast<NSUInteger>(config.gpu_index)];
		}
		else
		{
			for(id<MTLDevice> dev in all)
			{
				if(!dev.hasUnifiedMemory)
				{
					selected = dev;
					break;
				}
			}
			if(!selected)
				selected = MTLCreateSystemDefaultDevice();
			if(!selected && all.count > 0)
				selected = all[0];
		}

		if(!selected)
		{
			setError(error, "no Metal GPU device found");
			return false;
		}
		if(![selected supportsFamily:MTLGPUFamilyApple6] && ![selected supportsFamily:MTLGPUFamilyApple5])
		{
			setError(error, "Metal device lacks required compute/FP16 support");
			return false;
		}

		d->device = selected;
		d->queue = [d->device newCommandQueue];
		if(!d->queue)
		{
			setError(error, "failed to create Metal command queue");
			return false;
		}
		d->gpu_name = std::string(d->device.name.UTF8String) + " (Metal)";

		NSError *ns_err = nil;
		MTLCompileOptions *opts = [[MTLCompileOptions alloc] init];
		if(@available(macOS 15.0, *))
		{
			opts.mathMode = MTLMathModeFast;
		}
		else
		{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
			opts.fastMathEnabled = YES;
#pragma clang diagnostic pop
		}
		NSString *src = [NSString stringWithUTF8String:ROBZFG_METAL_SHADER_SOURCE];
		id<MTLLibrary> lib = [d->device newLibraryWithSource:src options:opts error:&ns_err];
		if(!lib)
		{
			setError(error, ns_err ? ns_err.localizedDescription.UTF8String : "failed to compile Metal shaders");
			return false;
		}

		auto makePso = [&](NSString *name) -> id<MTLComputePipelineState> {
			id<MTLFunction> fn = [lib newFunctionWithName:name];
			if(!fn)
				return nil;
			return [d->device newComputePipelineStateWithFunction:fn error:&ns_err];
		};

		d->pso_fill_timestep = makePso(@"fill_timestep");
		d->pso_warp2d = makePso(@"rife_warp2d");
		d->pso_nv12_to_net = makePso(@"nv12_to_net");
		d->pso_synthesize = makePso(@"robzfg_synthesize");
		if(!d->pso_fill_timestep || !d->pso_warp2d || !d->pso_nv12_to_net || !d->pso_synthesize)
		{
			setError(error, ns_err ? ns_err.localizedDescription.UTF8String : "failed to create Metal compute pipelines");
			return false;
		}

		const std::string param_path = config.model_dir + "/flownet.param";
		const std::string bin_path = config.model_dir + "/flownet.bin";
		if(!loadRifeModel(param_path, bin_path, d->model, error))
			return false;

		d->padding = config.padding > 0 ? config.padding : paddingForModel(config.model_dir);
		d->divisor = config.flow_divisor;
		d->protect_static = config.protect_static;
		d->sharp_sampling = config.sharp_sampling;
		d->inited = true;
		return true;
	}
}

bool MetalRifeBackend::initialized() const
{
	return d->inited;
}

std::string MetalRifeBackend::gpuName() const
{
	return d->gpu_name;
}

void MetalRifeBackend::reset()
{
	d->releaseFrames();
}

bool MetalRifeBackend::setFlowDivisor(int flow_divisor)
{
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
		if(!d->ensurePipeline(nullptr))
			return false;
	}
	return true;
}

int MetalRifeBackend::flowDivisor() const
{
	return d->divisor;
}

bool MetalRifeBackend::ready() const
{
	return d->inited && d->prev.valid && (d->cur.valid || d->pending);
}

bool MetalRifeBackend::push(const Nv12View &frame, const ColorInfo &color, std::string *error)
{
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

	@autoreleasepool
	{
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
			if(!d->ensurePipeline(error))
				return false;
		}
		else if(!d->current_pipeline && !d->ensurePipeline(error))
		{
			return false;
		}

		if(d->pending)
		{
			id<MTLCommandBuffer> cmd = [d->queue commandBuffer];
			d->encodeNv12ToNet(cmd, d->cur);
			[cmd commit];
			[cmd waitUntilCompleted];
			if(cmd.status != MTLCommandBufferStatusCompleted || cmd.error)
			{
				d->releaseFrames();
				setError(error, cmd.error ? cmd.error.localizedDescription.UTF8String : "Metal GPU upload failed");
				return false;
			}
		}

		if(d->cur.valid)
			std::swap(d->prev, d->cur);
		d->cur.valid = false;
		d->dropFields();

		if(!d->ensureFrameBuffers(d->cur, error))
			return false;

		copyPlane(static_cast<uint8_t *>(d->cur.y_buf.contents), frame.y, d->w, frame.y_stride, d->w, d->h);
		copyPlane(static_cast<uint8_t *>(d->cur.uv_buf.contents), frame.uv, d->w, frame.uv_stride, d->w, d->h / 2);
		d->pending = true;
		return true;
	}
}

bool MetalRifeBackend::interpolate(float t, const Nv12Mut &out, InterpolateTiming *timing, std::string *error, float field_time)
{
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

	@autoreleasepool
	{
		if(!d->ensurePipeline(error) || !d->ensureWorkingBuffers(error))
			return false;

		MPSCommandBuffer *mps_cmd = [MPSCommandBuffer commandBufferFromCommandQueue:d->queue];
		if(!mps_cmd)
		{
			setError(error, "failed to create MPSCommandBuffer");
			return false;
		}

		if(d->pending)
			d->encodeNv12ToNet(mps_cmd.rootCommandBuffer, d->cur);

		const float wanted_field_time = (field_time > 0.f && field_time < 1.f) ? field_time : t;
		if(!d->fields_valid || std::abs(d->fields_time - wanted_field_time) > 0.0001f)
		{
			d->dropFields();
			if(!d->timestep_valid || std::abs(d->timestep_value - wanted_field_time) > 0.0001f)
			{
				id<MTLComputeCommandEncoder> enc = [mps_cmd.rootCommandBuffer computeCommandEncoder];
				TimestepParams tp{ d->wp, d->hp, wanted_field_time };
				[enc setComputePipelineState:d->pso_fill_timestep];
				[enc setBuffer:d->timestep_buf offset:0 atIndex:0];
				[enc setBytes:&tp length:sizeof(tp) atIndex:1];
				[enc dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(d->wp), static_cast<NSUInteger>(d->hp), 1)
					threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
				[enc endEncoding];
				d->timestep_value = wanted_field_time;
				d->timestep_valid = true;
			}

			auto resolveTensorData = [&](const std::string &blob) -> MPSGraphTensorData * {
				if(blob == "in0")
					return d->prev.net_data;
				if(blob == "in1")
					return d->cur.net_data;
				if(blob == "in2")
					return d->timestep_data;
				if(blob == "robzfg_fields")
					return d->fields_data;
				return d->current_pipeline->inter_data.at(blob);
			};
			auto resolveBuffer = [&](const std::string &blob) -> id<MTLBuffer> {
				if(blob == "in0")
					return d->prev.net_buf;
				if(blob == "in1")
					return d->cur.net_buf;
				if(blob == "in2")
					return d->timestep_buf;
				if(blob == "robzfg_fields")
					return d->fields_buf;
				return d->current_pipeline->inter_bufs.at(blob);
			};

			for(const PipelineStep &step : d->current_pipeline->steps)
			{
				if(step.is_warp)
				{
					id<MTLComputeCommandEncoder> enc = [mps_cmd.rootCommandBuffer computeCommandEncoder];
					[enc setComputePipelineState:d->pso_warp2d];
					for(const WarpOp &w : step.warps)
					{
						WarpParams wp_p{ w.w, w.h, w.c, w.w * w.h };
						[enc setBuffer:resolveBuffer(w.img_blob) offset:0 atIndex:0];
						[enc setBuffer:resolveBuffer(w.flow_blob) offset:w.flow_offset_bytes atIndex:1];
						[enc setBuffer:resolveBuffer(w.out_blob) offset:0 atIndex:2];
						[enc setBytes:&wp_p length:sizeof(wp_p) atIndex:3];
						[enc dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(w.w), static_cast<NSUInteger>(w.h), 1)
							threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
					}
					[enc endEncoding];
				}
				else
				{
					NSMutableArray<MPSGraphTensorData *> *inputs = [NSMutableArray arrayWithCapacity:step.ordered_feed_blobs.size()];
					for(const std::string &fb : step.ordered_feed_blobs)
						[inputs addObject:resolveTensorData(fb)];
					NSMutableArray<MPSGraphTensorData *> *results = [NSMutableArray arrayWithCapacity:step.output_blobs.size()];
					for(const std::string &ob : step.output_blobs)
						[results addObject:resolveTensorData(ob)];
					[step.exec encodeToCommandBuffer:mps_cmd
										 inputsArray:inputs
										resultsArray:results
								 executionDescriptor:nil];
				}
			}

			d->fields_time = wanted_field_time;
			d->fields_valid = true;
		}

		id<MTLCommandBuffer> live_cmd = mps_cmd.rootCommandBuffer;
		{
			id<MTLComputeCommandEncoder> enc = [live_cmd computeCommandEncoder];
			SynthesizeParams sp{};
			sp.w = d->w;
			sp.h = d->h;
			sp.nw = d->nw;
			sp.nh = d->nh;
			sp.tw = d->wp;
			sp.tcstep = d->wp * d->hp;
			sp.k = d->divisor;
			sp.t = t;
			sp.protect_static = d->protect_static ? 1 : 0;
			sp.field_t = d->fields_time;
			sp.bicubic = d->sharp_sampling ? 1 : 0;

			[enc setComputePipelineState:d->pso_synthesize];
			[enc setBuffer:d->fields_buf offset:0 atIndex:0];
			[enc setBuffer:d->prev.y_buf offset:0 atIndex:1];
			[enc setBuffer:d->prev.uv_buf offset:0 atIndex:2];
			[enc setBuffer:d->cur.y_buf offset:0 atIndex:3];
			[enc setBuffer:d->cur.uv_buf offset:0 atIndex:4];
			[enc setBuffer:d->out_y_buf offset:0 atIndex:5];
			[enc setBuffer:d->out_uv_buf offset:0 atIndex:6];
			[enc setBytes:&sp length:sizeof(sp) atIndex:7];
			[enc dispatchThreads:MTLSizeMake(static_cast<NSUInteger>(d->w / 4), static_cast<NSUInteger>(d->h), 1)
				threadsPerThreadgroup:MTLSizeMake(16, 8, 1)];
			[enc endEncoding];
		}

		[live_cmd commit];
		[live_cmd waitUntilCompleted];
		if(live_cmd.status != MTLCommandBufferStatusCompleted || live_cmd.error)
		{
			d->releaseFrames();
			setError(error, live_cmd.error ? live_cmd.error.localizedDescription.UTF8String : "Metal command submission failed");
			return false;
		}

		copyPlane(out.y, static_cast<const uint8_t *>(d->out_y_buf.contents), out.y_stride, d->w, d->w, d->h);
		copyPlane(out.uv, static_cast<const uint8_t *>(d->out_uv_buf.contents), out.uv_stride, d->w, d->w, d->h / 2);

		if(timing)
			timing->total_ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
		return true;
	}
}

} // namespace robzfg

#endif // __APPLE__
