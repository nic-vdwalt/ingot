#+build !js
package fit

import "core:strings"
import "core:testing"
import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

@(test)
fit_variable_list_append_keeps_public_snapshot_current :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	for position in 0 ..< 257 {
		testing.expect(t, variable_list_append(&index, i64(position)))
		testing.expect_value(t, len(index.heights), position + 1)
		testing.expect_value(t, index.heights[position], i64(position))
		testing.expect_value(t, index.total, i64(position * (position + 1) / 2))
	}
	total := index.total
	testing.expect(t, !variable_list_append(&index, -1))
	testing.expect_value(t, index.total, total)
	testing.expect_value(t, len(index.heights), 257)
	testing.expect(t, variable_list_update(&index, 0, 10))
	testing.expect_value(t, variable_list_prefix(&index, 1), i64(10))
}

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

Fit_Test_Wheel_State :: struct {
	wheel:    Point,
	dominant: f32,
}

Fit_Test_Wrapped_Height_State :: struct {
	matched: bool,
	cases:   i32,
}

fit_test_icon_render :: proc(surface: ^Surface, _: Rect, _: rawptr) -> bool {
	_ = surface_icon_button(surface, Widget_Id(1), .Settings, "Settings", {10, 10, 28, 28})
	return false
}

fit_test_icon_draw :: proc(builder: ^Builder, _: rawptr) {
	canvas(builder, fit_test_icon_render)
}

fit_test_wheel_render :: proc(surface: ^Surface, _: Rect, userdata: rawptr) -> bool {
	state := cast(^Fit_Test_Wheel_State)userdata
	state.wheel = surface_wheel_v(surface)
	state.dominant = surface_wheel(surface)
	return false
}

fit_test_wheel_draw :: proc(builder: ^Builder, userdata: rawptr) {
	canvas(builder, fit_test_wheel_render, userdata)
}

fit_test_wrapped_height_render :: proc(surface: ^Surface, _: Rect, userdata: rawptr) -> bool {
	assert(surface != nil)
	assert(userdata != nil)
	state := cast(^Fit_Test_Wrapped_Height_State)userdata
	widget := surface_ui(surface)
	font_size := surface_text_size(surface, .Label)
	line_height := surface_text_line_height(surface, .Label)
	texts := [?]string {
		"alpha beta gamma",
		"alpha\nbeta",
		"longunbrokenidentifier",
		"héllo 世界",
	}
	widths := [?]i32{48, 200, 32, 40}
	state.matched = true
	for text, index in texts {
		measured := surface_text_wrapped_height(
			surface,
			text,
			widths[index],
			font_size,
			line_height,
		)
		drawn := ui.draw_text_wrapped_frame(
			widget.frame,
			0,
			i32(index) * line_height * 4,
			widths[index],
			text,
			ui.Color{255, 255, 255, 255},
			font_size,
			line_height,
		)
		state.matched = state.matched && measured == drawn && measured >= line_height
		state.cases += 1
	}
	return false
}

fit_test_wrapped_height_draw :: proc(builder: ^Builder, userdata: rawptr) {
	canvas(builder, fit_test_wrapped_height_render, userdata)
}

fit_test_noop_render :: proc(_: ^Surface, _: Rect, _: rawptr) -> bool {
	return false
}

fit_test_bridge_draw :: proc(builder: ^Builder, state: rawptr) {
	root := column(builder)
	label(root, "Bridge")
	label(root, "Body")
	if s := cast(^Fit_Test_Build_State)state; s != nil do s.calls += 1
}

fit_test_modal_draw :: proc(builder: ^Builder, state: rawptr) {
	root := column(builder)
	label(root, "Modal body")
	if s := cast(^Fit_Test_Build_State)state; s != nil do s.calls += 1
}

Fit_Buffer_Field :: struct {
	text:  ^strings.Builder,
	state: ^Text_Input_State,
	built: bool,
}

fit_buffer_field_draw :: proc(builder: ^Builder, user_data: rawptr) {
	f := cast(^Fit_Buffer_Field)user_data
	root := column(builder, {gap = .XS})
	text_input(
		root,
		"field",
		f.text,
		f.state,
		"Name",
		{semantics = {name = "Name"}, size = {width = grow()}},
	)
	f.built = true
}

fit_test_overflow_draw :: proc(builder: ^Builder, _: rawptr) {
	root := column(builder)
	canvas_leaf(
		root,
		{intrinsic = {w = 80, h = 60}, size = {width = fixed(80), height = fixed(60)}},
		fit_test_noop_render,
	)
}

@(test)
fit_standard_icon_button_is_font_independent :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	test_driver_set_semantics(&driver, true)
	testing.expect(t, test_driver_frame(&driver, {}, fit_test_icon_draw))
	summary := test_driver_paint_summary(&driver)
	diagnostics := test_driver_diagnostics(&driver)
	testing.expect(t, summary.main_geometry_commands >= 11)
	testing.expect_value(t, summary.semantic_nodes, 1)
	testing.expect_value(t, diagnostics.unsupported_glyphs, i32(0))
}

@(test)
fit_surface_wheel_preserves_both_axes :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Fit_Test_Wheel_State
	input := Test_Input {
		mouse_wheel = {3, 1},
		screen_size = {320, 240},
	}
	testing.expect(t, test_driver_frame(&driver, input, fit_test_wheel_draw, &state))
	testing.expect_value(t, state.wheel, input.mouse_wheel)
	expected_dominant := input.mouse_wheel.y
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		expected_dominant *= 5
	}
	testing.expect_value(t, state.dominant, expected_dominant)
}

@(test)
fit_surface_wrapped_height_matches_rendering :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Fit_Test_Wrapped_Height_State
	testing.expect(t, test_driver_frame(&driver, {}, fit_test_wrapped_height_draw, &state))
	testing.expect(t, state.matched)
	testing.expect_value(t, state.cases, i32(4))
}

@(test)
fit_reports_constrained_layout_overflow :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	ui.ui_frame_begin(&frame, &runtime)
	builder: Builder
	builder_open(&builder, &frame, {0, 0, 100, 100})
	fit_test_overflow_draw(&builder, nil)
	_ = measure(&builder)
	render_at(&builder, {0, 0, 40, 30})
	testing.expect_value(t, ui.ui_frame_diagnostics(&frame).layout_overflows, i32(1))
	builder_close(&builder)
	ui.ui_frame_end(&frame)
	ui.ui_frame_destroy(&frame)
}

