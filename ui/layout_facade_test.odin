#+build !js
package ui

import "core:testing"

@(private = "file")
layout_intrinsic_measure :: proc(text: cstring, size: i32) -> i32 {
	assert(size > 0, "layout_intrinsic_measure: invalid size")
	return i32(len(string(text))) * 7
}

Prepared_Custom_Counts :: struct {
	measure, render: i32,
	rect:            Rect_I32,
}

@(private = "file")
prepared_custom_measure_test :: proc(
	u: ^Ui,
	constraints: Intrinsic_Constraints,
	userdata: rawptr,
) -> Intrinsic_Size {
	assert(u != nil && userdata != nil, "prepared_custom_measure_test: invalid argument")
	assert(constraints.max_w >= 0, "prepared_custom_measure_test: invalid constraint")
	counts := cast(^Prepared_Custom_Counts)userdata
	counts.measure += 1
	return intrinsic_leaf(40, 20)
}

@(private = "file")
prepared_custom_render_test :: proc(u: ^Ui, rect: Rect_I32, userdata: rawptr) -> bool {
	assert(u != nil && userdata != nil, "prepared_custom_render_test: invalid argument")
	assert(rect.w >= 0 && rect.h >= 0, "prepared_custom_render_test: invalid rect")
	counts := cast(^Prepared_Custom_Counts)userdata
	counts.render += 1
	counts.rect = rect
	return false
}

@(test)
layout_space_tokens_follow_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 1.5)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 900, 300})
	testing.expect_value(t, space_px(&u, .SM), i32(12))
	testing.expect_value(t, insets_of(&u, .LG), insets(24))
	testing.expect(t, !compact(&u, 500))
	end(&u)
}

@(test)
layout_named_row_resolves_exact_slots :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(80), grow()}, gap = .SM)
	first := flex_slot_next(&u, 40)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, first, Rect_I32{0, 0, 80, 40})
	testing.expect_value(t, second, Rect_I32{88, 0, 212, 40})
}

@(test)
layout_facade_prepared_toolbar_declares_dynamic_children_once :: proc(t: ^testing.T) {
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
	begin(&u, &frame, {0, 0, 300, 100})
	before := remaining_rect(&u)
	prepared: Prepared_Ui
	prepared_begin(&prepared, intrinsic_constraints(max_w = before.w))
	prepared_row_begin(&prepared, {gap = .SM, align = .Center})
	save := prepared_button(&prepared, button_spec(&u, id(&u, "save"), "Save", {style = .Primary}))
	show_cancel := true
	if show_cancel {
		_ = prepared_button(&prepared, button_spec(&u, id(&u, "cancel"), "Cancel"))
	}
	prepared_container_end(&prepared)
	toolbar := prepared_measure(&u, &prepared)
	testing.expect_value(t, remaining_rect(&u), before)
	fit_rect := prepared_fit(&u, &prepared)
	end(&u)
	testing.expect_value(t, fit_rect.w, toolbar.w)
	testing.expect_value(t, fit_rect.h, toolbar.h)
	testing.expect(t, !prepared_activated(&prepared, save), "idle button activated")
	testing.expect_value(t, frame.degenerate_drops, 0)
}

@(test)
layout_facade_concise_prepared_group_fits_content_and_overloads :: proc(t: ^testing.T) {
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
	begin(&u, &frame, {0, 0, 500, 200})
	prepared: Prepared_Ui
	prepared_row(&u, &prepared, {gap = .SM, align = .Center})
	_ = prepared_label(&prepared, "Actions", Prepared_Label_Options{role = .Label})
	prepared_column_begin(&prepared, {gap = .XS})
	string_button := prepared_button(&prepared, "save", "Save")
	u64_button := prepared_button(&prepared, u64(7), "Seven")
	prepared_container_end(&prepared)
	widget_button := prepared_button(&prepared, id(&u, "apply"), "Apply")
	rect := prepared_end(&prepared)
	end(&u)
	testing.expect(t, rect.w > 0 && rect.w < 500, "fit group did not retain natural width")
	testing.expect(t, rect.h > 0, "fit group has no height")
	testing.expect(t, !prepared_activated(&prepared, string_button), "string button activated")
	testing.expect(t, !prepared_activated(&prepared, u64_button), "u64 button activated")
	testing.expect(t, !prepared_activated(&prepared, widget_button), "ID button activated")
	testing.expect_value(t, u.focus_count, 3)
}

