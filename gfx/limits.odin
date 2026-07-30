// ingot:gfx - GPU budget negotiation.
//
// The engine used to allocate desktop-sized pools unconditionally: three
// 16 MiB geometry + 16 MiB uniform stream slots (96 MiB of buffers) and a
// 2048x2048 font atlas, then assert on failure. Desktop drivers absorb that;
// mobile GPUs expose spec-minimum limits and far less memory, so the same
// init path aborted the whole module on a phone with no diagnosable output.
//
// The policy here is pure and platform-neutral: given an adapter's reported
// limits it returns the pool sizes the engine will actually ask for. Both
// platform backends run it before requesting the device, pass the result as
// `requiredLimits`, and size their pools from it (batch.odin, text.odin).
package gfx

import "core:fmt"
import wg "vendor:wgpu"

// Desktop-class targets. A device that can afford these gets them unchanged,
// so nothing about existing native behavior moves.
GPU_BUDGET_GEOMETRY_BYTES_DEFAULT :: u64(16 * 1024 * 1024)
GPU_BUDGET_UNIFORM_BYTES_DEFAULT :: u64(16 * 1024 * 1024)
GPU_BUDGET_ATLAS_DIM_DEFAULT :: u32(2048)

// Floors: below these the engine cannot draw a useful frame, so a device that
// cannot meet them has failed regardless. They also stop a zero-filled or
// bogus limits struct (a driver returning Status.Error) from producing a
// degenerate zero-sized budget that would divide-by-zero downstream.
GPU_BUDGET_GEOMETRY_BYTES_MINIMUM :: u64(1024 * 1024)
GPU_BUDGET_UNIFORM_BYTES_MINIMUM :: u64(1024 * 1024)
GPU_BUDGET_ATLAS_DIM_MINIMUM :: u32(512)

// Atlas rows are uploaded as R8, whose wgpu bytesPerRow must be a multiple of
// 256; the atlas dimension is the row stride, so every candidate width has to
// stay 256-aligned (see text.odin's ATLAS_DIM note).
GPU_BUDGET_ATLAS_DIM_ALIGN :: u32(256)

// A single stream slot may claim at most 1/8th of the device's whole buffer
// allowance. STREAM_SLOT_COUNT (3) slots hold a geometry and a uniform buffer
// each, so the streams together stay under 3/4 of maxBufferSize and leave room
// for textures, the atlas, and transient buffers.
GPU_BUDGET_BUFFER_SHARE :: u64(8)

#assert(GPU_BUDGET_GEOMETRY_BYTES_DEFAULT >= GPU_BUDGET_GEOMETRY_BYTES_MINIMUM)
#assert(GPU_BUDGET_UNIFORM_BYTES_DEFAULT >= GPU_BUDGET_UNIFORM_BYTES_MINIMUM)
#assert(GPU_BUDGET_ATLAS_DIM_DEFAULT >= GPU_BUDGET_ATLAS_DIM_MINIMUM)
// The floor is itself a legal atlas width, so clamping to it can never produce
// a stride the R8 upload would reject.
#assert(GPU_BUDGET_ATLAS_DIM_MINIMUM % GPU_BUDGET_ATLAS_DIM_ALIGN == 0)
#assert(GPU_BUDGET_ATLAS_DIM_DEFAULT % GPU_BUDGET_ATLAS_DIM_ALIGN == 0)
#assert(GPU_BUDGET_BUFFER_SHARE >= u64(STREAM_SLOT_COUNT))

Gpu_Budget :: struct {
	geometry_stream_bytes: u64,
	uniform_stream_bytes:  u64,
	atlas_dim:             u32,
}

// gpu_budget_default returns the desktop-class budget. Used before an adapter
// exists (e.g. the headless test contexts) so callers always have a valid,
// non-zero budget to size against.
gpu_budget_default :: proc() -> Gpu_Budget {
	return Gpu_Budget {
		geometry_stream_bytes = GPU_BUDGET_GEOMETRY_BYTES_DEFAULT,
		uniform_stream_bytes = GPU_BUDGET_UNIFORM_BYTES_DEFAULT,
		atlas_dim = GPU_BUDGET_ATLAS_DIM_DEFAULT,
	}
}