@(test)
fit_surface_builder_bridge_renders_in_subrect :: proc(t: ^testing.T) {
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
	builder: Builder
	state: Fit_Test_Build_State
	surface_builder_with(&surface, &builder, {20, 20, 200, 120}, fit_test_bridge_draw, &state)
	testing.expect_value(t, state.calls, i32(1))
	testing.expect(t, !builder.bound, "bridge left builder bound")
	testing.expect(t, builder.inner.prepared.rendered, "bridge did not render")
	frame.markdown_telemetry.preparations = 7
	frame.markdown_telemetry.layout_walks = 11
	performance := surface_performance_snapshot(&surface)
	testing.expect_value(t, performance.markdown_preparations, u64(7))
	testing.expect_value(t, performance.markdown_layout_walks, u64(11))
	testing.expect_value(t, performance.scratch_allocations, frame.scratch.allocation_count)
	testing.expect_value(
		t,
		performance.scratch_bytes,
		frame.scratch.allocation_request_bytes + frame.scratch.resize_request_bytes,
	)
	_ = ui.end(&root)
}

@(test)
fit_surface_modal_builder_bridge_renders :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	frame: ui.Ui_Frame
	output := new(ui.Ui_Output)
	defer free(output)
	frame.output = output
	input := ui.Ui_Input {
		screen_size = {320, 240},
	}
	ui.ui_frame_begin(&frame, &runtime, &input)
	defer ui.ui_frame_end(&frame)
	root: ui.Ui
	ui.begin(&root, &frame, {0, 0, 320, 240})
	surface := Surface {
		inner = &root,
	}
	modal: Modal_State
	builder: Builder
	state: Fit_Test_Build_State
	testing.expect(t, surface_modal_open(&surface, &modal, Modal_Id(42)))
	reason := surface_modal_builder_with(
		&surface,
		&modal,
		"Modal",
		{200, 160},
		&builder,
		fit_test_modal_draw,
		&state,
		options = {placement = .Bottom},
	)
	testing.expect_value(
		t,
		modal.inner.rect.y + modal.inner.rect.h,
		i32(240) - ui.ui_frame_metrics(&frame).PADDING,
	)
	testing.expect_value(t, reason, Modal_Close_Reason.None)
	testing.expect_value(t, state.calls, i32(1))
	testing.expect(t, !builder.bound)
	root_node := builder.inner.prepared.nodes[builder.inner.prepared.root]
	testing.expect_value(t, root_node.rect.x, modal.inner.rect.x + 8)
	testing.expect_value(t, root_node.rect.y, modal.inner.rect.y + ui.ui_frame_sc(&frame, 40) + 8)
	testing.expect_value(t, builder.inner.prepared.constraints.max_w, modal.inner.rect.w - 16)
	testing.expect_value(
		t,
		builder.inner.prepared.constraints.max_h,
		modal.inner.rect.h - ui.ui_frame_sc(&frame, 40) - 16,
	)
	_ = ui.end(&root)
}

@(test)
fit_builder_text_input_accepts_caller_buffer :: proc(t: ^testing.T) {
	// The declarative text_input must accept app-owned (strings.Builder,
	// Text_Input_State) state, not only a bundled Input_Box.
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
	text: strings.Builder
	strings.builder_init(&text)
	defer strings.builder_destroy(&text)
	strings.write_string(&text, "hello")
	state: Text_Input_State
	defer text_input_state_destroy(&state)
	builder: Builder
	ctx := Fit_Buffer_Field {
		text  = &text,
		state = &state,
	}
	surface_builder_with(&surface, &builder, {20, 20, 240, 80}, fit_buffer_field_draw, &ctx)
	testing.expect(t, ctx.built, "declarative caller-buffer text input did not build")
	testing.expect(t, !builder.bound, "bridge left builder bound")
	testing.expect(t, builder.inner.prepared.rendered, "buffer input did not render")
	_ = ui.end(&root)
}

@(test)
fit_theme_facade_builds_and_validates_palette :: proc(t: ^testing.T) {
	theme := theme_from_palette(
		{
			basis = .Dark,
			ground = {18, 20, 24, 255},
			surface = {28, 31, 36, 255},
			surface_raised = {38, 42, 48, 255},
			control = {48, 53, 61, 255},
			control_hover = {62, 69, 79, 255},
			control_pressed = {78, 87, 99, 255},
			foreground = {238, 241, 244, 255},
			foreground_muted = {174, 182, 190, 255},
			accent = {126, 200, 255, 255},
			foreground_on_accent = {17, 19, 24, 255},
			danger = {255, 145, 145, 255},
			foreground_on_danger = {17, 19, 24, 255},
			success = {142, 226, 166, 255},
			border = {104, 115, 126, 255},
			focus = {126, 200, 255, 230},
		},
	)
	testing.expect(t, theme_is_valid(theme))
	theme_set_color(&theme, .Background_Selection, Color{50, 70, 96, 255})
	testing.expect_value(t, theme_get_color(theme, .Background_Selection), Color{50, 70, 96, 255})
}

@(test)
fit_session_try_theme_rejects_without_mutation :: proc(t: ^testing.T) {
	session := new(Session)
	defer free(session)
	session_init(session)
	defer session_destroy(session)
	before := ui_gfx.session_runtime(&session.inner).style
	generation := ui_gfx.session_runtime(&session.inner).generation
	invalid := theme_dark()
	theme_set_color(&invalid, .Foreground_Primary, theme_get_color(invalid, .Background))
	validation := session_try_set_theme(session, invalid)
	testing.expect_value(t, validation.code, Theme_Validation_Code.Primary_Contrast)
	testing.expect_value(t, ui_gfx.session_runtime(&session.inner).style, before)
	testing.expect_value(t, ui_gfx.session_runtime(&session.inner).generation, generation)
}

@(private = "file")
fit_test_font_for_size :: proc(data: rawptr, face: ui.Font_Face, size: i32) -> ui.Font_Id {
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
fit_test_measure :: proc(constraints: Constraints, user_data: rawptr) -> Size {
	assert(user_data != nil, "fit test measure: invalid argument")
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "fit test measure: invalid bounds")
	counts := cast(^Fit_Test_Counts)user_data
	counts.measure += 1
	return {48, 24, false}
}

@(private = "file")
fit_test_measure_wide :: proc(constraints: Constraints, user_data: rawptr) -> Size {
	assert(user_data != nil, "fit test wide measure: invalid argument")
	assert(
		constraints.max_w >= 0 && constraints.max_h >= 0,
		"fit test wide measure: invalid bounds",
	)
	counts := cast(^Fit_Test_Counts)user_data
	counts.measure += 1
	return {100, 24, false}
}

@(private = "file")
fit_test_render :: proc(surface: ^Surface, rect: Rect, user_data: rawptr) -> bool {
	assert(surface != nil && user_data != nil, "fit test render: invalid argument")
	assert(rect.w >= 0 && rect.h >= 0, "fit test render: invalid rect")
	counts := cast(^Fit_Test_Counts)user_data
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
	root := center(&builder, {gap = .SM, padding = .LG})
	label(root, "Hello from Ingot")
	button(root, "continue", "Continue")
	size := measure(&builder)
	testing.expect_value(t, size, Size{960, 640, false})
	render_at(&builder, {0, 0, size.w, size.h})
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
fit_test_continue :: proc(user_data: rawptr) {
	assert(user_data != nil, "fit test action: nil state")
	state := cast(^Fit_Test_Readme_State)user_data
	state.continued = true
	state.action_calls += 1
}

@(private = "file")
fit_test_readme_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "fit readme test: invalid argument")
	state := cast(^Fit_Test_Readme_State)user_data
	root := center(builder, {gap = .SM, padding = .LG})
	label(root, "Hello from Ingot")
	button(root, "continue", "Continue", action(fit_test_continue, state))
	state.confirmation_visible = state.continued
	if state.continued do label(root, "Continued")
}

