#+build !js
package ui

// Headless tests for the text_input refactor: per-instance selection, undo,
// pill maintenance, masking, and the per-instance wrapped-lines memo (the
// two-input scenario that the old module-global memo could not serve).

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "ingot:testx"

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
	sel_set(&sel, &sb, -10, 100)
	lo, hi = sel_range(&sel)
	testing.expect_value(t, lo, 0)
	testing.expect_value(t, hi, len("hello world"))
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
TI_Key_Frame :: struct {
	text:    string, // initial buffer contents
	cursor:  int, // -1 places the caret at the end
	key:     KeyboardKey,
	shift:   bool,
	alt:     bool, // Alt/Option held (word variants)
	cmd:     bool, // Cmd/Ctrl held (line variants)
	masked:  bool,
	height:  i32,
	width:   i32, // zero uses 300
	pill:    Mention_Span, // zero = no pill
	repeat:  bool, // send the auto-repeat edge instead of the initial press
	presses: int, // how many frames to run; zero means one
}

@(private = "file")
Ti_Key_Result :: struct {
	text:      string,
	cursor:    int,
	submitted: bool,
	undo_len:  int,
	pill_len:  int,
}

@(private = "file")
ti_key_frame :: proc(config: TI_Key_Frame) -> Ti_Key_Result {
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
	if config.alt do input.keys_down[input_key_index(.LEFT_ALT)] = true
	if config.cmd do input.keys_down[input_key_index(.LEFT_CONTROL)] = true

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, config.text)
	box.st.cursor = len(config.text) if config.cursor < 0 else config.cursor
	if config.pill.end > config.pill.start do append(&box.st.pills, config.pill)

	width := config.width if config.width > 0 else 300
	submitted := false
	frames := max(config.presses, 1)
	for _ in 0 ..< frames {
		ui_frame_begin(frame, runtime, &input)
		if text_input_at(
			frame,
			{0, 0, width, config.height},
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
		len(box.st.undo.undo),
		len(box.st.pills),
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

// A ZWJ emoji sequence is one user-perceived character: a single backspace
// must remove the whole 18-byte family, not one codepoint of it.
@(test)
text_input_backspace_removes_a_whole_emoji_cluster :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "a👩‍👩‍👦", cursor = -1, key = .BACKSPACE, height = 30},
	)
	testing.expect_value(t, result.text, "a")
	testing.expect_value(t, result.cursor, 1)
}

@(test)
text_input_forward_delete_removes_a_combining_pair :: proc(t: ^testing.T) {
	// "e" + U+0301 (combining acute) + "x": forward delete at 0 removes the
	// full 3-byte cluster in one keystroke.
	result := ti_key_frame({text = "e\u0301x", cursor = 0, key = .DELETE, height = 30})
	testing.expect_value(t, result.text, "x")
	testing.expect_value(t, result.cursor, 0)
}

@(test)
text_input_arrows_step_over_grapheme_clusters :: proc(t: ^testing.T) {
	right := ti_key_frame({text = "e\u0301x", cursor = 0, key = .RIGHT, height = 30})
	testing.expect_value(t, right.cursor, 3)
	left := ti_key_frame({text = "a👩‍👩‍👦", cursor = -1, key = .LEFT, height = 30})
	testing.expect_value(t, left.cursor, 1)
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

// --- Undo snapshot hygiene ---------------------------------------------------
//
// A snapshot for an edit that changed nothing makes one Cmd+Z appear dead,
// and a coalesce window that slides with every keystroke folds minutes of
// typing into a single undo step. Both are pinned here.

@(test)
undo_coalesce_window_is_anchored_at_the_group_start :: proc(t: ^testing.T) {
	u: Input_Undo
	defer input_undo_destroy(&u)
	// Keystrokes 0.9s apart: a sliding window would coalesce them forever.
	input_undo_record(&u, "a", 1, nil, .Insert, 0.0)
	input_undo_record(&u, "ab", 2, nil, .Insert, 0.9)
	testing.expect_value(t, len(u.undo), 1)
	input_undo_record(&u, "abc", 3, nil, .Insert, 1.8)
	testing.expect_value(t, len(u.undo), 2)
}

@(test)
text_input_noop_backspace_records_no_undo_snapshot :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 0, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.undo_len, 0)
}

