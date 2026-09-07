package main

import "core:testing"

@(test)
host_cursor_owner_follows_the_current_frame_draw_claim :: proc(t: ^testing.T) {
	testing.expect_value(t, cursor_owner(false), Cursor_Owner.OS)
	testing.expect_value(t, cursor_owner(true), Cursor_Owner.Game)
	testing.expect_value(t, cursor_owner(false), Cursor_Owner.OS)
}

@(test)
host_refresh_rate_uses_fallback_for_invalid_monitor_rates :: proc(t: ^testing.T) {
	testing.expect_value(t, refresh_rate_or_fallback(60), i32(60))
	testing.expect_value(t, refresh_rate_or_fallback(120), i32(120))
	testing.expect_value(t, refresh_rate_or_fallback(144), i32(144))
	testing.expect_value(t, refresh_rate_or_fallback(0), REFRESH_RATE_FALLBACK)
	testing.expect_value(t, refresh_rate_or_fallback(-1), REFRESH_RATE_FALLBACK)
}

@(test)
host_refresh_rate_change_only_reports_a_new_monitor_rate :: proc(t: ^testing.T) {
	refresh_rate, changed := refresh_rate_change(60, 120)
	testing.expect_value(t, refresh_rate, i32(120))
	testing.expect(t, changed)
	refresh_rate, changed = refresh_rate_change(120, 120)
	testing.expect_value(t, refresh_rate, i32(120))
	testing.expect(t, !changed)
	refresh_rate, changed = refresh_rate_change(144, 0)
	testing.expect_value(t, refresh_rate, REFRESH_RATE_FALLBACK)
	testing.expect(t, changed)
}

@(test)
host_frame_pacing_modes_are_explicit :: proc(t: ^testing.T) {
	testing.expect_value(t, frame_pacing_mode(0), Frame_Pacing_Mode.Fifo_Free)
	testing.expect_value(t, frame_pacing_mode(1), Frame_Pacing_Mode.Immediate_Display_Link)
	testing.expect_value(t, frame_pacing_mode(2), Frame_Pacing_Mode.Fifo_Display_Link)
	testing.expect_value(t, frame_pacing_mode(99), Frame_Pacing_Mode.Fifo_Free)
	testing.expect(t, !frame_pacing_uses_display_link(.Fifo_Free))
	testing.expect(t, frame_pacing_uses_display_link(.Immediate_Display_Link))
	testing.expect(t, frame_pacing_uses_display_link(.Fifo_Display_Link))
	testing.expect(t, frame_pacing_uses_immediate(.Immediate_Display_Link))
	testing.expect(t, !frame_pacing_uses_immediate(.Fifo_Display_Link))
}
