// ingot:gfx - streamed geometry slots: buffer allocation with bounded
// retries, per-slot lifecycle (acquire, submit, retire, abandon), and the
// checked reservation arithmetic for indexed geometry and uniforms.
package gfx

import "core:fmt"
import "core:mem"
import wg "vendor:wgpu"

// Halving 16 MiB down to the 1 MiB floor takes four steps, so eight attempts
// is generous headroom while still bounding the retry statically (Tiger Style:
// put a limit on everything). A budget that needed more halvings than this
// would already be below the floor the caller asserts.
STREAM_BUFFER_ATTEMPTS_MAX :: 8

// _stream_buffer_create allocates one stream buffer, halving the request until
// the device accepts it or the floor is reached. A phone can refuse a
// desktop-sized buffer even when the reported limits allow it (limits describe
// the API ceiling, not free VRAM), and the previous code asserted on the nil
// return - an Odin panic, which on web traps the wasm module and kills the
// requestAnimationFrame loop for good. Degrading beats dying.
//
// Returns a nil buffer when even the floor-sized allocation fails, which the
// caller treats as an operating error rather than a programmer error.
@(private)
_stream_buffer_create :: proc(
	device: wg.Device,
	usage: wg.BufferUsageFlags,
	requested, minimum: u64,
) -> (
	wg.Buffer,
	u64,
) {
	assert(device != nil, "_stream_buffer_create: nil device")
	assert(minimum > 0, "_stream_buffer_create: zero floor")
	assert(requested >= minimum, "_stream_buffer_create: request below floor")
	size := requested
	for _ in 0 ..< STREAM_BUFFER_ATTEMPTS_MAX {
		buffer := wg.DeviceCreateBuffer(device, &{usage = usage, size = size})
		if buffer != nil {
			assert(size >= minimum, "_stream_buffer_create: allocated below floor")
			return buffer, size
		}
		if size <= minimum do return nil, 0
		size = max(size / 2, minimum)
	}
	// Exhausting the bound means the floor was never reached, which only a
	// mis-sized budget constant could cause.
	assert(size <= minimum, "_stream_buffer_create: retries exhausted above floor")
	return nil, 0
}

// _stream_slots_init allocates the per-slot geometry and uniform pools. The
// device and budget are passed in rather than read from the active-context
// global so this stays a pure leaf its caller can test (the same shape as
// _geometry_upload_transient). Returns false when even the floor-sized pools
// cannot be allocated, leaving the caller to decide the context's fate.
@(private)
_stream_slots_init :: proc(
	ctx: ^Context,
	r: ^Renderer,
	device: wg.Device,
	budget: Gpu_Budget,
) -> bool {
	assert(ctx != nil, "_stream_slots_init: nil context")
	assert(r == &ctx.rend, "_stream_slots_init: foreign renderer")
	assert(device != nil, "_stream_slots_init: nil device")
	assert(budget.geometry_stream_bytes > 0, "_stream_slots_init: empty geometry budget")
	assert(budget.uniform_stream_bytes > 0, "_stream_slots_init: empty uniform budget")
	limits, status := wg.DeviceGetLimits(device)
	r.uniform_alignment = u64(limits.minUniformBufferOffsetAlignment)
	if status != .Success || r.uniform_alignment == 0 do r.uniform_alignment = 256
	r.active_stream_slot = -1
	r.geometry_bytes = budget.geometry_stream_bytes
	r.uniform_bytes = budget.uniform_stream_bytes
	for &slot in r.stream_slots {
		geometry, geometry_size := _stream_buffer_create(
			device,
			{.Vertex, .Index, .CopyDst},
			r.geometry_bytes,
			GPU_BUDGET_GEOMETRY_BYTES_MINIMUM,
		)
		uniform, uniform_size := _stream_buffer_create(
			device,
			{.Uniform, .CopyDst},
			r.uniform_bytes,
			GPU_BUDGET_UNIFORM_BYTES_MINIMUM,
		)
		if geometry == nil || uniform == nil {
			// Below the floor the engine cannot draw at all. Report it and
			// let the caller close the context rather than aborting the
			// process (a panic here traps the wasm module for good).
			if geometry != nil do wg.BufferRelease(geometry)
			if uniform != nil do wg.BufferRelease(uniform)
			ctx.last_error = .Stream_Allocation
			fmt.eprintln("gfx: GPU stream buffer allocation failed; device out of memory")
			return false
		}
		_stats_buffer_created(ctx, false)
		_stats_buffer_created(ctx, false)
		slot.geometry_buffer = geometry
		slot.uniform_buffer = uniform
		// Every slot shares one reservation bound, so a slot that had to
		// shrink pulls the whole renderer down with it.
		r.geometry_bytes = min(r.geometry_bytes, geometry_size)
		r.uniform_bytes = min(r.uniform_bytes, uniform_size)
	}
	if r.geometry_bytes != budget.geometry_stream_bytes ||
	   r.uniform_bytes != budget.uniform_stream_bytes {
		fmt.eprintfln(
			"gfx: stream pools reduced to geometry=%d KiB uniform=%d KiB after allocation failure",
			r.geometry_bytes / 1024,
			r.uniform_bytes / 1024,
		)
	}
	assert(r.geometry_bytes >= GPU_BUDGET_GEOMETRY_BYTES_MINIMUM)
	assert(r.uniform_bytes >= GPU_BUDGET_UNIFORM_BYTES_MINIMUM)
	return true
}