@(test)
layout_facade_concise_prepared_group_resolves_width_and_wrap :: proc(t: ^testing.T) {
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
	begin(&u, &frame, {0, 0, 120, 300})
	row: Prepared_Ui
	prepared_row(&u, &row)
	_ = prepared_label(&row, "Grow", Prepared_Label_Options{}, grow())
	_ = prepared_button(&row, "button", "Button")
	row_rect := prepared_end(&row)
	column: Prepared_Ui
	prepared_column(&u, &column)
	prepared_column_begin(&column, {gap = .XS})
	_ = prepared_label(
		&column,
		"alpha beta gamma delta epsilon",
		Prepared_Label_Options{wrap = true},
	)
	prepared_container_end(&column)
	column_rect := prepared_end(&column)
	end(&u)
	testing.expect_value(t, row_rect.w, i32(120))
	testing.expect(t, column_rect.w <= 120, "wrapped group exceeded remaining width")
	testing.expect(
		t,
		column_rect.h > ui_frame_metrics(&frame).FONT_SIZE_BODY,
		"label did not wrap",
	)
}


@(test)
layout_facade_fit_builder_dynamic_children_and_outputs_are_bounded :: proc(t: ^testing.T) {
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
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	active := true
	counts: Prepared_Custom_Counts
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_column(&builder, {gap = .XS})
	fit_builder_label(&builder, "Actions")
	fit_builder_row(&builder, {gap = .XS})
	for index in 0 ..< 2 {
		fit_builder_button(&builder, u64(index + 1), "Item", &active)
	}
	show_cancel := true
	if show_cancel {
		fit_builder_button(&builder, "cancel", "Cancel", .Primary, &active)
	}
	fit_end(&builder)
	fit_builder_button(&builder, id(&u, "apply"), "Apply", &active)
	fit_builder_custom(
		&builder,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
		},
	)
	fit_end(&builder)
	before := remaining_rect(&u)
	rect := fit_render(&builder)
	after := remaining_rect(&u)
	end(&u)
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
	testing.expect(t, !active, "activation output was not reset or aggregated")
	testing.expect_value(t, u.focus_count, 4)
	testing.expect_value(t, counts.measure, 2)
	testing.expect_value(t, counts.render, 1)
	testing.expect_value(t, after.y - before.y, rect.h)
}

@(test)
layout_facade_fit_builder_reuse_clears_stale_outputs :: proc(t: ^testing.T) {
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
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	active, stale := true, true
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_row(&builder)
	fit_builder_button(&builder, "first", "First", &active)
	fit_builder_button(&builder, "stale", "Stale", &stale)
	fit_end(&builder)
	_ = fit_render(&builder)
	stale = true
	active = true
	fit_begin(&builder, &u)
	fit_builder_row(&builder)
	fit_builder_button(&builder, "second", "Second", &active)
	fit_end(&builder)
	_ = fit_render(&builder)
	end(&u)
	testing.expect_value(t, u.focus_count, 3)
	testing.expect(t, !active, "second render retained stale activation")
	testing.expect(t, stale, "second render cleared removed output")
}

@(test)
layout_facade_fit_accepts_caller_node_capacity :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	counts: Prepared_Custom_Counts
	builder: Fit_Builder
	nodes: [MAX_PREPARED_NODES + 64]Prepared_Node
	outputs: [MAX_PREPARED_NODES + 64]^bool
	fit_builder_set_storage(&builder, {nodes = nodes[:], outputs = outputs[:]})
	fit_begin(&builder, &u)
	fit_builder_flow(&builder)
	for _ in 0 ..< len(nodes) - 1 {
		fit_builder_custom(
			&builder,
			{
				measure = prepared_custom_measure_test,
				render = prepared_custom_render_test,
				userdata = &counts,
			},
		)
	}
	fit_end(&builder)
	testing.expect_value(t, builder.prepared.count, i32(len(nodes)))
	testing.expect_value(t, prepared_capacity(&builder.prepared), len(nodes))
	_ = fit_render(&builder)
	fit_builder_reset_storage(&builder)
	testing.expect_value(t, prepared_capacity(&builder.prepared), int(MAX_PREPARED_NODES))
	end(&u)
}

@(test)
layout_facade_prepared_accepts_small_caller_storage :: proc(t: ^testing.T) {
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
	defer ui_frame_destroy(&frame)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	prepared: Prepared_Ui
	nodes: [MAX_LAYOUT_DEPTH]Prepared_Node
	prepared_set_storage(&prepared, {nodes = nodes[:]})
	prepared_begin(&prepared)
	prepared_row_begin(&prepared)
	_ = prepared_label(&prepared, "Small")
	prepared_container_end(&prepared)
	size := prepared_measure(&u, &prepared)
	prepared_render_at(&u, &prepared, {0, 0, size.w, size.h})
	testing.expect_value(t, prepared_capacity(&prepared), len(nodes))
	prepared_reset_storage(&prepared)
	testing.expect_value(t, prepared_capacity(&prepared), int(MAX_PREPARED_NODES))
	end(&u)
}

