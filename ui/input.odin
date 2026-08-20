package ui

INPUT_KEY_COUNT :: 349
INPUT_MOUSE_BUTTON_COUNT :: 7
INPUT_CHAR_CAP :: 64
INPUT_CLIPBOARD_CAP :: 4096
// Mirrors the gfx backend's PREEDIT_MAX so a staged IME composition is never
// truncated crossing the adapter boundary.
INPUT_PREEDIT_CAP :: 256

Ui_Input :: struct {
	screen_size:        Vec2,
	dpi_scale:          f32,
	frame_time:         f32,
	time:               f64,
	fps:                i32,
	monitor_refresh:    i32,
	mouse_position:     Vec2,
	mouse_delta:        Vec2,
	mouse_wheel:        Vec2,
	keys_pressed:       [INPUT_KEY_COUNT]bool,
	keys_repeat:        [INPUT_KEY_COUNT]bool,
	keys_released:      [INPUT_KEY_COUNT]bool,
	keys_down:          [INPUT_KEY_COUNT]bool,
	mouse_pressed:      [INPUT_MOUSE_BUTTON_COUNT]bool,
	mouse_released:     [INPUT_MOUSE_BUTTON_COUNT]bool,
	mouse_down:         [INPUT_MOUSE_BUTTON_COUNT]bool,
	characters:         [INPUT_CHAR_CAP]rune,
	character_count:    int,
	characters_dropped: int,
	clipboard:          [INPUT_CLIPBOARD_CAP]u8,
	clipboard_len:      int,
	// In-progress IME composition (UTF-8) plus the caret byte offset within
	// it. Display-only: committed text still arrives via `characters`.
	preedit:            [INPUT_PREEDIT_CAP]u8,
	preedit_len:        int,
	preedit_caret:      int,
	window_focused:     bool,
	cursor_on_screen:   bool,
	window_fullscreen:  bool,
}

input_normalize :: proc(input: ^Ui_Input) {
	assert(input != nil, "input_normalize: nil input")
	if input.character_count < 0 {
		input.character_count = 0
	} else if input.character_count > INPUT_CHAR_CAP {
		input.characters_dropped += input.character_count - INPUT_CHAR_CAP
		input.character_count = INPUT_CHAR_CAP
	}
	input.clipboard_len = clamp(input.clipboard_len, 0, INPUT_CLIPBOARD_CAP)
	input.preedit_len = clamp(input.preedit_len, 0, INPUT_PREEDIT_CAP)
	input.preedit_caret = clamp(input.preedit_caret, 0, input.preedit_len)
	assert(input.character_count >= 0 && input.character_count <= INPUT_CHAR_CAP)
	assert(input.preedit_caret >= 0 && input.preedit_caret <= input.preedit_len)
}

input_key_index :: proc(key: Key) -> int {
	index := int(key)
	if index < 0 || index >= INPUT_KEY_COUNT do return -1
	return index
}

input_mouse_index :: proc(button: Mouse_Button) -> int {
	index := int(button)
	if index < 0 || index >= INPUT_MOUSE_BUTTON_COUNT do return -1
	return index
}

input_key_pressed :: proc(input: ^Ui_Input, key: Key) -> bool {
	assert(input != nil, "input_key_pressed: nil input")
	index := input_key_index(key)
	return index >= 0 && input.keys_pressed[index]
}

input_key_pressed_repeat :: proc(input: ^Ui_Input, key: Key) -> bool {
	assert(input != nil, "input_key_pressed_repeat: nil input")
	index := input_key_index(key)
	return index >= 0 && input.keys_repeat[index]
}

input_key_released :: proc(input: ^Ui_Input, key: Key) -> bool {
	assert(input != nil, "input_key_released: nil input")
	index := input_key_index(key)
	return index >= 0 && input.keys_released[index]
}

input_key_down :: proc(input: ^Ui_Input, key: Key) -> bool {
	assert(input != nil, "input_key_down: nil input")
	index := input_key_index(key)
	return index >= 0 && input.keys_down[index]
}

input_mouse_pressed :: proc(input: ^Ui_Input, button: Mouse_Button) -> bool {
	assert(input != nil, "input_mouse_pressed: nil input")
	index := input_mouse_index(button)
	return index >= 0 && input.mouse_pressed[index]
}

input_mouse_released :: proc(input: ^Ui_Input, button: Mouse_Button) -> bool {
	assert(input != nil, "input_mouse_released: nil input")
	index := input_mouse_index(button)
	return index >= 0 && input.mouse_released[index]
}

input_mouse_down :: proc(input: ^Ui_Input, button: Mouse_Button) -> bool {
	assert(input != nil, "input_mouse_down: nil input")
	index := input_mouse_index(button)
	return index >= 0 && input.mouse_down[index]
}

input_character :: proc(input: ^Ui_Input, index: int) -> (rune, bool) {
	assert(input != nil, "input_character: nil input")
	count := clamp(input.character_count, 0, INPUT_CHAR_CAP)
	if index < 0 || index >= count do return 0, false
	return input.characters[index], true
}

input_clipboard :: proc(input: ^Ui_Input) -> string {
	assert(input != nil, "input_clipboard: nil input")
	assert(
		input.clipboard_len >= 0 && input.clipboard_len <= INPUT_CLIPBOARD_CAP,
		"input_clipboard: invalid length",
	)
	return string(input.clipboard[:input.clipboard_len])
}