@(test)
fit_button_action_runs_once_in_activating_frame :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	test_driver_set_storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	state: Fit_Test_Readme_State
	base := Test_Input {
		mouse_position = {480, 332},
		screen_size    = {960, 640},
		dpi_scale      = 1,
	}
	testing.expect(t, test_driver_frame(&driver, base, fit_test_readme_draw, &state))
	testing.expect(t, !state.continued && !state.confirmation_visible)
	testing.expect(t, !test_driver_redraw_requested(&driver))
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, test_driver_frame(&driver, pressed, fit_test_readme_draw, &state))
	testing.expect(t, !state.continued && state.action_calls == 0)
	testing.expect(t, !test_driver_redraw_requested(&driver))
	released := base
	released.mouse_released[0] = true
	testing.expect(t, test_driver_frame(&driver, released, fit_test_readme_draw, &state))
	testing.expect(t, state.continued && !state.confirmation_visible)
	testing.expect_value(t, state.action_calls, i32(1))
	testing.expect(t, test_driver_redraw_requested(&driver))
	testing.expect(t, test_driver_frame(&driver, base, fit_test_readme_draw, &state))
	testing.expect(t, state.confirmation_visible)
	testing.expect_value(t, state.action_calls, i32(1))
	testing.expect(t, !test_driver_redraw_requested(&driver))
}

@(test)
fit_signal_is_zero_value_and_one_shot :: proc(t: ^testing.T) {
	signal: Signal
	testing.expect(t, !signal_peek(&signal))
	signal.pending = true
	testing.expect(t, signal_peek(&signal))
	testing.expect(t, signal_take(&signal))
	testing.expect(t, !signal_take(&signal))
	signal.pending = true
	signal_reset(&signal)
	testing.expect(t, !signal_peek(&signal))
}

Fit_Test_Delayed_State :: struct {
	signal:   Signal,
	consumed: i32,
}

@(private = "file")
fit_test_delayed_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "fit delayed test: invalid argument")
	state := cast(^Fit_Test_Delayed_State)user_data
	root := center(builder)
	if button_delayed(root, "delayed", "Delayed", &state.signal) do state.consumed += 1
}

@(test)
fit_button_delayed_consumes_activation_on_later_build :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Fit_Test_Delayed_State
	base := Test_Input {
		mouse_position = {400, 300},
		screen_size    = {800, 600},
		dpi_scale      = 1,
	}
	testing.expect(t, test_driver_frame(&driver, base, fit_test_delayed_draw, &state))
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, test_driver_frame(&driver, pressed, fit_test_delayed_draw, &state))
	released := base
	released.mouse_released[0] = true
	testing.expect(t, test_driver_frame(&driver, released, fit_test_delayed_draw, &state))
	testing.expect(t, signal_peek(&state.signal) && state.consumed == 0)
	testing.expect(t, test_driver_frame(&driver, base, fit_test_delayed_draw, &state))
	testing.expect(t, !signal_peek(&state.signal) && state.consumed == 1)
	testing.expect(t, test_driver_frame(&driver, base, fit_test_delayed_draw, &state))
	testing.expect_value(t, state.consumed, i32(1))
}

@(private = "file")
fit_test_legacy_button_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "fit legacy button test: invalid argument")
	state := cast(^Fit_Test_Legacy_Button_State)user_data
	if state.clicked do state.consumed = true
	root := center(builder)
	button(root, "legacy", "Legacy", &state.clicked)
}

@(test)
fit_button_legacy_bool_output_remains_compatible :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	test_driver_set_storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	state: Fit_Test_Legacy_Button_State
	base := Test_Input {
		mouse_position = {480, 320},
		screen_size    = {960, 640},
		dpi_scale      = 1,
	}
	testing.expect(t, test_driver_frame(&driver, base, fit_test_legacy_button_draw, &state))
	pressed := base
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	testing.expect(t, test_driver_frame(&driver, pressed, fit_test_legacy_button_draw, &state))
	released := base
	released.mouse_released[0] = true
	testing.expect(t, test_driver_frame(&driver, released, fit_test_legacy_button_draw, &state))
	testing.expect(t, state.clicked && !state.consumed)
	testing.expect(t, test_driver_frame(&driver, base, fit_test_legacy_button_draw, &state))
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
	root := column(&builder, {gap = .SM})
	row_parent := row(root, {gap = .XS})
	custom(row_parent, {measure = fit_test_measure, render = fit_test_render, user_data = &counts})
	flow_parent := flow(root, {gap_x = .XS, gap_y = .SM})
	custom(
		flow_parent,
		{measure = fit_test_measure, render = fit_test_render, user_data = &counts},
	)
	grid_parent := grid(root, {columns = 1})
	attachment_parent := attachment(grid_parent, {target_kind = .Viewport, z = Z_Order(200)})
	custom(
		attachment_parent,
		{measure = fit_test_measure, render = fit_test_render, user_data = &counts},
	)
	_ = render(&builder)
	builder_close(&builder)
	testing.expect_value(t, counts.render, i32(3))
	testing.expect(t, counts.measure >= 3, "custom leaves were not measured")
}