@(test)
layout_facade_prepared_wrapped_label_remeasures_height_for_width :: proc(t: ^testing.T) {
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
	begin(&u, &frame, {0, 0, 300, 200})
	wide: Prepared_Ui
	prepared_begin(&wide, intrinsic_constraints(max_w = 200))
	prepared_column_begin(&wide)
	_ = prepared_label(&wide, Label_Spec{text = "alpha beta gamma delta", wrap = true})
	prepared_container_end(&wide)
	wide_size := prepared_measure(&u, &wide)
	narrow: Prepared_Ui
	prepared_begin(&narrow, intrinsic_constraints(max_w = 60))
	prepared_column_begin(&narrow)
	_ = prepared_label(&narrow, Label_Spec{text = "alpha beta gamma delta", wrap = true})
	prepared_container_end(&narrow)
	narrow_size := prepared_measure(&u, &narrow)
	testing.expect(t, narrow_size.h > wide_size.h, "narrow label did not grow")
	prepared_render_at(&u, &wide, {0, 0, wide_size.w, wide_size.h})
	prepared_render_at(&u, &narrow, {0, wide_size.h, narrow_size.w, narrow_size.h})
	end(&u)
}

@(test)
layout_facade_prepared_two_axis_and_aspect_size_are_deterministic :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	counts: Prepared_Custom_Counts
	prepared: Prepared_Ui
	prepared_begin(&prepared, intrinsic_constraints(max_w = 200, max_h = 100))
	prepared_row_begin(&prepared)
	_ = prepared_custom(
		&prepared,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
			size = {width = fixed(160), aspect = {16, 9}},
		},
	)
	prepared_container_end(&prepared)
	size := prepared_measure(&u, &prepared)
	prepared_render_at(&u, &prepared, {0, 0, size.w, size.h})
	end(&u)
	testing.expect_value(t, counts.rect.w, i32(160))
	testing.expect_value(t, counts.rect.h, i32(90))
}

@(test)
layout_facade_fit_render_at_does_not_consume_cursor :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	before := remaining_rect(&u)
	counts: Prepared_Custom_Counts
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_row(&builder)
	fit_builder_custom(
		&builder,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
		},
	)
	fit_end(&builder)
	size := fit_measure(&builder)
	target := Rect_I32{17, 29, size.w, size.h}
	fit_render_at(&builder, target)
	after := remaining_rect(&u)
	end(&u)
	testing.expect_value(t, before, after)
	testing.expect_value(t, counts.rect, target)
}

@(test)
layout_facade_prepared_attachment_is_out_of_flow_and_screen_anchored :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		screen_size = {300, 200},
	}
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	counts: Prepared_Custom_Counts
	prepared: Prepared_Ui
	prepared_begin(&prepared, intrinsic_constraints(max_w = 300))
	prepared_row_begin(&prepared)
	_ = prepared_attachment_begin(
		&prepared,
		{
			target_kind = .Screen_Rect,
			target_screen = {100, 50, 20, 10},
			target_point = .Bottom_Right,
			self_point = .Top_Left,
			z = Z_POPUP + 25,
			claim = true,
		},
	)
	_ = prepared_custom(
		&prepared,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
		},
	)
	prepared_container_end(&prepared)
	prepared_container_end(&prepared)
	size := prepared_measure(&u, &prepared)
	prepared_render_at(&u, &prepared, {0, 0, size.w, size.h})
	end(&u)

	testing.expect_value(t, size, Intrinsic_Size{})
	testing.expect_value(t, counts.rect, Rect_I32{120, 60, 40, 20})
	testing.expect_value(t, counts.render, i32(1))
	testing.expect_value(t, frame.route.cur.count, 1)
	testing.expect_value(t, frame.route.cur.zs[0], Z_POPUP + 25)
}

@(test)
layout_facade_fit_attachment_builder_renders_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		screen_size = {300, 200},
	}
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	counts: Prepared_Custom_Counts
	builder: Fit_Builder
	fit_begin(&builder, &u)
	fit_builder_row(&builder)
	fit_builder_attachment(&builder, {target_kind = .Viewport, z = Z_POPUP})
	fit_builder_custom(
		&builder,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
		},
	)
	fit_end(&builder)
	fit_end(&builder)
	_ = fit_render(&builder)
	end(&u)
	testing.expect_value(t, counts.render, i32(1))
}

