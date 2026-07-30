#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

// A desktop-class adapter: generous buffer allowance and a large texture
// ceiling. The engine must ask for exactly the same pools it always has, so
// negotiation cannot regress native behavior.
@(private = "file")
_desktop_limits :: proc() -> wg.Limits {
	return wg.Limits {
		maxBufferSize = 256 * 1024 * 1024,
		maxTextureDimension2D = 16384,
		minUniformBufferOffsetAlignment = 256,
	}
}

// The WebGPU spec minimums a conservative mobile GPU may report.
@(private = "file")
_mobile_limits :: proc() -> wg.Limits {
	return wg.Limits {
		maxBufferSize = 32 * 1024 * 1024,
		maxTextureDimension2D = 4096,
		minUniformBufferOffsetAlignment = 256,
	}
}

@(test)
gpu_budget_desktop_keeps_defaults :: proc(t: ^testing.T) {
	budget := _gpu_budget_from_limits(_desktop_limits())
	testing.expect_value(t, budget.geometry_stream_bytes, GPU_BUDGET_GEOMETRY_BYTES_DEFAULT)
	testing.expect_value(t, budget.uniform_stream_bytes, GPU_BUDGET_UNIFORM_BYTES_DEFAULT)
	testing.expect_value(t, budget.atlas_dim, GPU_BUDGET_ATLAS_DIM_DEFAULT)
	testing.expect(t, gpu_budget_is_full(budget))
	testing.expect_value(t, budget, gpu_budget_default())
}

@(test)
gpu_budget_clamps_constrained_device :: proc(t: ^testing.T) {
	// 32 MiB / 8 = 4 MiB per stream: well under the desktop target, so the
	// three slots together claim 24 MiB instead of 96 MiB.
	budget := _gpu_budget_from_limits(_mobile_limits())
	testing.expect_value(t, budget.geometry_stream_bytes, u64(4 * 1024 * 1024))
	testing.expect_value(t, budget.uniform_stream_bytes, u64(4 * 1024 * 1024))
	testing.expect(t, !gpu_budget_is_full(budget))
	// A 4096 texture ceiling still clears the 2048 atlas untouched.
	testing.expect_value(t, budget.atlas_dim, GPU_BUDGET_ATLAS_DIM_DEFAULT)
	total := (budget.geometry_stream_bytes + budget.uniform_stream_bytes) * u64(STREAM_SLOT_COUNT)
	testing.expect(t, total < _mobile_limits().maxBufferSize)
}

@(test)
gpu_budget_clamps_small_texture_ceiling :: proc(t: ^testing.T) {
	limits := _mobile_limits()
	limits.maxTextureDimension2D = 1024
	budget := _gpu_budget_from_limits(limits)
	testing.expect_value(t, budget.atlas_dim, u32(1024))
	testing.expect(t, !gpu_budget_is_full(budget))
	// Non-aligned ceilings round down to the R8 bytesPerRow alignment.
	limits.maxTextureDimension2D = 1500
	budget = _gpu_budget_from_limits(limits)
	testing.expect_value(t, budget.atlas_dim, u32(1280))
	testing.expect_value(t, budget.atlas_dim % GPU_BUDGET_ATLAS_DIM_ALIGN, u32(0))
}

@(test)
gpu_budget_floors_degenerate_limits :: proc(t: ^testing.T) {
	// A driver that fails to report limits yields a zeroed struct. The budget
	// must stay usable and non-zero rather than dividing the engine by zero.
	budget := _gpu_budget_from_limits(wg.Limits{})
	testing.expect_value(t, budget.geometry_stream_bytes, GPU_BUDGET_GEOMETRY_BYTES_DEFAULT)
	testing.expect_value(t, budget.uniform_stream_bytes, GPU_BUDGET_UNIFORM_BYTES_DEFAULT)
	testing.expect_value(t, budget.atlas_dim, GPU_BUDGET_ATLAS_DIM_DEFAULT)

	// An absurdly small but non-zero allowance clamps to the floor, never
	// below it and never to zero.
	tiny := wg.Limits {
		maxBufferSize         = 64 * 1024,
		maxTextureDimension2D = 64,
	}
	budget = _gpu_budget_from_limits(tiny)
	testing.expect_value(t, budget.geometry_stream_bytes, GPU_BUDGET_GEOMETRY_BYTES_MINIMUM)
	testing.expect_value(t, budget.uniform_stream_bytes, GPU_BUDGET_UNIFORM_BYTES_MINIMUM)
	testing.expect_value(t, budget.atlas_dim, GPU_BUDGET_ATLAS_DIM_MINIMUM)
	testing.expect(t, budget.geometry_stream_bytes > 0)
	testing.expect(t, budget.atlas_dim > 0)
}

// There is deliberately no requiredLimits test: the engine no longer passes
// DeviceDescriptor.requiredLimits, because vendor:wgpu's browser glue decodes
// that pointer at the wrong offset and Safari rejects the device. See the
// hazard note in limits.odin. Adapter limits are read for pool sizing only,
// which is what the tests above and below cover.

@(test)
gpu_budget_active_never_returns_zero :: proc(t: ^testing.T) {
	// Headless contexts (text_test) create a device without negotiating, so
	// the renderer must still get a usable budget instead of zero-sized
	// pools that would divide reservation math by zero.
	saved := g.budget
	defer g.budget = saved
	g.budget = Gpu_Budget{}
	budget := gpu_budget_active()
	testing.expect_value(t, budget, gpu_budget_default())
	testing.expect(t, budget.geometry_stream_bytes > 0)
	testing.expect(t, budget.uniform_stream_bytes > 0)
	testing.expect(t, budget.atlas_dim > 0)

	// A partially-zeroed budget is equally unusable and must not leak
	// through: any zero field falls back wholesale.
	g.budget = Gpu_Budget {
		geometry_stream_bytes = GPU_BUDGET_GEOMETRY_BYTES_DEFAULT,
		uniform_stream_bytes  = GPU_BUDGET_UNIFORM_BYTES_DEFAULT,
	}
	testing.expect_value(t, gpu_budget_active(), gpu_budget_default())

	// A fully negotiated constrained budget passes through unchanged.
	g.budget = _gpu_budget_from_limits(_mobile_limits())
	testing.expect_value(t, gpu_budget_active(), g.budget)
}
