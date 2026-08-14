#+build !js
package fit

import "ingot:ui"

Test_Driver_Impl :: struct {
	runtime: ui.Ui_Runtime,
	frame:   ^ui.Ui_Frame,
	output:  ^ui.Ui_Output,
	builder: Builder,
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

Test_Driver_Frame :: proc(
	driver: ^Test_Driver,
	input: Test_Input,
	draw: Draw_Proc,
	userdata: rawptr = nil,
) -> bool {
	assert(driver != nil && driver.inner != nil, "Fit.Test_Driver_Frame: invalid driver")
	assert(draw != nil, "Fit.Test_Driver_Frame: nil callback")
	impl := cast(^Test_Driver_Impl)driver.inner
	size := input.screen_size
	if size.x <= 0 do size.x = 800
	if size.y <= 0 do size.y = 600
	resolved_input := input
	resolved_input.screen_size = size
	inner_input := test_driver_input(resolved_input)
	impl.output^ = {}
	impl.frame.output = impl.output
	ui.ui_frame_begin(impl.frame, &impl.runtime, &inner_input)
	builder_open(&impl.builder, impl.frame, {0, 0, i32(size.x), i32(size.y)})
	draw(&impl.builder, userdata)
	assert(impl.builder.inner.prepared.depth == 0, "Fit.Test_Driver_Frame: unbalanced builder")
	if !impl.builder.inner.prepared.rendered do _ = Render(&impl.builder)
	builder_close(&impl.builder)
	ui.ui_frame_end(impl.frame)
	return true
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