@(test)
text_input_noop_forward_delete_records_no_undo_snapshot :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = -1, key = .DELETE, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.undo_len, 0)
}

@(test)
text_input_real_delete_records_one_undo_snapshot :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = -1, key = .BACKSPACE, height = 30})
	testing.expect_value(t, result.text, "ab")
	testing.expect_value(t, result.undo_len, 1)
}

// --- Clipboard: copy / cut / paste -------------------------------------------
//
// ti_clip_frame drives one real frame with a clipboard modifier held, so the
// copy, cut, and paste tests run the exact keyboard pipeline a user's
// shortcut takes. Clipboard output is read before ui_frame_end, matching how
// the platform layer consumes it.

@(private = "file")
TI_Clip_Frame :: struct {
	text:      string, // initial buffer contents (caret parks at the end)
	sel_lo:    int,
	sel_hi:    int, // sel_hi > sel_lo pre-selects that range
	key:       KeyboardKey,
	masked:    bool,
	clipboard: string, // pre-loaded clipboard (for paste)
	max_bytes: int, // zero uses the default cap
	height:    i32,
}

@(private = "file")
Ti_Clip_Result :: struct {
	text:            string,
	clipboard_write: bool,
	clipboard_text:  string,
}

@(private = "file")
ti_clip_frame :: proc(config: TI_Clip_Frame) -> Ti_Clip_Result {
	assert(config.height > 0, "ti_clip_frame: non-positive height")
	assert(config.sel_lo <= config.sel_hi, "ti_clip_frame: inverted selection")
	assert(len(config.clipboard) <= INPUT_CLIPBOARD_CAP, "ti_clip_frame: clipboard over cap")
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
	input.keys_down[input_key_index(.LEFT_CONTROL)] = true
	input.keys_pressed[input_key_index(config.key)] = true
	input.clipboard = config.clipboard

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, config.text)
	st: Text_Input_State
	defer text_input_state_destroy(&st)
	st.cursor = len(config.text)
	if config.sel_hi > config.sel_lo {
		text_input_selection_set(&st, &sb, config.sel_lo, config.sel_hi)
	}

	cfg := Text_Input_Config {
		rect = {0, 0, 300, config.height},
		placeholder = "field",
		active = true,
		masked = config.masked,
		enable_undo = true,
		max_bytes = config.max_bytes,
		submit = .Never,
		semantics = {name = "N"},
	}
	ui_frame_begin(frame, runtime, &input)
	_ = text_input_box(frame, cfg, &sb, &st)
	result := Ti_Clip_Result {
		text            = strings.clone(strings.to_string(sb), context.temp_allocator),
		clipboard_write = frame.output.platform.clipboard_write,
	}
	if result.clipboard_write {
		plat := &frame.output.platform
		result.clipboard_text = strings.clone(
			string(plat.clipboard_text[:plat.clipboard_text_len]),
			context.temp_allocator,
		)
	}
	ui_frame_end(frame)
	return result
}

@(test)
text_input_copy_on_masked_field_leaves_clipboard_alone :: proc(t: ^testing.T) {
	result := ti_clip_frame(
		{text = "secret", sel_lo = 0, sel_hi = 6, key = .C, masked = true, height = 30},
	)
	testing.expect(t, !result.clipboard_write, "a password must never reach the clipboard")
	testing.expect_value(t, result.text, "secret")
}

@(test)
text_input_cut_on_masked_field_deletes_without_copying :: proc(t: ^testing.T) {
	result := ti_clip_frame(
		{text = "secret", sel_lo = 0, sel_hi = 6, key = .X, masked = true, height = 30},
	)
	testing.expect(t, !result.clipboard_write, "a password must never reach the clipboard")
	testing.expect_value(t, result.text, "")
}