@(private = "file")
fit_test_controls :: proc(parent: Parent, state: ^Fit_Test_Control_State) {
	assert(parent.builder != nil && state != nil, "fit test controls: invalid argument")
	checkbox(parent, "checked", "Checked", &state.checked, {changed = &state.changed})
	toggle(parent, "toggle", "toggle", &state.checked, {changed = &state.changed})
	radio(parent, u64(7), "Choice", &state.selected, 7, {changed = &state.changed})
	slider(parent, "value", &state.value, 0, 10, 1, "Value", {changed = &state.changed})
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
	root := column(&builder)
	child := row(root)
	label(child, "Child")
	label(root, "After child")
	first := id(scope(root, "first"), "control")
	second := id(scope(root, "second"), "control")
	testing.expect(t, first != second, "scoped IDs collided")
	nodes := builder.inner.prepared.nodes[:]
	testing.expect_value(t, nodes[1].parent, i32(0))
	testing.expect_value(t, nodes[2].parent, i32(1))
	testing.expect_value(t, nodes[3].parent, i32(0))
	testing.expect_value(t, nodes[0].child_count, i32(2))
	_ = render(&builder)
	builder_close(&builder)
}
@(test)
fit_controls_forward_caller_owned_motion :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	theme := theme_dark()
	ui.ui_runtime_set_theme(&runtime, theme.inner)
	output := new(ui.Ui_Output)
	defer free(output)
	frame := ui.Ui_Frame {
		output = output,
	}
	defer ui.ui_frame_destroy(&frame)
	button_motion, toggle_motion, slider_motion, tabs_motion: Control_Motion_State
	checked := false
	value: f32 = 40
	active: i32
	labels := []string{"First", "Second"}
	input := ui.Ui_Input {
		frame_time = 1.0 / 60.0,
	}
	for iteration in 0 ..< 240 {
		if iteration == 1 {
			checked = true
			active = 1
		}
		ui.ui_frame_begin(&frame, &runtime, &input)
		builder: Builder
		builder_open(&builder, &frame, {0, 0, 600, 300})
		root := column(&builder)
		before := [4]Control_Motion_State{button_motion, toggle_motion, slider_motion, tabs_motion}
		button(root, "button", "button", Button_Options{motion = &button_motion})
		toggle(root, "toggle", "toggle", &checked, {motion = &toggle_motion})
		slider(root, "slider", &value, 0, 100, 5, "Value", {motion = &slider_motion})
		tabs(root, "tabs", labels, &active, options = {motion = &tabs_motion})
		testing.expect_value(
			t,
			[4]Control_Motion_State{button_motion, toggle_motion, slider_motion, tabs_motion},
			before,
		)
		_ = measure(&builder)
		testing.expect_value(
			t,
			[4]Control_Motion_State{button_motion, toggle_motion, slider_motion, tabs_motion},
			before,
		)
		_ = render(&builder)
		builder_close(&builder)
		testing.expect(t, button_motion.hover.initialized && slider_motion.hover.initialized)
		testing.expect(t, toggle_motion.value.initialized && tabs_motion.indicator.initialized)
		if iteration == 1 {
			testing.expect_value(t, toggle_motion.value.current, f32(1))
			testing.expect(t, tabs_motion.indicator.current == tabs_motion.indicator.target)
		}
		testing.expect_value(t, value, f32(40))
		testing.expect_value(t, output.main.dropped_commands, 0)
		if iteration == 239 {
			testing.expect_value(t, toggle_motion.value.current, f32(1))
			testing.expect(t, tabs_motion.indicator.current == tabs_motion.indicator.target)
			testing.expect(t, !output.platform.request_redraw)
		}
		ui.ui_frame_end(&frame)
	}
}

@(test)
fit_region_button_overloads_preserve_layout :: proc(t: ^testing.T) {
	baseline: ui.Rect_I32
	for variant in 0 ..< 4 {
		runtime: ui.Ui_Runtime
		backend := i32(1)
		fit_test_runtime(&runtime, &backend)
		frame: ui.Ui_Frame
		output := new(ui.Ui_Output)
		frame.output = output
		ui.ui_frame_begin(&frame, &runtime)
		region: Region
		ui.begin(&region.inner, &frame, {0, 0, 300, 200})
		motion: Control_Motion_State
		clicked: bool
		switch variant {
		case 0:
			clicked = region_button(&region, "item", "Item", .Primary, false, &motion)
		case 1:
			clicked = region_button(
				&region,
				region_id(&region, "item"),
				"Item",
				.Primary,
				false,
				&motion,
			)
		case 2:
			clicked = region_button(&region, u64(7), "Item", .Primary, false, &motion)
		case 3:
			clicked = region_button(
				&region,
				region_id(&region, u64(7)),
				"Item",
				.Primary,
				false,
				&motion,
			)
		}
		remaining := ui.remaining_rect(&region.inner)
		if variant == 0 do baseline = remaining
		testing.expect_value(t, remaining, baseline)
		testing.expect(t, !clicked)
		ui.end(&region.inner)
		ui.ui_frame_end(&frame)
		ui.ui_frame_destroy(&frame)
		free(output)
		ui.ui_runtime_destroy(&runtime)
	}
}

@(test)
fit_regions_forward_caller_owned_motion :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	backend := i32(1)
	fit_test_runtime(&runtime, &backend)
	defer ui.ui_runtime_destroy(&runtime)
	theme := theme_dark()
	ui.ui_runtime_set_theme(&runtime, theme.inner)
	output := new(ui.Ui_Output)
	defer free(output)
	frame := ui.Ui_Frame {
		output = output,
	}
	defer ui.ui_frame_destroy(&frame)
	button_motion, toggle_motion, slider_motion, tabs_motion, header_motion: Control_Motion_State
	checked, open: bool
	value: f32 = 40
	active: i32
	slider: Slider_State
	input := ui.Ui_Input {
		frame_time = 1.0 / 60.0,
	}
	region: Region
	for iteration in 0 ..< 2 {
		if iteration == 1 {
			checked, open = true, true
			active = 1
		}
		ui.ui_frame_begin(&frame, &runtime, &input)
		ui.begin(&region.inner, &frame, {0, 0, 600, 300})
		_ = region_button(&region, "button", "button", motion = &button_motion)
		_ = region_toggle(&region, "toggle", "toggle", &checked, &toggle_motion)
		numeric_motion: Control_Motion_State
		_ = region_toggle(&region, u64(77), "Numeric", &checked, &numeric_motion)
		testing.expect(t, numeric_motion.value.initialized)
		_ = region_slider(
			&region,
			"slider",
			&slider,
			&value,
			0,
			100,
			5,
			240,
			"Value",
			&slider_motion,
		)
		_ = region_tab_bar(&region, "tabs", []string{"First", "Second"}, &active, &tabs_motion)
		_ = region_collapsible_header(
			&region,
			"header",
			"Details",
			&open,
			{motion = &header_motion},
		)
		ui.end(&region.inner)
		testing.expect(t, button_motion.hover.initialized && slider_motion.hover.initialized)
		testing.expect(t, toggle_motion.value.initialized && header_motion.value.initialized)
		testing.expect(t, tabs_motion.indicator.initialized)
		if iteration == 1 {
			testing.expect_value(t, toggle_motion.value.current, f32(1))
			testing.expect_value(t, header_motion.value.current, f32(1))
			testing.expect(t, tabs_motion.indicator.current == tabs_motion.indicator.target)
		}
		ui.ui_frame_end(&frame)
	}
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
	root := column(&builder)
	fit_test_controls(root, &state)
	size := measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 0, "native controls did not measure")
	render_at(&builder, {0, 0, size.w, size.h})
	testing.expect(t, !state.changed, "unchanged controls did not reset output")
	testing.expect_value(t, builder.root.focus_seq, 4)
	builder_close(&builder)
}

