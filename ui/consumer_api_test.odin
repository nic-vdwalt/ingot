#+build !js
package ui

import "core:testing"

@(test)
consumer_api_baseline_compiles :: proc(t: ^testing.T) {
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
	defer ui_frame_destroy(&frame)
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)

	u: Ui
	name: Input_Box
	defer input_box_destroy(&name)
	showing := true
	items := [3]u64{101, 205, 309}
	begin(&u, &frame, {0, 0, 640, 480}, gap = .SM)
	scope_begin(&u, "form")
	_ = text_input(&u, "name", &name, "Name", Text_Input_Options{semantics = {name = "Name"}})
	_ = checkbox(&u, "showing", "Show items", &showing)
	_ = button(&u, "save", "Save", Button_Options{style = .Primary})
	apply := false
	_ = fit_button(
		"full-options",
		"Full options",
		Fit_Button_Options{disabled = true, activated = &apply},
	)
	_ = fit_row(
		{gap = .SM, align = .Center},
		{
			fit_label("Actions", {role = .Label, track = grow()}),
			fit_button("static", "Static", .Primary, &apply),
		},
	)
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_row(&builder, {gap = .SM, align = .Center})
	fit_builder_label(&builder, "Actions", {role = .Label, track = grow()})
	fit_builder_button(&builder, "apply", "Apply", .Primary, &apply)
	fit_end(&builder)
	_ = fit_render(&builder)
	scope(&u, "items", consumer_api_items, &items)
	canvas(&u, {height = 120}, consumer_api_canvas)
	scope_end(&u)
	end(&u)

	testing.expect_value(t, u.focus_count, 7)
}

@(private = "file")
consumer_api_canvas :: proc(frame: ^Ui_Frame, rect: Rect_I32, userdata: rawptr) {
	assert(frame != nil && frame.open, "consumer_api_canvas: invalid frame")
	assert(userdata == nil, "consumer_api_canvas: unexpected userdata")
	canvas_clear(frame, rect, {16, 18, 24, 255})
}

@(private = "file")
consumer_api_items :: proc(u: ^Ui, userdata: rawptr) {
	assert(u != nil && userdata != nil, "consumer_api_items: invalid arguments")
	items := cast(^[3]u64)userdata
	for item in items {
		_ = button(u, item, "Item")
	}
}
