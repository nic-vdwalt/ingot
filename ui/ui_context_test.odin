#+build !js
package ui

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
ui_frame_normalizes_hostile_input_lengths :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.character_count = INPUT_CHAR_CAP + 9
	input.pointer_event_count = INPUT_POINTER_EVENT_CAP + 9
	input.clipboard = strings.repeat("x", INPUT_CLIPBOARD_CAP + 9, context.temp_allocator)
	input.preedit_len = INPUT_PREEDIT_CAP + 9
	input.preedit_caret = INPUT_PREEDIT_CAP + 9
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	testing.expect_value(t, input.character_count, INPUT_CHAR_CAP)
	testing.expect_value(t, input.characters_dropped, 9)
	testing.expect_value(t, input.pointer_event_count, INPUT_POINTER_EVENT_CAP)
	testing.expect(t, input.pointer_events_overflowed)
	testing.expect_value(t, len(input.clipboard), INPUT_CLIPBOARD_CAP)
	testing.expect_value(t, input.preedit_len, INPUT_PREEDIT_CAP)
	_, ok := input_character(&input, INPUT_CHAR_CAP)
	testing.expect(t, !ok)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
}

@(test)
input_clip_utf8_preserves_rune_boundaries :: proc(t: ^testing.T) {
	text := "abc€z"
	testing.expect_value(t, input_clip_utf8(text, 3), 3)
	testing.expect_value(t, input_clip_utf8(text, 4), 3)
	testing.expect_value(t, input_clip_utf8(text, 6), 6)
	testing.expect_value(t, input_clip_utf8(text, 99), len(text))
}

@(test)
ui_frame_style_matches_individual_accessors :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 1.5)
	ui_runtime_set_theme(&runtime, theme_light())

	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)

	metrics, style := ui_frame_style(&frame)
	testing.expect(t, metrics == ui_frame_metrics(&frame), "style metrics must alias the runtime")
	testing.expect(t, style == ui_frame_theme(&frame), "style theme must alias the runtime")
	testing.expect_value(t, metrics.FONT_SIZE_BODY, ui_frame_metrics(&frame).FONT_SIZE_BODY)
	testing.expect_value(t, style.fg_primary, theme_light().fg_primary)
}

// Facade geometry tests run at scale 1 so design units and screen-space pixels
// coincide and the expected rectangles stay readable.
@(private = "file")
facade_frame :: proc(runtime: ^Ui_Runtime, frame: ^Ui_Frame) {
	assert(runtime != nil && frame != nil, "facade_frame: nil argument")
	ui_runtime_init(runtime)
	ui_frame_begin(frame, runtime)
}

@(private = "file")
facade_frame_end :: proc(runtime: ^Ui_Runtime, frame: ^Ui_Frame) {
	assert(runtime != nil && frame != nil, "facade_frame_end: nil argument")
	ui_frame_end(frame)
	ui_runtime_destroy(runtime)
}

@(test)
test_slot_next_column_and_row :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {0, 0, 200, 100})
	r1 := slot_next(&u, 50, 20)
	testing.expect_value(t, r1, Rect_I32{0, 0, 50, 20})
	row_begin(&u, 30)
	r2 := slot_next(&u, 40, 30)
	testing.expect_value(t, r2, Rect_I32{0, 20, 40, 30})
	row_end(&u)
	end(&u)
}

@(test)
frame_rect_to_screen_tracks_nested_pane_origins :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	rect := Rectangle{1, 2, 30, 40}
	testing.expect_value(t, frame_rect_to_screen(&frame, rect), rect)
	testing.expect_value(t, frame_rect_to_local(&frame, rect), rect)
	ui_frame_pane_push(&frame, {10.5, 20.25})
	screen := Rectangle{11.5, 22.25, 30, 40}
	testing.expect_value(t, frame_rect_to_screen(&frame, rect), screen)
	testing.expect_value(t, frame_rect_to_local(&frame, screen), rect)
	testing.expect_value(
		t,
		frame_to_local(&frame, frame_to_screen(&frame, {3.5, -2.25})),
		Vector2{3.5, -2.25},
	)
	ui_frame_pane_push(&frame, {-4.25, -8.5})
	screen = Rectangle{7.25, 13.75, 30, 40}
	testing.expect_value(t, frame_rect_to_screen(&frame, rect), screen)
	testing.expect_value(t, frame_rect_to_local(&frame, screen), rect)
	ui_frame_pane_pop(&frame)
	ui_frame_pane_pop(&frame)
}

