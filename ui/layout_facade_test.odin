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
layout_facade_fit_tree_is_uniform_content_sized_and_exactly_once :: proc(t: ^testing.T) {
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
	counts: Prepared_Custom_Counts
	string_active, u64_active, widget_active, custom_active: bool
	root := fit_row(
		{gap = .SM, align = .Center},
		{
			fit_label("Actions", {role = .Label}),
			fit_column(
				{gap = .XS},
				{
					fit_button("save", "Save", .Primary, &string_active),
					fit_button(u64(7), "Seven", &u64_active),
				},
			),
			fit_button(id(&u, "apply"), "Apply", &widget_active),
			fit_custom(
				{
					measure = prepared_custom_measure_test,
					render = prepared_custom_render_test,
					userdata = &counts,
				},
				{activated = &custom_active},
			),
		},
	)
	rect := fit_tree(&u, root)
	end(&u)
	testing.expect(t, rect.w > 0 && rect.w < 500, "fit tree did not retain natural width")
	testing.expect(t, rect.h > 0, "fit tree has no height")
	testing.expect(t, !string_active && !u64_active && !widget_active, "idle button activated")
	testing.expect(t, !custom_active, "idle custom leaf activated")
	testing.expect_value(t, counts.render, i32(1))
	testing.expect_value(t, u.focus_count, 3)
}

@(test)
layout_facade_fit_tree_resolves_width_and_wrapping :: proc(t: ^testing.T) {
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
	row_rect := fit_tree(
		&u,
		fit_row({}, {fit_label("Grow", {track = grow()}), fit_button("button", "Button")}),
	)
	column_rect := fit_tree(
		&u,
		fit_column({}, {fit_label("alpha beta gamma delta epsilon", {wrap = true})}),
	)
	end(&u)
	testing.expect_value(t, row_rect.w, i32(120))
	testing.expect(t, column_rect.w <= 120, "wrapped tree exceeded remaining width")
	testing.expect(
		t,
		column_rect.h > ui_frame_metrics(&frame).FONT_SIZE_BODY,
		"tree label did not wrap",
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
layout_facade_fit_nodes_remains_a_dynamic_slice_escape_hatch :: proc(t: ^testing.T) {
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
	active := true
	children := fit_nodes(&u, 1)
	append(&children, fit_button("item", "Item", &active))
	rect := fit_tree(&u, fit_row({}, children[:]))
	end(&u)
	testing.expect(t, !active, "activation output was not reset")
	testing.expect_value(t, u.focus_count, 1)
	testing.expect(t, rect.w > 0 && rect.h > 0, "dynamic slice tree was empty")
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
