#+build !js
package fit

import "core:time"
import "ingot:ui"

Test_Driver_Impl :: struct {
	runtime:     ui.Ui_Runtime,
	frame:       ^ui.Ui_Frame,
	output:      ^ui.Ui_Output,
	builder:     Builder,
	telemetry:   Frame_Telemetry,
	diagnostics: Frame_Diagnostics,
}

Test_Driver_Init :: proc(driver: ^Test_Driver) {
	assert(driver != nil && driver.inner == nil, "Fit.Test_Driver_Init: invalid driver")
	impl := new(Test_Driver_Impl)
	impl.frame = new(ui.Ui_Frame)
	impl.output = new(ui.Ui_Output)
	ui.ui_runtime_init(&impl.runtime)
	ui.ui_runtime_set_text_backend(
		&impl.runtime,
		{data = impl, font_for_size = test_driver_font, measure = test_driver_measure},
	)
	driver.inner = impl
}

Test_Driver_Destroy :: proc(driver: ^Test_Driver) {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Destroy: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	assert(!impl.builder.bound, "Fit.Test_Driver_Destroy: frame open")
	ui.ui_frame_destroy(impl.frame)
	ui.ui_runtime_destroy(&impl.runtime)
	free(impl.output)
	free(impl.frame)
	free(impl)
	driver^ = {}
}

Test_Driver_Set_Storage :: proc(driver: ^Test_Driver, storage: Storage) {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Set_Storage: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	assert(!impl.builder.bound, "Fit.Test_Driver_Set_Storage: frame open")
	Set_Storage(&impl.builder, storage)
}

Test_Driver_Set_Semantics :: proc(driver: ^Test_Driver, enabled: bool) {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Set_Semantics: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	assert(!impl.builder.bound, "Fit.Test_Driver_Set_Semantics: frame open")
	ui.sem_enable(&impl.runtime, enabled)
}