@(test)
text_input_copy_and_cut_still_work_on_plain_fields :: proc(t: ^testing.T) {
	copied := ti_clip_frame({text = "hello", sel_lo = 0, sel_hi = 5, key = .C, height = 30})
	testing.expect(t, copied.clipboard_write, "copy must reach the clipboard")
	testing.expect_value(t, copied.clipboard_text, "hello")
	testing.expect_value(t, copied.text, "hello")
	cut := ti_clip_frame({text = "hello", sel_lo = 0, sel_hi = 5, key = .X, height = 30})
	testing.expect(t, cut.clipboard_write, "cut must reach the clipboard")
	testing.expect_value(t, cut.clipboard_text, "hello")
	testing.expect_value(t, cut.text, "")
}

@(test)
text_input_paste_over_selection_budgets_after_the_delete :: proc(t: ^testing.T) {
	// The buffer sits at max_bytes; the selection frees exactly the space
	// the paste needs, so the paste must fully replace it.
	result := ti_clip_frame(
		{
			text = "aaaaa",
			sel_lo = 0,
			sel_hi = 5,
			key = .V,
			clipboard = "bbbbb",
			max_bytes = 5,
			height = 30,
		},
	)
	testing.expect_value(t, result.text, "bbbbb")
}

@(test)
text_input_paste_strips_carriage_returns :: proc(t: ^testing.T) {
	result := ti_clip_frame({text = "", key = .V, clipboard = "a\r\nb\r", height = 90})
	testing.expect_value(t, result.text, "a\nb")
}

@(test)
text_input_paste_accepts_more_than_legacy_clipboard_cap :: proc(t: ^testing.T) {
	clipboard := strings.repeat("x", 4096 * 3, context.temp_allocator)
	result := ti_clip_frame({key = .V, clipboard = clipboard, height = 90})
	testing.expect_value(t, len(result.text), 4096 * 3)
	testing.expect_value(t, result.text, clipboard)
}

// --- Pixel-to-column and incremental rewrap equivalence ----------------------

// A deterministic variable-width backend: per-rune advances summed over the
// string, so prefix widths are monotonic but not uniform.
@(private = "file")
ti_var_width :: proc(text: cstring, size: i32) -> i32 {
	_ = size
	total: i32 = 0
	for r in string(text) do total += 4 + i32(r) % 7
	return total
}

// The pre-optimization linear scan, kept as the reference oracle for the
// binary-search implementation.
@(private = "file")
ti_pixel_col_linear :: proc(system: ^Text_System, line: string, px, font_size: i32) -> int {
	if px <= 0 do return 0
	col := 0
	i := 0
	for i < len(line) {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		prefix := strings.clone_to_cstring(line[:j], context.temp_allocator)
		width := measure_text_with(system, prefix, font_size)
		if width > px {
			previous := strings.clone_to_cstring(line[:i], context.temp_allocator)
			previous_width := measure_text_with(system, previous, font_size)
			if px - previous_width < width - px do return col
			return col + 1
		}
		col += 1
		i = j
	}
	return col
}

@(test)
caret_pixel_to_col_search_matches_the_linear_scan :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, ti_var_width)
	defer text_system_destroy(&system)
	lines := []string {
		"",
		"a",
		"hello world",
		"h\u00e9llo w\u00f6rld",
		"\u65e5\u672c\u8a9e\u30c6\u30ad\u30b9\u30c8",
		"aaaa bbbb cccc dddd",
	}
	for line in lines {
		line_c := strings.clone_to_cstring(line, context.temp_allocator)
		full := measure_text_with(&system, line_c, 16)
		for px in i32(-2) ..= full + 3 {
			want := ti_pixel_col_linear(&system, line, px, 16)
			got := caret_pixel_to_col_with(&system, line, px, 16)
			testing.expectf(t, want == got, "line=%q px=%d want=%d got=%d", line, px, want, got)
			if want != got do return
		}
		free_all(context.temp_allocator)
	}
}