@(test)
layout_weighted_division_matches_declared_shares :: proc(t: ^testing.T) {
	// Weighted division has no facade entry point: flex tracks supersede it.
	// The physical tier keeps it for callers driving a Layout directly.
	l: Layout
	layout_begin(&l, 0, 0, 320, 200, 8)
	layout_inset(&l, insets(12))
	push_row(&l, 64, 8)
	row_weights(&l, {1, 2})
	left := next_weighted(&l, 1)
	right := next_weighted(&l, 2)
	testing.expect_value(t, left, Rect_I32{12, 12, 96, 64})
	testing.expect_value(t, right, Rect_I32{116, 12, 192, 64})
	layout_pop(&l)
	testing.expect_value(t, take_remaining(&l), Rect_I32{12, 84, 296, 104})
	layout_end(&l)
}

@(test)
test_ui_runtime_frames_are_isolated_and_share_roots :: proc(t: ^testing.T) {
	a, b: Ui_Runtime
	ui_runtime_init(&a)
	ui_runtime_init(&b)
	defer ui_runtime_destroy(&a)
	defer ui_runtime_destroy(&b)
	ui_runtime_set_scale(&a, 2)
	testing.expect_value(t, a.scale, f32(2))
	testing.expect_value(t, b.scale, f32(1))

	frame_a, frame_b: Ui_Frame
	ui_frame_begin(&frame_a, &a)
	ui_frame_begin(&frame_b, &b)
	u1, u2: Ui
	begin(&u1, &frame_a, {0, 0, 100, 100})
	begin(&u2, &frame_a, {0, 0, 100, 100})
	testing.expect_value(t, frame_a.open_roots, 2)
	testing.expect_value(t, frame_b.open_roots, 0)
	end(&u2)
	end(&u1)
	ui_frame_end(&frame_a)
	ui_frame_end(&frame_b)
	testing.expect(t, u1.frame == nil && u2.frame == nil)
}

@(test)
test_ui_frame_pane_origins_are_isolated :: proc(t: ^testing.T) {
	a, b: Ui_Runtime
	ui_runtime_init(&a)
	ui_runtime_init(&b)
	defer ui_runtime_destroy(&a)
	defer ui_runtime_destroy(&b)
	frame_a, frame_b: Ui_Frame
	ui_frame_begin(&frame_a, &a)
	ui_frame_begin(&frame_b, &b)
	ui_frame_pane_push(&frame_a, {10, 20})
	ui_frame_pane_push(&frame_b, {100, 200})
	testing.expect_value(t, frame_to_screen(&frame_a, {1, 2}), Vector2{11, 22})
	testing.expect_value(t, frame_to_screen(&frame_b, {1, 2}), Vector2{101, 202})
	testing.expect_value(t, frame_to_local(&frame_a, {11, 22}), Vector2{1, 2})
	testing.expect_value(t, frame_to_local(&frame_b, {101, 202}), Vector2{1, 2})
	ui_frame_pane_pop(&frame_a)
	testing.expect_value(t, frame_pane_origin(&frame_a), Vector2{})
	testing.expect_value(t, frame_pane_origin(&frame_b), Vector2{100, 200})
	ui_frame_pane_pop(&frame_b)
	ui_frame_end(&frame_a)
	ui_frame_end(&frame_b)
}

@(test)
test_ui_frame_transient_context_is_isolated_and_reset :: proc(t: ^testing.T) {
	runtime_a, runtime_b: Ui_Runtime
	ui_runtime_init(&runtime_a)
	ui_runtime_init(&runtime_b)
	defer ui_runtime_destroy(&runtime_a)
	defer ui_runtime_destroy(&runtime_b)

	frame_a, frame_b: Ui_Frame
	defer ui_frame_destroy(&frame_a)
	defer ui_frame_destroy(&frame_b)
	ui_frame_begin(&frame_a, &runtime_a)
	ui_frame_begin(&frame_b, &runtime_b)
	view_a := frame_view(&frame_a, make([]u8, 32, ui_frame_allocator(&frame_a)))
	view_b := frame_view(&frame_b, make([]u8, 64, ui_frame_allocator(&frame_b)))
	testing.expect_value(t, len(frame_view_items(&frame_a, view_a)), 32)
	testing.expect_value(t, len(frame_view_items(&frame_b, view_b)), 64)
	set_text_cull_band_frame(&frame_a, 10, 20)
	set_text_cull_band_frame(&frame_b, 100, 200)
	testing.expect_value(t, frame_a.text_cull_top, i32(10))
	testing.expect_value(t, frame_b.text_cull_top, i32(100))
	ui_frame_end(&frame_a)
	ui_frame_end(&frame_b)
	testing.expect_value(t, frame_a.text_cull_top, min(i32))
	testing.expect_value(t, frame_a.text_cull_bottom, max(i32))

	frame_a.text_cull_top = 55
	frame_a.text_cull_bottom = 66
	ui_frame_begin(&frame_a, &runtime_a)
	testing.expect_value(t, frame_a.text_cull_top, min(i32))
	testing.expect_value(t, frame_a.text_cull_bottom, max(i32))
	ui_frame_end(&frame_a)
}

