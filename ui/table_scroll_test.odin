#+build !js
package ui

import "core:testing"

@(private = "file")
scroll_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
	input: ^Ui_Input,
) {
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

@(private = "file")
scroll_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "Name", track = grow(1, 0)}
	buffer[1] = {label = "Value", track = grow(1, 0), numeric = true}
	return buffer[:2]
}

@(private = "file")
render_body :: proc(u: ^Ui, st: ^Table_State, style: Table_Style, count: int) -> Table_Window {
	columns: [2]Table_Column
	specs := scroll_columns(columns[:])
	win := table_begin(u, "tbl", specs, st, style, 30, count, visible_h = 0)
	last := min(win.first + win.visible_rows, count)
	for i in win.first ..< last {
		_ = table_row(u, st, i, "row")
		cell(u, "a")
		cell_value(u, "b")
		table_row_close(u)
	}
	table_end(u, st)
	return win
}

// The body windows a fixed-height row set and clamps an out-of-range scroll.
@(test)
test_table_scroll_windows_and_clamps :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500} // keep the pointer off the body
	scroll_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	st: Table_State
	st.scroll = 999 // far past the end; must clamp
	style := table_style_default()
	u: Ui
	begin(&u, &frame, {0, 0, 400, 230})
	win := render_body(&u, &st, style, 50)
	end(&u)

	testing.expect_value(t, win.visible_rows, 6) // (230 - 30 header) / 30
	testing.expect_value(t, win.first, 44) // 50 - 6
	testing.expect(t, st.scroll == 44, "scroll clamps in place")
}

// Changing the scroll moves the window while the geometry (row size, width)
// stays put — the header is redrawn above the scissor every frame.
@(test)
test_table_scroll_header_sticky_body_moves :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500}
	scroll_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)

	st: Table_State
	style := table_style_default()

	st.scroll = 0
	first_a, rows_a, roww_a, rowh_a: int
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 230})
		win := render_body(&u, &st, style, 50)
		end(&u)
		first_a = win.first
		rows_a = win.visible_rows
		roww_a = int(win.row_w)
		rowh_a = int(win.row_h_px)
	}
	ui_frame_end(&frame)

	st.scroll = 10
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 230})
		win := render_body(&u, &st, style, 50)
		end(&u)
		testing.expect_value(t, first_a, 0)
		testing.expect_value(t, win.first, 10)
		testing.expect_value(t, win.visible_rows, rows_a)
		testing.expect_value(t, int(win.row_w), roww_a)
		testing.expect_value(t, int(win.row_h_px), rowh_a)
	}
}

// After a reorder the body's solved column mapping follows the new order, so
// cells land under the right header.
@(test)
test_table_scroll_cells_follow_reorder :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500}
	scroll_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	columns: [2]Table_Column
	specs := scroll_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	table_order_move(&st, 0, 1) // swap the two columns
	style := table_style_default()

	u: Ui
	begin(&u, &frame, {0, 0, 400, 230})
	win := table_begin(&u, "tbl", specs, &st, style, 30, 3)
	last := min(win.first + win.visible_rows, 3)
	for i in win.first ..< last {
		_ = table_row(&u, &st, i, "row")
		cell(&u, "a")
		cell_value(&u, "b")
		table_row_close(&u)
	}
	table_end(&u, &st)
	end(&u)

	testing.expect_value(t, st.build.cols[0], i32(1)) // Value now leftmost
	testing.expect_value(t, st.build.cols[1], i32(0))
}

// A region too short for even the header yields an empty window without panic.
@(test)
test_table_scroll_degenerate_region :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500}
	scroll_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	st: Table_State
	style := table_style_default()
	u: Ui
	begin(&u, &frame, {0, 0, 400, 20}) // shorter than the 30px header
	win := render_body(&u, &st, style, 50)
	end(&u)

	testing.expect_value(t, win.visible_rows, 0)
}
