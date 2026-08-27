package ui

import "core:fmt"

color_hex_digit :: proc(value: u8) -> (u8, bool) {
	if value >= '0' && value <= '9' do return value - '0', true
	if value >= 'a' && value <= 'f' do return value - 'a' + 10, true
	if value >= 'A' && value <= 'F' do return value - 'A' + 10, true
	return 0, false
}

color_hex_byte :: proc(value: string) -> (u8, bool) {
	if len(value) != 2 do return 0, false
	hi, hi_ok := color_hex_digit(value[0])
	lo, lo_ok := color_hex_digit(value[1])
	if !hi_ok || !lo_ok do return 0, false
	return hi * 16 + lo, true
}

color_format_hex :: proc(value: Color, include_alpha: bool = false) -> string {
	if include_alpha {
		return fmt.tprintf("#%02X%02X%02X%02X", value[0], value[1], value[2], value[3])
	}
	return fmt.tprintf("#%02X%02X%02X", value[0], value[1], value[2])
}

color_parse_hex :: proc(value: string, allow_alpha: bool = false) -> (Color, bool) {
	expected := 9 if allow_alpha else 7
	if len(value) != expected || value[0] != '#' do return {}, false
	red, red_ok := color_hex_byte(value[1:3])
	green, green_ok := color_hex_byte(value[3:5])
	blue, blue_ok := color_hex_byte(value[5:7])
	alpha: u8 = 255
	alpha_ok := true
	if allow_alpha do alpha, alpha_ok = color_hex_byte(value[7:9])
	if !red_ok || !green_ok || !blue_ok || !alpha_ok do return {}, false
	return Color{red, green, blue, alpha}, true
}