@(private = "file")
isolation_measure_narrow :: proc(text: cstring, size: i32) -> i32 {
	assert(size > 0, "isolation_measure_narrow: invalid size")
	return i32(utf8.rune_count(string(text))) * 5
}

@(private = "file")
isolation_measure_wide :: proc(text: cstring, size: i32) -> i32 {
	assert(size > 0, "isolation_measure_wide: invalid size")
	return i32(utf8.rune_count(string(text))) * 11
}

@(test)
test_ui_runtime_text_wrap_theme_and_destroy_are_isolated :: proc(t: ^testing.T) {
	a, b: Ui_Runtime
	ui_runtime_init(&a)
	ui_runtime_init(&b)
	set_measure_backend_with(&a.text, isolation_measure_narrow)
	set_measure_backend_with(&b.text, isolation_measure_wide)
	ui_runtime_set_scale(&a, 2)
	a.style = THEME_LIGHT

	frame_a, frame_b: Ui_Frame
	ui_frame_begin(&frame_a, &a)
	ui_frame_begin(&frame_b, &b)
	testing.expect_value(t, measure_text_frame(&frame_a, "abcd", 16), i32(20))
	testing.expect_value(t, measure_text_frame(&frame_b, "abcd", 16), i32(44))
	lines_a := wrap_text_frame(&frame_a, "aa aa", 35, 16)
	lines_b := wrap_text_frame(&frame_b, "aa aa", 35, 16)
	testing.expect_value(t, len(lines_a), 1)
	testing.expect_value(t, len(lines_b), 2)
	testing.expect_value(t, ui_frame_theme(&frame_a).bg_app, THEME_LIGHT.bg_app)
	ingot := theme_retro_ingot()
	testing.expect_value(t, ui_frame_theme(&frame_b).bg_app, ingot.bg_app)
	testing.expect_value(t, ui_frame_sc(&frame_a, 8), i32(16))
	testing.expect_value(t, ui_frame_sc(&frame_b, 8), i32(8))
	ui_frame_end(&frame_a)
	ui_frame_end(&frame_b)

	ui_runtime_destroy(&a)
	ui_frame_begin(&frame_b, &b)
	testing.expect_value(t, measure_text_frame(&frame_b, "abcd", 16), i32(44))
	testing.expect_value(t, len(wrap_text_frame(&frame_b, "aa aa", 35, 16)), 2)
	ui_frame_end(&frame_b)
	ui_runtime_destroy(&b)
}

@(test)
test_ui_runtime_spell_state_is_isolated :: proc(t: ^testing.T) {
	a, b: Ui_Runtime
	ui_runtime_init(&a)
	ui_runtime_init(&b)
	spell_ignore_session_with(&a.spell, "ingotword")
	spell_ignore_session_with(&a.spell, "ingotword")
	testing.expect(t, "ingotword" in a.spell.ignored)
	testing.expect(t, "ingotword" not_in b.spell.ignored)
	testing.expect_value(t, a.spell.generation, u64(1))
	testing.expect_value(t, b.spell.generation, u64(0))
	ui_runtime_destroy(&a)
	testing.expect_value(t, b.spell.generation, u64(0))
	ui_runtime_destroy(&b)
}

@(test)
test_explicit_frame_resources_follow_own_runtime :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 2)
	custom := theme_light()
	ui_runtime_set_theme(&runtime, custom)

	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	testing.expect(t, ui_frame_text(&frame) == &runtime.text)
	testing.expect_value(t, ui_frame_sc(&frame, 7), 14)
	testing.expect_value(
		t,
		ui_frame_metrics(&frame).FONT_SIZE_BODY,
		runtime.metrics.FONT_SIZE_BODY,
	)
	testing.expect_value(t, ui_frame_theme(&frame).bg_color, custom.bg_color)
	ui_frame_end(&frame)
}

