package ui

frame_input :: proc(frame: ^Ui_Frame) -> ^Ui_Input {
	assert(frame != nil, "frame_input: nil frame")
	if frame.input == nil do return &frame.input_default
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

// is_key_pressed_or_repeat is the binding every navigation key must use. The
// platform layer reports the initial keystroke and the auto-repeat ticks as
// two separate events (GLFW PRESS lands in keys_pressed, REPEAT in
// keys_repeat), so a widget that reads only one of them either drops the first
// tap or never repeats while the key is held.
is_key_pressed_or_repeat :: proc(frame: ^Ui_Frame, key: KeyboardKey) -> bool {
	input := frame_input(frame)
	return input_key_pressed(input, key) || input_key_pressed_repeat(input, key)
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
	assert(frame != nil, "request_redraw: nil frame")
	if frame.output != nil do frame.output.platform.request_redraw = true
}

request_redraw_in :: proc(frame: ^Ui_Frame, seconds: f64) {
	assert(frame != nil, "request_redraw_in: nil frame")
	assert(seconds >= 0, "request_redraw_in: negative delay")
	if frame.output == nil do return
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

sync_web_submit_button :: proc(
	frame: ^Ui_Frame,
	form_id, label: string,
	x, y, width, height, style, font_size: i32,
	enabled: bool,
) -> bool {
	assert(frame != nil && frame.output != nil, "sync_web_submit_button: invalid frame")
	assert(width >= 0 && height >= 0, "sync_web_submit_button: negative size")
	_ = form_id
	_ = style
	_ = font_size
	output := &frame.output.platform
	if output.control_count >= PLATFORM_CONTROL_CAP {
		output.controls_dropped += 1
		return false
	}
	if len(label) > PLATFORM_TEXT_CAP - output.control_text_len {
		output.controls_dropped += 1
		return false
	}
	control := &output.controls[output.control_count]
	control.kind = .Submit_Button
	control.rect = {f32(x), f32(y), f32(width), f32(height)}
	control.text_offset = output.control_text_len
	control.text_length = len(label)
	control.disabled = !enabled
	copy(output.control_text[output.control_text_len:], transmute([]u8)label)
	output.control_text_len += len(label)
	output.control_count += 1
	return false
}
