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

// --- Enter semantics by box height ------------------------------------------
//
// A box the caller sized for several lines is a text area, and a text area
// that swallows Enter reads as broken input. These pin the rule that height
// alone decides: one visible line submits, two or more type a newline. Both
// halves of the contract are checked every time - the buffer the user sees
// and the submitted flag the caller branches on - because a box that both
// typed a newline and reported a submit would look right and act wrong.
//
// ti_key_frame drives one real frame through text_input_at rather than
// calling the edit helpers directly, so the keyboard pipeline, the masked
// renderer and the caret model are all on the path a user's keystroke takes.

@(private = "file")
Ti_Key_Frame :: struct {
	text:    string, // initial buffer contents
	cursor:  int, // -1 places the caret at the end
	key:     KeyboardKey,
	shift:   bool,
	masked:  bool,
	height:  i32,
	repeat:  bool, // send the auto-repeat edge instead of the initial press
	presses: int, // how many frames to run; zero means one
}

@(private = "file")
Ti_Key_Result :: struct {
	text:      string,
	cursor:    int,
	submitted: bool,
}

@(private = "file")
ti_key_frame :: proc(config: Ti_Key_Frame) -> Ti_Key_Result {
	assert(config.height > 0, "ti_key_frame: non-positive height")
	assert(config.presses >= 0, "ti_key_frame: negative press count")
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	defer ui_frame_destroy(frame)
	frame.output = output

	input: Ui_Input
	input.screen_size = {800, 600}
	index := input_key_index(config.key)
	assert(index >= 0, "ti_key_frame: unknown key")
	if config.repeat {
		input.keys_repeat[index] = true
	} else {
		input.keys_pressed[index] = true
	}
	if config.shift do input.keys_down[input_key_index(.LEFT_SHIFT)] = true

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, config.text)
	box.st.cursor = len(config.text) if config.cursor < 0 else config.cursor

	submitted := false
	frames := max(config.presses, 1)
	for _ in 0 ..< frames {
		ui_frame_begin(frame, runtime, &input)
		if text_input_at(
			frame,
			{0, 0, 300, config.height},
			&box,
			"field",
			true,
			masked = config.masked,
			semantics = {name = "N"},
		) {
			submitted = true
		}
		ui_frame_end(frame)
	}
	return {
		strings.clone(strings.to_string(box.sb), context.temp_allocator),
		box.st.cursor,
		submitted,
	}
}

@(private = "file")
Ti_Enter_Result :: struct {
	text:      string,
	submitted: bool,
}

@(private = "file")
ti_enter_frame :: proc(height: i32, shift: bool) -> Ti_Enter_Result {
	result := ti_key_frame(
		{text = "ab", cursor = -1, key = .ENTER, shift = shift, height = height},
	)
	return {result.text, result.submitted}
}

@(test)
text_input_enter_types_newline_in_a_text_area :: proc(t: ^testing.T) {
	result := ti_enter_frame(90, false)
	testing.expect_value(t, result.text, "ab\n")
	testing.expect(t, !result.submitted, "a text area must not submit on Enter")
}

@(test)
text_input_enter_submits_a_single_line_field :: proc(t: ^testing.T) {
	result := ti_enter_frame(30, false)
	testing.expect_value(t, result.text, "ab")
	testing.expect(t, result.submitted, "a one-line field must submit on Enter")
}

@(test)
text_input_shift_enter_still_types_a_newline_in_a_field :: proc(t: ^testing.T) {
	result := ti_enter_frame(30, true)
	testing.expect_value(t, result.text, "ab\n")
	testing.expect(t, !result.submitted, "Shift+Enter must not also submit")
}

@(test)
text_input_visible_lines_matches_the_rendered_band :: proc(t: ^testing.T) {
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	frame := new(Ui_Frame)
	defer free(frame)
	defer ui_frame_destroy(frame)
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(frame, runtime)
	defer ui_frame_end(frame)

	metrics := ui_frame_metrics(frame)
	pad := ui_frame_sc(frame, 12)
	testing.expect_value(t, text_input_visible_lines(frame, 1), i32(1))
	testing.expect_value(t, text_input_visible_lines(frame, pad + metrics.LINE_HEIGHT), i32(1))
	testing.expect_value(t, text_input_visible_lines(frame, pad + metrics.LINE_HEIGHT * 3), i32(3))
	testing.expect_value(
		t,
		text_input_default_submit(frame, pad + metrics.LINE_HEIGHT),
		Text_Input_Submit.Enter,
	)
	testing.expect_value(
		t,
		text_input_default_submit(frame, pad + metrics.LINE_HEIGHT * 2),
		Text_Input_Submit.Never,
	)
}

// --- Backspace and forward delete -------------------------------------------
//
// Every field shape must delete, including the masked one: a password box the
// user cannot correct a typo in is unusable, and masking is a render-time
// concern that must not reach the edit path. These run through the same
// keyboard pipeline a real keystroke takes, so the web regression that dropped
// every BACKSPACE edge would fail here rather than only in a browser.

