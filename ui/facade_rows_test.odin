#+build !js
package ui

import "core:testing"

@(private = "file")
facade_rows_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
	input: ^Ui_Input = nil,
) {
	assert(runtime != nil && frame != nil, "facade_rows_frame: nil argument")
	assert(output != nil && text_backend != nil, "facade_rows_frame: nil argument")
	ui_runtime_init(runtime)
	ui_runtime_set_text_backend(
		runtime,
		{
			data = text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	frame.output = output
	ui_frame_begin(frame, runtime, input)
}

// A row must consume exactly its declared strip and lay cells on the flex
// tracks; an unhovered row reports no interaction.
@(test)
facade_row_select_lays_out_cells :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	// Default input has the mouse at {0,0} — inside the first row — so park
	// it far away to assert the unhovered path.
	input: Ui_Input
	input.mouse_position = {-500, -500}
	facade_rows_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 200})
	scope_begin(&u, "list")
	last_click: f64
	result := row_select_begin(&u, "row-0", 26, {fixed(120), grow()}, false, &last_click)
	cell(&u, "name")
	cell(&u, "value")
	row_select_end(&u)
	scope_end(&u)
	end(&u)

	testing.expect(t, !result.hovered, "no mouse over headless frame")
	testing.expect(t, !result.clicked, "no click without input")
	testing.expect(t, !result.double_clicked, "no double click without input")
}

// A click inside the row's strip must report clicked; a second click within
// the double-click window must report double_clicked and reset the slot.
@(test)
facade_row_select_double_click :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {50, 13}
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_released[input_mouse_index(.LEFT)] = true
	input.time = 10.0
	facade_rows_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)

	last_click: f64
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		scope_begin(&u, "list")
		result := row_select_begin(&u, "row-0", 26, {grow()}, false, &last_click)
		cell(&u, "only")
		row_select_end(&u)
		scope_end(&u)
		end(&u)
		testing.expect(t, result.clicked, "first click should register")
		testing.expect(t, !result.double_clicked, "first click is single")
		testing.expect(t, last_click == 10.0, "timestamp recorded")
	}
	ui_frame_end(&frame)

	// Second frame, 0.2 s later: same click becomes a double click.
	input.time = 10.2
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		scope_begin(&u, "list")
		result := row_select_begin(&u, "row-0", 26, {grow()}, false, &last_click)
		cell(&u, "only")
		row_select_end(&u)
		scope_end(&u)
		end(&u)
		testing.expect(t, result.double_clicked, "second click within window is double")
		testing.expect(t, last_click == 0, "double click resets the slot")
	}
}

// list_window must clamp scroll into range and report a correct window.
@(test)
facade_list_window_clamps_and_windows :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_rows_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 130})
	scope_begin(&u, "list")
	scroll: f32 = 999 // far beyond range; must clamp
	first, visible := list_window_begin(&u, "rows", 26, 50, &scroll)
	list_window_end(&u)
	scope_end(&u)
	end(&u)

	testing.expect_value(t, visible, 5) // 130 / 26
	testing.expect_value(t, first, 45) // clamped to count - visible
	testing.expect(t, scroll == 45, "scroll clamped in place")
}

// An empty list keeps the window sane.
@(test)
facade_list_window_empty :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	facade_rows_frame(&runtime, &frame, output, &text_backend)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	u: Ui
	begin(&u, &frame, {0, 0, 400, 130})
	scope_begin(&u, "list")
	scroll: f32 = 5
	first, visible := list_window_begin(&u, "rows", 26, 0, &scroll)
	list_window_end(&u)
	scope_end(&u)
	end(&u)

	testing.expect_value(t, first, 0)
	testing.expect(t, visible >= 0, "visible must not go negative")
	testing.expect(t, scroll == 0, "scroll clamps to zero for empty lists")
}
