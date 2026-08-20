#+build !js
package fit

import "core:testing"
import "ingot:ui"

Fit_Test_Counts :: struct {
	measure: i32,
	render:  i32,
	rect:    Rect,
}

Fit_Test_Build_State :: struct {
	calls: i32,
	depth: i32,
	first: Widget_Id,
}

Fit_Test_Control_State :: struct {
	checked:  bool,
	selected: i32,
	value:    f32,
	changed:  bool,
}

Fit_Test_Readme_State :: struct {
	continued:            bool,
	confirmation_visible: bool,
	action_calls:         i32,
}

Fit_Test_Legacy_Button_State :: struct {
	clicked:  bool,
	consumed: bool,
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
fit_root_grow_container_centers_children_in_viewport :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	ui.sem_enable(&runtime, true)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 960, 640})
	root := Center(&builder, {gap = .SM, padding = .LG})
	Label(root, "Hello from Ingot")
	Button(root, "continue", "Continue")
	size := Measure(&builder)
	testing.expect_value(t, size, Size{960, 640, false})
	Render_At(&builder, {0, 0, size.w, size.h})
	semantics := ui.sem_frame(&frame)
	testing.expect_value(t, semantics.count, 2)
	label, button := semantics.nodes[0].rect, semantics.nodes[1].rect
	testing.expect(t, abs((label.x * 2 + label.w) - 960) <= 1, "label not horizontally centered")
	testing.expect(
		t,
		abs((button.x * 2 + button.w) - 960) <= 1,
		"button not horizontally centered",
	)
	group_top, group_bottom := label.y, button.y + button.h
	testing.expect(t, abs((group_top + group_bottom) - 640) <= 1, "group not vertically centered")
	builder_close(&builder)
}

@(private = "file")
fit_test_continue :: proc(userdata: rawptr) {
	assert(userdata != nil, "fit test action: nil state")
	state := cast(^Fit_Test_Readme_State)userdata
	state.continued = true
	state.action_calls += 1
}

@(private = "file")
fit_test_readme_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "fit readme test: invalid argument")
	state := cast(^Fit_Test_Readme_State)userdata
	root := Center(builder, {gap = .SM, padding = .LG})
	Label(root, "Hello from Ingot")
	Button(root, "continue", "Continue", On(fit_test_continue, state))
	state.confirmation_visible = state.continued
	if state.continued do Label(root, "Continued")
}

@(test)
fit_button_action_runs_once_in_activating_frame :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	Test_Driver_Set_Storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	state: Fit_Test_Readme_State
	base := Test_Input {
		mouse_position = {480, 332},
		screen_size    = {960, 640},
		dpi_scale      = 1,
	}
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_readme_draw, &state))
	testing.expect(t, !state.continued && !state.confirmation_visible)
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, pressed, fit_test_readme_draw, &state))
	testing.expect(t, !state.continued && state.action_calls == 0)
	released := base
	released.mouse_released[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, released, fit_test_readme_draw, &state))
	testing.expect(t, state.continued && !state.confirmation_visible)
	testing.expect_value(t, state.action_calls, i32(1))
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_readme_draw, &state))
	testing.expect(t, state.confirmation_visible)
	testing.expect_value(t, state.action_calls, i32(1))
}

@(test)
fit_signal_is_zero_value_and_one_shot :: proc(t: ^testing.T) {
	signal: Signal
	testing.expect(t, !Signal_Peek(&signal))
	signal.pending = true
	testing.expect(t, Signal_Peek(&signal))
	testing.expect(t, Signal_Take(&signal))
	testing.expect(t, !Signal_Take(&signal))
	signal.pending = true
	Signal_Reset(&signal)
	testing.expect(t, !Signal_Peek(&signal))
}

Fit_Test_Delayed_State :: struct {
	signal:   Signal,
	consumed: i32,
}

@(private = "file")
fit_test_delayed_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "fit delayed test: invalid argument")
	state := cast(^Fit_Test_Delayed_State)userdata
	root := Center(builder)
	if Button_Delayed(root, "delayed", "Delayed", &state.signal) do state.consumed += 1
}

