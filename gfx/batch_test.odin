#+build !js
package gfx

import "core:testing"

@(test)
stream_does_not_reuse_current_unsubmitted_range :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 1024}
	_, first, first_ok := _stream_reserve(&arena, 128, 4)
	_stream_submit(&arena, 1)
	_, current, current_ok := _stream_reserve(&arena, 128, 4)
	_stream_poll(&arena, 1)
	_, next, next_ok := _stream_reserve(&arena, 128, 4)
	testing.expect(t, first_ok && current_ok && next_ok)
	testing.expect(t, first != current && current != next)
	testing.expect_value(t, arena.reclaim, u64(128))
	testing.expect_value(t, arena.frame_begin, u64(128))
}

@(test)
stream_reuses_only_completed_submitted_ranges :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 256}
	_, first, first_ok := _stream_reserve(&arena, 128, 4)
	_stream_submit(&arena, 1)
	_, second, second_ok := _stream_reserve(&arena, 128, 4)
	_stream_submit(&arena, 2)
	_, _, full_ok := _stream_reserve(&arena, 4, 4)
	testing.expect(t, first_ok && second_ok && !full_ok)
	testing.expect_value(t, first, u64(0))
	testing.expect_value(t, second, u64(128))

	_stream_poll(&arena, 1)
	_, wrapped, wrapped_ok := _stream_reserve(&arena, 128, 4)
	testing.expect(t, wrapped_ok)
	testing.expect_value(t, wrapped, u64(0))
	_stream_submit(&arena, 3)

	_stream_poll(&arena, 2)
	testing.expect_value(t, arena.reclaim, u64(256))
	_stream_poll(&arena, 3)
	testing.expect_value(t, arena.reclaim, u64(384))
}

@(test)
stream_reports_bounded_exhaustion_without_overwrite :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 64}
	_, first, first_ok := _stream_reserve(&arena, 48, 4)
	write_before := arena.write
	_, _, overflow_ok := _stream_reserve(&arena, 20, 4)
	testing.expect(t, first_ok && !overflow_ok)
	testing.expect_value(t, first, u64(0))
	testing.expect_value(t, arena.write, write_before)
	testing.expect_value(t, arena.reclaim, u64(0))
}

@(test)
stream_honours_uniform_alignment_across_wrap :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 1024}
	_, first, first_ok := _stream_reserve(&arena, 48, 256)
	_, second, second_ok := _stream_reserve(&arena, 48, 256)
	_stream_submit(&arena, 1)
	_stream_poll(&arena, 1)
	_, third, third_ok := _stream_reserve(&arena, 48, 256)
	_, fourth, fourth_ok := _stream_reserve(&arena, 48, 256)
	_, wrapped, wrapped_ok := _stream_reserve(&arena, 48, 256)
	testing.expect(t, first_ok && second_ok && third_ok && fourth_ok && wrapped_ok)
	testing.expect_value(t, first % 256, u64(0))
	testing.expect_value(t, second % 256, u64(0))
	testing.expect_value(t, third % 256, u64(0))
	testing.expect_value(t, fourth % 256, u64(0))
	testing.expect_value(t, wrapped % 256, u64(0))
	testing.expect_value(t, wrapped, u64(0))
}

@(test)
stream_failed_combined_reservation_does_not_consume_space :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 64, write = 40}
	write_before := arena.write
	_, _, ok := _stream_reserve_indexed(&arena, 20, 12)
	testing.expect(t, !ok)
	testing.expect_value(t, arena.write, write_before)
	testing.expect_value(t, arena.reclaim, u64(0))
}

@(test)
stream_zero_ticket_does_not_advance_frame_ownership :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 1024}
	_, _, reserve_ok := _stream_reserve(&arena, 128, 4)
	frame_begin_before := arena.frame_begin
	submit_ok := _stream_submit(&arena, 0)
	testing.expect(t, reserve_ok && !submit_ok)
	testing.expect_value(t, arena.frame_begin, frame_begin_before)
	testing.expect_value(t, arena.count, u32(0))
}

@(test)
stream_retirement_capacity_failure_is_not_silent :: proc(t: ^testing.T) {
	arena := Stream_Arena{capacity = 4096}
	for ticket: u64 = 1; ticket <= STREAM_RETIREMENTS_MAX; ticket += 1 {
		_, _, reserve_ok := _stream_reserve(&arena, 32, 4)
		submit_ok := _stream_submit(&arena, ticket)
		testing.expect(t, reserve_ok && submit_ok)
	}
	_, _, reserve_ok := _stream_reserve(&arena, 32, 4)
	frame_begin_before := arena.frame_begin
	submit_ok := _stream_submit(&arena, STREAM_RETIREMENTS_MAX + 1)
	testing.expect(t, reserve_ok && !submit_ok)
	testing.expect_value(t, arena.frame_begin, frame_begin_before)
	testing.expect_value(t, arena.count, u32(STREAM_RETIREMENTS_MAX))
}
