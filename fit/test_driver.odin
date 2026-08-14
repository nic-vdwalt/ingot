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
	Column(&impl.builder)
	draw(&impl.builder, userdata)
	End(&impl.builder)
	assert(impl.builder.inner.prepared.depth == 0, "Fit.Test_Driver_Frame: unbalanced builder")
	if !impl.builder.inner.prepared.rendered do _ = Render(&impl.builder)
	builder_close(&impl.builder)
	ui.ui_frame_end(impl.frame)
	return true
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
	result.time = input.time
	result.screen_size = {input.screen_size.x, input.screen_size.y}
	result.character_count = min(input.character_count, len(result.characters))
	for index in 0 ..< result.character_count do result.characters[index] = input.characters[index]
	for pressed, index in input.mouse_pressed do result.mouse_pressed[index] = pressed
	for released, index in input.mouse_released do result.mouse_released[index] = released
	for down, index in input.mouse_down do result.mouse_down[index] = down
	for pressed, index in input.keys_pressed {
		if index >= len(result.keys_pressed) do break
		result.keys_pressed[index] = pressed
	}
	for down, index in input.keys_down {
		if index >= len(result.keys_down) do break
		result.keys_down[index] = down
	}
	return result
}