@(test)
fit_parent_public_contract_compiles :: proc(t: ^testing.T) {
	center_proc: proc(_: ^Builder, _: Container_Options) -> Parent = center
	row_proc: proc(_: Parent, _: Container_Options) -> Parent = row
	label_proc: proc(_: Parent, _: string, _: Label_Options) = label
	button_proc: proc(_: Parent, _: string, _: string, _: Action) = button
	delayed: proc(_: Parent, _: string, _: string, _: ^Signal) -> bool = button_delayed
	scope_proc: proc(_: Parent, _: string) -> Parent = scope
	id_proc: proc(_: Parent, _: string) -> Widget_Id = id
	section_proc: proc(_: Parent, _: string, _: Section_Options) -> Parent = section
	card_proc: proc(_: Parent, _: Card_Options) -> Parent = card
	grid_proc: proc(_: Parent, _: Grid_Options) -> Parent = grid
	grid_cell_proc: proc(_: Parent, _: Grid_Cell_Options) -> Parent = grid_cell
	toggle_proc: proc(_: Parent, _: string, _: string, _: ^bool, _: Control_Options) = toggle
	dropdown_proc: proc(
			_: Parent,
			_: string,
			_: []string,
			_: ^i32,
			_: ^Dropdown_State,
			_: string,
			_: Control_Options,
		) =
		dropdown
	combobox_proc: proc(
			_: Parent,
			_: string,
			_: ^Combobox_State,
			_: []Combobox_Item,
			_: ^u64,
			_: string,
			_: string,
			_: Control_Options,
		) =
		combobox
	testing.expect(t, center_proc != nil && row_proc != nil && label_proc != nil)
	testing.expect(t, button_proc != nil && delayed != nil && scope_proc != nil && id_proc != nil)
	testing.expect(
		t,
		section_proc != nil && card_proc != nil && grid_proc != nil && grid_cell_proc != nil,
	)
	testing.expect(t, toggle_proc != nil && dropdown_proc != nil && combobox_proc != nil)
}

@(test)
fit_track_public_contract_compiles :: proc(t: ^testing.T) {
	fixed_proc: proc(_: i32) -> Track = fixed
	grow_proc: proc(_: i32, _: i32, _: i32) -> Track = grow
	percent_proc: proc(_: f32, _: i32, _: i32) -> Track = percent
	fit_proc: proc(_: i32, _: i32, _: i32) -> Track = fit
	hug_proc: proc(_: i32, _: i32) -> Track = hug
	testing.expect(t, fixed_proc != nil && grow_proc != nil && percent_proc != nil)
	testing.expect(t, fit_proc != nil && hug_proc != nil)
}

@(test)
fit_default_intrinsic_child_hugs_before_explicit_fit :: proc(t: ^testing.T) {
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
	builder_open(&builder, &frame, {0, 0, 140, 24})
	first, second: Fit_Test_Counts
	root := row(&builder, {size = {width = fixed(140), height = fixed(24)}})
	custom(root, {measure = fit_test_measure_wide, render = fit_test_render, user_data = &first})
	custom(
		root,
		{measure = fit_test_measure_wide, render = fit_test_render, user_data = &second},
		{track = fit(100)},
	)
	_ = measure(&builder)
	render_at(&builder, {0, 0, 140, 24})
	builder_close(&builder)
	testing.expect_value(t, first.rect.w, i32(100))
	testing.expect_value(t, second.rect.w, i32(40))
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
	defer input_box_destroy(&box)
	root := column(&builder, {gap = .XS})
	text_input(root, "name", &box, "Name", {semantics = {name = "Name"}})
	progress(root, 0.5, {label = "progress"})
	separator(root)
	spacer(root, .SM)
	columns := [?]Table_Column{{"Name", grow(), false}, {"Value", fixed(80), true}}
	table: Table_State
	table_begin(root, &table, columns[:])
	table_row(&table, 24)
	table_cell(&table, "Alpha")
	table_cell(&table, "42")
	table_row_end(&table)
	table_end(&table)
	size := measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 0, "native leaves did not measure")
	render_at(&builder, {0, 0, 320, size.h})
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
		inner = {offset = 99.5},
	}
	root := column(&builder)
	scroll_parent := scroll(
		root,
		"content",
		&state,
		{keyboard = true, bar = true, size = {width = grow(), height = fixed(100)}},
	)
	content := column(scroll_parent)
	spacer(content, .XL, {size = {height = fixed(200)}})
	size := measure(&builder)
	testing.expect_value(t, size.h, i32(100))
	render_at(&builder, {0, 0, 200, 100})
	testing.expect_value(t, state.inner.content_h, i32(200))
	testing.expect_value(t, state.inner.viewport_h, i32(100))
	testing.expect_value(t, state.inner.offset, f32(99.5))
	testing.expect_value(t, output.main.clip_count, 0)
	builder_close(&builder)
}

@(test)
fit_native_horizontal_scroll_clamps_wide_row :: proc(t: ^testing.T) {
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
		inner = {offset = 150},
	}
	root := column(&builder)
	scroll_parent := scroll(
		root,
		"cards",
		&state,
		{
			axis = .Horizontal,
			keyboard = true,
			bar = true,
			size = {width = grow(), height = fixed(100)},
		},
	)
	content := row(scroll_parent, {size = {width = fixed(320), height = fixed(80)}})
	spacer(content, .XL, {size = {width = fixed(320), height = fixed(80)}})
	_ = measure(&builder)
	render_at(&builder, {0, 0, 200, 100})
	testing.expect_value(t, state.inner.content_w, i32(320))
	testing.expect_value(t, state.inner.viewport_w, i32(200))
	testing.expect_value(t, state.inner.offset, f32(120))
	builder_close(&builder)
}

@(test)
fit_native_scroll_preserves_offset_until_final_placement :: proc(t: ^testing.T) {
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
		inner = {offset = 72},
	}
	root := column(&builder, {track = grow()})
	scroll_parent := scroll(root, "content", &state, {track = grow()})
	content := column(scroll_parent)
	spacer(content, .XL, {size = {height = fixed(240)}})
	_ = measure(&builder)
	render_at(&builder, {0, 0, 200, 100})
	testing.expect_value(t, state.inner.content_h, i32(240))
	testing.expect_value(t, state.inner.viewport_h, i32(100))
	testing.expect_value(t, state.inner.offset, f32(72))
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
	canvas(&builder, fit_test_render, &counts)
	_ = render(&builder)
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
	root := column(&builder)
	_ = section(root, "section", {container = {gap = .SM}})
	card_parent := card(root)
	canvas_leaf(
		card_parent,
		{intrinsic = {w = 48, h = 24}, size = {width = fixed(48), height = fixed(24)}},
		fit_test_render,
		&counts,
	)
	testing.expect(t, compact(&builder, 640), "compact branch did not use builder bounds")
	size := measure(&builder)
	testing.expect(t, size.w > 0 && size.h > 24, "declarative tree did not measure")
	render_at(&builder, {0, 0, size.w, size.h})
	testing.expect_value(t, counts.render, i32(1))
	testing.expect_value(t, counts.rect.w, i32(56))
	testing.expect_value(t, counts.rect.h, i32(24))
	builder_close(&builder)
}

