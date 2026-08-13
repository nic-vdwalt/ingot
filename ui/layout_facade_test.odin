#+build !js
package ui

import "core:testing"

@(private = "file")
layout_intrinsic_measure :: proc(text: cstring, size: i32) -> i32 {
	assert(size > 0, "layout_intrinsic_measure: invalid size")
	return i32(len(string(text))) * 7
}

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
	begin(&u, &frame, {0, 0, 900, 300})
	testing.expect_value(t, space_px(&u, .SM), i32(12))
	testing.expect_value(t, insets_of(&u, .LG), insets(24))
	testing.expect(t, !compact(&u, 500))
	end(&u)
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
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(80), grow()}, gap = .SM)
	first := flex_slot_next(&u, 40)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, first, Rect_I32{0, 0, 80, 40})
	testing.expect_value(t, second, Rect_I32{88, 0, 212, 40})
}

@(test)
layout_facade_composes_intrinsic_toolbar_without_consuming_layout :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	set_measure_backend_with(&runtime.text, layout_intrinsic_measure)
	ui_runtime_set_scale(&runtime, 1.5)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	before := remaining_rect(&u)
	save := intrinsic_padding_space(&u, intrinsic_text(&u, "Save"), .SM)
	cancel := intrinsic_padding_space(&u, intrinsic_text(&u, "Cancel"), .SM)
	gap := space_px(&u, .SM)
	toolbar := intrinsic_row({save, cancel}, gap)
	testing.expect_value(t, remaining_rect(&u), before)
	intrinsic_flex_row_begin(&u, toolbar.h, {intrinsic_fit_width(toolbar), grow()}, gap = .SM)
	fit_rect := flex_slot_px(&u, toolbar.h)
	rest_rect := flex_slot_px(&u, toolbar.h)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, fit_rect.w, toolbar.w)
	testing.expect_value(t, fit_rect.h, toolbar.h)
	testing.expect_value(t, fit_rect.w + rest_rect.w + gap, i32(300))
	testing.expect_value(t, frame.degenerate_drops, 0)
}

@(test)
layout_root_stays_screen_space_while_children_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 2)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {10, 20, 200, 100})
	row_begin(&u, 20)
	rect := slot_next(&u, 30, 10)
	row_end(&u)
	end(&u)
	testing.expect_value(t, rect, Rect_I32{10, 20, 60, 20})
}

@(test)
layout_nested_container_consumes_one_flex_track :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(100), grow()})
	column_begin(&u, 100)
	child := slot_next(&u, 40, 20)
	column_end(&u)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, child, Rect_I32{0, 0, 40, 20})
	testing.expect_value(t, second, Rect_I32{100, 0, 200, 40})
}

@(test)
layout_flow_reflows_when_available_width_changes :: proc(t: ^testing.T) {
	wide: Flow_Layout
	flow_begin(&wide, {0, 0, 120, 100}, 4, 6)
	_ = flow_next(&wide, 50, 20)
	wide_second := flow_next(&wide, 50, 20)
	wide_bounds := flow_end(&wide)
	narrow: Flow_Layout
	flow_begin(&narrow, {0, 0, 80, 100}, 4, 6)
	_ = flow_next(&narrow, 50, 20)
	narrow_second := flow_next(&narrow, 50, 20)
	narrow_bounds := flow_end(&narrow)
	testing.expect_value(t, wide_second, Rect_I32{54, 0, 50, 20})
	testing.expect_value(t, wide_bounds.h, i32(20))
	testing.expect_value(t, narrow_second, Rect_I32{0, 26, 50, 20})
	testing.expect_value(t, narrow_bounds.h, i32(46))
}

@(test)
layout_end_reports_consumed_extent :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 50, 300, ROOT_EXTENT_OPEN})
	row_begin(&u, 40)
	row_end(&u)
	space(&u, .LG)
	end_y := end(&u)
	// 50 root origin + 40 row + 16 trailing token; no magic epilogue math.
	testing.expect_value(t, end_y, i32(106))
}

@(test)
layout_facade_flex_justify_packs_space_between :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(60), fixed(60)}, justify = .Space_Between)
	first := flex_slot_next(&u, 40)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, first, Rect_I32{0, 0, 60, 40})
	testing.expect_value(t, second, Rect_I32{240, 0, 60, 40})
}
