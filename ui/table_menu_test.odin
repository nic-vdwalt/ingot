#+build !js
package ui

import "core:testing"

@(private = "file")
menu_frame :: proc(
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
menu_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "Name", track = grow(1, 0)}
	buffer[1] = {label = "Count", track = fixed(80), numeric = true}
	buffer[2] = {label = "State", track = grow(1, 0)}
	return buffer[:3]
}

// A hidden column drops out of the solved body layout: n shrinks and the
// display map skips it.
@(test)
test_table_visibility_hidden_column_skipped :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500}
	menu_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	columns: [3]Table_Column
	specs := menu_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	_ = table_visibility_toggle(&st, 1) // hide "Count"
	style := table_style_default()

	u: Ui
	begin(&u, &frame, {0, 0, 400, 230})
	win := table_begin(&u, "tbl", specs, &st, style, 30, 2)
	last := min(win.first + win.visible_rows, 2)
	for i in win.first ..< last {
		_ = table_row(&u, &st, i, "row")
		cell(&u, "a")
		cell(&u, "b")
		table_row_close(&u)
	}
	table_end(&u, &st)
	end(&u)

	testing.expect_value(t, st.build.n, 2)
	testing.expect_value(t, st.build.cols[0], i32(0)) // Name
	testing.expect_value(t, st.build.cols[1], i32(2)) // State; Count skipped
}

// The visibility menu renders without input and reports no change.
@(test)
test_table_visibility_menu_renders :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	text_backend: Test_Text_Backend_State
	input: Ui_Input
	input.mouse_position = {-500, -500}
	menu_frame(&runtime, &frame, output, &text_backend, &input)
	defer ui_runtime_destroy(&runtime)
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)

	columns: [3]Table_Column
	specs := menu_columns(columns[:])
	st: Table_State
	style := table_style_default()
	_ = style

	u: Ui
	begin(&u, &frame, {0, 0, 200, 200})
	changed := table_visibility_menu(&u, "cols", specs, &st, 26)
	end(&u)

	testing.expect(t, !changed, "no input, no change")
	testing.expect(t, st.initialized, "menu seeds the state")
}
