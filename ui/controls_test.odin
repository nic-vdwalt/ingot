#+build !js
package ui

import "core:testing"

@(test)
slider_step_value_snaps_and_clamps :: proc(t: ^testing.T) {
	// Continuous (step 0): straight lerp.
	testing.expect_value(t, slider_step_value(0, 10, 0, 0.5), f32(5))
	testing.expect_value(t, slider_step_value(0, 10, 0, 0), f32(0))
	testing.expect_value(t, slider_step_value(0, 10, 0, 1), f32(10))
	// Stepped: snaps to the nearest multiple of step from lo.
	testing.expect_value(t, slider_step_value(0, 10, 2, 0.4), f32(4))
	testing.expect_value(t, slider_step_value(0, 10, 2, 0.61), f32(6))
	// Negative ranges work.
	testing.expect_value(t, slider_step_value(-5, 5, 5, 0.5), f32(0))
	// Snapping never escapes [lo, hi].
	testing.expect_value(t, slider_step_value(0, 10, 3, 1), f32(9))
}

@(test)
slider_keyboard_delta_prefers_step :: proc(t: ^testing.T) {
	testing.expect_value(t, slider_keyboard_delta(0, 10, 2), f32(2))
	// No step: 1% of the range.
	testing.expect_value(t, slider_keyboard_delta(0, 100, 0), f32(1))
}

@(test)
menu_nav_skips_separators_and_disabled :: proc(t: ^testing.T) {
	items := []Menu_Item {
		{label = "a"},
		{separator = true},
		{label = "b", disabled = true},
		{label = "c"},
	}
	// Down from "a" skips the separator and the disabled row to reach "c".
	testing.expect_value(t, menu_nav_next(items, 0, 1), 3)
	// Down from "c" wraps back to "a".
	testing.expect_value(t, menu_nav_next(items, 3, 1), 0)
	// Up from "a" wraps to "c".
	testing.expect_value(t, menu_nav_next(items, 0, -1), 3)
}

@(test)
menu_nav_all_unselectable_stays_put :: proc(t: ^testing.T) {
	items := []Menu_Item{{separator = true}, {label = "x", disabled = true}}
	testing.expect_value(t, menu_nav_next(items, 1, 1), 1)
}

@(test)
context_menu_height_counts_rows :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	items := []Menu_Item{{label = "a"}, {separator = true}, {label = "b"}}
	want := runtime.metrics.MENU_PAD * 2 + runtime.metrics.MENU_ITEM_H * 2 + ui_frame_sc(&frame, 5)
	testing.expect_value(t, context_menu_height_frame(&frame, items), want)
}

@(test)
theme_palettes_define_widget_colors :: proc(t: ^testing.T) {
	// Every color the new widgets rely on must be present in both built-in
	// palettes; a zero-alpha entry renders the control invisible.
	for pal in ([2]Theme{theme_dark(), theme_light()}) {
		testing.expect(t, pal.focus_ring.a > 0, "focus_ring unset")
		testing.expect(t, pal.modal_dim.a > 0, "modal_dim unset")
		testing.expect(t, pal.bg_popup.a > 0, "bg_popup unset")
		testing.expect(t, pal.button_danger_bg.a > 0, "button_danger_bg unset")
		testing.expect(t, pal.button_danger_hover.a > 0, "button_danger_hover unset")
		testing.expect(t, pal.button_danger_fg.a > 0, "button_danger_fg unset")
		testing.expect(t, pal.button_pressed.a > 0, "button_pressed unset")
		testing.expect(t, pal.button_disabled_bg.a > 0, "button_disabled_bg unset")
	}
}