// Randomized edits against a warm memo must produce exactly the lines a cold
// full rewrap produces - the incremental splice is only a performance path.
@(test)
vlines_incremental_matches_full_rewrap :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, ti_mono)
	defer text_system_destroy(&system)
	warm: Input_Vlines_Memo
	defer input_vlines_memo_destroy(&warm)
	p := testx.prng_make(0x7)
	doc := strings.builder_make()
	defer strings.builder_destroy(&doc)
	strings.write_string(&doc, "alpha beta gamma\ndelta epsilon\n\nzeta eta theta iota")
	w := 6 * TI_CELL
	_ = input_visual_lines_memo_with(&system, &warm, strings.to_string(doc), w, 16)
	runes := []rune{'a', 'b', ' ', '\n', '\u00e9', '\u4e16'}
	for iter in 0 ..< 500 {
		text := strings.to_string(doc)
		pos := caret_clamp(text, testx.int_range(&p, 0, len(text) + 1))
		if testx.int_range(&p, 0, 3) == 0 && len(text) > 0 {
			end := caret_clamp(text, min(len(text), pos + testx.int_range(&p, 1, 8)))
			if end > pos {
				combined := strings.concatenate({text[:pos], text[end:]}, context.temp_allocator)
				strings.builder_reset(&doc)
				strings.write_string(&doc, combined)
			}
		} else {
			ins := strings.builder_make(context.temp_allocator)
			for _ in 0 ..< testx.int_range(&p, 1, 6) {
				strings.write_rune(&ins, runes[testx.int_range(&p, 0, len(runes))])
			}
			combined := strings.concatenate(
				{text[:pos], strings.to_string(ins), text[pos:]},
				context.temp_allocator,
			)
			strings.builder_reset(&doc)
			strings.write_string(&doc, combined)
		}
		cur := strings.to_string(doc)
		spliced := input_visual_lines_memo_with(&system, &warm, cur, w, 16)
		cold: Input_Vlines_Memo
		full := input_visual_lines_memo_with(&system, &cold, cur, w, 16)
		ok := len(spliced) == len(full)
		if ok {
			for vl, i in spliced do ok &&= vl == full[i]
		}
		testing.expectf(
			t,
			ok,
			"seed=0x7 iter=%d spliced=%v full=%v text=%q",
			iter,
			spliced,
			full,
			cur,
		)
		input_vlines_memo_destroy(&cold)
		if !ok do return
		free_all(context.temp_allocator)
	}
}

// --- Word / line delete ------------------------------------------------------
//
// Alt+Backspace is composer muscle memory; a field that only deletes runes
// makes rewriting a sentence painful. Cmd+Backspace (line start) rides the
// same helper.

@(test)
text_input_alt_backspace_deletes_the_previous_word :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "hello world", cursor = -1, key = .BACKSPACE, alt = true, height = 30},
	)
	testing.expect_value(t, result.text, "hello ")
	testing.expect_value(t, result.cursor, 6)
	testing.expect_value(t, result.undo_len, 1)
}

@(test)
text_input_alt_backspace_at_the_start_is_a_no_op :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 0, key = .BACKSPACE, alt = true, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.undo_len, 0)
}

@(test)
text_input_alt_delete_removes_the_next_word :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "hello world", cursor = 5, key = .DELETE, alt = true, height = 30},
	)
	testing.expect_value(t, result.text, "hello")
	testing.expect_value(t, result.cursor, 5)
	testing.expect_value(t, result.undo_len, 1)
}

@(test)
text_input_alt_delete_at_the_end_is_a_no_op :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = -1, key = .DELETE, alt = true, height = 30})
	testing.expect_value(t, result.text, "abc")
	testing.expect_value(t, result.undo_len, 0)
}

@(test)
text_input_cmd_backspace_deletes_to_line_start :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "ab cd\nef gh", cursor = -1, key = .BACKSPACE, cmd = true, height = 90},
	)
	testing.expect_value(t, result.text, "ab cd\n")
	testing.expect_value(t, result.cursor, 6)
}

