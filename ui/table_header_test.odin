#+build !js
package ui

import "core:testing"

// table_test_frame boots a headless runtime+frame with a measuring text backend,
// mirroring facade_rows_frame. Reused by the header/scroll interaction tests.
@(private = "file")
table_test_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	output: ^Ui_Output,
	text_backend: ^Test_Text_Backend_State,
	input: ^Ui_Input,
) {
	assert(runtime != nil && frame != nil, "table_test_frame: nil argument")
	assert(output != nil && text_backend != nil && input != nil, "table_test_frame: nil argument")
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
resize_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "Name", track = fixed(100)}
	buffer[1] = {label = "Rest", track = grow(1, 0)}
	return buffer[:2]
}

// Dragging the border between two columns widens the left one; because its
// neighbour grows, the total stays pinned to the row width (conservation).
@(test)
test_table_header_resize_widens_and_conserves :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	columns: [2]Table_Column
	specs := resize_columns(columns[:])
	st: Table_State
	style := table_style_default()

	// Frame 1: press exactly on the border at x=100.
	input: Ui_Input
	input.mouse_position = {100, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_down[input_mouse_index(.LEFT)] = true
	table_test_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	testing.expect(t, st.resize.active, "press on border must claim the resize latch")
	testing.expect_value(t, st.resize.column, i32(0))
	ui_frame_end(&frame)

	// Frame 2: hold and drag 40px right.
	input.mouse_position = {140, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = false
	ui_frame_begin(&frame, &runtime, &input)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		changed := table_header_ex(&u, "tbl", specs, &st, style, 30)
		testing.expect(t, changed, "drag changes width")
		end(&u)
	}
	testing.expect_value(t, st.width_px[0], i32(140))
	ui_frame_end(&frame)

	// Frame 3: release.
	input.mouse_down[input_mouse_index(.LEFT)] = false
	input.mouse_released[input_mouse_index(.LEFT)] = true
	ui_frame_begin(&frame, &runtime, &input)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	testing.expect(t, !st.resize.active, "release drops the latch")
	ui_frame_end(&frame)

	// Conservation: over the same 400px row, column 0 is now 140 and its grow
	// neighbour absorbed the rest.
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(&st, specs, tracks[:], cols[:])
	widths: [TABLE_COLUMN_COUNT_MAX]i32
	table_resolve_pixels(tracks[:n], 400, 0, widths[:])
	testing.expect_value(t, widths[0], i32(140))
	testing.expect_value(t, widths[1], i32(260))
}

// A drag past the minimum clamps the column instead of collapsing it.
@(test)
test_table_header_resize_clamps_to_min :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	columns: [2]Table_Column
	specs := resize_columns(columns[:])
	st: Table_State
	style := table_style_default() // min_column_px = 32

	input: Ui_Input
	input.mouse_position = {100, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_down[input_mouse_index(.LEFT)] = true
	table_test_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	ui_frame_end(&frame)

	// Drag far left, past zero.
	input.mouse_position = {10, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = false
	ui_frame_begin(&frame, &runtime, &input)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	defer ui_frame_end(&frame)
	testing.expect_value(t, st.width_px[0], i32(32))
}

// A single-frame click away from any border still toggles the sort.
@(test)
test_table_header_click_still_sorts :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	columns: [2]Table_Column
	specs := resize_columns(columns[:])
	st: Table_State
	style := table_style_default()

	input: Ui_Input
	input.mouse_position = {50, 15} // inside column 0 body, far from the border
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_released[input_mouse_index(.LEFT)] = true
	table_test_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		changed := table_header_ex(&u, "tbl", specs, &st, style, 30)
		testing.expect(t, changed, "header click toggles sort")
		end(&u)
	}
	testing.expect_value(t, st.sort.column, i32(0))
	testing.expect(t, !st.resize.active, "a body click never starts a resize")
}

@(private = "file")
reorder_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "A", track = fixed(100)}
	buffer[1] = {label = "B", track = fixed(100)}
	buffer[2] = {label = "C", track = fixed(100)}
	return buffer[:3]
}

// Press a header, drag it past the next column's midpoint, and release: the
// display order updates and the sort is left untouched.
@(test)
test_table_header_reorder_moves_column :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	columns: [3]Table_Column
	specs := reorder_columns(columns[:])
	st: Table_State
	style := table_style_default()

	// Frame 1: press column 0 (x=50) and hold.
	input: Ui_Input
	input.mouse_position = {50, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_down[input_mouse_index(.LEFT)] = true
	table_test_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	testing.expect(t, st.reorder.active, "press arms the reorder latch")
	testing.expect_value(t, st.reorder.from, i32(0))
	ui_frame_end(&frame)

	// Frame 2: drag into column 1, past its left but staying below x=150.
	input.mouse_position = {140, 15}
	input.mouse_pressed[input_mouse_index(.LEFT)] = false
	ui_frame_begin(&frame, &runtime, &input)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	testing.expect(t, st.reorder.active, "still dragging")
	ui_frame_end(&frame)

	// Frame 3: release at x=140 -> drop slot 1.
	input.mouse_down[input_mouse_index(.LEFT)] = false
	input.mouse_released[input_mouse_index(.LEFT)] = true
	ui_frame_begin(&frame, &runtime, &input)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	defer ui_frame_end(&frame)
	testing.expect(t, !st.reorder.active, "release clears the latch")
	testing.expect_value(t, int(st.order[0]), 1)
	testing.expect_value(t, int(st.order[1]), 0)
	testing.expect_value(t, int(st.order[2]), 2)
	testing.expect_value(t, st.sort.column, i32(-1)) // a drag never sorts
}

// Pressing exactly on a column border starts a resize, never a reorder.
@(test)
test_table_header_border_press_prefers_resize :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	columns: [3]Table_Column
	specs := reorder_columns(columns[:])
	st: Table_State
	style := table_style_default()

	input: Ui_Input
	input.mouse_position = {100, 15} // border between columns 0 and 1
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	input.mouse_down[input_mouse_index(.LEFT)] = true
	table_test_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	{
		u: Ui
		begin(&u, &frame, {0, 0, 400, 200})
		_ = table_header_ex(&u, "tbl", specs, &st, style, 30)
		end(&u)
	}
	testing.expect(t, st.resize.active, "border press starts a resize")
	testing.expect(t, !st.reorder.active, "border press never starts a reorder")
	testing.expect_value(t, int(st.order[0]), 0) // order untouched
}

