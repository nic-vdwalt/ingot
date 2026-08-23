#+build !js
package ui

// Unit tests for widget helper logic: undo stack limits, truncation helpers,
// word bounds, wheel accumulation, wrapped hit-testing, settings preset
// lookup, and markdown raw/display offset roundtrips.

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(private = "file")
W_CELL :: i32(10)

@(private = "file")
w_mono :: proc(text: cstring, size: i32) -> i32 {
	return i32(utf8.rune_count(string(text))) * W_CELL
}

@(test)
button_spec_and_facade_share_geometry :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 200, 100})
	spec := button_spec(&u, id(&u, "save"), "Save")
	size := button_spec_size(&u, spec)
	before := remaining_rect(&u)
	_ = button(&u, "legacy", "Save")
	after := remaining_rect(&u)
	end(&u)
	testing.expect_value(t, size.w, button_fit_w_frame(&frame, "Save"))
	testing.expect_value(t, after.y - before.y, size.h)
}

@(test)
button_palette_uses_theme_borders_and_interaction_fills :: proc(t: ^testing.T) {
	style := theme_retro_orange()
	p0, p1, _, _, pb0, pb1 := btn_palette(&style, .Primary)
	s0, s1, _, _, sb0, sb1 := btn_palette(&style, .Secondary)
	testing.expect_value(t, p0, style.button_bg)
	testing.expect_value(t, p1, style.button_hover)
	testing.expect_value(t, pb0, style.border_color)
	testing.expect_value(t, pb1, style.fg_accent)
	testing.expect_value(t, s0, style.bg_active)
	testing.expect_value(t, s1, style.bg_hover)
	testing.expect_value(t, sb0, style.border_color)
	testing.expect_value(t, sb1, style.fg_accent)
}

@(test)
input_undo_cap_evicts_oldest :: proc(t: ^testing.T) {
	u: Input_Undo
	defer input_undo_destroy(&u)
	// Force distinct snapshots by alternating kinds outside coalescing.
	for i in 0 ..< INPUT_UNDO_MAX + 5 {
		kind: Input_Edit_Kind = .Insert if i % 2 == 0 else .Delete
		input_undo_record(&u, "text", i, nil, kind, f64(i) * 10)
	}
	testing.expect_value(t, len(u.undo), INPUT_UNDO_MAX)
	// Oldest snapshots were evicted: the first surviving cursor is 5.
	testing.expect_value(t, u.undo[0].cursor, 5)
}

@(test)
input_undo_record_invalidates_redo :: proc(t: ^testing.T) {
	u: Input_Undo
	defer input_undo_destroy(&u)
	append(&u.redo, make_input_snapshot("stale", 0, nil))
	input_undo_record(&u, "a", 1, nil, .Insert, 0)
	testing.expect_value(t, len(u.redo), 0)
}

@(test)
input_undo_reset_handles_empty_snapshots :: proc(t: ^testing.T) {
	u: Input_Undo
	input_undo_record(&u, "", 0, nil, .Other, 0)
	input_undo_reset(&u)
	testing.expect_value(t, len(u.undo), 0)
	input_undo_destroy(&u)
}

@(test)
truncate_helpers_fit_and_cut :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, w_mono)
	defer text_system_destroy(&system)
	// Fits: returned untouched.
	testing.expect_value(
		t,
		truncate_to_width_dir_with(&system, "abc", 10 * W_CELL, 16, .Tail),
		"abc",
	)
	testing.expect_value(
		t,
		truncate_to_width_dir_with(&system, "abc", 10 * W_CELL, 16, .Head),
		"abc",
	)
	// Tail cut keeps a head prefix and appends the ellipsis; head cut keeps a
	// tail suffix behind it. Exact glyph counts depend on the shared measure
	// backend (parallel tests may swap it), so assert the structural contract.
	cut := truncate_to_width_dir_with(&system, "abcdefgh", 5 * W_CELL, 16, .Tail)
	testing.expect(t, len(cut) < len("abcdefgh") + len("…"), "tail cut did not shrink")
	testing.expect(t, strings.has_suffix(cut, "…"), "tail cut must end with ellipsis")
	testing.expect(
		t,
		strings.has_prefix("abcdefgh", cut[:len(cut) - len("…")]),
		"tail cut must keep a prefix",
	)
	left := truncate_to_width_dir_with(&system, "abcdefgh", 5 * W_CELL, 16, .Head)
	testing.expect(t, strings.has_prefix(left, "…"), "head cut must start with ellipsis")
	testing.expect(
		t,
		strings.has_suffix("abcdefgh", left[len("…"):]),
		"head cut must keep a suffix",
	)
	// Empty input is returned as-is.
	testing.expect_value(t, truncate_to_width_dir_with(&system, "", 100, 16, .Tail), "")
}

@(test)
truncate_path_middle_keeps_ends :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	set_measure_backend_with(&runtime.text, w_mono)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	path := "alloy/src/ui/widgets.odin"
	// Wide enough: untouched.
	testing.expect_value(t, truncate_path_middle_frame(&frame, path, 30 * W_CELL, 16), path)
	// Middle truncation keeps the first segment and the filename visible.
	got := truncate_path_middle_frame(&frame, path, 24 * W_CELL, 16)
	testing.expect(t, strings.has_suffix(got, "widgets.odin"), "filename must stay visible")
	testing.expect(t, strings.contains(got, "…"), "middle cut must show an ellipsis")
	// Trailing slash (directory entry) is preserved.
	dir := "alloy/src/ui/deep/"
	got_dir := truncate_path_middle_frame(&frame, dir, 14 * W_CELL, 16)
	testing.expect(t, strings.has_suffix(got_dir, "/"), "directory slash must survive")
	testing.expect(t, strings.contains(got_dir, "…"), "middle cut must show an ellipsis")
}