@(test)
text_input_word_delete_over_a_pill_drops_the_pill :: proc(t: ^testing.T) {
	// "@pill.txt" is one word; deleting the range it occupies must drop the
	// span too, or a stale pill would chip-highlight unrelated text.
	result := ti_key_frame(
		{
			text = "hi @pill.txt",
			cursor = -1,
			key = .BACKSPACE,
			alt = true,
			pill = {3, 12},
			height = 30,
		},
	)
	testing.expect_value(t, result.text, "hi ")
	testing.expect_value(t, result.cursor, 3)
	testing.expect_value(t, result.pill_len, 0)
}

// --- Visual-row vertical navigation ------------------------------------------
//
// The test backend measures 16px per byte and the wrap adds 1px spacing per
// rune, so a 120px box (inner 100px) wraps "aaaa bbbb cccc" into three
// four-char visual rows. Up/Down must move between those rows - jumping the
// whole logical paragraph is the bug these pin down.

@(test)
text_input_down_moves_one_visual_row_in_wrapped_text :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "aaaa bbbb cccc", cursor = 2, key = .DOWN, width = 120, height = 90},
	)
	// Row 1 is "bbbb" at bytes [5,9); x was 2 runes -> column 2.
	testing.expect_value(t, result.cursor, 7)
}

@(test)
text_input_up_moves_one_visual_row_in_wrapped_text :: proc(t: ^testing.T) {
	result := ti_key_frame(
		{text = "aaaa bbbb cccc", cursor = 7, key = .UP, width = 120, height = 90},
	)
	testing.expect_value(t, result.cursor, 2)
}

@(test)
text_input_up_on_the_first_row_moves_to_text_start :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 2, key = .UP, height = 30})
	testing.expect_value(t, result.cursor, 0)
}

@(test)
text_input_down_on_the_last_row_moves_to_text_end :: proc(t: ^testing.T) {
	result := ti_key_frame({text = "abc", cursor = 1, key = .DOWN, height = 30})
	testing.expect_value(t, result.cursor, 3)
}

@(test)
text_input_vertical_nav_preserves_the_column_across_short_lines :: proc(t: ^testing.T) {
	// Down twice from column 3 through a one-char line must land on column 3
	// of the third line, not column 1 - the desired-x memory these pin down.
	result := ti_key_frame(
		{text = "aaaa\nb\ncccc", cursor = 3, key = .DOWN, height = 90, presses = 2},
	)
	testing.expect_value(t, result.cursor, 10)
}

@(test)
text_input_page_up_and_down_move_by_the_visible_page :: proc(t: ^testing.T) {
	// Six visual rows, three visible (h=90): PageUp from row 5 lands row 2.
	text := "aaaa bbbb cccc dddd eeee ffff"
	up := ti_key_frame({text = text, cursor = 25, key = .PAGE_UP, width = 120, height = 90})
	testing.expect_value(t, up.cursor, 10)
	down := ti_key_frame({text = text, cursor = 0, key = .PAGE_DOWN, width = 120, height = 90})
	testing.expect_value(t, down.cursor, 15)
}

// --- Shift+click and drag auto-scroll ----------------------------------------

@(private = "file")
TI_Click_Frame :: struct {
	text:   string,
	cursor: int,
	mouse:  Vec2, // pane-local press position
	shift:  bool,
	height: i32,
	clicks: int, // number of sequential press frames (0 -> 1)
	pill:   Mention_Span, // appended to the box's pills when non-empty
}

@(private = "file")
Ti_Click_Result :: struct {
	cursor:      int,
	sel_lo:      int,
	sel_hi:      int,
	selecting:   bool,
	click_count: int,
}

