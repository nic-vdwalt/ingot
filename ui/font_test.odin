#+build !js
package ui

import "core:testing"

Test_Text_Backend_State :: struct {
	font_calls:    int,
	measure_calls: int,
	advance:       f32,
}

test_text_font_for_size :: proc(data: rawptr, size: i32) -> Font_Id {
	state := cast(^Test_Text_Backend_State)data
	state.font_calls += 1
	return Font_Id(size)
}

test_text_measure :: proc(data: rawptr, font: Font_Id, text: string, size, spacing: f32) -> Vec2 {
	state := cast(^Test_Text_Backend_State)data
	state.measure_calls += 1
	advance := state.advance
	if advance <= 0 do advance = size
	return {f32(len(text)) * advance, size}
}

@(test)
test_draw_text_frame_copies_text_with_backend_font :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	text := [8]u8{'G', 'a', 'l', 'l', 'e', 'r', 'y', 0}
	draw_text_frame(&frame, cstring(&text[0]), 10, 20, 16, Color{255, 255, 255, 255})
	text[0] = 'X'
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 1)
	command := output.main.commands[0]
	testing.expect_value(t, command.kind, Paint_Kind.Text)
	testing.expect_value(t, command.font, Font_Id(16))
	testing.expect_value(t, paint_text(&output.main, command), "Gallery")
	testing.expect_value(t, state.font_calls, 1)
}

@(test)
test_target_codepoint_uses_backend_font_without_pane_translation :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	output := new(Ui_Output)
	defer free(output)
	frame: Ui_Frame
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	ui_frame_pane_push(&frame, {100, 200})
	draw_target_codepoint_frame(&frame, 'A', 4, 8, 16, Color{255, 255, 255, 255})
	ui_frame_pane_pop(&frame)
	ui_frame_end(&frame)

	testing.expect_value(t, output.main.count, 1)
	command := output.main.commands[0]
	testing.expect_value(t, command.font, Font_Id(16))
	testing.expect_value(t, command.p0, Vec2{4, 8})
	testing.expect_value(t, state.font_calls, 1)
}

@(test)
test_measure_text_frame_uses_backend_font :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	width := measure_text_frame(&frame, "Gallery", 16)
	ui_frame_end(&frame)

	testing.expect_value(t, width, i32(112))
	testing.expect_value(t, state.font_calls, 1)
	testing.expect_value(t, state.measure_calls, 1)
}

@(test)
text_backend_measure_cache_reuses_and_invalidates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	first: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &first, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	width_a := measure_text_string_frame(&frame, "stable", 16)
	width_b := measure_text_string_frame(&frame, "stable", 16)
	ui_frame_end(&frame)
	testing.expect_value(t, width_a, width_b)
	testing.expect_value(t, first.measure_calls, 1)
	second := Test_Text_Backend_State {
		advance = 11,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &second, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	ui_frame_begin(&frame, &runtime)
	width_c := measure_text_string_frame(&frame, "stable", 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	testing.expect_value(t, second.measure_calls, 1)
	testing.expect(t, width_c != width_a, "backend change reused stale measurement")
}

@(test)
test_backend_measure_l0_is_exact_and_bounded :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	labels := [?]string{"zero", "one", "two", "three", "four", "five", "six", "seven", "eight"}
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	for label in labels do _ = measure_text_string_frame(&frame, label, 16)
	occupied := 0
	for entry in runtime.text.measure_l0 do if entry.valid do occupied += 1
	testing.expect_value(t, occupied, MEASURE_L0_CAPACITY)
	testing.expect_value(t, runtime.text.measure_l0_next, 1)
	testing.expect_value(t, state.measure_calls, len(labels))
	_ = measure_text_string_frame(&frame, "eight", 16)
	testing.expect_value(t, state.measure_calls, len(labels))
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
}