@(test)
find_word_bounds_identifier_chars :: proc(t: ^testing.T) {
	text := "foo bar_baz9 qux"
	s, e := find_word_bounds(text, 6)
	testing.expect_value(t, text[s:e], "bar_baz9")
	// Offset on the whitespace just after a word selects that word (the
	// backward walk crosses it; the forward walk stops at the space).
	s, e = find_word_bounds(text, 3)
	testing.expect_value(t, text[s:e], "foo")
	// Bounds clamp at string edges.
	s, e = find_word_bounds(text, 0)
	testing.expect_value(t, text[s:e], "foo")
}

@(test)
find_word_bounds_multibyte_runes :: proc(t: ^testing.T) {
	// Bytes >= 0x80 are word bytes, so accented words select fully even when
	// the offset lands mid-rune, and the boundary stays at the ASCII space.
	text := "héllo wörld"
	s, e := find_word_bounds(text, 3)
	testing.expect_value(t, text[s:e], "héllo")
	s, e = find_word_bounds(text, len(text))
	testing.expect_value(t, text[s:e], "wörld")
	// CJK runs (3-byte runes, no spaces) select as one word.
	cjk := "日本語 テスト"
	s, e = find_word_bounds(cjk, 4)
	testing.expect_value(t, cjk[s:e], "日本語")
	// ASCII punctuation still splits words.
	hyphen := "self-hosted"
	s, e = find_word_bounds(hyphen, 2)
	testing.expect_value(t, hyphen[s:e], "self")
}

@(test)
caret_grapheme_steps_match_rune_steps_on_ascii :: proc(t: ^testing.T) {
	text := "ab\ncd"
	for pos in 0 ..= len(text) {
		testing.expect_value(t, caret_next_grapheme(text, pos), caret_next_rune(text, pos))
		testing.expect_value(t, caret_prev_grapheme(text, pos), caret_prev_rune(text, pos))
	}
}

@(test)
caret_grapheme_steps_over_clusters :: proc(t: ^testing.T) {
	// "a" + family emoji (18 bytes: three 4-byte emoji joined by two 3-byte
	// ZWJs) + "b": one step crosses the whole cluster in both directions.
	family := "a👩‍👩‍👦b"
	testing.expect_value(t, caret_next_grapheme(family, 1), 19)
	testing.expect_value(t, caret_prev_grapheme(family, 19), 1)
	// Mid-cluster offsets snap out to the cluster edges.
	testing.expect_value(t, caret_next_grapheme(family, 5), 19)
	testing.expect_value(t, caret_prev_grapheme(family, 5), 1)
	// Combining mark: "e" + U+0301 is one cluster of 3 bytes.
	combining := "e\u0301x"
	testing.expect_value(t, caret_next_grapheme(combining, 0), 3)
	testing.expect_value(t, caret_prev_grapheme(combining, 3), 0)
	// Edges clamp; a caret at a line start steps over the newline.
	testing.expect_value(t, caret_next_grapheme("x", 1), 1)
	testing.expect_value(t, caret_prev_grapheme("", 0), 0)
	testing.expect_value(t, caret_prev_grapheme("a\nb", 2), 1)
}

@(test)
wheel_accum_carries_fractions :: proc(t: ^testing.T) {
	accum: f32
	// Small deltas accumulate until a whole row is reached.
	testing.expect_value(t, wheel_accum_steps(&accum, 0.4), 0)
	testing.expect_value(t, wheel_accum_steps(&accum, 0.4), 0)
	testing.expect_value(t, wheel_accum_steps(&accum, 0.4), -1) // wheel up = scroll up
	// Direction reversal resets the remainder.
	testing.expect_value(t, wheel_accum_steps(&accum, -1.5), 1)
	// Zero delta never changes state.
	before := accum
	testing.expect_value(t, wheel_accum_steps(&accum, 0), 0)
	testing.expect_value(t, accum, before)
}

@(test)
hit_test_wrapped_maps_rows_and_columns :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	set_measure_backend_with(&runtime.text, w_mono)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	text := "aaa bbb"
	w := 5 * W_CELL // wraps after "aaa"
	// Click on row 0, column 1.
	off := hit_test_wrapped_frame(&frame, 0, 0, w, text, W_CELL, 0, 16)
	testing.expect_value(t, off, 1)
	// Click on row 1 lands inside "bbb".
	off2 := hit_test_wrapped_frame(&frame, 0, 0, w, text, 0, runtime.metrics.LINE_HEIGHT, 16)
	testing.expect(t, off2 >= 4 && off2 <= 7)
	// Empty text misses.
	testing.expect_value(t, hit_test_wrapped_frame(&frame, 0, 0, w, "", 0, 0, 16), -1)
}

@(test)
settings_preset_index_lookup :: proc(t: ^testing.T) {
	testing.expect_value(t, settings_scale_preset_index(0.0), 0) // Auto
	testing.expect_value(t, settings_scale_preset_index(1.0), 3) // 100%
	testing.expect_value(t, settings_scale_preset_index(2.0), 8) // 200%
	testing.expect_value(t, settings_scale_preset_index(0.33), 0) // no match: Auto
}

@(test)
markdown_offset_roundtrip :: proc(t: ^testing.T) {
	line := "a **bold** `code` end"
	spans := parse_inline_spans_with(line)
	display_len := spans_display_len(spans)
	// display -> raw -> display is identity for every display position.
	for d in 0 ..< display_len {
		raw := display_to_raw(spans, d)
		testing.expect(t, raw >= 0 && raw <= len(line), "raw offset out of bounds")
		back := raw_to_display(spans, raw)
		testing.expect_value(t, back, d)
	}
}