// gpu_budget_is_full reports whether the device met every desktop target.
// Derived rather than stored so it cannot drift from the sizes it describes.
gpu_budget_is_full :: proc(budget: Gpu_Budget) -> bool {
	return(
		budget.geometry_stream_bytes == GPU_BUDGET_GEOMETRY_BYTES_DEFAULT &&
		budget.uniform_stream_bytes == GPU_BUDGET_UNIFORM_BYTES_DEFAULT &&
		budget.atlas_dim == GPU_BUDGET_ATLAS_DIM_DEFAULT \
	)
}

// gpu_budget_is_usable reports whether a budget can size a pool at all. A
// zeroed budget means negotiation never ran (headless contexts), not that the
// device is tiny, so callers substitute the default instead of trusting it.
gpu_budget_is_usable :: proc(budget: Gpu_Budget) -> bool {
	return(
		budget.geometry_stream_bytes >= GPU_BUDGET_GEOMETRY_BYTES_MINIMUM &&
		budget.uniform_stream_bytes >= GPU_BUDGET_UNIFORM_BYTES_MINIMUM &&
		budget.atlas_dim >= GPU_BUDGET_ATLAS_DIM_MINIMUM \
	)
}

// _gpu_budget_align_atlas rounds a candidate atlas dimension down to the R8
// copy alignment, never below the floor.
@(private)
_gpu_budget_align_atlas :: proc(candidate: u32) -> u32 {
	if candidate < GPU_BUDGET_ATLAS_DIM_MINIMUM do return GPU_BUDGET_ATLAS_DIM_MINIMUM
	aligned := (candidate / GPU_BUDGET_ATLAS_DIM_ALIGN) * GPU_BUDGET_ATLAS_DIM_ALIGN
	if aligned < GPU_BUDGET_ATLAS_DIM_MINIMUM do return GPU_BUDGET_ATLAS_DIM_MINIMUM
	assert(aligned <= candidate, "_gpu_budget_align_atlas: rounded up")
	assert(aligned % GPU_BUDGET_ATLAS_DIM_ALIGN == 0, "_gpu_budget_align_atlas: unaligned")
	return aligned
}

// _gpu_budget_stream clamps one stream pool against the device's buffer
// allowance, honouring the floor. A zero maximum_buffer_bytes (unreported
// limits) falls back to the target rather than collapsing to zero - the
// allocation retry in _stream_slots_init is the real safety net there.
@(private)
_gpu_budget_stream :: proc(target, maximum_buffer_bytes, minimum: u64) -> u64 {
	assert(target >= minimum, "_gpu_budget_stream: target below floor")
	assert(minimum > 0, "_gpu_budget_stream: zero floor")
	if maximum_buffer_bytes == 0 do return target
	share := maximum_buffer_bytes / GPU_BUDGET_BUFFER_SHARE
	if share >= target do return target
	if share < minimum do return minimum
	assert(share <= maximum_buffer_bytes, "_gpu_budget_stream: share exceeds allowance")
	return share
}

