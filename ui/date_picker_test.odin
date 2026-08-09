#+build !js
package ui

import "core:testing"

@(test)
test_calendar_days_in_month_handles_leap_years :: proc(t: ^testing.T) {
	testing.expect_value(t, calendar_days_in_month(2026, 1), i32(31))
	testing.expect_value(t, calendar_days_in_month(2026, 2), i32(28))
	testing.expect_value(t, calendar_days_in_month(2024, 2), i32(29))
	testing.expect_value(t, calendar_days_in_month(2000, 2), i32(29))
	testing.expect_value(t, calendar_days_in_month(1900, 2), i32(28))
	testing.expect_value(t, calendar_days_in_month(2026, 4), i32(30))
}

@(test)
test_calendar_weekday_matches_known_dates :: proc(t: ^testing.T) {
	// 2026-07-29 is a Wednesday (3); 2000-01-01 was a Saturday (6).
	testing.expect_value(t, calendar_weekday(2026, 7, 29), i32(3))
	testing.expect_value(t, calendar_weekday(2000, 1, 1), i32(6))
	testing.expect_value(t, calendar_weekday(2024, 2, 29), i32(4))
}

@(test)
test_calendar_parse_round_trips_and_rejects_garbage :: proc(t: ^testing.T) {
	date, ok := calendar_parse("2026-02-28")
	testing.expect(t, ok)
	testing.expect_value(t, date.year, i32(2026))
	testing.expect_value(t, calendar_format(date), "2026-02-28")
	_, bad_day := calendar_parse("2026-02-30")
	testing.expect(t, !bad_day)
	_, bad_shape := calendar_parse("not-a-date")
	testing.expect(t, !bad_shape)
	_, bad_month := calendar_parse("2026-13-01")
	testing.expect(t, !bad_month)
}

@(test)
test_date_picker_month_shift_wraps_years :: proc(t: ^testing.T) {
	st := Date_Picker_State {
		view_year  = 2026,
		view_month = 1,
	}
	date_picker_shift_month(&st, -1)
	testing.expect_value(t, st.view_year, i32(2025))
	testing.expect_value(t, st.view_month, i32(12))
	date_picker_shift_month(&st, 1)
	testing.expect_value(t, st.view_year, i32(2026))
	testing.expect_value(t, st.view_month, i32(1))
}

@(test)
date_picker_popup_clamps_and_records_in_screen_space :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	input := Ui_Input {
		screen_size = {800, 600},
	}
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer {
		ui_frame_end(&frame)
		ui_frame_destroy(&frame)
	}
	ui_frame_pane_push(&frame, {500.5, 300.25})
	defer ui_frame_pane_pop(&frame)
	state := Date_Picker_State {
		open        = true,
		just_opened = true,
		view_year   = 2026,
		view_month  = 8,
	}
	value := Calendar_Date{2026, 8, 9}
	_ = date_picker_at(&frame, {200, 200, 120, 30}, &state, &value, "", 800, 600)
	metrics := ui_frame_metrics(&frame)
	menu_w := ui_frame_sc(&frame, 30) * 7 + metrics.PADDING * 2
	menu_h := ui_frame_sc(&frame, 30) * 8 + metrics.PADDING * 2
	expected := Rectangle{f32(800 - menu_w), f32(500 - menu_h - 2), f32(menu_w), f32(menu_h)}
	testing.expect_value(t, output.overlay.commands[0].rect, expected)
	testing.expect_value(t, output.overlay.commands[3].rect.y, expected.y + f32(metrics.PADDING))
}
