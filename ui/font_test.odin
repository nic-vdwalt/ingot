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
