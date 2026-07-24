#+build !js
package ui

import "core:testing"
import "core:unicode/utf8"

@(test)
test_ui_slot_column_and_row :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 200, 100)
	r1 := ui_slot(&u, 50, 20)
	testing.expect_value(t, r1, Rect_I32{0, 0, 50, 20})
	ui_row(&u, 30)
	r2 := ui_slot(&u, 40, 30)
	testing.expect_value(t, r2, Rect_I32{0, 20, 40, 30})
	ui_row_end(&u)
	ui_end(&u)
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
	ui_begin_frame(&u1, &frame_a, 0, 0, 100, 100)
	ui_begin_frame(&u2, &frame_a, 0, 0, 100, 100)
	testing.expect_value(t, frame_a.open_roots, 2)
	testing.expect_value(t, frame_b.open_roots, 0)
	ui_end(&u2)
	ui_end(&u1)
	ui_frame_end(&frame_a)
	ui_frame_end(&frame_b)
	testing.expect(t, u1.frame == nil && u2.frame == nil)
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
	testing.expect_value(t, ui_frame_theme(&frame_b).bg_app, THEME_DARK.bg_app)
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
	testing.expect(t, "ingotword" in a.spell.ignored)
	testing.expect(t, "ingotword" not_in b.spell.ignored)
	testing.expect_value(t, a.spell.generation, u64(1))
	testing.expect_value(t, b.spell.generation, u64(0))
	ui_runtime_destroy(&a)
	testing.expect_value(t, b.spell.generation, u64(0))
	ui_runtime_destroy(&b)
}

@(test)
test_ui_focus_ids_sequential_and_counted :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 100, 100)
	f1 := ui_focus(&u)
	f2 := ui_focus(&u)
	testing.expect_value(t, f1.id, 1)
	testing.expect_value(t, f2.id, 2)
	testing.expect(t, f1.focus == &u.focus_slot)
	ui_end(&u)
	testing.expect_value(t, u.focus_count, 2)
	// Next frame resets the sequence and latches the new count.
	ui_begin(&u, 0, 0, 100, 100)
	testing.expect_value(t, ui_focus(&u).id, 1)
	ui_end(&u)
	testing.expect_value(t, u.focus_count, 1)
}

@(test)
test_ui_stable_focus_survives_insert_and_reorder :: proc(t: ^testing.T) {
	u: Ui
	a, b, inserted := focus_id(11), focus_id(22), focus_id(33)
	ui_begin(&u, 0, 0, 100, 100)
	ui_focus(&u, a)
	focus_opt_set(ui_focus(&u, b))
	ui_end(&u)

	ui_begin(&u, 0, 0, 100, 100)
	ui_focus(&u, inserted)
	ui_focus(&u, b)
	ui_focus(&u, a)
	ui_end(&u)
	testing.expect_value(t, u.stable_focus.active, b)
	testing.expect_value(t, u.stable_count, 3)
}

@(test)
test_ui_stable_focus_clears_missing_target :: proc(t: ^testing.T) {
	u: Ui
	a, b := focus_id(1), focus_id(2)
	ui_begin(&u, 0, 0, 100, 100)
	ui_focus(&u, a)
	focus_opt_set(ui_focus(&u, b))
	ui_end(&u)
	ui_begin(&u, 0, 0, 100, 100)
	ui_focus(&u, a)
	ui_end(&u)
	testing.expect_value(t, u.stable_focus.active, FOCUS_ID_NONE)
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
test_ui_slot_row_cross_trim :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 10, 10, 300, 200, gap = 4)
	ui_row(&u, 40, gap = 8)
	r1 := ui_slot(&u, 100, 30)
	testing.expect_value(t, r1, Rect_I32{10, 10, 100, 30})
	r2 := ui_slot(&u, 100, 40)
	testing.expect_value(t, r2, Rect_I32{118, 10, 100, 40})
	ui_row_end(&u)
	// Root gap applies after the row strip.
	r3 := ui_slot(&u, 50, 20)
	testing.expect_value(t, r3, Rect_I32{10, 54, 50, 20})
	ui_end(&u)
}

@(test)
test_ui_space_advances_cursor :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 100, 100)
	ui_space(&u, 25)
	r := ui_slot(&u, 100, 10)
	testing.expect_value(t, r, Rect_I32{0, 25, 100, 10})
	ui_end(&u)
}

@(test)
test_ui_flex_slots_preserve_cross_trim :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 10, 20, 300, 100)
	ui_row(&u, 40, gap = 10)
	ui_flex_begin(&u, {flex_fixed(80), flex_grow()})
	a := ui_flex_slot(&u, 20)
	b := ui_flex_slot(&u, 30)
	ui_row_end(&u)
	ui_end(&u)
	testing.expect_value(t, a, Rect_I32{10, 20, 80, 20})
	testing.expect_value(t, b, Rect_I32{100, 20, 210, 30})
}