@(private = "file")
fit_test_region_body :: proc(region: ^Region, user_data: rawptr) {
	assert(region != nil && region.inner.open && user_data != nil)
	calls := cast(^i32)user_data
	calls^ += 1
	region_label(region, "Scoped")
}

@(private = "file")
fit_test_layer_body :: proc(surface: ^Surface, user_data: rawptr) {
	assert(surface != nil && user_data != nil)
	calls := cast(^i32)user_data
	calls^ += 1
}

@(private = "file")
fit_test_reserved_layer_body :: proc(surface: ^Surface, user_data: rawptr) {
	assert(surface != nil && user_data != nil)
	calls := cast(^i32)user_data
	calls^ += 1
	surface_fill_rect(surface, {0, 0, 10, 10}, {255, 0, 0, 255})
	surface_fill_rect(surface, {10, 0, 10, 10}, {0, 255, 0, 255})
}

@(private = "file")
fit_test_pane_body :: proc(surface: ^Surface, content_y: i32, user_data: rawptr) -> i32 {
	assert(surface != nil && user_data != nil)
	calls := cast(^i32)user_data
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
	_ = region_with(&surface, {0, 0, 120, 40}, fit_test_region_body, &calls, {scope = "scope"})
	layer_with(&surface, Z_Order(100), fit_test_layer_body, &calls)
	pane: Pane_State
	pane_with(&surface, &pane, {0, 40, 120, 80}, fit_test_pane_body, &calls)
	testing.expect_value(t, calls, i32(3))
	testing.expect_value(t, frame.z_count, 0)
	testing.expect_value(t, frame.pane_count, 0)
	testing.expect(t, !pane.inner.open, "pane helper retained open state")
	_ = ui.end(&root)
}

@(test)
fit_reserved_layer_retains_exact_paint_and_restores_depth :: proc(t: ^testing.T) {
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
	accepted := layer_with_reserved_paint(
		&surface,
		Z_Order(600),
		2,
		fit_test_reserved_layer_body,
		&calls,
	)
	testing.expect(t, accepted)
	testing.expect_value(t, calls, i32(1))
	testing.expect_value(t, output.overlay.count, 2)
	testing.expect_value(t, frame.z_count, 0)
	testing.expect_value(t, frame.pane_count, 0)
	_ = ui.end(&root)
}

@(test)
fit_reserved_layer_rejects_atomically_when_overlay_is_saturated :: proc(t: ^testing.T) {
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
	ui.layer_begin(&frame, ui.Z_Order(700))
	for _ in 0 ..< PAINT_COMMAND_CAP - 1 {
		ui.draw_rectangle(&frame, 0, 0, 1, 1, {255, 255, 255, 255})
	}
	ui.layer_end(&frame)
	before := output.overlay.count
	calls: i32
	accepted := layer_with_reserved_paint(
		&surface,
		Z_Order(600),
		2,
		fit_test_reserved_layer_body,
		&calls,
	)
	testing.expect(t, !accepted)
	testing.expect_value(t, calls, i32(0))
	testing.expect_value(t, output.overlay.count, before)
	testing.expect_value(t, output.overlay.dropped_commands, 0)
	testing.expect_value(t, frame.z_count, 0)
	testing.expect_value(t, frame.pane_count, 0)
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
	first_region := region_open(&surface, &first, {0, 0, 160, 120}, {scope = "first"})
	first_id := region_id(first_region, "control")
	first_u64 := region_id(first_region, u64(7))
	_ = region_close(first_region)
	second_region := region_open(&surface, &second, {160, 0, 160, 120}, {scope = "second"})
	second_id := region_id(second_region, "control")
	_ = region_close(second_region)
	testing.expect(t, first_id != second_id, "managed scopes did not compose identity")
	testing.expect(t, first_id != first_u64, "string and integer identities collided")
	testing.expect_value(t, first.inner.ids.depth, 0)
	testing.expect_value(t, second.inner.ids.depth, 0)
	testing.expect_value(t, px(&surface, i32(8)), i32(12))
	testing.expect_value(t, px(&surface, f32(8)), f32(12))
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
	layout_begin(&surface, &layout, {10, 20, 100, 40})
	first := layout_next(&layout, 30)
	second := layout_remaining(&layout)
	layout_end(&layout)
	testing.expect_value(t, first, Rect{10, 20, 100, 30})
	testing.expect_value(t, second, Rect{10, 50, 100, 10})
	testing.expect(t, !layout.open && layout.surface == nil, "layout retained borrowed surface")
	layout_begin(&surface, &layout, {0, 0, 50, 20})
	compat := surface_layout_next(&surface, &layout, 10)
	surface_layout_end(&surface, &layout)
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
	grid_begin(&surface, &grid, {0, 0, 100, 0}, 2, 20)
	testing.expect_value(t, grid_next(&grid), Rect{0, 0, 50, 20})
	_ = grid_end(&grid)
	flow: Flow_State
	flow_begin(&surface, &flow, {0, 0, 100, 0}, 4, 4)
	testing.expect_value(t, flow_next(&flow, 30, 20), Rect{0, 0, 30, 20})
	_ = flow_end(&flow)
	column: Fit_Column_State
	fit_column_begin(&surface, &column, 0, 0, 100)
	testing.expect_value(t, fit_column_next(&column, 20), Rect{0, 0, 100, 20})
	_ = fit_column_end(&column)
	testing.expect(t, !grid.open && !flow.open && !column.open, "explicit state remained open")
	_ = ui.end(&root)
}

@(test)
fit_vertical_cursor_composes_and_reuses_caller_state :: proc(t: ^testing.T) {
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
	cursor: Vertical_Cursor_State
	vertical_cursor_begin(&surface, &cursor, 10, 20, 180, gap = 6)
	line := vertical_cursor_text(&cursor, "Summary", .Label, .Secondary)
	header := vertical_cursor_section_header(&cursor, "DETAILS")
	bounds := vertical_cursor_end(&cursor)
	testing.expect_value(t, header.y, line.y + line.h + 6)
	testing.expect_value(t, bounds.h, line.h + 6 + header.h)
	testing.expect(t, !cursor.open && cursor.surface == nil, "cursor retained borrowed surface")
	paint_count := output.main.count
	vertical_cursor_begin_bounded(&surface, &cursor, {0, 0, 100, 10})
	clamped := vertical_cursor_section_header(&cursor, "CLAMPED")
	_ = vertical_cursor_end(&cursor)
	testing.expect_value(t, clamped, Rect{0, 0, 100, 10})
	testing.expect_value(t, output.main.count, paint_count)
	testing.expect_value(t, vertical_cursor_overflow(&cursor), header.h - 10)
	_ = ui.end(&root)
}

