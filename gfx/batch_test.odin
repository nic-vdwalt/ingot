#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
stream_slot_does_not_reuse_submitted_work :: proc(t: ^testing.T) {
	slots: [2]Stream_Slot
	first := _stream_slots_acquire(slots[:], 0)
	testing.expect_value(t, first, i32(0))
	slots[first].geometry_write = 128
	testing.expect(t, _stream_slot_submit(&slots[first], 1))

	second := _stream_slots_acquire(slots[:], 0)
	testing.expect_value(t, second, i32(1))
	testing.expect_value(t, slots[0].state, Stream_Slot_State.Submitted)
}

@(test)
stream_slot_reuses_only_completed_work :: proc(t: ^testing.T) {
	slots: [2]Stream_Slot
	first := _stream_slots_acquire(slots[:], 0)
	slots[first].geometry_write = 128
	slots[first].uniform_write = 64
	testing.expect(t, _stream_slot_submit(&slots[first], 1))
	second := _stream_slots_acquire(slots[:], 0)
	testing.expect(t, _stream_slot_submit(&slots[second], 2))

	testing.expect_value(t, _stream_slots_acquire(slots[:], 0), i32(-1))
	reused := _stream_slots_acquire(slots[:], 1)
	testing.expect_value(t, reused, first)
	testing.expect_value(t, slots[reused].geometry_write, u64(0))
	testing.expect_value(t, slots[reused].uniform_write, u64(0))
}

@(test)
stream_slot_reports_bounded_exhaustion :: proc(t: ^testing.T) {
	slots: [2]Stream_Slot
	first := _stream_slots_acquire(slots[:], 0)
	second := _stream_slots_acquire(slots[:], 0)
	testing.expect(t, first >= 0 && second >= 0)
	testing.expect_value(t, _stream_slots_acquire(slots[:], 0), i32(-1))
}

@(test)
stream_slot_abandon_restores_acquisition_capacity :: proc(t: ^testing.T) {
	renderer := new(Renderer)
	defer free(renderer)
	renderer.active_stream_slot = _stream_slots_acquire(renderer.stream_slots[:], 0)
	testing.expect(t, renderer.active_stream_slot >= 0)
	slot := &renderer.stream_slots[renderer.active_stream_slot]
	slot.geometry_write = 128
	slot.uniform_write = 64

	_stream_slot_abandon(renderer)

	testing.expect_value(t, renderer.active_stream_slot, i32(-1))
	testing.expect_value(t, slot.state, Stream_Slot_State.Free)
	testing.expect_value(t, slot.geometry_write, u64(0))
	testing.expect_value(t, slot.uniform_write, u64(0))
	testing.expect(t, _stream_slots_acquire(renderer.stream_slots[:], 0) >= 0)
}

@(test)
stream_slot_honours_uniform_alignment :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state = .Recording,
	}
	first, first_ok := _stream_slot_reserve_uniform(&slot, 48, 256, 1024)
	second, second_ok := _stream_slot_reserve_uniform(&slot, 48, 256, 1024)
	third, third_ok := _stream_slot_reserve_uniform(&slot, 48, 256, 1024)
	testing.expect(t, first_ok && second_ok && third_ok)
	testing.expect_value(t, first, u64(0))
	testing.expect_value(t, second, u64(256))
	testing.expect_value(t, third, u64(512))
}

@(test)
stream_slot_failed_indexed_reservation_is_atomic :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state          = .Recording,
		geometry_write = 40,
	}
	write_before := slot.geometry_write
	_, _, ok := _stream_slot_reserve_indexed(&slot, 20, 12, 64)
	testing.expect(t, !ok)
	testing.expect_value(t, slot.geometry_write, write_before)
}

@(test)
stream_slot_zero_ticket_preserves_recording_ownership :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state          = .Recording,
		geometry_write = 128,
	}
	testing.expect(t, !_stream_slot_submit(&slot, 0))
	testing.expect_value(t, slot.state, Stream_Slot_State.Recording)
	testing.expect_value(t, slot.geometry_write, u64(128))
}

@(test)
stream_slot_intermediate_work_stays_in_recording_epoch :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state = .Recording,
	}
	_, _, first_ok := _stream_slot_reserve_indexed(&slot, 64, 24, 1024)
	write_after_intermediate := slot.geometry_write
	_, _, second_ok := _stream_slot_reserve_indexed(&slot, 64, 24, 1024)
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, slot.geometry_write > write_after_intermediate)
	testing.expect_value(t, slot.state, Stream_Slot_State.Recording)
	testing.expect(t, _stream_slot_submit(&slot, 7))
	testing.expect_value(t, slot.state, Stream_Slot_State.Submitted)
}