// ti_click_frame drives one or more real frames, each with a left-button
// press at the same position, so the press/drag pipeline (shift-extend and
// the single/double/triple click machine included) runs exactly as a user's
// clicks do. Frames are 0.1s apart - inside the 0.4s multi-click window.
@(private = "file")
ti_click_frame :: proc(config: TI_Click_Frame) -> Ti_Click_Result {
	assert(config.height > 0, "ti_click_frame: non-positive height")
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
	input.mouse_position = config.mouse
	if config.shift do input.keys_down[input_key_index(.LEFT_SHIFT)] = true

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, config.text)
	box.st.cursor = config.cursor
	if config.pill.end > config.pill.start do append(&box.st.pills, config.pill)

	clicks := max(config.clicks, 1)
	for i in 0 ..< clicks {
		input.time = f64(i) * 0.1
		input.mouse_pressed[input_mouse_index(.LEFT)] = true
		input.mouse_down[input_mouse_index(.LEFT)] = true
		ui_frame_begin(frame, runtime, &input)
		_ = text_input_at(
			frame,
			{0, 0, 300, config.height},
			&box,
			"field",
			true,
			semantics = {name = "N"},
		)
		ui_frame_end(frame)
	}
	lo, hi := text_input_selection_range(&box.st)
	return {box.st.cursor, lo, hi, box.st.sel.active, box.st.sel.click_count}
}

@(test)
text_input_shift_click_extends_from_the_caret :: proc(t: ^testing.T) {
	// inner_x = PADDING (10); 16px per byte puts column 5 at x = 10 + 80.
	result := ti_click_frame(
		{text = "hello world", cursor = 0, mouse = {90, 10}, shift = true, height = 30},
	)
	testing.expect(t, result.selecting, "shift+click must create a selection")
	testing.expect_value(t, result.sel_lo, 0)
	testing.expect_value(t, result.sel_hi, 5)
	testing.expect_value(t, result.cursor, 5)
	// Shift+click must not advance the double/triple-click state machine.
	testing.expect_value(t, result.click_count, 0)
}

@(test)
text_input_plain_click_places_the_caret :: proc(t: ^testing.T) {
	result := ti_click_frame(
		{text = "hello world", cursor = 0, mouse = {90, 10}, shift = false, height = 30},
	)
	testing.expect(t, !result.selecting, "a plain click must not select")
	testing.expect_value(t, result.cursor, 5)
	testing.expect_value(t, result.click_count, 1)
}

@(test)
text_input_double_click_selects_the_whole_word :: proc(t: ^testing.T) {
	// inner_x = PADDING (10); 16px per byte puts byte 2 at x = 10 + 32. The
	// same-frame drag (button still down on the press frame) must not shrink
	// the selection back to the click point.
	result := ti_click_frame(
		{text = "hello world", cursor = 0, mouse = {42, 10}, clicks = 2, height = 30},
	)
	testing.expect(t, result.selecting, "double-click must select the word")
	testing.expect_value(t, result.click_count, 2)
	testing.expect_value(t, result.sel_lo, 0)
	testing.expect_value(t, result.sel_hi, 5)
	testing.expect_value(t, result.cursor, 5)
}

@(test)
text_input_double_click_selects_the_whole_accented_word :: proc(t: ^testing.T) {
	// "héllo" is 6 bytes; a double-click after the 'h' (byte 1, x = 10 + 16)
	// must select the full word - continuation bytes may not stop the scan.
	result := ti_click_frame(
		{text = "héllo wörld", cursor = 0, mouse = {26, 10}, clicks = 2, height = 30},
	)
	testing.expect(t, result.selecting, "double-click must select the accented word")
	testing.expect_value(t, result.sel_lo, 0)
	testing.expect_value(t, result.sel_hi, 6)
	testing.expect_value(t, result.cursor, 6)
}

@(test)
text_input_double_click_selects_the_whole_cjk_word :: proc(t: ^testing.T) {
	// Two clicks at the same spot on 3-byte runes must still group into a
	// double-click (the old 2-byte slop broke near wide-rune boundaries).
	result := ti_click_frame(
		{text = "日本語 テスト", cursor = 0, mouse = {58, 10}, clicks = 2, height = 30},
	)
	testing.expect_value(t, result.click_count, 2)
	testing.expect_value(t, result.sel_lo, 0)
	testing.expect_value(t, result.sel_hi, 9)
}

