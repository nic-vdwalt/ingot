#+build !js
package fit

import "core:testing"
import "ingot:ui"

Fit_Test_Counts :: struct {
	measure: i32,
	render:  i32,
	rect:    Rect,
}

@(private = "file")
fit_test_measure :: proc(
	root: ^ui.Ui,
	constraints: ui.Intrinsic_Constraints,
	userdata: rawptr,
) -> Size {
	assert(root != nil && userdata != nil, "fit test measure: invalid argument")
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "fit test measure: invalid bounds")
	counts := cast(^Fit_Test_Counts)userdata
	counts.measure += 1
	return {48, 24, false}
}

@(private = "file")
fit_test_render :: proc(root: ^ui.Ui, rect: Rect, userdata: rawptr) -> bool {
	assert(root != nil && userdata != nil, "fit test render: invalid argument")
	assert(rect.w >= 0 && rect.h >= 0, "fit test render: invalid rect")
	counts := cast(^Fit_Test_Counts)userdata
	counts.render += 1
	counts.rect = rect
	return false
}

@(test)
fit_builder_nested_layout_renders_once :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	ui.ui_runtime_set_scale(&runtime, 1.5)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	counts: Fit_Test_Counts
	Column(&builder, {gap = .SM})
	Row(&builder, {gap = .XS})
	Custom(&builder, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	End(&builder)
	Flow(&builder, {gap_x = .XS, gap_y = .SM})
	Custom(&builder, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	End(&builder)
	Grid(&builder, {columns = 1})
	Attachment(&builder, {target_kind = .Viewport, z = ui.Z_POPUP})
	Custom(&builder, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	End(&builder)
	End(&builder)
	End(&builder)
	_ = Render(&builder)
	builder_close(&builder)
	testing.expect_value(t, counts.render, i32(3))
	testing.expect(t, counts.measure >= 3, "custom leaves were not measured")
}

@(test)
fit_public_contract_compiles :: proc(t: ^testing.T) {
	draw: Draw_Proc = fit_test_draw
	run: proc(^App, Config, Draw_Proc, rawptr) -> bool = Run
	button_string: proc(^Builder, string, string, ^bool) = Button
	button_u64: proc(^Builder, u64, string, ^bool) = Button
	measure: proc(^Builder) -> Size = Measure
	render_at: proc(^Builder, Rect) = Render_At
	session_begin: proc(^Session) -> (^Builder, bool) = Session_Begin
	testing.expect(t, draw != nil && run != nil)
	testing.expect(t, button_string != nil && button_u64 != nil)
	testing.expect(t, measure != nil && render_at != nil && session_begin != nil)
}

@(private = "file")
fit_test_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil, "fit test draw: nil builder")
	_ = userdata
	Column(builder)
	Label(builder, "Hello")
	active := false
	Button(builder, "save", "Save", &active)
	Button(builder, u64(7), "Seven", &active)
	End(builder)
}
