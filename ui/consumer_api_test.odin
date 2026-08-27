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
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_row(&builder, {gap = .SM, align = .Center})
	fit_builder_label(&builder, "Actions", {role = .Label, track = grow()})
	fit_builder_button(&builder, "apply", "Apply", .Primary, &apply)
	fit_end(&builder)
	_ = fit_render(&builder)
	flow_builder: Fit_Builder
	fit_begin(&flow_builder, &u)
	fit_builder_flow(&flow_builder, {gap_x = .XS, gap_y = .XS})
	fit_builder_label(&flow_builder, "Flow", {size = {aspect = {16, 9}}})
	fit_end(&flow_builder)
	flow_size := fit_measure(&flow_builder)
	fit_render_at(&flow_builder, {0, 0, flow_size.w, flow_size.h})
	tracks := [3]Track{fixed(80), grow(), fit(120)}
	grid_builder: Fit_Builder
	fit_begin(&grid_builder, &u)
	fit_builder_grid(&grid_builder, {column_tracks = tracks[:], row_height = 24})
	fit_builder_grid_cell(&grid_builder, {placement = {column_span = 2}})
	fit_builder_label(&grid_builder, "Spanning")
	fit_end(&grid_builder)
	fit_builder_label(&grid_builder, "Automatic")
	fit_end(&grid_builder)
	_ = fit_render(&grid_builder)
	transition: Transition_Rect_State
	transition_rect_reset(&transition, {0, 0, 40, 20})
	attachment_builder: Fit_Builder
	fit_begin(&attachment_builder, &u)
	fit_builder_row(&attachment_builder)
	fit_builder_attachment(
		&attachment_builder,
		{target_kind = .Viewport, z = Z_TOOLTIP, transition = {state = &transition}},
	)
	fit_builder_label(&attachment_builder, "Attached")
	fit_end(&attachment_builder)
	fit_end(&attachment_builder)
	_ = fit_render(&attachment_builder)
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
