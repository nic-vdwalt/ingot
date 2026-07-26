package ui

import "core:testing"

@(test)
layout_space_tokens_follow_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 1.5)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	ui_begin_frame(&u, &frame, 0, 0, 900, 300)
	testing.expect_value(t, ui_space_px(&u, .SM), i32(12))
	testing.expect_value(t, ui_insets(&u, .LG), insets(24))
	testing.expect(t, !ui_compact(&u, 500))
	ui_end(&u)
}

@(test)
layout_named_row_resolves_exact_slots :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	ui_begin_frame(&u, &frame, 0, 0, 300, 100)
	ui_row_begin(&u, 40, {flex_fixed(80), flex_grow()}, {gap = .SM})
	first := ui_flex_slot(&u, 40)
	second := ui_flex_slot(&u, 40)
	ui_row_end(&u)
	ui_end(&u)
	testing.expect_value(t, first, Rect_I32{0, 0, 80, 40})
	testing.expect_value(t, second, Rect_I32{88, 0, 212, 40})
}