@(test)
fit_button_delayed_consumes_activation_on_later_build :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	state: Fit_Test_Delayed_State
	base := Test_Input {
		mouse_position = {400, 300},
		screen_size    = {800, 600},
		dpi_scale      = 1,
	}
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_delayed_draw, &state))
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, pressed, fit_test_delayed_draw, &state))
	released := base
	released.mouse_released[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, released, fit_test_delayed_draw, &state))
	testing.expect(t, Signal_Peek(&state.signal) && state.consumed == 0)
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_delayed_draw, &state))
	testing.expect(t, !Signal_Peek(&state.signal) && state.consumed == 1)
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_delayed_draw, &state))
	testing.expect_value(t, state.consumed, i32(1))
}

@(private = "file")
fit_test_legacy_button_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "fit legacy button test: invalid argument")
	state := cast(^Fit_Test_Legacy_Button_State)userdata
	if state.clicked do state.consumed = true
	root := Center(builder)
	Button(root, "legacy", "Legacy", &state.clicked)
}

@(test)
fit_button_legacy_bool_output_remains_compatible :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	Test_Driver_Set_Storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	state: Fit_Test_Legacy_Button_State
	base := Test_Input {
		mouse_position = {480, 320},
		screen_size    = {960, 640},
		dpi_scale      = 1,
	}
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_legacy_button_draw, &state))
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, pressed, fit_test_legacy_button_draw, &state))
	released := base
	released.mouse_released[0] = true
	testing.expect(t, Test_Driver_Frame(&driver, released, fit_test_legacy_button_draw, &state))
	testing.expect(t, state.clicked && !state.consumed)
	testing.expect(t, Test_Driver_Frame(&driver, base, fit_test_legacy_button_draw, &state))
	testing.expect(t, state.consumed && !state.clicked)
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
	root := Column(&builder, {gap = .SM})
	row := Row(root, {gap = .XS})
	Custom(row, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	flow := Flow(root, {gap_x = .XS, gap_y = .SM})
	Custom(flow, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	grid := Grid(root, {columns = 1})
	attachment := Attachment(grid, {target_kind = .Viewport, z = Z_Order(200)})
	Custom(attachment, {measure = fit_test_measure, render = fit_test_render, userdata = &counts})
	_ = Render(&builder)
	builder_close(&builder)
	testing.expect_value(t, counts.render, i32(3))
	testing.expect(t, counts.measure >= 3, "custom leaves were not measured")
}

@(private = "file")
fit_test_controls :: proc(parent: Parent, state: ^Fit_Test_Control_State) {
	assert(parent.builder != nil && state != nil, "fit test controls: invalid argument")
	Checkbox(parent, "checked", "Checked", &state.checked, {changed = &state.changed})
	Radio(parent, u64(7), "Choice", &state.selected, 7, {changed = &state.changed})
	Slider(parent, "value", &state.value, 0, 10, 1, "Value", {changed = &state.changed})
}

@(test)
fit_parent_handles_support_ancestor_reuse_and_scopes :: proc(t: ^testing.T) {
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
	root := Column(&builder)
	child := Row(root)
	Label(child, "Child")
	Label(root, "After child")
	first := Id(Scope(root, "first"), "control")
	second := Id(Scope(root, "second"), "control")
	testing.expect(t, first != second, "scoped IDs collided")
	nodes := builder.inner.prepared.nodes[:]
	testing.expect_value(t, nodes[1].parent, i32(0))
	testing.expect_value(t, nodes[2].parent, i32(1))
	testing.expect_value(t, nodes[3].parent, i32(0))
	testing.expect_value(t, nodes[0].child_count, i32(2))
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
	root := Column(&builder)
	fit_test_controls(root, &state)
	size := Measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 0, "native controls did not measure")
	Render_At(&builder, {0, 0, size.w, size.h})
	testing.expect(t, !state.changed, "unchanged controls did not reset output")
	testing.expect_value(t, builder.root.focus_seq, 3)
	builder_close(&builder)
}