@(test)
test_focus_state_survives_insert_and_reorder :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	a, b, inserted := widget_id(u64(11)), widget_id(u64(22)), widget_id(u64(33))
	begin(&u, &frame, {0, 0, 100, 100})
	focus(&u, a)
	focus_opt_set(focus(&u, b))
	end(&u)

	begin(&u, &frame, {0, 0, 100, 100})
	focus(&u, inserted)
	focus(&u, b)
	focus(&u, a)
	end(&u)
	testing.expect_value(t, u.focus_state.active, focus_widget_id(b))
	testing.expect_value(t, u.focus_count, 3)
}

@(test)
test_focus_state_clears_missing_target :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	a, b := widget_id(u64(1)), widget_id(u64(2))
	begin(&u, &frame, {0, 0, 100, 100})
	focus(&u, a)
	focus_opt_set(focus(&u, b))
	end(&u)
	begin(&u, &frame, {0, 0, 100, 100})
	focus(&u, a)
	end(&u)
	testing.expect_value(t, u.focus_state.active, FOCUS_ID_NONE)
}

@(test)
test_focus_state_clears_when_frame_has_no_focusables :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	a := widget_id(u64(7))
	begin(&u, &frame, {0, 0, 100, 100})
	focus_opt_set(focus(&u, a))
	end(&u)
	begin(&u, &frame, {0, 0, 100, 100})
	end(&u)
	testing.expect_value(t, u.focus_state.active, FOCUS_ID_NONE)
	testing.expect_value(t, u.focus_count, 0)
}

@(test)
test_focus_order_wraps_and_recovers :: proc(t: ^testing.T) {
	ids := [?]Focus_Id{focus_id(4), focus_id(8), focus_id(12)}
	testing.expect_value(t, focus_order_next(ids[:], FOCUS_ID_NONE, false), ids[0])
	testing.expect_value(t, focus_order_next(ids[:], FOCUS_ID_NONE, true), ids[2])
	testing.expect_value(t, focus_order_next(ids[:], ids[2], false), ids[0])
	testing.expect_value(t, focus_order_next(ids[:], ids[0], true), ids[2])
}

@(test)
test_root_can_disable_tab_navigation :: proc(t: ^testing.T) {
	input: Ui_Input
	input.keys_pressed[input_key_index(.TAB)] = true
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	u: Ui
	button := widget_id(u64(7))
	begin(&u, &frame, {0, 0, 100, 100})
	focus(&u, button)
	end(&u)
	begin(&u, &frame, {0, 0, 100, 100}, tab_navigation = false)
	focus(&u, button)
	end(&u)
	testing.expect_value(t, u.focus_state.active, FOCUS_ID_NONE)
}

@(test)
test_slot_next_row_cross_trim :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {10, 10, 300, 200}, gap = .XS)
	row_begin(&u, 40, gap = .SM)
	r1 := slot_next(&u, 100, 30)
	testing.expect_value(t, r1, Rect_I32{10, 10, 100, 30})
	r2 := slot_next(&u, 100, 40)
	testing.expect_value(t, r2, Rect_I32{118, 10, 100, 40})
	row_end(&u)
	// Root gap applies after the row strip.
	r3 := slot_next(&u, 50, 20)
	testing.expect_value(t, r3, Rect_I32{10, 54, 50, 20})
	end(&u)
}

@(test)
test_space_advances_cursor :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {0, 0, 100, 100})
	space(&u, .XL)
	r := slot_next(&u, 100, 10)
	testing.expect_value(t, r, Rect_I32{0, 24, 100, 10})
	end(&u)
}

@(test)
test_flex_slots_preserve_cross_trim :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {10, 20, 300, 100})
	flex_row_begin(&u, 40, {fixed(80), grow()}, gap = .MD, align = .Start)
	a := flex_slot_next(&u, 20)
	b := flex_slot_next(&u, 30)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, a, Rect_I32{10, 20, 80, 20})
	testing.expect_value(t, b, Rect_I32{102, 20, 208, 30})
}

@(test)
test_row_cross_alignment_applies_to_slots :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {10, 20, 300, 100})
	row_begin(&u, 40, align = .Center)
	a := slot_next(&u, 80, 20)
	row_end(&u)
	end(&u)
	testing.expect_value(t, a, Rect_I32{10, 30, 80, 20})
}

@(test)
test_zero_sized_slot_is_not_visible :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	facade_frame(&runtime, &frame)
	defer facade_frame_end(&runtime, &frame)
	u: Ui
	begin(&u, &frame, {0, 0, 0, 0})
	r := slot_next(&u, 100, 20)
	end(&u)
	testing.expect(t, !slot_visible(r))
	testing.expect_value(t, r, Rect_I32{})
}