@(test)
stream_transients_follow_submission_slot_lifetime :: proc(t: ^testing.T) {
	renderer := new(Renderer)
	defer free(renderer)
	renderer.active_stream_slot = _stream_slots_acquire(renderer.stream_slots[:], 0)
	buffer := wg.Buffer(uintptr(1))
	append(&renderer.transient_buffers, buffer)

	_stream_transients_retire(renderer, renderer.active_stream_slot)

	testing.expect_value(t, len(renderer.transient_buffers), 0)
	testing.expect_value(t, len(renderer.retired_buffers[renderer.active_stream_slot]), 1)
	testing.expect_value(t, renderer.retired_buffers[renderer.active_stream_slot][0], buffer)
}

@(test)
stream_slot_indexed_reservation_reports_exact_layout :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state          = .Recording,
		geometry_write = 3,
	}
	vertex, index, ok := _stream_slot_reserve_indexed(&slot, 5, 3, 15)
	testing.expect(t, ok)
	testing.expect_value(t, vertex, u64(4))
	testing.expect_value(t, index, u64(12))
	testing.expect_value(t, slot.geometry_write, u64(15))
}

@(test)
stream_slot_failed_uniform_reservation_is_atomic :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state         = .Recording,
		uniform_write = 900,
	}
	write_before := slot.uniform_write
	offset, ok := _stream_slot_reserve_uniform(&slot, 48, 256, 1024)
	testing.expect(t, !ok)
	testing.expect_value(t, offset, u64(0))
	testing.expect_value(t, slot.uniform_write, write_before)
}

@(test)
stream_reservation_rejects_u64_overflow_atomically :: proc(t: ^testing.T) {
	slot := Stream_Slot {
		state          = .Recording,
		geometry_write = max(u64) - 1,
		uniform_write  = max(u64) - 1,
	}
	geometry_before := slot.geometry_write
	uniform_before := slot.uniform_write
	_, _, indexed_ok := _stream_slot_reserve_indexed(&slot, 8, 4, max(u64))
	_, uniform_ok := _stream_slot_reserve_uniform(&slot, 8, 4, max(u64))
	testing.expect(t, !indexed_ok)
	testing.expect(t, !uniform_ok)
	testing.expect_value(t, slot.geometry_write, geometry_before)
	testing.expect_value(t, slot.uniform_write, uniform_before)
}

@(test)
stream_shadow_grows_geometrically_and_preserves_bytes :: proc(t: ^testing.T) {
	shadow: [dynamic]byte
	defer delete(shadow)
	testing.expect(t, _stream_shadow_ensure(&shadow, 5, 16384))
	testing.expect_value(t, len(shadow), 4096)
	shadow[0] = 17
	testing.expect(t, _stream_shadow_ensure(&shadow, 4097, 16384))
	testing.expect_value(t, len(shadow), 8192)
	testing.expect_value(t, shadow[0], byte(17))
}

@(test)
stream_slot_reuse_preserves_shadow_capacity :: proc(t: ^testing.T) {
	slots: [1]Stream_Slot
	defer delete(slots[0].geometry_shadow)
	first := _stream_slots_acquire(slots[:], 0)
	testing.expect(t, _stream_shadow_ensure(&slots[first].geometry_shadow, 64, 8192))
	capacity := len(slots[first].geometry_shadow)
	testing.expect(t, _stream_slot_submit(&slots[first], 1))
	reused := _stream_slots_acquire(slots[:], 1)
	testing.expect_value(t, reused, first)
	testing.expect_value(t, slots[reused].geometry_write, u64(0))
	testing.expect_value(t, len(slots[reused].geometry_shadow), capacity)
}

@(test)
batch_capacity_constants_cover_complete_primitives :: proc(t: ^testing.T) {
	testing.expect_value(t, BATCH_MAX_VERTICES % 4, 0)
	testing.expect_value(t, BATCH_MAX_INDICES % 6, 0)
	testing.expect(t, BATCH_MAX_INDICES >= BATCH_MAX_VERTICES / 4 * 6)
	testing.expect(t, MODEL_STACK_MAX > 0)
}

@(test)
unified_ui_state_preserves_texture_for_solids :: proc(t: ^testing.T) {
	current := wg.BindGroup(uintptr(1))
	neutral := wg.BindGroup(uintptr(2))
	testing.expect_value(t, _batch_bind(.Solid, nil, current, neutral), current)
	testing.expect_value(t, _batch_bind(.Solid, nil, nil, neutral), neutral)
}

