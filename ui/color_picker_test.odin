#+build !js
package ui

import "core:testing"

@(test)
color_hex_round_trips_rgb_and_rgba :: proc(t: ^testing.T) {
	value := Color{0x12, 0xAB, 0x00, 0x7F}
	testing.expect_value(t, color_format_hex(value), "#12AB00")
	testing.expect_value(t, color_format_hex(value, true), "#12AB007F")
	rgb, rgb_ok := color_parse_hex("#12ab00")
	rgba, rgba_ok := color_parse_hex("#12AB007f", true)
	testing.expect(t, rgb_ok && rgba_ok)
	testing.expect_value(t, rgb, Color{0x12, 0xAB, 0x00, 0xFF})
	testing.expect_value(t, rgba, value)
}

@(test)
color_hex_rejects_invalid_inputs :: proc(t: ^testing.T) {
	values := [5]string{"", "12AB00", "#123", "#GG0000", "#12AB007F"}
	for value in values {
		_, ok := color_parse_hex(value)
		testing.expect(t, !ok)
	}
}
