#+build !js
package ui

import "core:testing"

@(test)
scale_clamps :: proc(t: ^testing.T) {
	defer set_ui_scale(1.0)
	set_ui_scale(10.0)
	testing.expect_value(t, ui_scale(), 3.0) // clamped to max
	set_ui_scale(0.1)
	testing.expect_value(t, ui_scale(), 0.5) // clamped to min
}

@(test)
scale_sc_rounding :: proc(t: ^testing.T) {
	defer set_ui_scale(1.0)
	set_ui_scale(2.0)
	testing.expect_value(t, sc(10), 20)
	testing.expect_value(t, scf(2.5), 5.0)
	// 1.5x with rounding: 3 * 1.5 = 4.5 -> 5.
	set_ui_scale(1.5)
	testing.expect_value(t, sc(3), 5)
}

@(test)
scale_noop_when_unchanged :: proc(t: ^testing.T) {
	defer set_ui_scale(1.0)
	set_ui_scale(2.0)
	before := FONT_SIZE
	set_ui_scale(2.0) // same value: early-return, no recompute needed
	testing.expect_value(t, FONT_SIZE, before)
	testing.expect_value(t, ui_scale(), 2.0)
}