@(test)
fit_parent_public_contract_compiles :: proc(t: ^testing.T) {
	center: proc(_: ^Builder, _: Container_Options) -> Parent = Center
	row: proc(_: Parent, _: Container_Options) -> Parent = Row
	label: proc(_: Parent, _: string, _: Label_Options) = Label
	button: proc(_: Parent, _: string, _: string, _: Action) = Button
	delayed: proc(_: Parent, _: string, _: string, _: ^Signal) -> bool = Button_Delayed
	scope: proc(_: Parent, _: string) -> Parent = Scope
	id: proc(_: Parent, _: string) -> Widget_Id = Id
	section: proc(_: Parent, _: string, _: Section_Options) -> Parent = Section
	card: proc(_: Parent, _: Card_Options) -> Parent = Card
	testing.expect(t, center != nil && row != nil && label != nil)
	testing.expect(t, button != nil && delayed != nil && scope != nil && id != nil)
	testing.expect(t, section != nil && card != nil)
}
@(test)
fit_builder_native_leaves_and_table_render :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	ui.sem_enable(&runtime, true)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	box: Input_Box
	defer Input_Box_Destroy(&box)
	root := Column(&builder, {gap = .XS})
	Text_Input(root, "name", &box, "Name", {semantics = {name = "Name"}})
	Progress(root, 0.5, {label = "Progress"})
	Separator(root)
	Spacer(root, .SM)
	columns := [?]Table_Column{{"Name", Grow(), false}, {"Value", Fixed(80), true}}
	table: Table_State
	Table_Begin(root, &table, columns[:])
	Table_Row(&table, 24)
	Table_Cell(&table, "Alpha")
	Table_Cell(&table, "42")
	Table_Row_End(&table)
	Table_End(&table)
	size := Measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 0, "native leaves did not measure")
	Render_At(&builder, {0, 0, 320, size.h})
	testing.expect_value(t, builder.root.focus_seq, 1)
	testing.expect(t, !table.open && table.row.builder == nil, "table retained lifecycle state")
	testing.expect(t, ui.sem_frame(&frame).count >= 4, "native leaves omitted semantics")
	builder_close(&builder)
}

@(test)
fit_native_scroll_clamps_and_translates_child :: proc(t: ^testing.T) {
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
	builder_open(&builder, &frame, {0, 0, 200, 100})
	state := Scroll_State {
		inner = {offset = 999},
	}
	root := Column(&builder)
	scroll := Scroll(
		root,
		"content",
		&state,
		{keyboard = true, bar = true, size = {width = Grow(), height = Fixed(100)}},
	)
	content := Column(scroll)
	Spacer(content, .XL, {size = {height = Fixed(200)}})
	size := Measure(&builder)
	testing.expect_value(t, size.h, i32(100))
	Render_At(&builder, {0, 0, 200, 100})
	testing.expect_value(t, state.inner.content_h, i32(200))
	testing.expect_value(t, state.inner.offset, f32(100))
	testing.expect_value(t, output.main.clip_count, 0)
	builder_close(&builder)
}

@(test)
fit_canvas_declares_full_root_and_renders_once :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
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
	Canvas(&builder, fit_test_render, &counts)
	_ = Render(&builder)
	testing.expect_value(t, counts.measure, i32(0))
	testing.expect_value(t, counts.render, i32(1))
	testing.expect_value(t, counts.rect, Rect{0, 0, 320, 240})
	builder_close(&builder)
}

@(test)
fit_declarative_helpers_measure_and_render :: proc(t: ^testing.T) {
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
	counts: Fit_Test_Counts
	root := Column(&builder)
	_ = Section(root, "Section", {container = {gap = .SM}})
	card := Card(root)
	Canvas_Leaf(
		card,
		{intrinsic = {w = 48, h = 24}, size = {width = Fixed(48), height = Fixed(24)}},
		fit_test_render,
		&counts,
	)
	testing.expect(t, Compact(&builder, 640), "compact branch did not use builder bounds")
	size := Measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 24, "declarative tree did not measure")
	Render_At(&builder, {0, 0, size.w, size.h})
	testing.expect_value(t, counts.render, i32(1))
	testing.expect_value(t, counts.rect.w, i32(56))
	testing.expect_value(t, counts.rect.h, i32(24))
	builder_close(&builder)
}

