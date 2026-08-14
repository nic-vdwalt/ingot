#+build !js
package fit

import "base:runtime"
import "core:testing"
import "ingot:ui"

Fit_Test_Counts :: struct {
	measure: i32,
	render:  i32,
	rect:    Rect,
}

Fit_Test_Build_State :: struct {
	calls: i32,
	first: Widget_Id,
}

Fit_Test_Control_State :: struct {
	checked:  bool,
	selected: i32,
	value:    f32,
	changed:  bool,
}

@(private = "file")
fit_test_font_for_size :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	assert(data != nil && size > 0, "fit test font: invalid argument")
	return ui.Font_Id(size)
}

@(private = "file")
fit_test_text_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	assert(data != nil && font != 0, "fit test text: invalid backend")
	assert(size >= 0 && spacing >= 0, "fit test text: invalid geometry")
	return {f32(len(text)) * max(size * 0.5, 1), size}
}

@(private = "file")
fit_test_runtime :: proc(runtime: ^ui.Ui_Runtime, backend: ^i32) {
	assert(runtime != nil && backend != nil, "fit test runtime: invalid argument")
	ui.ui_runtime_init(runtime)
	ui.ui_runtime_set_text_backend(
		runtime,
		{data = backend, font_for_size = fit_test_font_for_size, measure = fit_test_text_measure},
	)
}

@(private = "file")
fit_test_measure :: proc(constraints: Constraints, userdata: rawptr) -> Size {
	assert(userdata != nil, "fit test measure: invalid argument")
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "fit test measure: invalid bounds")
	counts := cast(^Fit_Test_Counts)userdata
	counts.measure += 1
	return {48, 24, false}
}

@(private = "file")
fit_test_render :: proc(surface: ^Surface, rect: Rect, userdata: rawptr) -> bool {
	assert(surface != nil && userdata != nil, "fit test render: invalid argument")
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
	Attachment(&builder, {target_kind = .Viewport, z = Z_Order(200)})
	Custom(&builder, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	End(&builder)
	End(&builder)
	End(&builder)
	_ = Render(&builder)
	builder_close(&builder)
	testing.expect_value(t, counts.render, i32(3))
	testing.expect(t, counts.measure >= 3, "custom leaves were not measured")
}

@(private = "file")
fit_test_scoped_body :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "fit test scoped body: invalid argument")
	state := cast(^Fit_Test_Build_State)userdata
	state.calls += 1
	state.first = Id(builder, "control")
	Label(builder, "Scoped")
}

@(private = "file")
fit_test_controls :: proc(builder: ^Builder, state: ^Fit_Test_Control_State) {
	assert(builder != nil && state != nil, "fit test controls: invalid argument")
	Checkbox(builder, "checked", "Checked", &state.checked, {changed = &state.changed})
	Radio(builder, u64(7), "Choice", &state.selected, 7, {changed = &state.changed})
	Slider(builder, "value", &state.value, 0, 10, 1, "Value", {changed = &state.changed})
}

@(test)
fit_scoped_containers_invoke_once_and_restore_depth :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	state: Fit_Test_Build_State
	Column_With(&builder, fit_test_scoped_body, &state)
	testing.expect_value(t, state.calls, i32(1))
	testing.expect_value(t, builder.inner.prepared.depth, i32(0))
	_ = Render(&builder)
	builder_close(&builder)
}

@(test)
fit_scope_composes_stable_distinct_ids :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	Column(&builder)
	first, second: Fit_Test_Build_State
	Scope(&builder, "first", fit_test_scoped_body, &first)
	Scope(&builder, "second", fit_test_scoped_body, &second)
	End(&builder)
	testing.expect(t, first.first != second.first, "scoped IDs collided")
	testing.expect_value(t, first.calls, i32(1))
	testing.expect_value(t, second.calls, i32(1))
	_ = Render(&builder)
	builder_close(&builder)
}

@(test)
fit_native_controls_measure_and_render_once :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	state := Fit_Test_Control_State {
		selected = 1,
		value    = 5,
		changed  = true,
	}
	Column(&builder)
	fit_test_controls(&builder, &state)
	End(&builder)
	size := Measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 0, "native controls did not measure")
	Render_At(&builder, {0, 0, size.w, size.h})
	testing.expect(t, !state.changed, "unchanged controls did not reset output")
	testing.expect_value(t, builder.root.focus_seq, 3)
	builder_close(&builder)
}

@(test)
fit_public_contract_compiles :: proc(t: ^testing.T) {
	draw: Draw_Proc = fit_test_draw
	run: proc(_: ^App, _: Config, _: Draw_Proc, _: rawptr) -> bool = Run
	button_string: proc(_: ^Builder, _: string, _: string, _: ^bool) = Button
	button_u64: proc(_: ^Builder, _: u64, _: string, _: ^bool) = Button
	measure: proc(_: ^Builder) -> Size = Measure
	render_at: proc(_: ^Builder, _: Rect) = Render_At
	session_draw: proc(_: ^Session, _: Session_Draw_Proc, _: rawptr) -> bool = Session_Draw
	set_storage: proc(_: ^Builder, _: Storage) = Set_Storage
	reset_storage: proc(_: ^Builder) = Reset_Storage
	storage_capacity: proc(_: ^Builder) -> int = Storage_Capacity
	row_with: proc(
			_: ^Builder,
			_: Build_Proc,
			_: rawptr,
			_: Container_Options,
			_: runtime.Source_Code_Location,
		) =
		Row_With
	id_string: proc(_: ^Builder, _: string) -> Widget_Id = Id
	checkbox: proc(_: ^Builder, _: string, _: string, _: ^bool, _: Control_Options) = Checkbox
	radio: proc(_: ^Builder, _: u64, _: string, _: ^i32, _: i32, _: Control_Options) = Radio
	slider: proc(_: ^Builder, _: Widget_Id, _: ^f32, _, _, _: f32, _: string, _: Control_Options) =
		Slider
	testing.expect(t, draw != nil && run != nil)
	testing.expect(t, button_string != nil && button_u64 != nil)
	testing.expect(t, measure != nil && render_at != nil && session_draw != nil)
	testing.expect(t, set_storage != nil && reset_storage != nil && storage_capacity != nil)
	testing.expect(t, row_with != nil && id_string != nil)
	testing.expect(t, checkbox != nil && radio != nil && slider != nil)
}