@(test)
text_backend_measure_cache_runtime_policy_isolated :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	ui_runtime_set_backend_measure_cache_enabled(&runtime, false)
	measure_cache_telemetry_reset_with(&runtime.text)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	width_a := measure_text_string_frame(&frame, "stable", 16)
	width_b := measure_text_string_frame(&frame, "stable", 16)
	ui_frame_end(&frame)
	entries, _ := measure_cache_stats_with(&runtime.text)
	testing.expect_value(t, width_a, width_b)
	testing.expect_value(t, state.measure_calls, 2)
	testing.expect_value(t, entries, 0)
	when UI_TELEMETRY_ENABLED {
		_, misses, bypasses := measure_cache_telemetry_with(&runtime.text)
		testing.expect_value(t, misses, u64(0))
		testing.expect_value(t, bypasses, u64(2))
	}
	ui_runtime_set_backend_measure_cache_enabled(&runtime, true)
	ui_frame_begin(&frame, &runtime)
	_ = measure_text_string_frame(&frame, "stable", 16)
	_ = measure_text_string_frame(&frame, "stable", 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	entries, _ = measure_cache_stats_with(&runtime.text)
	testing.expect_value(t, state.measure_calls, 3)
	testing.expect_value(t, entries, 1)
}

@(test)
test_frame_text_geometry_uses_render_backend :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state := Test_Text_Backend_State {
		advance = 11,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	text := "aa aa"
	lines := wrap_compute_frame(&frame, text, 35, 16)
	row, caret_x := input_caret_visual_frame(&frame, lines, text, 2, 16)
	col := caret_pixel_to_col_frame(&frame, "abcd", 33, 16)
	ui_frame_end(&frame)

	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, text[lines[0].start:lines[0].end], "aa")
	testing.expect_value(t, row, 0)
	testing.expect_value(t, caret_x, i32(22))
	testing.expect_value(t, col, 3)
	testing.expect(t, state.measure_calls > 0, "frame geometry must use the render backend")
}

@(test)
test_markdown_width_uses_render_backend :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	state := Test_Text_Backend_State {
		advance = 11,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	plain_width := wrapped_max_line_width_md_frame(&frame, "abcd", 100, 16)
	bold_width := wrapped_max_line_width_md_frame(&frame, "**abcd**", 100, 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	ui_runtime_destroy(&runtime)

	testing.expect_value(t, plain_width, i32(44))
	testing.expect_value(t, bold_width, i32(44))
	testing.expect(t, state.measure_calls > 0, "markdown width must use the render backend")
}

// A resetting backend models ui_gfx: Font_Id values index a font table that
// reset empties, so an id handed out before a reset dangles after it.
Test_Resetting_Backend_State :: struct {
	using base:  Test_Text_Backend_State,
	live_size:   i32,
	reset_calls: int,
	invalid_use: int,
}

test_resetting_font_for_size :: proc(data: rawptr, size: i32) -> Font_Id {
	state := cast(^Test_Resetting_Backend_State)data
	state.font_calls += 1
	state.live_size = size
	return Font_Id(size)
}

test_resetting_measure :: proc(
	data: rawptr,
	font: Font_Id,
	text: string,
	size, spacing: f32,
) -> Vec2 {
	state := cast(^Test_Resetting_Backend_State)data
	state.measure_calls += 1
	// Stands in for ui_gfx's "adapter_measure: invalid font" assertion.
	if font != Font_Id(state.live_size) do state.invalid_use += 1
	return {f32(len(text)) * size, size}
}

test_resetting_reset :: proc(data: rawptr) {
	state := cast(^Test_Resetting_Backend_State)data
	state.reset_calls += 1
	state.live_size = 0
}

@(test)
test_mid_frame_scale_change_invalidates_font_memo :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	state: Test_Resetting_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &state,
			font_for_size = test_resetting_font_for_size,
			measure = test_resetting_measure,
			reset = test_resetting_reset,
		},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)

	_ = measure_text_string_frame(&frame, "before", 16)
	testing.expect_value(t, state.invalid_use, 0)

	// An auto-fit pass resizing content to its container, mid-frame.
	ui_runtime_set_scale(&runtime, 1.5)
	testing.expect_value(t, state.reset_calls, 1)

	_ = measure_text_string_frame(&frame, "after", 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	ui_runtime_destroy(&runtime)

	testing.expect_value(t, state.invalid_use, 0)
	testing.expect(
		t,
		state.font_calls >= 2,
		"a font reset must force the frame to re-resolve its font",
	)
}