@(test)
vertex_modes_are_distinct_and_gpu_sized :: proc(t: ^testing.T) {
	testing.expect_value(t, u32(Vertex_Mode.Solid), u32(0))
	testing.expect_value(t, u32(Vertex_Mode.Text), u32(1))
	testing.expect_value(t, size_of(Vertex_Mode), size_of(u32))
}

// --- capacity and overflow --------------------------------------------------
//
// BATCH_MAX_VERTICES was cut from a round number to a measured one, so the
// behaviour at the boundary has to be pinned: reaching the cap must flush and
// continue, never corrupt or silently drop geometry. A request larger than the
// whole batch is the one case that cannot be served at all, and it must be
// refused rather than overrun the array.

@(test)
batch_reserve_refuses_requests_larger_than_capacity :: proc(t: ^testing.T) {
	// Heap-allocated: Renderer is ~11 MB, far past a safe stack frame - the
	// very cost this capacity work is about.
	r := new(Renderer)
	defer free(r)
	// No active pass, so _batch_reserve cannot flush its way out: this
	// isolates the pure capacity check from the flush path.
	testing.expect(
		t,
		!_batch_reserve(r, BATCH_MAX_VERTICES + 1, 6),
		"a vertex request above the cap must be refused",
	)
	testing.expect(
		t,
		!_batch_reserve(r, 4, BATCH_MAX_INDICES + 1),
		"an index request above the cap must be refused",
	)
	// Nothing was written for a refused reservation.
	testing.expect_value(t, len(r.verts), 0)
	testing.expect_value(t, len(r.indices), 0)
}

@(test)
batch_reserve_fits_exactly_to_capacity :: proc(t: ^testing.T) {
	r := new(Renderer)
	defer free(r)
	// The boundary itself must succeed: an off-by-one here would waste the
	// last slot of a now-measured capacity.
	testing.expect(
		t,
		_batch_reserve(r, BATCH_MAX_VERTICES, BATCH_MAX_INDICES),
		"a request of exactly the capacity must fit an empty batch",
	)
}

@(test)
batch_peak_tracks_high_water_across_flushes :: proc(t: ^testing.T) {
	// The peak is what justifies the capacity constants, so it must survive
	// the per-flush clear rather than reporting only the last batch. Calls
	// the production helper renderer_flush uses - asserting on a value the
	// test itself assigned would prove nothing.
	r := new(Renderer)
	defer free(r)
	_batch_record_peak(r, 100, 150)
	testing.expect_value(t, r.peak_verts, 100)
	testing.expect_value(t, r.peak_indices, 150)

	// A smaller later batch must not lower the mark.
	_batch_record_peak(r, 40, 60)
	testing.expect_value(t, r.peak_verts, 100)
	testing.expect_value(t, r.peak_indices, 150)

	// A larger one must raise it.
	_batch_record_peak(r, 250, 300)
	testing.expect_value(t, r.peak_verts, 250)
	testing.expect_value(t, r.peak_indices, 300)

	// And the public accessor reports it against the capacity, which is what
	// the smoke harness prints.
	usage := Peak_Usage {
		vertices          = r.peak_verts,
		vertices_capacity = BATCH_MAX_VERTICES,
		indices           = r.peak_indices,
		indices_capacity  = BATCH_MAX_INDICES,
	}
	testing.expect(t, usage.vertices <= usage.vertices_capacity)
	testing.expect(t, usage.indices <= usage.indices_capacity)
}

@(test)
batch_capacities_cover_the_measured_peak :: proc(t: ^testing.T) {
	// Measured with the gallery smoke run at 3840x2160, the heaviest scene
	// in the repo. The capacity must clear that peak with real headroom: a
	// display larger than 4K scales the vertex count further, and falling
	// back to one-shot buffers during ordinary use is the regression this
	// guards. 1.5x is the minimum margin, which 262,144 satisfies at 2.4x.
	MEASURED_4K_VERTICES :: 107_968
	MEASURED_4K_INDICES :: 125_880
	CAPACITY_MARGIN_MIN :: 3 // expressed as thirds to stay integer: 3/2 = 1.5x
	testing.expect(
		t,
		BATCH_MAX_VERTICES * 2 >= MEASURED_4K_VERTICES * CAPACITY_MARGIN_MIN,
		"vertex capacity must clear the measured 4K peak by at least 1.5x",
	)
	testing.expect(
		t,
		BATCH_MAX_INDICES * 2 >= MEASURED_4K_INDICES * CAPACITY_MARGIN_MIN,
		"index capacity must clear the measured 4K peak by at least 1.5x",
	)
}