@(private = "file")
fit_test_region_body :: proc(region: ^Region, userdata: rawptr) {
	assert(region != nil && region.inner.open && userdata != nil)
	calls := cast(^i32)userdata
	calls^ += 1
	Region_Label(region, "Scoped")
}

@(private = "file")
fit_test_layer_body :: proc(surface: ^Surface, userdata: rawptr) {
	assert(surface != nil && userdata != nil)
	calls := cast(^i32)userdata
	calls^ += 1
}

@(private = "file")
fit_test_pane_body :: proc(surface: ^Surface, content_y: i32, userdata: rawptr) -> i32 {
	assert(surface != nil && userdata != nil)
	calls := cast(^i32)userdata
	calls^ += 1
	return content_y + 20
}

@(test)
fit_scoped_surface_helpers_restore_depth :: proc(t: ^testing.T) {
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
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	surface := Surface {
		inner = &root,
	}
	calls: i32
	_ = Region_With(&surface, {0, 0, 120, 40}, fit_test_region_body, &calls, {scope = "scope"})
	Layer_With(&surface, Z_Order(100), fit_test_layer_body, &calls)
	pane: Pane_State
	Pane_With(&surface, &pane, {0, 40, 120, 80}, fit_test_pane_body, &calls)
	testing.expect_value(t, calls, i32(3))
	testing.expect_value(t, frame.z_count, 0)
	testing.expect_value(t, frame.pane_count, 0)
	testing.expect(t, !pane.inner.open, "pane helper retained open state")
	_ = ui.end(&root)
}

@(test)
fit_region_managed_scope_balances_and_composes_ids :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	ui.ui_runtime_set_scale(&runtime, 1.5)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	surface := Surface {
		inner = &root,
	}
	first, second: Region
	first_region := Region_Open(&surface, &first, {0, 0, 160, 120}, {scope = "first"})
	first_id := Region_Id(first_region, "control")
	first_u64 := Region_Id(first_region, u64(7))
	_ = Region_Close(first_region)
	second_region := Region_Open(&surface, &second, {160, 0, 160, 120}, {scope = "second"})
	second_id := Region_Id(second_region, "control")
	_ = Region_Close(second_region)
	testing.expect(t, first_id != second_id, "managed scopes did not compose identity")
	testing.expect(t, first_id != first_u64, "string and integer identities collided")
	testing.expect_value(t, first.inner.ids.depth, 0)
	testing.expect_value(t, second.inner.ids.depth, 0)
	testing.expect_value(t, Px(&surface, i32(8)), i32(12))
	testing.expect_value(t, Px(&surface, f32(8)), f32(12))
	_ = ui.end(&root)
}

@(test)
fit_concise_layout_state_reuses_after_end :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	surface := Surface {
		inner = &root,
	}
	layout: Layout_State
	Layout_Begin(&surface, &layout, {10, 20, 100, 40})
	first := Layout_Next(&layout, 30)
	second := Layout_Remaining(&layout)
	Layout_End(&layout)
	testing.expect_value(t, first, Rect{10, 20, 100, 30})
	testing.expect_value(t, second, Rect{10, 50, 100, 10})
	testing.expect(t, !layout.open && layout.surface == nil, "layout retained borrowed surface")
	Layout_Begin(&surface, &layout, {0, 0, 50, 20})
	compat := Surface_Layout_Next(&surface, &layout, 10)
	Surface_Layout_End(&surface, &layout)
	testing.expect_value(t, compat, Rect{0, 0, 50, 10})
	_ = ui.end(&root)
}

