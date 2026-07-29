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