@(test)
fit_surface_input_focus_paint_contract_compiles :: proc(t: ^testing.T) {
	key_down: proc(_: ^Surface, _: Key) -> bool = Surface_Key_Down
	key_repeat: proc(_: ^Surface, _: Key) -> bool = Surface_Key_Pressed_Or_Repeat
	characters: proc(_: ^Surface) -> []rune = Surface_Characters
	clipboard: proc(_: ^Surface) -> string = Surface_Clipboard
	focus_id: proc(_: string) -> Focus_Id = Focus_Id_String
	focus_link: proc(_: ^Focus_State, _: Focus_Id) -> Focus_Link = Focus_Link_To
	semantic: proc(
			_: ^Surface,
			_: Semantic_Role,
			_: Rect,
			_: string,
			_: Semantic_State,
			_: Focus_Link,
			_: string,
			_: string,
			_: int,
			_: int,
		) =
		Surface_Semantic
	circle: proc(_: ^Surface, _: Point, _: f32, _: Color) = Surface_Fill_Circle
	clip: proc(_: ^Surface, _: Rect) = Surface_Clip_Begin
	testing.expect(t, key_down != nil && key_repeat != nil)
	testing.expect(t, characters != nil && clipboard != nil)
	testing.expect(t, focus_id != nil && focus_link != nil && semantic != nil)
	testing.expect(t, circle != nil && clip != nil)
}

@(test)
fit_gallery_surface_contract_compiles :: proc(t: ^testing.T) {
	line_chart: proc(
			_: ^Surface,
			_: Rect,
			_: []Chart_Series,
			_: ^Chart_State,
			_: Chart_Options,
		) -> int =
		Surface_Line_Chart
	bar_chart: proc(
			_: ^Surface,
			_: Rect,
			_: []Chart_Series,
			_: ^Chart_State,
			_: Chart_Options,
		) -> int =
		Surface_Bar_Chart
	markdown: proc(_: ^Surface, _: Rect, _: string, _: Color) -> Markdown_Result = Surface_Markdown
	toasts: proc(_: ^Surface, _: ^Toast_State) = Surface_Toasts
	grid_end: proc(_: ^Surface, _: ^Grid_State) -> Rect = Surface_Grid_End
	chart_reset: proc(_: ^Chart_State) = Chart_Reset
	modal_open: proc(_: ^Modal_State) = Modal_Open
	modal_is_open: proc(_: ^Modal_State) -> bool = Modal_Is_Open
	menu_is_open: proc(_: ^Context_Menu_State) -> bool = Context_Menu_Is_Open
	confirm_is_open: proc(_: ^Confirm_Dialog_State) -> bool = Confirm_Dialog_Is_Open
	testing.expect(t, line_chart != nil && bar_chart != nil)
	testing.expect(t, markdown != nil && toasts != nil && grid_end != nil)
	testing.expect(t, chart_reset != nil && modal_open != nil && modal_is_open != nil)
	testing.expect(t, menu_is_open != nil && confirm_is_open != nil)
}

@(test)
fit_gallery_state_helpers_round_trip :: proc(t: ^testing.T) {
	chart := Chart_State {
		enter_anim  = 1,
		hover_index = 3,
	}
	Chart_Reset(&chart)
	testing.expect_value(t, chart.enter_anim, f32(0))
	testing.expect_value(t, chart.hover_index, -1)
	modal: Modal_State
	testing.expect(t, !Modal_Is_Open(&modal))
	Modal_Open(&modal)
	testing.expect(t, Modal_Is_Open(&modal))
	menu: Context_Menu_State
	testing.expect(t, !Context_Menu_Is_Open(&menu))
	confirm: Confirm_Dialog_State
	testing.expect(t, !Confirm_Dialog_Is_Open(&confirm))
}

@(test)
fit_caller_storage_selects_and_resets_capacity :: proc(t: ^testing.T) {
	builder: Builder
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	Set_Storage(&builder, {nodes = nodes[:], outputs = outputs[:]})
	testing.expect_value(t, Storage_Capacity(&builder), len(nodes))
	Reset_Storage(&builder)
	testing.expect_value(t, Storage_Capacity(&builder), int(STORAGE_NODE_DEFAULT))
}

@(private = "file")
fit_test_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil, "fit test draw: nil builder")
	_ = userdata
	root_container: {
		Column(builder)
		defer End(builder)
		Label(builder, "Hello")
		active := false
		Button(builder, "save", "Save", &active)
		Button(builder, u64(7), "Seven", &active)
	}
}
