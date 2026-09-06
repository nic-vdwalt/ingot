package ui

INPUT_KEY_COUNT :: 349
INPUT_MOUSE_BUTTON_COUNT :: 7
INPUT_CHAR_CAP :: 64
INPUT_POINTER_EVENT_CAP :: 64
INPUT_CLIPBOARD_CAP :: 16 * 1024
// Mirrors the gfx backend's PREEDIT_MAX so a staged IME composition is never
// truncated crossing the adapter boundary.
INPUT_PREEDIT_CAP :: 256

Pointer_Id :: distinct u32

Pointer_Type :: enum u8 {
	Unknown,
	Mouse,
	Touch,
	Pen,
}

Pointer_Event_Kind :: enum u8 {
	Move,
	Down,
	Up,
	Cancel,
}

Pointer_Button :: enum i8 {
	None    = -1,
	Left    = 0,
	Right   = 1,
	Middle  = 2,
	Side    = 3,
	Extra   = 4,
	Forward = 5,
	Back    = 6,
}

Pointer_Buttons :: distinct u16

Pointer_Event :: struct {
	id:           Pointer_Id,
	position:     Vec2,
	pressure:     f32,
	buttons:      Pointer_Buttons,
	kind:         Pointer_Event_Kind,
	pointer_type: Pointer_Type,
	button:       Pointer_Button,
	primary:      bool,
}

Ui_Input :: struct {
	screen_size:               Vec2,
	dpi_scale:                 f32,
	frame_time:                f32,
	time:                      f64,
	fps:                       i32,
	monitor_refresh:           i32,
	mouse_position:            Vec2,
	mouse_delta:               Vec2,
	mouse_wheel:               Vec2,
	keys_pressed:              [INPUT_KEY_COUNT]bool,
	keys_repeat:               [INPUT_KEY_COUNT]bool,
	keys_released:             [INPUT_KEY_COUNT]bool,
	keys_down:                 [INPUT_KEY_COUNT]bool,
	mouse_pressed:             [INPUT_MOUSE_BUTTON_COUNT]bool,
	mouse_released:            [INPUT_MOUSE_BUTTON_COUNT]bool,
	mouse_down:                [INPUT_MOUSE_BUTTON_COUNT]bool,
	pointer_events:            [INPUT_POINTER_EVENT_CAP]Pointer_Event,
	pointer_event_count:       int,
	pointer_events_overflowed: bool,
	characters:                [INPUT_CHAR_CAP]rune,
	character_count:           int,
	characters_dropped:        int,
	clipboard:                 string,
	// In-progress IME composition (UTF-8) plus the caret byte offset within
	// it. Display-only: committed text still arrives via `characters`.
	preedit:                   [INPUT_PREEDIT_CAP]u8,
	preedit_len:               int,
	preedit_caret:             int,
	window_focused:            bool,
	cursor_on_screen:          bool,
	window_fullscreen:         bool,
}

input_normalize :: proc(input: ^Ui_Input) {
	assert(input != nil, "input_normalize: nil input")
	if input.pointer_event_count < 0 {
		input.pointer_event_count = 0
		input.pointer_events_overflowed = true
	} else if input.pointer_event_count > INPUT_POINTER_EVENT_CAP {
		input.pointer_event_count = INPUT_POINTER_EVENT_CAP
		input.pointer_events_overflowed = true
	}
	if input.character_count < 0 {
		input.character_count = 0
	} else if input.character_count > INPUT_CHAR_CAP {
		input.characters_dropped += input.character_count - INPUT_CHAR_CAP
		input.character_count = INPUT_CHAR_CAP
	}
	input.clipboard = input.clipboard[:input_clip_utf8(input.clipboard, INPUT_CLIPBOARD_CAP)]
	input.preedit_len = clamp(input.preedit_len, 0, INPUT_PREEDIT_CAP)
	input.preedit_caret = clamp(input.preedit_caret, 0, input.preedit_len)
	assert(input.pointer_event_count >= 0 && input.pointer_event_count <= INPUT_POINTER_EVENT_CAP)
	assert(input.character_count >= 0 && input.character_count <= INPUT_CHAR_CAP)
	assert(len(input.clipboard) <= INPUT_CLIPBOARD_CAP)
	assert(input.preedit_caret >= 0 && input.preedit_caret <= input.preedit_len)
}

input_clip_utf8 :: proc(text: string, capacity: int) -> int {
	assert(capacity >= 0, "input_clip_utf8: negative capacity")
	count := min(len(text), capacity)
	for count > 0 && count < len(text) && (text[count] & 0xc0) == 0x80 do count -= 1
	assert(count >= 0 && count <= capacity, "input_clip_utf8: invalid result")
	return count
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
	assert(len(input.clipboard) <= INPUT_CLIPBOARD_CAP, "input_clipboard: invalid length")
	return input.clipboard
}
