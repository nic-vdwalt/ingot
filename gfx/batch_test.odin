#+build !js
package gfx

import "core:testing"

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