// _gpu_budget_from_limits derives the pool sizes the engine will request from
// what the adapter reports it can support.
@(private)
_gpu_budget_from_limits :: proc(limits: wg.Limits) -> Gpu_Budget {
	budget := Gpu_Budget {
		geometry_stream_bytes = _gpu_budget_stream(
			GPU_BUDGET_GEOMETRY_BYTES_DEFAULT,
			limits.maxBufferSize,
			GPU_BUDGET_GEOMETRY_BYTES_MINIMUM,
		),
		uniform_stream_bytes  = _gpu_budget_stream(
			GPU_BUDGET_UNIFORM_BYTES_DEFAULT,
			limits.maxBufferSize,
			GPU_BUDGET_UNIFORM_BYTES_MINIMUM,
		),
		atlas_dim             = GPU_BUDGET_ATLAS_DIM_DEFAULT,
	}
	if limits.maxTextureDimension2D > 0 &&
	   limits.maxTextureDimension2D < GPU_BUDGET_ATLAS_DIM_DEFAULT {
		budget.atlas_dim = _gpu_budget_align_atlas(limits.maxTextureDimension2D)
	}
	// Postcondition: every consumer divides or allocates by these, so a
	// degenerate budget must never escape this procedure.
	assert(gpu_budget_is_usable(budget), "_gpu_budget_from_limits: unusable budget")
	if limits.maxTextureDimension2D > 0 {
		assert(
			budget.atlas_dim <= max(limits.maxTextureDimension2D, GPU_BUDGET_ATLAS_DIM_MINIMUM),
			"_gpu_budget_from_limits: atlas exceeds device ceiling",
		)
	}
	return budget
}

// Why the engine does NOT pass DeviceDescriptor.requiredLimits on web:
// vendor:wgpu's browser glue decodes that pointer as a WGPURequiredLimits
// wrapper - web/wgpu.js's RequiredLimitsPtr reads `this.Limits(start + 8)`
// and Limits() then skips another 4 bytes, so fields are read from
// pointer+12. A bare ^wg.Limits has its fields at offset 4, which mis-aligns
// all 31 limits (maxTextureDimension1D picks up half of a u64) and makes
// Safari reject the device outright - a black canvas on every mobile boot.
// The marshaller reads all 31 fields from that same base, so no subset of the
// struct is safe to fill either.
//
// Adapter limits are still read, but only to SIZE our pools
// (_gpu_budget_from_limits above). The bounded halve-and-retry in
// batch.odin's _stream_buffer_create is the real safety net for a device that
// refuses a large buffer, and it needs no cooperation from the JS glue.

// gpu_negotiate_budget queries the adapter and returns the pool budget this
// device can serve. Called by both platform backends immediately before
// AdapterRequestDevice; the caller stores it on the context, keeping this a
// leaf that owns no mutable state (Tiger Style: the parent owns the globals).
//
// A constrained device is logged rather than silently accepted: on mobile the
// browser console is unreachable, so this line is what the on-page crash
// panel shows when a phone cannot serve the desktop-class pools.
@(private)
gpu_negotiate_budget :: proc(adapter: wg.Adapter) -> Gpu_Budget {
	assert(adapter != nil, "gpu_negotiate_budget: nil adapter")
	supported, status := wg.AdapterGetLimits(adapter)
	if status != .Success {
		// Operating error, not a programmer error: keep the desktop targets
		// and let the allocation retry in _stream_slots_init find the real
		// ceiling.
		fmt.eprintln("gfx: adapter limits unavailable; using default GPU budget")
		return gpu_budget_default()
	}
	budget := _gpu_budget_from_limits(supported)
	if !gpu_budget_is_full(budget) {
		fmt.eprintfln(
			"gfx: constrained GPU budget (geometry=%d KiB uniform=%d KiB atlas=%d, maxBufferSize=%d KiB)",
			budget.geometry_stream_bytes / 1024,
			budget.uniform_stream_bytes / 1024,
			budget.atlas_dim,
			supported.maxBufferSize / 1024,
		)
	}
	assert(gpu_budget_is_usable(budget), "gpu_negotiate_budget: unusable budget")
	return budget
}

// gpu_budget_active returns the negotiated budget, substituting the desktop
// default when no negotiation has run (headless test contexts create a device
// directly). Callers can therefore always size against a usable budget.
@(private)
gpu_budget_active :: proc() -> Gpu_Budget {
	budget := gpu_budget_is_usable(g.budget) ? g.budget : gpu_budget_default()
	assert(gpu_budget_is_usable(budget), "gpu_budget_active: unusable budget")
	return budget
}
