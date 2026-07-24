package ui

frame_input :: proc(frame: ^Ui_Frame) -> ^Ui_Input {
	assert(frame != nil && frame.open, "frame_input: invalid frame")
	assert(frame.input != nil, "frame_input: missing input")
	return frame.input
}

get_mouse_position :: proc(frame: ^Ui_Frame) -> Vector2 {
	return frame_input(frame).mouse_position
}

get_mouse_delta :: proc(frame: ^Ui_Frame) -> Vector2 {
	return frame_input(frame).mouse_delta
}

get_mouse_wheel_move :: proc(frame: ^Ui_Frame) -> f32 {
	return frame_input(frame).mouse_wheel.y
}

get_mouse_wheel_move_v :: proc(frame: ^Ui_Frame) -> Vector2 {
	return frame_input(frame).mouse_wheel
}

is_key_pressed :: proc(frame: ^Ui_Frame, key: KeyboardKey) -> bool {
	return input_key_pressed(frame_input(frame), key)
}

is_key_pressed_repeat :: proc(frame: ^Ui_Frame, key: KeyboardKey) -> bool {
	return input_key_pressed_repeat(frame_input(frame), key)
}

is_key_released :: proc(frame: ^Ui_Frame, key: KeyboardKey) -> bool {
	return input_key_released(frame_input(frame), key)
}

is_key_down :: proc(frame: ^Ui_Frame, key: KeyboardKey) -> bool {
	return input_key_down(frame_input(frame), key)
}

is_mouse_button_pressed :: proc(frame: ^Ui_Frame, button: MouseButton) -> bool {
	return input_mouse_pressed(frame_input(frame), button)
}

is_mouse_button_released :: proc(frame: ^Ui_Frame, button: MouseButton) -> bool {
	return input_mouse_released(frame_input(frame), button)
}

is_mouse_button_down :: proc(frame: ^Ui_Frame, button: MouseButton) -> bool {
	return input_mouse_down(frame_input(frame), button)
}

request_redraw :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.output != nil, "request_redraw: invalid frame")
	frame.output.platform.request_redraw = true
}

request_redraw_in :: proc(frame: ^Ui_Frame, seconds: f64) {
	assert(frame != nil && frame.output != nil, "request_redraw_in: invalid frame")
	assert(seconds >= 0, "request_redraw_in: negative delay")
	if frame.output.platform.redraw_after == 0 || seconds < frame.output.platform.redraw_after {
		frame.output.platform.redraw_after = seconds
	}
}

set_text_input_rect :: proc(frame: ^Ui_Frame, x, y, width, height: i32) {
	assert(frame != nil && frame.output != nil, "set_text_input_rect: invalid frame")
	assert(width >= 0 && height >= 0, "set_text_input_rect: negative size")
	frame.output.platform.text_input_rect = {f32(x), f32(y), f32(width), f32(height)}
	frame.output.platform.text_input_active = true
}
