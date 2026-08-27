package ui

import "core:fmt"

Time_Of_Day :: struct {
	hour:   i32,
	minute: i32,
	second: i32,
	set:    bool,
}

time_of_day_valid :: proc(value: Time_Of_Day) -> bool {
	if !value.set do return false
	return value.hour >= 0 && value.hour <= 23 &&
	       value.minute >= 0 && value.minute <= 59 &&
	       value.second >= 0 && value.second <= 59
}

time_of_day_format :: proc(value: Time_Of_Day, show_seconds: bool = false) -> string {
	assert(time_of_day_valid(value), "time_of_day_format: invalid time")
	if show_seconds do return fmt.tprintf("%02d:%02d:%02d", value.hour, value.minute, value.second)
	return fmt.tprintf("%02d:%02d", value.hour, value.minute)
}

@(private = "file")
time_two_digits :: proc(value: string) -> (i32, bool) {
	if len(value) != 2 do return 0, false
	if value[0] < '0' || value[0] > '9' || value[1] < '0' || value[1] > '9' do return 0, false
	return i32(value[0] - '0') * 10 + i32(value[1] - '0'), true
}

time_of_day_parse :: proc(value: string, show_seconds: bool = false) -> (Time_Of_Day, bool) {
	expected := 8 if show_seconds else 5
	if len(value) != expected || value[2] != ':' do return {}, false
	if show_seconds && value[5] != ':' do return {}, false
	hour, hour_ok := time_two_digits(value[0:2])
	minute, minute_ok := time_two_digits(value[3:5])
	second: i32
	second_ok := true
	if show_seconds do second, second_ok = time_two_digits(value[6:8])
	result := Time_Of_Day{hour, minute, second, true}
	if !hour_ok || !minute_ok || !second_ok || !time_of_day_valid(result) do return {}, false
	return result, true
}