@(private)
_stream_shadow_ensure :: proc(shadow: ^[dynamic]byte, required, capacity: u64) -> bool {
	assert(shadow != nil)
	assert(required <= capacity)
	if required <= u64(len(shadow)) do return true
	grown := max(u64(4096), u64(len(shadow)) * 2)
	for grown < required {
		if grown > capacity / 2 {
			grown = capacity
			break
		}
		grown *= 2
	}
	if grown < required || grown > capacity do return false
	resize(shadow, int(grown))
	return u64(len(shadow)) >= required
}

@(private)
_stream_slot_upload :: proc(ctx: ^Context, r: ^Renderer) -> bool {
	assert(ctx != nil, "_stream_slot_upload: nil context")
	assert(r == &ctx.rend, "_stream_slot_upload: foreign renderer")
	if r.active_stream_slot < 0 do return false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	assert(slot.state == .Recording)
	assert(slot.geometry_uploaded <= slot.geometry_write)
	assert(slot.uniform_uploaded <= slot.uniform_write)
	if slot.geometry_write > slot.geometry_uploaded {
		started := platform_now()
		start := slot.geometry_uploaded
		byte_count := slot.geometry_write - start
		wg.QueueWriteBuffer(
			ctx.queue,
			slot.geometry_buffer,
			start,
			raw_data(slot.geometry_shadow[start:slot.geometry_write]),
			uint(byte_count),
		)
		slot.geometry_uploaded = slot.geometry_write
		_stats_stream_write(ctx, false, byte_count, platform_now() - started)
	}
	if slot.uniform_write > slot.uniform_uploaded {
		started := platform_now()
		start := slot.uniform_uploaded
		byte_count := slot.uniform_write - start
		wg.QueueWriteBuffer(
			ctx.queue,
			slot.uniform_buffer,
			start,
			raw_data(slot.uniform_shadow[start:slot.uniform_write]),
			uint(byte_count),
		)
		slot.uniform_uploaded = slot.uniform_write
		_stats_stream_write(ctx, true, byte_count, platform_now() - started)
	}
	return true
}

@(private)
_stream_slots_poll :: proc(slots: []Stream_Slot, completed: u64) {
	for &slot in slots {
		if slot.state == .Submitted && completed >= slot.ticket {
			slot.geometry_write = 0
			slot.geometry_uploaded = 0
			slot.uniform_write = 0
			slot.uniform_uploaded = 0
			slot.ticket = 0
			slot.state = .Free
		}
	}
}

@(private)
_stream_slots_acquire :: proc(slots: []Stream_Slot, completed: u64) -> i32 {
	_stream_slots_poll(slots, completed)
	for &slot, index in slots {
		if slot.state == .Free {
			slot.geometry_write = 0
			slot.geometry_uploaded = 0
			slot.uniform_write = 0
			slot.uniform_uploaded = 0
			slot.ticket = 0
			slot.state = .Recording
			return i32(index)
		}
	}
	return -1
}

@(private)
_stream_slot_acquire :: proc(r: ^Renderer, completed: u64) -> bool {
	assert(r != nil)
	assert(r.active_stream_slot < 0)
	r.active_stream_slot = _stream_slots_acquire(r.stream_slots[:], completed)
	return r.active_stream_slot >= 0
}

@(private)
_stream_slot_submit :: proc(slot: ^Stream_Slot, ticket: u64) -> bool {
	assert(slot != nil)
	if slot.state != .Recording || ticket == 0 do return false
	slot.ticket = ticket
	slot.state = .Submitted
	return true
}