@(test)
layout_facade_prepared_transition_uses_visual_geometry :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		screen_size = {300, 200},
		frame_time  = 0.05,
	}
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 200})
	state: Transition_Rect_State
	transition_rect_reset(&state, {0, 0, 10, 10})
	counts: Prepared_Custom_Counts
	prepared: Prepared_Ui
	prepared_begin(&prepared, intrinsic_constraints(max_w = 300))
	prepared_row_begin(&prepared)
	_ = prepared_custom(
		&prepared,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
			size = {transition = {state = &state}},
		},
	)
	prepared_container_end(&prepared)
	size := prepared_measure(&u, &prepared)
	prepared_render_at(&u, &prepared, {100, 100, size.w, size.h})
	end(&u)
	testing.expect(t, counts.rect.x > 0 && counts.rect.x < 100)
	testing.expect(t, counts.rect.y > 0 && counts.rect.y < 100)
	testing.expect_value(t, counts.render, i32(1))
}

@(test)
layout_facade_prepared_custom_leaf_measures_and_renders_once :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 100, 100})
	counts: Prepared_Custom_Counts
	prepared: Prepared_Ui
	prepared_begin(&prepared, intrinsic_constraints(max_w = 100))
	prepared_row_begin(&prepared)
	_ = prepared_custom(
		&prepared,
		{
			measure = prepared_custom_measure_test,
			render = prepared_custom_render_test,
			userdata = &counts,
		},
	)
	prepared_container_end(&prepared)
	_ = prepared_fit(&u, &prepared)
	end(&u)
	testing.expect_value(t, counts.measure, i32(2))
	testing.expect_value(t, counts.render, i32(1))
}

@(test)
layout_root_stays_screen_space_while_children_scale :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	ui_runtime_set_scale(&runtime, 2)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {10, 20, 200, 100})
	row_begin(&u, 20)
	rect := slot_next(&u, 30, 10)
	row_end(&u)
	end(&u)
	testing.expect_value(t, rect, Rect_I32{10, 20, 60, 20})
}

@(test)
layout_nested_container_consumes_one_flex_track :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(100), grow()})
	column_begin(&u, 100)
	child := slot_next(&u, 40, 20)
	column_end(&u)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, child, Rect_I32{0, 0, 40, 20})
	testing.expect_value(t, second, Rect_I32{100, 0, 200, 40})
}

@(test)
layout_flow_reflows_when_available_width_changes :: proc(t: ^testing.T) {
	wide: Flow_Layout
	flow_begin(&wide, {0, 0, 120, 100}, 4, 6)
	_ = flow_next(&wide, 50, 20)
	wide_second := flow_next(&wide, 50, 20)
	wide_bounds := flow_end(&wide)
	narrow: Flow_Layout
	flow_begin(&narrow, {0, 0, 80, 100}, 4, 6)
	_ = flow_next(&narrow, 50, 20)
	narrow_second := flow_next(&narrow, 50, 20)
	narrow_bounds := flow_end(&narrow)
	testing.expect_value(t, wide_second, Rect_I32{54, 0, 50, 20})
	testing.expect_value(t, wide_bounds.h, i32(20))
	testing.expect_value(t, narrow_second, Rect_I32{0, 26, 50, 20})
	testing.expect_value(t, narrow_bounds.h, i32(46))
}

@(test)
layout_end_reports_consumed_extent :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 50, 300, ROOT_EXTENT_OPEN})
	row_begin(&u, 40)
	row_end(&u)
	space(&u, .LG)
	end_y := end(&u)
	// 50 root origin + 40 row + 16 trailing token; no magic epilogue math.
	testing.expect_value(t, end_y, i32(106))
}

@(test)
layout_facade_flex_justify_packs_space_between :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)
	defer ui_frame_end(&frame)
	u: Ui
	begin(&u, &frame, {0, 0, 300, 100})
	flex_row_begin(&u, 40, {fixed(60), fixed(60)}, justify = .Space_Between)
	first := flex_slot_next(&u, 40)
	second := flex_slot_next(&u, 40)
	flex_row_end(&u)
	end(&u)
	testing.expect_value(t, first, Rect_I32{0, 0, 60, 40})
	testing.expect_value(t, second, Rect_I32{240, 0, 60, 40})
}