// The cstring measure entry point must hit the same backend cache as the
// string one: chat markdown layout measures via cstrings every frame, and an
// uncached path was the dominant CPU cost in long chats.
@(test)
test_measure_text_frame_cstring_uses_backend_cache :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	width_a := measure_text_frame(&frame, "stable", 16)
	width_b := measure_text_frame(&frame, "stable", 16)
	width_c := measure_text_string_frame(&frame, "stable", 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	testing.expect_value(t, width_a, width_b)
	testing.expect_value(t, width_a, width_c)
	testing.expect_value(t, state.measure_calls, 1)
}

// Rune advances are cached per (font, size, epoch): the wrap/truncate hot
// paths call rune_width_frame per rune per frame, which previously issued a
// backend measure each time.
@(test)
test_rune_advance_cache_measures_once_and_invalidates :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	first: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &first, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	ascii_a := rune_width_frame(&frame, 'a', 16)
	ascii_b := rune_width_frame(&frame, 'a', 16)
	wide_a := rune_width_frame(&frame, '\u00e9', 16)
	wide_b := rune_width_frame(&frame, '\u00e9', 16)
	ui_frame_end(&frame)
	testing.expect_value(t, ascii_a, ascii_b)
	testing.expect_value(t, wide_a, wide_b)
	testing.expect_value(t, first.measure_calls, 2)

	// A backend swap bumps the font epoch; stale advances must not be reused.
	second := Test_Text_Backend_State {
		advance = 11,
	}
	ui_runtime_set_text_backend(
		&runtime,
		{data = &second, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	ui_frame_begin(&frame, &runtime)
	ascii_c := rune_width_frame(&frame, 'a', 16)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	testing.expect_value(t, second.measure_calls, 1)
	testing.expect(t, ascii_c != ascii_a, "epoch bump reused a stale rune advance")
}

// wrap_text_frame results are cached by content hash: identical inputs return
// identical lines with no recompute, and a width change recomputes.
@(test)
test_wrap_text_frame_cache_reuses_lines :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	state: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &state, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	text := "aa aa"
	lines_a := wrap_text_frame(&frame, text, 35, 16)
	calls_after_first := state.measure_calls
	lines_b := wrap_text_frame(&frame, text, 35, 16)
	testing.expect_value(t, state.measure_calls, calls_after_first)
	testing.expect_value(t, len(runtime.text.wrap_frame_cache), 1)
	testing.expect_value(t, len(lines_a), len(lines_b))
	for line, index in lines_a {
		testing.expect_value(t, line, lines_b[index])
	}
	lines_wide := wrap_text_frame(&frame, text, 200, 16)
	testing.expect_value(t, len(runtime.text.wrap_frame_cache), 2)
	testing.expect_value(t, len(lines_wide), 1)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	testing.expect_value(t, len(lines_a), 2)
	testing.expect_value(t, text[lines_a[0].start:lines_a[0].end], "aa")
}

// The linear truncator must match the old per-prefix behavior: longest
// prefix/suffix that fits with the ellipsis, for ASCII and multibyte text.
@(test)
test_truncate_linear_matches_reference :: proc(t: ^testing.T) {
	system: Text_System
	text_system_init(&system)
	defer text_system_destroy(&system)
	set_measure_backend_with(&system, proc(text: cstring, size: i32) -> i32 {
		return i32(len(string(text))) * 10
	})

	// ASCII, tail: "…" is 3 bytes = 30 wide; 80 leaves 50 for "hello".
	tail := truncate_to_width_dir_with(&system, "hello world", 80, 16, .Tail)
	testing.expect_value(t, tail, "hello…")

	// ASCII, head: keep the tail.
	head := truncate_to_width_dir_with(&system, "hello world", 80, 16, .Head)
	testing.expect_value(t, head, "…world")

	// Multibyte: é is 2 bytes (20 wide); 70 leaves 40, i.e. exactly 2 runes.
	multi := truncate_to_width_dir_with(&system, "ééééé", 70, 16, .Tail)
	testing.expect_value(t, multi, "éé…")

	// Fits untouched.
	fits := truncate_to_width_dir_with(&system, "ok", 200, 16, .Tail)
	testing.expect_value(t, fits, "ok")
}