@(test)
text_input_backspace_deletes_the_previous_rune :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = -1, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "ab")
	testing.expect_value(t, result.cursor, 2)
}

@(test)
text_input_backspace_deletes_in_a_masked_field :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "secret", cursor = -1, key = .BACKSPACE, masked = true, height = 30},
	)
	testing.expect_value(t, result.text, "secre")
	testing.expect_value(t, result.cursor, 5)
}

@(test)
text_input_backspace_deletes_in_a_text_area :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "line", cursor = -1, key = .BACKSPACE, height = 90})
	testing.expect_value(t, result.text, "lin")
	testing.expect_value(t, result.cursor, 3)
}

// A multi-byte rune must leave on one keystroke, not one byte at a time.
@(test)
text_input_backspace_removes_a_whole_rune :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "h\u00e9", cursor = -1, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "h")
	testing.expect_value(t, result.cursor, 1)
}

@(test)
text_input_backspace_masked_removes_a_whole_rune :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "p\u00e4ss", cursor = -1, key = .BACKSPACE, masked = true, height = 30},
	)
	testing.expect_value(t, result.text, "p\u00e4s")
	testing.expect_value(t, result.cursor, 4)
}

// Auto-repeat is a separate platform edge from the initial press; a field that
// reads only one of them either drops the first tap or never repeats.
@(test)
text_input_backspace_honours_auto_repeat :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "abcd", cursor = -1, key = .BACKSPACE, repeat = true, height = 30},
	)
	testing.expect_value(t, result.text, "abc")
}

@(test)
text_input_backspace_repeats_across_frames :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "abcd", cursor = -1, key = .BACKSPACE, height = 30, presses = 3},
	)
	testing.expect_value(t, result.text, "a")
	testing.expect_value(t, result.cursor, 1)
}

// Negative space: nothing before the caret means nothing to delete, and an
// empty buffer must not underflow.
@(test)
text_input_backspace_at_the_start_is_a_no_op :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 0, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.cursor, 0)
}

@(test)
text_input_backspace_on_an_empty_field_is_a_no_op :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "", cursor = 0, key = .BACKSPACE, masked = true, height = 30})
	testing.expect_value(t, result.text, "")
	testing.expect_value(t, result.cursor, 0)
}

@(test)
text_input_forward_delete_removes_the_next_rune :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 1, key = .DELETE, height = 30})
	testing.expect_value(t, result.text, "ac")
	testing.expect_value(t, result.cursor, 1)
}

@(test)
text_input_forward_delete_removes_in_a_masked_field :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 0, key = .DELETE, masked = true, height = 30})
	testing.expect_value(t, result.text, "bc")
	testing.expect_value(t, result.cursor, 0)
}

@(test)
text_input_forward_delete_at_the_end_is_a_no_op :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = -1, key = .DELETE, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.cursor, 3)
}

// A caret mid-string must delete at the caret, not at the end - the bug an
// end-anchored fallback would hide.
@(test)
text_input_backspace_deletes_at_the_caret_not_the_end :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abcd", cursor = 2, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "acd")
	testing.expect_value(t, result.cursor, 1)
}

// --- IME proxy arming --------------------------------------------------------
//
// On web the caret rect is what focuses the hidden textarea that carries
// keystrokes and composition into the engine; when no field arms it,
// input_poll deactivates platform text input and focus returns to the canvas.
// Masking is a render-time concern, so a password field must arm it exactly
// like a plain one - otherwise the proxy never takes focus and the field is
// dead to the keyboard on the browser target.

@(private = "file")
ti_text_input_active :: proc(masked: bool, active: bool) -> bool {
	runtime := new(Ui_Runtime)
	defer free(runtime)
	ui_runtime_init(runtime)
	defer ui_runtime_destroy(runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	frame := new(Ui_Frame)
	defer free(frame)
	defer ui_frame_destroy(frame)
	frame.output = output

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, "abc")
	box.st.cursor = 3

	ui_frame_begin(frame, runtime)
	_ = text_input_at(
		frame,
		{0, 0, 300, 30},
		&box,
		"field",
		active,
		masked = masked,
		semantics = {name = "N"},
	)
	armed := frame.output.platform.text_input_active
	ui_frame_end(frame)
	return armed
}

@(test)
text_input_active_field_arms_the_caret_rect :: proc(t: ^testing.T) {
	testing.expect(t, ti_text_input_active(false, true), "a plain field must arm the IME proxy")
}

@(test)
text_input_masked_field_arms_the_caret_rect :: proc(t: ^testing.T) {
	testing.expect(t, ti_text_input_active(true, true), "a password field must arm the IME proxy")
}

@(test)
text_input_inactive_field_leaves_the_caret_rect_alone :: proc(t: ^testing.T) {
	testing.expect(t, !ti_text_input_active(false, false), "an unfocused field must not arm it")
	testing.expect(t, !ti_text_input_active(true, false), "an unfocused field must not arm it")
}
