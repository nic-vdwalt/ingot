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
	slot := Stream_Slot{state = .Recording}
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
	slot := Stream_Slot{state = .Recording, geometry_write = 40}
	write_before := slot.geometry_write
	_, _, ok := _stream_slot_reserve_indexed(&slot, 20, 12, 64)
	testing.expect(t, !ok)
	testing.expect_value(t, slot.geometry_write, write_before)
}

@(test)
stream_slot_zero_ticket_preserves_recording_ownership :: proc(t: ^testing.T) {
	slot := Stream_Slot{state = .Recording, geometry_write = 128}
	testing.expect(t, !_stream_slot_submit(&slot, 0))
	testing.expect_value(t, slot.state, Stream_Slot_State.Recording)
	testing.expect_value(t, slot.geometry_write, u64(128))
}

@(test)
stream_slot_intermediate_work_stays_in_recording_epoch :: proc(t: ^testing.T) {
	slot := Stream_Slot{state = .Recording}
	_, _, first_ok := _stream_slot_reserve_indexed(&slot, 64, 24, 1024)
	write_after_intermediate := slot.geometry_write
	_, _, second_ok := _stream_slot_reserve_indexed(&slot, 64, 24, 1024)
	testing.expect(t, first_ok && second_ok)
	testing.expect(t, slot.geometry_write > write_after_intermediate)
	testing.expect_value(t, slot.state, Stream_Slot_State.Recording)
	testing.expect(t, _stream_slot_submit(&slot, 7))
	testing.expect_value(t, slot.state, Stream_Slot_State.Submitted)
}
