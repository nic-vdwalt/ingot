package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

INPUT_CHARACTER_DRAIN_MAX :: rl.CHAR_Q
#assert(INPUT_CHARACTER_DRAIN_MAX == ui.INPUT_CHAR_CAP)
#assert(rl.PREEDIT_MAX == ui.INPUT_PREEDIT_CAP)

pointer_snapshot_sanitize :: proc(input: ^ui.Ui_Input) {
	assert(input != nil, "pointer_snapshot_sanitize: nil input")
	if input.window_focused && input.cursor_on_screen do return
	input.cursor_on_screen = false
	input.mouse_position = {-1, -1}
	input.mouse_delta = {}
	input.mouse_wheel = {}
	input.mouse_pressed = {}
	input.mouse_released = {}
	input.mouse_down = {}
	assert(input.mouse_delta == {} && input.mouse_wheel == {})
}

capture_input_context :: proc(ctx: ^rl.Context, input: ^ui.Ui_Input) {
	assert(ctx != nil && input != nil, "capture_input_context: nil argument")
	input^ = {}
	input.screen_size = {f32(rl.context_screen_width(ctx)), f32(rl.context_screen_height(ctx))}
	input.dpi_scale = rl.context_window_scale_dpi(ctx).x
	input.frame_time = rl.context_frame_time(ctx)
	input.time = rl.context_time(ctx)
	input.fps = rl.context_fps(ctx)
	input.monitor_refresh = rl.GetMonitorRefreshRate(rl.GetCurrentMonitor())
	input.mouse_position = vec_to_ui(rl.context_get_mouse_position(ctx))
	input.mouse_delta = vec_to_ui(rl.context_get_mouse_delta(ctx))
	input.mouse_wheel = vec_to_ui(rl.context_get_mouse_wheel_move_v(ctx))
	input.window_focused = rl.context_window_focused(ctx)
	input.cursor_on_screen = rl.context_is_cursor_on_screen(ctx)
	input.window_fullscreen = rl.context_window_fullscreen(ctx)
	clipboard := rl.context_get_clipboard_text(ctx)
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
		input.keys_pressed[index] = rl.context_is_key_pressed(ctx, key)
		input.keys_repeat[index] = rl.context_is_key_pressed_repeat(ctx, key)
		input.keys_released[index] = rl.context_is_key_released(ctx, key)
		input.keys_down[index] = rl.context_is_key_down(ctx, key)
	}
	for index in 0 ..< ui.INPUT_MOUSE_BUTTON_COUNT {
		button := rl.MouseButton(index)
		input.mouse_pressed[index] = rl.context_is_mouse_button_pressed(ctx, button)
		input.mouse_released[index] = rl.context_is_mouse_button_released(ctx, button)
		input.mouse_down[index] = rl.context_is_mouse_button_down(ctx, button)
	}
	characters_drained := 0
	for characters_drained < INPUT_CHARACTER_DRAIN_MAX {
		character := rl.context_get_char_pressed(ctx)
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
	// Preedit is global backend state (one OS input method), not per-context.
	preedit, preedit_caret := rl.GetPreedit()
	input.preedit_len = min(len(preedit), ui.INPUT_PREEDIT_CAP)
	copy(input.preedit[:input.preedit_len], transmute([]u8)preedit)
	input.preedit_caret = clamp(preedit_caret, 0, input.preedit_len)
	pointer_snapshot_sanitize(input)
}