@(test)
fit_surface_input_focus_paint_contract_compiles :: proc(t: ^testing.T) {
	key_down: proc(_: ^Surface, _: Key) -> bool = surface_key_down
	key_repeat: proc(_: ^Surface, _: Key) -> bool = surface_key_pressed_or_repeat
	characters: proc(_: ^Surface) -> []rune = surface_characters
	clipboard: proc(_: ^Surface) -> string = surface_clipboard
	focus_id: proc(_: string) -> Focus_Id = focus_id_string
	focus_link: proc(_: ^Focus_State, _: Focus_Id) -> Focus_Link = focus_link_to
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
		surface_semantic
	circle: proc(_: ^Surface, _: Point, _: f32, _: Color) = surface_fill_circle
	clip: proc(_: ^Surface, _: Rect) = surface_clip_begin
	texture: proc(_: ^Surface, _: u32, _: Float_Rect, _: Float_Rect, _: Color) =
		surface_draw_texture
	reserved: proc(
			_: ^Surface,
			_: Z_Order,
			_: int,
			_: Layer_Build_Proc,
			_: rawptr,
			_: Float_Rect,
		) -> bool =
		layer_with_reserved_paint
	testing.expect(t, key_down != nil && key_repeat != nil)
	testing.expect(t, characters != nil && clipboard != nil)
	testing.expect(t, focus_id != nil && focus_link != nil && semantic != nil)
	testing.expect(t, circle != nil && clip != nil && reserved != nil && texture != nil)
}

@(test)
fit_caret_policy_preserves_canonical_behavior :: proc(t: ^testing.T) {
	at_epoch := caret_blink_phase(5, 5, 0.5, false)
	testing.expect(t, at_epoch.visible && at_epoch.animate)
	testing.expect_value(t, at_epoch.seconds_until_toggle, f64(0.5))
	before_epoch := caret_blink_phase(4, 5, 0.5, false)
	testing.expect(t, before_epoch.visible && before_epoch.animate)
	hidden := caret_blink_phase(5.5, 5, 0.5, false)
	testing.expect(t, !hidden.visible && hidden.animate)
	visible := caret_blink_phase(6, 5, 0.5, false)
	testing.expect(t, visible.visible && visible.animate)
	reduced := caret_blink_phase(100, 5, 0.5, true)
	testing.expect(t, reduced.visible && !reduced.animate)
	testing.expect_value(t, reduced.seconds_until_toggle, f64(0))
	metrics := Text_Metrics{12, 4, 3, 19}
	resolved := caret_metrics_or_fallback(metrics, true, 16, 20)
	testing.expect_value(t, resolved, metrics)
	fallback := caret_metrics_or_fallback({}, false, 16, 20)
	testing.expect_value(t, fallback, Text_Metrics{16, 0, 0, 20})
	rect := caret_rect({10, 20}, 34, metrics, 2)
	testing.expect_value(t, rect, Float_Rect{34, 20, 2, 16})
}

@(test)
fit_caret_surface_contract_compiles :: proc(t: ^testing.T) {
	timestamp: proc(_: ^Surface) -> f64 = surface_timestamp
	metrics: proc(_: ^Surface, _: i32) -> (Text_Metrics, bool) = surface_text_metrics
	hit: proc(_: ^Surface, _: string, _: i32, _: i32) -> int = surface_text_sized_byte_at_x
	redraw: proc(_: ^Surface, _: f64) = request_redraw_in
	reduced: proc(_: ^Surface) -> bool = surface_reduced_motion
	testing.expect(t, timestamp != nil && metrics != nil && hit != nil)
	testing.expect(t, redraw != nil && reduced != nil)
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
		surface_line_chart
	bar_chart: proc(
			_: ^Surface,
			_: Rect,
			_: []Chart_Series,
			_: ^Chart_State,
			_: Chart_Options,
		) -> int =
		surface_bar_chart
	markdown: proc(_: ^Surface, _: Rect, _: string, _: Color) -> Markdown_Result = surface_markdown
	markdown_context: proc(
			_: ^Surface,
			_: []string,
			_: Markdown_Reference_Resolver,
			_: rawptr,
		) -> Markdown_Context =
		markdown_context_create
	markdown_prepare: proc(_: ^Markdown_Context, _: i32, _: string) -> Markdown_Prepared =
		markdown_prepare
	markdown_measure: proc(_: ^Markdown_Context, _: ^Markdown_Prepared, _: ^i32) -> i32 =
		markdown_prepared_measure
	markdown_hit: proc(_: ^Markdown_Context, _: ^Markdown_Prepared, _, _, _, _: i32) -> int =
		markdown_prepared_hit_test
	markdown_source_y: proc(_: ^Markdown_Context, _: ^Markdown_Prepared, _: int) -> i32 =
		markdown_prepared_source_y
	toasts: proc(_: ^Surface, _: ^Toast_State) = surface_toasts
	grid_end: proc(_: ^Surface, _: ^Grid_State) -> Rect = surface_grid_end
	chart_reset_proc: proc(_: ^Chart_State) = chart_reset
	modal_open_proc: proc(_: ^Modal_State) = modal_open
	modal_is_open_proc: proc(_: ^Modal_State) -> bool = modal_is_open
	modal_builder: proc(
			_: ^Surface,
			_: ^Modal_State,
			_: string,
			_: [2]i32,
			_: ^Builder,
			_: Draw_Proc,
			_: rawptr,
			_: Modal_Options,
			_: i32,
		) -> Modal_Close_Reason =
		surface_modal_builder_with
	menu_is_open: proc(_: ^Context_Menu_State) -> bool = context_menu_is_open
	confirm_is_open: proc(_: ^Confirm_Dialog_State) -> bool = confirm_dialog_is_open
	testing.expect(t, line_chart != nil && bar_chart != nil)
	testing.expect(t, markdown_context != nil)
	testing.expect(t, markdown != nil && markdown_prepare != nil && markdown_measure != nil)
	testing.expect(
		t,
		markdown_hit != nil && markdown_source_y != nil && toasts != nil && grid_end != nil,
	)
	testing.expect(
		t,
		chart_reset_proc != nil && modal_open_proc != nil && modal_is_open_proc != nil,
	)
	testing.expect(t, modal_builder != nil)
	testing.expect(t, menu_is_open != nil && confirm_is_open != nil)
}

@(test)
fit_gallery_state_helpers_round_trip :: proc(t: ^testing.T) {
	chart := Chart_State {
		enter_anim  = 1,
		hover_index = 3,
	}
	chart_reset(&chart)
	testing.expect_value(t, chart.enter_anim, f32(0))
	testing.expect_value(t, chart.hover_index, -1)
	modal: Modal_State
	testing.expect(t, !modal_is_open(&modal))
	modal_open(&modal)
	testing.expect(t, modal_is_open(&modal))
	menu: Context_Menu_State
	testing.expect(t, !context_menu_is_open(&menu))
	confirm: Confirm_Dialog_State
	testing.expect(t, !confirm_dialog_is_open(&confirm))
}

