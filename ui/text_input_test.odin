#+build !js
package ui

// Headless tests for the text_input refactor: per-instance selection, undo,
// pill maintenance, masking, and the per-instance wrapped-lines memo (the
// two-input scenario that the old module-global memo could not serve).

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(private = "file")
TI_CELL :: i32(10)

@(private = "file")
ti_mono :: proc(text: cstring, size: i32) -> i32 {
	return i32(utf8.rune_count(string(text))) * TI_CELL
}

@(test)
sel_set_range_reset :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "hello world")
	sel: Input_Sel
	sel_set(&sel, &sb, 8, 3) // reversed order must normalize
	testing.expect(t, sel.active)
	lo, hi := sel_range(&sel)
	testing.expect_value(t, lo, 3)
	testing.expect_value(t, hi, 8)
	sel_reset(&sel)
	testing.expect(t, !sel.active)
	testing.expect(t, !sel.dragging)
	// Zero-length selection is not active.
	sel_set(&sel, &sb, 4, 4)
	testing.expect(t, !sel.active)
}

@(test)
selection_delete_drops_and_shifts_pills :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "aa @pill bb cc")
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{3, 8}) // "@pill" - intersects deletion
	append(&pills, Mention_Span{12, 14}) // "cc" - after deletion, must shift
	sel: Input_Sel
	sel_set(&sel, &sb, 3, 9) // delete "@pill "
	nc := selection_delete(&sel, &sb, &pills)
	testing.expect_value(t, nc, 3)
	testing.expect_value(t, strings.to_string(sb), "aa bb cc")
	testing.expect_value(t, len(pills), 1)
	testing.expect_value(t, pills[0], Mention_Span{6, 8})
	testing.expect(t, !sel.active)
}

@(test)
pill_delete_atomic_removes_range :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "see @a.txt now")
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{4, 10})
	nc := pill_delete_atomic(&sb, &pills, 0)
	testing.expect_value(t, nc, 4)
	testing.expect_value(t, strings.to_string(sb), "see  now")
	testing.expect_value(t, len(pills), 0)
}

@(test)
pills_drop_invalid_filters_out_of_bounds :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{0, 4}) // valid for blen 10
	append(&pills, Mention_Span{8, 14}) // end past blen - dropped
	append(&pills, Mention_Span{5, 5}) // empty - dropped
	append(&pills, Mention_Span{-2, 3}) // negative start - dropped
	pills_drop_invalid(&pills, 10)
	testing.expect_value(t, len(pills), 1)
	testing.expect_value(t, pills[0], Mention_Span{0, 4})
}

@(test)
masked_display_star_per_rune :: proc(t: ^testing.T) {
	testing.expect_value(t, masked_display(""), "")
	testing.expect_value(t, masked_display("abc"), "***")
	// Multi-byte runes still produce exactly one star each.
	testing.expect_value(t, masked_display("héllo"), "*****")
}

@(test)
undo_record_and_apply_roundtrip :: proc(t: ^testing.T) {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "first")
	cursor := 5
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	u: Input_Undo
	defer input_undo_destroy(&u)
	sel: Input_Sel

	// Snapshot, then mutate, then undo back.
	input_undo_record(&u, strings.to_string(sb), cursor, pills[:], .Other, 0.0)
	strings.builder_reset(&sb)
	strings.write_string(&sb, "second")
	cursor = 6
	undo_apply(&sel, &u, &sb, &cursor, &pills, redo = false)
	testing.expect_value(t, strings.to_string(sb), "first")
	testing.expect_value(t, cursor, 5)
	// Redo restores the mutated state.
	undo_apply(&sel, &u, &sb, &cursor, &pills, redo = true)
	testing.expect_value(t, strings.to_string(sb), "second")
	testing.expect_value(t, cursor, 6)
}

@(test)
undo_coalesces_same_kind_edits :: proc(t: ^testing.T) {
	u: Input_Undo
	defer input_undo_destroy(&u)
	input_undo_record(&u, "a", 1, nil, .Insert, 0.0)
	// Same kind inside the coalesce window folds into the prior snapshot.
	input_undo_record(&u, "ab", 2, nil, .Insert, 0.2)
	testing.expect_value(t, len(u.undo), 1)
	// A different kind always snapshots.
	input_undo_record(&u, "abc", 3, nil, .Delete, 0.3)
	testing.expect_value(t, len(u.undo), 2)
}