@(private)
_stream_transients_retire :: proc(r: ^Renderer, slot_index: i32) {
	assert(r != nil)
	assert(slot_index >= 0 && slot_index < len(r.stream_slots))
	append(&r.retired_buffers[slot_index], ..r.transient_buffers[:])
	clear(&r.transient_buffers)
}

@(private)
_stream_slot_submitted :: proc(r: ^Renderer, ticket: u64) -> bool {
	assert(r != nil)
	if r.active_stream_slot < 0 do return false
	assert(r.active_stream_slot < len(r.stream_slots))
	ok := _stream_slot_submit(&r.stream_slots[r.active_stream_slot], ticket)
	if ok {
		_stream_transients_retire(r, r.active_stream_slot)
		r.active_stream_slot = -1
	}
	return ok
}

@(private)
_stream_slot_abandon :: proc(r: ^Renderer) {
	assert(r != nil)
	if r.active_stream_slot < 0 do return
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	assert(slot.state == .Recording)
	slot.geometry_write = 0
	slot.geometry_uploaded = 0
	slot.uniform_write = 0
	slot.uniform_uploaded = 0
	slot.ticket = 0
	slot.state = .Free
	r.active_stream_slot = -1
}

@(private = "file")
checked_add_u64 :: proc(a, b: u64) -> (sum: u64, ok: bool) {
	if b > max(u64) - a do return 0, false
	return a + b, true
}

@(private = "file")
checked_align_u64 :: proc(value, alignment: u64) -> (aligned: u64, ok: bool) {
	assert(alignment > 0)
	padded := checked_add_u64(value, alignment - 1) or_return
	return padded / alignment * alignment, true
}

@(private)
_stream_slot_reserve_indexed :: proc(
	slot: ^Stream_Slot,
	vertex_bytes, index_bytes, capacity: u64,
) -> (
	vertex, index: u64,
	ok: bool,
) {
	assert(slot != nil)
	assert(slot.state == .Recording)
	assert(vertex_bytes > 0)
	assert(index_bytes > 0)
	write_before := slot.geometry_write
	vertex = checked_align_u64(write_before, GEOMETRY_STREAM_ALIGN) or_return
	vertex_end := checked_add_u64(vertex, vertex_bytes) or_return
	index = checked_align_u64(vertex_end, GEOMETRY_STREAM_ALIGN) or_return
	end := checked_add_u64(index, index_bytes) or_return
	if end > capacity do return 0, 0, false
	slot.geometry_write = end
	assert(slot.geometry_write >= write_before)
	assert(slot.geometry_write <= capacity)
	return vertex, index, true
}

@(private)
_stream_slot_reserve_uniform :: proc(
	slot: ^Stream_Slot,
	size, alignment, capacity: u64,
) -> (
	offset: u64,
	ok: bool,
) {
	assert(slot != nil)
	assert(slot.state == .Recording)
	assert(size > 0)
	assert(alignment > 0)
	write_before := slot.uniform_write
	offset = checked_align_u64(write_before, alignment) or_return
	end := checked_add_u64(offset, size) or_return
	if end > capacity do return 0, false
	slot.uniform_write = end
	assert(slot.uniform_write >= write_before)
	assert(slot.uniform_write <= capacity)
	return offset, true
}

@(private)
_uniform_upload :: proc(ctx: ^Context, r: ^Renderer, data: rawptr, size: u64) -> (u32, bool) {
	assert(ctx != nil)
	assert(r == &ctx.rend)
	assert(data != nil)
	assert(size > 0)
	if r.active_stream_slot < 0 do return 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	offset, ok := _stream_slot_reserve_uniform(slot, size, r.uniform_alignment, r.uniform_bytes)
	if !ok {
		_stats_reservation_failure(ctx, true)
		return 0, false
	}
	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.uniform_shadow, slot.uniform_write, r.uniform_bytes) {
		slot.uniform_write = offset
		_stats_reservation_failure(ctx, true)
		return 0, false
	}
	mem.copy(raw_data(slot.uniform_shadow[offset:]), data, int(size))
	_stream_record_peak(r, r.peak_geometry_bytes, slot.uniform_write)
	_stats_stream_copy(ctx, platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.peak_uniform_arena_bytes = max(
			ctx.stats_current.peak_uniform_arena_bytes,
			slot.uniform_write,
		)
	}
	assert(offset <= u64(max(u32)))
	return u32(offset), true
}

@(private)
_active_uniform_buffer :: proc(r: ^Renderer) -> wg.Buffer {
	assert(r != nil)
	if r.active_stream_slot < 0 do return nil
	assert(r.active_stream_slot < len(r.stream_slots))
	return r.stream_slots[r.active_stream_slot].uniform_buffer
}
