package ui

frame_input :: proc(frame: ^Ui_Frame) -> ^Ui_Input {
	assert(frame != nil, "frame_input: nil frame")
	if frame.input == nil do return &frame.input_default
	return frame.input
}

frame_viewport :: proc(frame: ^Ui_Frame) -> Rect_I32 {
	assert(frame != nil, "frame_viewport: nil frame")
	input := frame_input(frame)
	return {0, 0, i32(input.screen_size.x), i32(input.screen_size.y)}
}

frame_time :: proc(frame: ^Ui_Frame) -> f32 {
	return frame_input(frame).frame_time
}

frame_timestamp :: proc(frame: ^Ui_Frame) -> f64 {
	return frame_input(frame).time
}

frame_dpi_scale :: proc(frame: ^Ui_Frame) -> f32 {
	return frame_input(frame).dpi_scale
}

frame_fps :: proc(frame: ^Ui_Frame) -> i32 {
	return frame_input(frame).fps
}

frame_monitor_refresh :: proc(frame: ^Ui_Frame) -> i32 {
	return frame_input(frame).monitor_refresh
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

// frame_characters returns the printable characters typed this frame.
//
// The platform adapter drains the backend's character queue into Ui_Input at
// the top of every frame, so polling the backend from view code always yields
// nothing — the queue is already empty. Views must read this snapshot instead.
frame_characters :: proc(frame: ^Ui_Frame) -> []rune {
	assert(frame != nil, "frame_characters: nil frame")
	input := frame_input(frame)
	assert(
		input.character_count >= 0 && input.character_count <= INPUT_CHAR_CAP,
		"frame_characters: character count out of range",
	)
	return input.characters[:input.character_count]
}

// frame_characters_consume discards the characters typed this frame so a key
// that acted as a shortcut is not also typed into a text input drawn later in
// the same frame.
frame_characters_consume :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "frame_characters_consume: nil frame")
	input := frame_input(frame)
	assert(input != nil, "frame_characters_consume: nil input")
	input.character_count = 0
}

// frame_user_input_active reports whether the user touched the mouse or
// keyboard this frame, so a caller can stay at full frame rate instead of
// dropping into the event-driven idle strategy mid-gesture.
//
// This must read the Ui_Input snapshot for the same reason as
// frame_characters: the backend queues have already been drained.
frame_user_input_active :: proc(frame: ^Ui_Frame) -> bool {
	assert(frame != nil, "frame_user_input_active: nil frame")
	input := frame_input(frame)
	assert(input != nil, "frame_user_input_active: nil input")
	if input.mouse_delta != {0, 0} do return true
	if input.mouse_wheel != {0, 0} do return true
	if input.character_count > 0 do return true
	for down in input.mouse_down {
		if down do return true
	}
	for pressed in input.keys_pressed {
		if pressed do return true
	}
	for down in input.keys_down {
		if down do return true
	}
	return false
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