@(test)
fit_concise_grid_flow_and_fit_column_balance :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	defer ui.ui_frame_end(&frame)
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	surface := Surface {
		inner = &root,
	}
	grid: Grid_State
	Grid_Begin(&surface, &grid, {0, 0, 100, 0}, 2, 20)
	testing.expect_value(t, Grid_Next(&grid), Rect{0, 0, 50, 20})
	_ = Grid_End(&grid)
	flow: Flow_State
	Flow_Begin(&surface, &flow, {0, 0, 100, 0}, 4, 4)
	testing.expect_value(t, Flow_Next(&flow, 30, 20), Rect{0, 0, 30, 20})
	_ = Flow_End(&flow)
	column: Fit_Column_State
	Fit_Column_Begin(&surface, &column, 0, 0, 100)
	testing.expect_value(t, Fit_Column_Next(&column, 20), Rect{0, 0, 100, 20})
	_ = Fit_Column_End(&column)
	testing.expect(t, !grid.open && !flow.open && !column.open, "explicit state remained open")
	_ = ui.end(&root)
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

@(test)
fit_button_public_overloads_preserve_explicit_size :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend: i32
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
	root := Column(&builder)
	string_options := Button_Options {
		size = {width = Fixed(40), height = Fixed(16)},
	}
	Button(root, "string", "String", string_options)
	integer_options := Button_Options {
		size = {width = Fixed(50), height = Fixed(18)},
	}
	Button(root, u64(7), "Integer", integer_options)
	widget := Id(root, "widget")
	widget_options := Button_Options {
		size = {width = Fixed(60), height = Fixed(20)},
	}
	Button(root, widget, "Widget", widget_options)
	size := Measure(&builder)
	Render_At(&builder, {0, 0, size.w, size.h})
	builder_close(&builder)
	testing.expect_value(t, size.w, i32(60))
	testing.expect_value(t, size.h, i32(54))
}

@(test)
fit_test_driver_exposes_bounded_frame_results :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	Test_Driver_Set_Storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	Test_Driver_Set_Semantics(&driver, true)
	timing, ok := Test_Driver_Frame_Timed(
		&driver,
		{screen_size = {320, 240}, dpi_scale = 1},
		fit_test_draw,
	)
	testing.expect(t, ok, "timed test frame failed")
	testing.expect(t, timing.build_ns >= 0 && timing.measure_ns >= 0)
	testing.expect(t, timing.layout_render_ns >= 0 && timing.frame_finalize_ns >= 0)
	testing.expect(t, timing.finalize_ns >= timing.measure_ns, "finalize timing excluded measure")
	testing.expect(t, timing.frame_ns >= timing.build_ns, "frame timing excluded build")
	summary := Test_Driver_Paint_Summary(&driver)
	testing.expect(t, summary.main_commands > 0 && summary.semantic_nodes > 0)
	diagnostics := Test_Driver_Diagnostics(&driver)
	testing.expect_value(t, diagnostics.main_commands_dropped, i32(0))
	when ui.UI_TELEMETRY_ENABLED {
		telemetry := Test_Driver_Telemetry(&driver)
		testing.expect(t, telemetry.main.command_appends > 0)
	}
}

@(private = "file")
fit_test_draw :: proc(builder: ^Builder, userdata: rawptr) {
	assert(builder != nil, "fit test draw: nil builder")
	_ = userdata
	root := Column(builder)
	Label(root, "Hello")
	active := false
	Button(root, "save", "Save", &active)
	Button(root, u64(7), "Seven", &active)
}
// Fit's submit modes were once value-cast straight onto ui's, but the two
// enums are declared in different orders. Fit `.Enter` (2) landed outside ui's
// two-variant range, so ti_keys_enter matched neither `.Enter` nor `.Never`
// and swallowed the key: the box neither submitted nor typed a newline. Pin
// the mapping so a reordering of either enum fails here instead of in a
// dialog nobody can dismiss.
@(test)
test_text_input_submit_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, to_submit(.Default), ui.Text_Input_Submit.Enter)
	testing.expect_value(t, to_submit(.Enter), ui.Text_Input_Submit.Enter)
	testing.expect_value(t, to_submit(.Never), ui.Text_Input_Submit.Never)
	// Modifier-gated submission is not implemented in ui; plain Enter must
	// keep inserting a newline rather than wrongly submitting.
	testing.expect_value(t, to_submit(.Ctrl_Enter), ui.Text_Input_Submit.Never)
	testing.expect_value(t, to_submit(.Mod_Enter), ui.Text_Input_Submit.Never)
}