@(test)
mention_send_rewrite_resets_owned_state :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, ti_mono)
	defer text_system_destroy(&system)
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "prefix @men")
	st: Text_Input_State
	defer text_input_state_destroy(&st)
	st.cursor = strings.builder_len(sb)
	input_undo_record(&st.undo, strings.to_string(sb), st.cursor, st.pills[:], .Other, 0)
	_ = input_visual_lines_memo_with(&system, &st.memo, strings.to_string(sb), 200, 16)
	spellcheck_memo_set_key(&st.spell_memo, strings.to_string(sb), st.cursor, &st.pills, 1)

	prefix := strings.clone(strings.to_string(sb)[:7])
	strings.builder_reset(&sb)
	strings.write_string(&sb, prefix)
	delete(prefix)
	path := "alloy/src/ui/mentions.odin"
	strings.write_string(&sb, path)
	strings.write_byte(&sb, ' ')
	append(&st.pills, Mention_Span{7, 7 + len(path)})
	st.cursor = strings.builder_len(sb)
	encoded := encode_pills(strings.to_string(sb), st.pills[:])
	owned_message := strings.clone(encoded)
	defer delete(owned_message)
	strings.builder_reset(&sb)
	clear(&st.pills)
	input_undo_reset(&st.undo)
	st.cursor = 0
	_ = input_visual_lines_memo_with(&system, &st.memo, "", 200, 16)
	spellcheck_memo_set_key(&st.spell_memo, "", 0, &st.pills, 1)

	testing.expect_value(t, strings.to_string(sb), "")
	testing.expect_value(
		t,
		strip_pill_markers(owned_message),
		"prefix alloy/src/ui/mentions.odin ",
	)
}

@(test)
vlines_memo_two_instances_and_invalidation :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, ti_mono)
	defer text_system_destroy(&system)
	memo_a: Input_Vlines_Memo
	memo_b: Input_Vlines_Memo
	defer input_vlines_memo_destroy(&memo_a)
	defer input_vlines_memo_destroy(&memo_b)

	text_a := "aaa bbb ccc"
	text_b := "xx yy"
	w := 5 * TI_CELL
	la1 := input_visual_lines_memo_with(&system, &memo_a, text_a, w, 16)
	lb1 := input_visual_lines_memo_with(&system, &memo_b, text_b, w, 16)
	// Interleaved second lookups must hit each instance's own cache: same
	// backing slice pointer, no recompute (the old single-slot memo thrashed).
	la2 := input_visual_lines_memo_with(&system, &memo_a, text_a, w, 16)
	lb2 := input_visual_lines_memo_with(&system, &memo_b, text_b, w, 16)
	testing.expect(t, raw_data(la1) == raw_data(la2))
	testing.expect(t, raw_data(lb1) == raw_data(lb2))
	testing.expect(t, len(la1) > 1)
	testing.expect(t, len(lb1) >= 1)

	// Font size is part of the key, so scale changes cannot reuse stale lines.
	la3 := input_visual_lines_memo_with(&system, &memo_a, text_a, w, 16 + 1)
	testing.expect_value(t, memo_a.font_size, 16 + 1)
	testing.expect_value(t, len(la3), len(la1))
}

@(test)
text_input_states_keep_selection_memos_and_menus_isolated :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, ti_mono)
	defer text_system_destroy(&system)
	builder_a := strings.builder_make(context.temp_allocator)
	builder_b := strings.builder_make(context.temp_allocator)
	strings.write_string(&builder_a, "alpha beta")
	strings.write_string(&builder_b, "gamma delta")
	state_a, state_b: Text_Input_State
	defer text_input_state_destroy(&state_a)
	defer text_input_state_destroy(&state_b)
	text_input_selection_set(&state_a, &builder_a, 1, 5)
	text_input_selection_set(&state_b, &builder_b, 2, 7)
	_ = input_visual_lines_memo_with(&system, &state_a.memo, strings.to_string(builder_a), 40, 16)
	_ = input_visual_lines_memo_with(&system, &state_b.memo, strings.to_string(builder_b), 80, 16)
	state_a.spell_memo.valid = true
	state_b.spell_memo.valid = false
	state_a.spell_menu.open = true
	state_a.spell_menu.sb = &builder_a
	a_lo, a_hi := text_input_selection_range(&state_a)
	b_lo, b_hi := text_input_selection_range(&state_b)
	testing.expect_value(t, a_lo, 1)
	testing.expect_value(t, a_hi, 5)
	testing.expect_value(t, b_lo, 2)
	testing.expect_value(t, b_hi, 7)
	testing.expect_value(t, state_a.memo.width, i32(40))
	testing.expect_value(t, state_b.memo.width, i32(80))
	testing.expect(t, state_a.spell_memo.valid && !state_b.spell_memo.valid)
	testing.expect(t, text_input_spell_menu_active(&state_a, &builder_a))
	testing.expect(t, !text_input_spell_menu_active(&state_b, &builder_b))
}

@(test)
text_input_state_destroy_clears :: proc(t: ^testing.T) {
	st: Text_Input_State
	append(&st.pills, Mention_Span{0, 3})
	input_undo_record(&st.undo, "x", 1, st.pills[:], .Insert, 0.0)
	st.cursor = 1
	st.sel.active = true
	text_input_state_destroy(&st)
	testing.expect_value(t, st.cursor, 0)
	testing.expect_value(t, len(st.pills), 0)
	testing.expect_value(t, len(st.undo.undo), 0)
	testing.expect(t, !st.sel.active)
}
