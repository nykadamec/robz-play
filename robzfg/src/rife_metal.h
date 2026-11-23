// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Robz Play frame generation - Apple Metal + MPSGraph backend for RIFE v4.

#ifndef ROBZFG_RIFE_METAL_H
#define ROBZFG_RIFE_METAL_H

#ifdef __APPLE__

#include <memory>
#include <string>
#include <vector>

#include "robzfg/rife_interpolator.h"

namespace robzfg
{

class MetalRifeBackend
{
public:
	MetalRifeBackend();
	~MetalRifeBackend();
	MetalRifeBackend(const MetalRifeBackend &) = delete;
	MetalRifeBackend &operator=(const MetalRifeBackend &) = delete;

	static std::vector<GpuDevice> enumerateGpus();
	static bool isEnabled();

	bool init(const RifeInterpolator::Config &config, std::string *error = nullptr);
	bool initialized() const;
	std::string gpuName() const;

	void reset();
	bool setFlowDivisor(int flow_divisor);
	int flowDivisor() const;

	bool ready() const;
	bool push(const Nv12View &frame, const ColorInfo &color, std::string *error = nullptr);
	bool interpolate(float t, const Nv12Mut &out, InterpolateTiming *timing = nullptr, std::string *error = nullptr,
		float field_time = -1.f);

private:
	struct Impl;
	std::unique_ptr<Impl> d;
};

} // namespace robzfg

#endif // __APPLE__

#endif // ROBZFG_RIFE_METAL_H