@(test)
text_input_double_click_never_bisects_a_pill :: proc(t: ^testing.T) {
	// Pill covers "@alice" (bytes 3..9); the word under the click is "alice"
	// (bytes 4..9) and the selection must widen to the full pill.
	result := ti_click_frame(
	{
		text   = "hi @alice yo",
		cursor = 0,
		mouse  = {90, 10}, // byte 5, inside the pill
		clicks = 2,
		pill   = {3, 9},
		height = 30,
	},
	)
	testing.expect(t, result.selecting, "double-click in a pill must select it")
	testing.expect_value(t, result.sel_lo, 3)
	testing.expect_value(t, result.sel_hi, 9)
}

@(test)
click_count_groups_clicks_within_one_rune :: proc(t: ^testing.T) {
	sel: Input_Sel
	cjk := "日本語"
	ti_click_count_update(&sel, cjk, 0, 0.0)
	testing.expect_value(t, sel.click_count, 1)
	// One 3-byte rune of travel is still the same double-click target.
	ti_click_count_update(&sel, cjk, 3, 0.1)
	testing.expect_value(t, sel.click_count, 2)
	// More than one rune of ASCII travel resets the counter.
	sel2: Input_Sel
	ascii := "hello world"
	ti_click_count_update(&sel2, ascii, 2, 0.0)
	ti_click_count_update(&sel2, ascii, 6, 0.1)
	testing.expect_value(t, sel2.click_count, 1)
	// Clicks outside the 0.4s window reset even at the same offset.
	ti_click_count_update(&sel2, ascii, 6, 1.0)
	testing.expect_value(t, sel2.click_count, 1)
}

@(test)
drag_word_sel_keeps_the_anchor_word_selected :: proc(t: ^testing.T) {
	text := "foo bar baz"
	// Dragging right from a double-click on "bar" grows by whole words.
	anchor, extent := ti_drag_word_sel(text, nil, 5, 9)
	testing.expect_value(t, anchor, 4)
	testing.expect_value(t, extent, 11)
	// Dragging left of the anchor word flips direction; "bar" stays covered.
	anchor, extent = ti_drag_word_sel(text, nil, 5, 1)
	testing.expect_value(t, anchor, 7)
	testing.expect_value(t, extent, 0)
	// Dragging inside the anchor word keeps exactly that word.
	anchor, extent = ti_drag_word_sel(text, nil, 5, 6)
	testing.expect_value(t, anchor, 4)
	testing.expect_value(t, extent, 7)
}

@(test)
drag_autoscroll_row_steps_are_rate_limited_and_clamped :: proc(t: ^testing.T) {
	sel: Input_Sel
	// First tick steps one row down.
	row, stepped := ti_drag_autoscroll_row(&sel, 3, 10, false, TI_DRAG_SCROLL_SECS)
	testing.expect(t, stepped)
	testing.expect_value(t, row, 4)
	// A tick inside the window must not step again.
	_, stepped = ti_drag_autoscroll_row(&sel, 4, 10, false, TI_DRAG_SCROLL_SECS * 1.5)
	testing.expect(t, !stepped, "steps inside the rate window must be suppressed")
	// After the window, stepping resumes; upward steps clamp at row zero.
	row, stepped = ti_drag_autoscroll_row(&sel, 0, 10, true, TI_DRAG_SCROLL_SECS * 3)
	testing.expect(t, !stepped, "a clamped step at the top edge is not a step")
	testing.expect_value(t, row, 0)
	row, stepped = ti_drag_autoscroll_row(&sel, 9, 10, false, TI_DRAG_SCROLL_SECS * 4)
	testing.expect(t, !stepped, "a clamped step at the bottom edge is not a step")
	testing.expect_value(t, row, 9)
}

// --- IME preedit --------------------------------------------------------------

@(private = "file")
TI_Preedit_Frame :: struct {
	text:          string,
	cursor:        int,
	preedit:       string,
	preedit_caret: int,
	key:           KeyboardKey, // optional press staged alongside the preedit
	width:         i32, // zero uses 300
	height:        i32,
}