@(test)
fit_caller_storage_selects_and_resets_capacity :: proc(t: ^testing.T) {
	builder: Builder
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	customs: [STORAGE_NODE_DEFAULT + 64]Custom_Spec
	set_storage(&builder, {nodes = nodes[:], outputs = outputs[:], customs = customs[:]})
	testing.expect_value(t, storage_capacity(&builder), len(nodes))
	testing.expect_value(t, custom_capacity(&builder), len(customs))
	reset_storage(&builder)
	testing.expect_value(t, storage_capacity(&builder), int(STORAGE_NODE_DEFAULT))
	testing.expect_value(t, custom_capacity(&builder), int(STORAGE_NODE_DEFAULT))
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
	root := column(&builder)
	string_options := Button_Options {
		size = {width = fixed(40), height = fixed(16)},
	}
	button(root, "string", "String", string_options)
	integer_options := Button_Options {
		size = {width = fixed(50), height = fixed(18)},
	}
	button(root, u64(7), "Integer", integer_options)
	widget := id(root, "widget")
	widget_options := Button_Options {
		size = {width = fixed(60), height = fixed(20)},
	}
	button(root, widget, "Widget", widget_options)
	size := measure(&builder)
	render_at(&builder, {0, 0, size.w, size.h})
	builder_close(&builder)
	testing.expect_value(t, size.w, i32(60))
	testing.expect_value(t, size.h, i32(54))
}

@(test)
fit_test_driver_exposes_bounded_frame_results :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	nodes: [STORAGE_NODE_DEFAULT + 64]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 64]^bool
	test_driver_set_storage(&driver, {nodes = nodes[:], outputs = outputs[:]})
	test_driver_set_semantics(&driver, true)
	active := false
	timing, ok := test_driver_frame_timed(
		&driver,
		{screen_size = {320, 240}, dpi_scale = 1},
		fit_test_draw,
		&active,
	)
	testing.expect(t, ok, "timed test frame failed")
	testing.expect(t, timing.build_ns >= 0 && timing.measure_ns >= 0)
	testing.expect(t, timing.layout_render_ns >= 0 && timing.frame_finalize_ns >= 0)
	testing.expect(t, timing.finalize_ns >= timing.measure_ns, "finalize timing excluded measure")
	testing.expect(t, timing.frame_ns >= timing.build_ns, "frame timing excluded build")
	summary := test_driver_paint_summary(&driver)
	testing.expect(t, summary.main_commands > 0 && summary.semantic_nodes > 0)
	diagnostics := test_driver_diagnostics(&driver)
	testing.expect_value(t, diagnostics.main_commands_dropped, i32(0))
	when ui.UI_TELEMETRY_ENABLED {
		telemetry := test_driver_telemetry(&driver)
		testing.expect(t, telemetry.main.command_appends > 0)
	}
}

@(private = "file")
fit_test_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "fit test draw: invalid argument")
	active := cast(^bool)user_data
	root := column(builder)
	label(root, "Hello")
	button(root, "save", "Save", active)
	button(root, u64(7), "Seven", active)
}
// fit's submit modes are mapped explicitly because the façade declaration
// order remains independent from ui's implementation enum.
@(test)
test_text_input_submit_mapping :: proc(t: ^testing.T) {
	testing.expect_value(t, to_submit(.Default), ui.Text_Input_Submit.Enter)
	testing.expect_value(t, to_submit(.Enter), ui.Text_Input_Submit.Enter)
	testing.expect_value(t, to_submit(.Never), ui.Text_Input_Submit.Never)
	testing.expect_value(t, to_submit(.Ctrl_Enter), ui.Text_Input_Submit.Ctrl_Enter)
	testing.expect_value(t, to_submit(.Mod_Enter), ui.Text_Input_Submit.Mod_Enter)
}

@(test)
fit_failed_init_binding_is_retryable :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	nodes: [STORAGE_NODE_DEFAULT + 1]Storage_Node
	outputs: [STORAGE_NODE_DEFAULT + 1]^bool
	set_storage(&app.builder, {nodes = nodes[:], outputs = outputs[:]})
	first := i32(1)
	second := i32(2)
	callbacks := Callbacks {
		draw = fit_test_draw,
	}
	testing.expect(t, !app_init_finish(app, callbacks, &first, false))
	testing.expect_value(t, get_state(app), State.Empty)
	testing.expect(t, app.draw == nil && app.shutdown == nil && app.user_data == nil)
	testing.expect_value(t, storage_capacity(&app.builder), len(nodes))
	testing.expect(t, !app_init_finish(app, callbacks, &second, false))
	testing.expect(t, app.draw == nil && app.shutdown == nil && app.user_data == nil)
}


@(test)
fit_window_flag_mapping_is_semantic :: proc(t: ^testing.T) {
	all := Window_Flags {
		.Fullscreen,
		.Resizable,
		.Undecorated,
		.Transparent,
		.Msaa_4x,
		.Vsync,
		.Hidden,
		.Always_Run,
		.Minimized,
		.Maximized,
		.Unfocused,
		.Topmost,
		.High_Dpi,
		.Mouse_Passthrough,
		.Borderless_Windowed,
		.Interlaced,
		.No_Focus_On_Hover,
	}
	expected := gfx.ConfigFlags {
		.FULLSCREEN_MODE,
		.WINDOW_RESIZABLE,
		.WINDOW_UNDECORATED,
		.WINDOW_TRANSPARENT,
		.MSAA_4X_HINT,
		.VSYNC_HINT,
		.WINDOW_HIDDEN,
		.WINDOW_ALWAYS_RUN,
		.WINDOW_MINIMIZED,
		.WINDOW_MAXIMIZED,
		.WINDOW_UNFOCUSED,
		.WINDOW_TOPMOST,
		.WINDOW_HIGHDPI,
		.WINDOW_MOUSE_PASSTHROUGH,
		.BORDERLESS_WINDOWED_MODE,
		.INTERLACED_HINT,
		.WINDOW_NO_FOCUS_ON_HOVER,
	}
	testing.expect_value(t, to_window_flags({}), gfx.ConfigFlags{})
	testing.expect_value(t, to_window_flags(all), expected)
}

@(test)
fit_input_and_semantic_mappings_are_semantic :: proc(t: ^testing.T) {
	testing.expect_value(t, to_key(.Null), ui.Key.KEY_NULL)
	testing.expect_value(t, to_key(.A), ui.Key.A)
	testing.expect_value(t, to_key(.Keypad_Enter), ui.Key.KP_ENTER)
	testing.expect_value(t, to_key(.Right_Super), ui.Key.RIGHT_SUPER)
	testing.expect_value(t, to_mouse_button(.Left), ui.Mouse_Button.LEFT)
	testing.expect_value(t, to_mouse_button(.Back), ui.Mouse_Button.BACK)
	testing.expect_value(t, to_cursor(.Default), ui.Cursor.DEFAULT)
	testing.expect_value(t, to_cursor(.Not_Allowed), ui.Cursor.NOT_ALLOWED)
	testing.expect_value(t, to_semantic_role(.None), ui.Sem_Role.None)
	testing.expect_value(t, to_semantic_role(.List_Box), ui.Sem_Role.List_Box)
}