Test_Driver_Set_Backend_Measure_Cache :: proc(driver: ^Test_Driver, enabled: bool) {
	assert(driver != nil && driver.inner != nil, "Fit test driver cache: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	assert(!impl.builder.bound, "Fit test driver cache: frame open")
	ui.ui_runtime_set_backend_measure_cache_enabled(&impl.runtime, enabled)
}

Test_Driver_Frame :: proc(
	driver: ^Test_Driver,
	input: Test_Input,
	draw: Draw_Proc,
	userdata: rawptr = nil,
) -> bool {
	_, ok := Test_Driver_Frame_Timed(driver, input, draw, userdata)
	return ok
}

Test_Driver_Frame_Timed :: proc(
	driver: ^Test_Driver,
	input: Test_Input,
	draw: Draw_Proc,
	userdata: rawptr = nil,
) -> (
	Frame_Timing,
	bool,
) {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Frame_Timed: invalid driver")
	assert(draw != nil, "Fit.Test_Driver_Frame_Timed: nil callback")
	impl := cast(^Test_Driver_Impl)driver.inner
	size := input.screen_size
	if size.x <= 0 do size.x = 800
	if size.y <= 0 do size.y = 600
	resolved_input := input
	resolved_input.screen_size = size
	inner_input := test_driver_input(resolved_input)
	impl.output^ = {}
	impl.frame.output = impl.output
	frame_started := time.tick_now()
	ui.ui_frame_begin(impl.frame, &impl.runtime, &inner_input)
	builder_open(&impl.builder, impl.frame, {0, 0, i32(size.x), i32(size.y)})
	build_started := time.tick_now()
	draw(&impl.builder, userdata)
	build_ns := time.duration_nanoseconds(time.tick_since(build_started))
	assert(
		impl.builder.inner.prepared.depth == 0,
		"Fit.Test_Driver_Frame_Timed: unbalanced builder",
	)
	finalize_started := time.tick_now()
	measure_started := time.tick_now()
	size_measured := Measure(&impl.builder)
	measure_ns := time.duration_nanoseconds(time.tick_since(measure_started))
	render_started := time.tick_now()
	Render_At(&impl.builder, {0, 0, size_measured.w, size_measured.h})
	layout_render_ns := time.duration_nanoseconds(time.tick_since(render_started))
	close_started := time.tick_now()
	builder_close(&impl.builder)
	builder_close_ns := time.duration_nanoseconds(time.tick_since(close_started))
	frame_finalize_started := time.tick_now()
	ui.ui_frame_finalize(impl.frame)
	frame_finalize_ns := time.duration_nanoseconds(time.tick_since(frame_finalize_started))
	finalize_ns := time.duration_nanoseconds(time.tick_since(finalize_started))
	frame_ns := time.duration_nanoseconds(time.tick_since(frame_started))
	impl.telemetry = test_driver_telemetry(ui.ui_frame_telemetry(impl.frame))
	impl.diagnostics = test_driver_diagnostics(ui.ui_frame_diagnostics(impl.frame))
	ui.ui_frame_release(impl.frame)
	return {
			build_ns,
			measure_ns,
			layout_render_ns,
			builder_close_ns,
			frame_finalize_ns,
			finalize_ns,
			frame_ns,
		},
		true
}

Test_Driver_Redraw_Requested :: proc(driver: ^Test_Driver) -> bool {
	assert(
		driver != nil && driver.inner != nil,
		"Fit.Test_Driver_Redraw_Requested: invalid driver",
	)
	impl := cast(^Test_Driver_Impl)driver.inner
	assert(!impl.builder.bound, "Fit.Test_Driver_Redraw_Requested: frame open")
	return impl.output.platform.request_redraw
}

Test_Driver_Paint_Summary :: proc(driver: ^Test_Driver) -> Paint_Summary {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Paint_Summary: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	main_geometry := test_driver_geometry_count(&impl.output.main)
	overlay_geometry := test_driver_geometry_count(&impl.output.overlay)
	return {
		main_commands = impl.output.main.count,
		main_text_bytes = impl.output.main.text_len,
		main_geometry_commands = main_geometry,
		main_clip_depth = impl.output.main.clip_count,
		overlay_commands = impl.output.overlay.count,
		overlay_text_bytes = impl.output.overlay.text_len,
		overlay_geometry = overlay_geometry,
		overlay_clip_depth = impl.output.overlay.clip_count,
		semantic_nodes = impl.frame.semantics.cur.count,
	}
}

Test_Driver_Telemetry :: proc(driver: ^Test_Driver) -> Frame_Telemetry {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Telemetry: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	return impl.telemetry
}

Test_Driver_Diagnostics :: proc(driver: ^Test_Driver) -> Frame_Diagnostics {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Diagnostics: invalid driver")
	impl := cast(^Test_Driver_Impl)driver.inner
	return impl.diagnostics
}

@(private = "file")
test_driver_telemetry :: proc(value: ui.Ui_Frame_Telemetry) -> Frame_Telemetry {
	return {
		scratch_allocations = value.scratch_allocation_count,
		scratch_resizes = value.scratch_resize_count,
		scratch_allocation_bytes = value.scratch_allocation_request_bytes,
		scratch_resize_bytes = value.scratch_resize_request_bytes,
		main = {
			value.main.command_append_count,
			value.main.text_append_count,
			value.main.text_bytes_copied,
			value.main.command_growth_count,
			value.main.text_growth_count,
		},
		overlay = {
			value.overlay.command_append_count,
			value.overlay.text_append_count,
			value.overlay.text_bytes_copied,
			value.overlay.command_growth_count,
			value.overlay.text_growth_count,
		},
		text_input_full_paths = value.text_input_full_path_count,
		text_input_inactive_paths = value.text_input_inactive_candidates,
		phases = {
			value.prepared.phase_ns[.Measure_Natural],
			value.prepared.phase_ns[.Resolve_Size],
			value.prepared.phase_ns[.Measure_Resolved],
			value.prepared.phase_ns[.Place],
			value.prepared.phase_ns[.Render_Tree],
			value.prepared.phase_ns[.Output_Clear],
			value.prepared.phase_ns[.Finalize_Routes],
			value.prepared.phase_ns[.Finalize_Semantics],
			value.prepared.phase_ns[.Finalize_Lifetimes],
		},
		description_nodes = value.prepared.description_nodes,
		leaf_nodes = value.prepared.leaf_nodes,
		container_nodes = value.prepared.container_nodes,
		maximum_depth = value.prepared.maximum_depth,
		fixed_leaf_nodes = value.prepared.fixed_leaf_nodes,
		intrinsic_leaf_nodes = value.prepared.intrinsic_leaf_nodes,
		width_dependent_leaf_nodes = value.prepared.width_dependent_leaf_nodes,
		dependency_node_visits = value.prepared.dependency_node_visits,
		dependency_child_visits = value.prepared.dependency_child_visits,
		natural_node_visits = value.prepared.natural_node_visits,
		resolve_node_visits = value.prepared.resolve_node_visits,
		remeasure_node_visits = value.prepared.remeasure_node_visits,
		width_assignment_visits = value.prepared.width_assignment_visits,
		resolved_measure_visits = value.prepared.resolved_measure_visits,
		placement_node_visits = value.prepared.placement_node_visits,
		render_node_visits = value.prepared.render_node_visits,
		child_run_visits = value.prepared.child_run_visits,
		specialized_nodes = value.prepared.specialized_nodes,
		generic_fallback_nodes = value.prepared.generic_fallback_nodes,
		natural_leaf_measures = value.prepared.natural_leaf_measures,
		resolved_leaf_measures = value.prepared.resolved_leaf_measures,
		fixed_leaf_measure_skips = value.prepared.fixed_leaf_measure_skips,
		container_measures = value.prepared.container_measures,
		width_assignments = value.prepared.width_assignments,
		placed_nodes = value.prepared.placed_nodes,
		rendered_nodes = value.prepared.rendered_nodes,
		activation_outputs = value.prepared.activation_outputs,
		render_relayouts = value.prepared.render_relayouts,
		measure_cache_hits = value.measure_cache_hits,
		measure_cache_misses = value.measure_cache_misses,
		measure_cache_policy_bypasses = value.measure_cache_policy_bypasses,
	}
}

@(private = "file")
test_driver_diagnostics :: proc(value: ui.Ui_Frame_Diagnostics) -> Frame_Diagnostics {
	return {
		value.input_characters_dropped,
		value.degenerate_widgets_dropped,
		value.semantic_nodes_dropped,
		value.semantic_focus_dropped,
		value.semantic_actions_dropped,
		value.semantic_id_collisions,
		value.semantic_text_truncations,
		value.main_commands_dropped,
		value.main_text_bytes_dropped,
		value.overlay_commands_dropped,
		value.overlay_text_bytes_dropped,
		value.platform_controls_dropped,
	}
}

@(private = "file")
test_driver_geometry_count :: proc(list: ^ui.Paint_List) -> int {
	assert(list != nil, "Fit test driver: nil paint list")
	count := 0
	for index in 0 ..< list.count {
		kind := list.commands[index].kind
		if kind != .Text && kind != .Codepoint && kind != .Clip_Begin && kind != .Clip_End {
			count += 1
		}
	}
	return count
}

@(private = "file")
test_driver_font :: proc(data: rawptr, size: i32) -> ui.Font_Id {
	assert(data != nil && size > 0, "Fit test driver: invalid font")
	return ui.Font_Id(size)
}

@(private = "file")
test_driver_measure :: proc(
	data: rawptr,
	font: ui.Font_Id,
	text: string,
	size, spacing: f32,
) -> ui.Vec2 {
	assert(data != nil && font != 0, "Fit test driver: invalid text backend")
	assert(size >= 0 && spacing >= 0, "Fit test driver: invalid text geometry")
	return {f32(len(text)) * max(size * 0.5, 1), size}
}

@(private = "file")
test_driver_input :: proc(input: Test_Input) -> ui.Ui_Input {
	result: ui.Ui_Input
	result.mouse_position = {input.mouse_position.x, input.mouse_position.y}
	result.mouse_delta = {input.mouse_delta.x, input.mouse_delta.y}
	result.mouse_wheel = {input.mouse_wheel.x, input.mouse_wheel.y}
	result.frame_time = input.frame_time
	result.time = input.time
	result.dpi_scale = input.dpi_scale
	result.fps = input.fps
	result.monitor_refresh = input.monitor_refresh
	result.screen_size = {input.screen_size.x, input.screen_size.y}
	result.character_count = min(input.character_count, len(result.characters))
	for index in 0 ..< result.character_count do result.characters[index] = input.characters[index]
	result.clipboard_len = min(input.clipboard_len, len(result.clipboard))
	for index in 0 ..< result.clipboard_len do result.clipboard[index] = input.clipboard[index]
	for pressed, index in input.mouse_pressed do result.mouse_pressed[index] = pressed
	for released, index in input.mouse_released do result.mouse_released[index] = released
	for down, index in input.mouse_down do result.mouse_down[index] = down
	for pressed, index in input.keys_pressed {
		if index >= len(result.keys_pressed) do break
		result.keys_pressed[index] = pressed
	}
	for repeated, index in input.keys_repeat {
		if index >= len(result.keys_repeat) do break
		result.keys_repeat[index] = repeated
	}
	for released, index in input.keys_released {
		if index >= len(result.keys_released) do break
		result.keys_released[index] = released
	}
	for down, index in input.keys_down {
		if index >= len(result.keys_down) do break
		result.keys_down[index] = down
	}
	return result
}