@(private = "file")
Ti_Preedit_Result :: struct {
	text:       string,
	cursor:     int,
	undo_len:   int,
	caret_rect: Rect, // OS candidate-window rect the frame reported
}

// ti_preedit_frame drives one real frame with an IME composition staged in
// the input snapshot, exactly as the platform adapter delivers it.
@(private = "file")
ti_preedit_frame :: proc(config: TI_Preedit_Frame) -> Ti_Preedit_Result {
	assert(config.height > 0, "ti_preedit_frame: non-positive height")
	assert(len(config.preedit) <= INPUT_PREEDIT_CAP, "ti_preedit_frame: preedit too long")
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
	input.preedit_len = len(config.preedit)
	copy(input.preedit[:input.preedit_len], transmute([]u8)config.preedit)
	input.preedit_caret = clamp(config.preedit_caret, 0, input.preedit_len)
	if config.key != .KEY_NULL {
		index := input_key_index(config.key)
		assert(index >= 0, "ti_preedit_frame: unknown key")
		input.keys_pressed[index] = true
	}

	box: Input_Box
	defer input_box_destroy(&box)
	strings.write_string(&box.sb, config.text)
	box.st.cursor = config.cursor

	width := config.width if config.width > 0 else 300
	ui_frame_begin(frame, runtime, &input)
	_ = text_input_at(
		frame,
		{0, 0, width, config.height},
		&box,
		"field",
		true,
		semantics = {name = "N"},
	)
	ui_frame_end(frame)
	return {
		strings.clone(strings.to_string(box.sb), context.temp_allocator),
		box.st.cursor,
		len(box.st.undo.undo),
		output.platform.text_input_rect,
	}
}

@(test)
text_input_preedit_is_display_only :: proc(t: ^testing.T) {
	// Composing must not touch the builder, the cursor, or undo history.
	result := ti_preedit_frame(
		{text = "ab", cursor = 1, preedit = "かな", preedit_caret = 6, height = 30},
	)
	testing.expect_value(t, result.text, "ab")
	testing.expect_value(t, result.cursor, 1)
	testing.expect_value(t, result.undo_len, 0)
}

@(test)
text_input_preedit_caret_tracks_the_composition :: proc(t: ^testing.T) {
	// 16px per byte: caret at cursor 1 + preedit caret 2 renders after the
	// display prefix "axy" at x = inner_x (10) + 48. Without a composition
	// the same field reports x = 10 + 16.
	base := ti_preedit_frame({text = "ab", cursor = 1, height = 30})
	testing.expect_value(t, base.caret_rect.x, f32(26))
	composed := ti_preedit_frame(
		{text = "ab", cursor = 1, preedit = "xy", preedit_caret = 2, height = 30},
	)
	testing.expect_value(t, composed.caret_rect.x, f32(58))
}

@(test)
text_input_preedit_suppresses_the_keyboard :: proc(t: ^testing.T) {
	// The OS input method owns the keys mid-composition: a backspace staged
	// in the same frame must not delete committed text.
	result := ti_preedit_frame(
		{text = "ab", cursor = 2, preedit = "x", preedit_caret = 1, key = .BACKSPACE, height = 30},
	)
	testing.expect_value(t, result.text, "ab")
	testing.expect_value(t, result.cursor, 2)
}

@(test)
text_input_preedit_wraps_onto_the_next_row :: proc(t: ^testing.T) {
	// Inner width 60px fits three 16px runes plus wrap spacing; a four-byte
	// composition pushes the caret onto the second visual row.
	result := ti_preedit_frame(
		{text = "", cursor = 0, preedit = "abcd", preedit_caret = 4, width = 80, height = 90},
	)
	base := ti_preedit_frame({text = "", cursor = 0, width = 80, height = 90})
	testing.expect(
		t,
		result.caret_rect.y > base.caret_rect.y,
		"a wrapped composition must move the caret down a row",
	)
}
