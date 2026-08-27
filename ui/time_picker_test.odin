#+build !js
package ui

import "core:testing"

@(test)
time_of_day_round_trips_supported_formats :: proc(t: ^testing.T) {
	value := Time_Of_Day{23, 59, 58, true}
	testing.expect_value(t, time_of_day_format(value), "23:59")
	testing.expect_value(t, time_of_day_format(value, true), "23:59:58")
	short, short_ok := time_of_day_parse("23:59")
	full, full_ok := time_of_day_parse("23:59:58", true)
	testing.expect(t, short_ok && full_ok)
	testing.expect_value(t, short, Time_Of_Day{23, 59, 0, true})
	testing.expect_value(t, full, value)
}

@(test)
time_of_day_rejects_malformed_and_out_of_range_values :: proc(t: ^testing.T) {
	values := [6]string{"", "1:00", "24:00", "12:60", "12-00", "12:00:00"}
	for value in values {
		_, ok := time_of_day_parse(value)
		testing.expect(t, !ok)
	}
	_, ok := time_of_day_parse("12:00:60", true)
	testing.expect(t, !ok)
}
