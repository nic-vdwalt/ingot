package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

INPUT_CHARACTER_DRAIN_MAX :: rl.CHAR_Q
#assert(INPUT_CHARACTER_DRAIN_MAX == ui.INPUT_CHAR_CAP)

capture_input :: proc(input: ^ui.Ui_Input) {
	assert(input != nil, "capture_input: nil input")
	input^ = {}
	input.screen_size = {f32(rl.GetScreenWidth()), f32(rl.GetScreenHeight())}
	input.dpi_scale = rl.GetWindowScaleDPI().x
	input.frame_time = rl.GetFrameTime()
	input.time = rl.GetTime()
	input.fps = rl.GetFPS()
	input.monitor_refresh = rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
	input.mouse_position = vec_to_ui(rl.GetMousePosition())
	input.mouse_delta = vec_to_ui(rl.GetMouseDelta())
	input.mouse_wheel = vec_to_ui(rl.GetMouseWheelMoveV())
	input.window_focused = rl.IsWindowFocused()
	input.cursor_on_screen = rl.IsCursorOnScreen()
	input.window_fullscreen = rl.IsWindowFullscreen()
	clipboard := rl.GetClipboardText()
	if clipboard != nil {
		clipboard_text := string(clipboard)
		input.clipboard_len = min(len(clipboard_text), ui.INPUT_CLIPBOARD_CAP)
		copy(input.clipboard[:input.clipboard_len], transmute([]u8)clipboard_text)
	}
	assert(
		input.clipboard_len >= 0 && input.clipboard_len <= ui.INPUT_CLIPBOARD_CAP,
		"capture_input: invalid clipboard length",
	)

	for index in 0 ..< ui.INPUT_KEY_COUNT {
		key := rl.KeyboardKey(index)
		input.keys_pressed[index] = rl.IsKeyPressed(key)
		input.keys_repeat[index] = rl.IsKeyPressedRepeat(key)
		input.keys_released[index] = rl.IsKeyReleased(key)
		input.keys_down[index] = rl.IsKeyDown(key)
	}
	for index in 0 ..< ui.INPUT_MOUSE_BUTTON_COUNT {
		button := rl.MouseButton(index)
		input.mouse_pressed[index] = rl.IsMouseButtonPressed(button)
		input.mouse_released[index] = rl.IsMouseButtonReleased(button)
		input.mouse_down[index] = rl.IsMouseButtonDown(button)
	}
	characters_drained := 0
	for characters_drained < INPUT_CHARACTER_DRAIN_MAX {
		character := rl.GetCharPressed()
		if character == 0 do break
		characters_drained += 1
		if input.character_count < ui.INPUT_CHAR_CAP {
			input.characters[input.character_count] = character
			input.character_count += 1
		} else {
			input.characters_dropped += 1
		}
	}
	assert(input.character_count <= ui.INPUT_CHAR_CAP)
	assert(characters_drained <= INPUT_CHARACTER_DRAIN_MAX)
}
