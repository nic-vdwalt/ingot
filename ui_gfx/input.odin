package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

INPUT_CHARACTER_DRAIN_MAX :: rl.CHAR_Q
#assert(INPUT_CHARACTER_DRAIN_MAX == ui.INPUT_CHAR_CAP)
#assert(rl.POINTER_EVENTS_MAX == ui.INPUT_POINTER_EVENT_CAP)
#assert(rl.PREEDIT_MAX == ui.INPUT_PREEDIT_CAP)
#assert(ui.INPUT_KEY_COUNT == 349)
#assert(ui.INPUT_MOUSE_BUTTON_COUNT == 7)
#assert(int(ui.Key.KEY_NULL) == int(rl.KeyboardKey.KEY_NULL))
#assert(int(ui.Key.RIGHT_SUPER) == int(rl.KeyboardKey.RIGHT_SUPER))
#assert(int(ui.Mouse_Button.LEFT) == int(rl.MouseButton.LEFT))
#assert(int(ui.Mouse_Button.BACK) == int(rl.MouseButton.BACK))
#assert(int(ui.Pointer_Type.Mouse) == int(rl.Pointer_Type.Mouse))
#assert(int(ui.Pointer_Type.Pen) == int(rl.Pointer_Type.Pen))
#assert(int(ui.Pointer_Event_Kind.Move) == int(rl.Pointer_Event_Kind.Move))
#assert(int(ui.Pointer_Event_Kind.Cancel) == int(rl.Pointer_Event_Kind.Cancel))
#assert(int(ui.Pointer_Button.None) == int(rl.Pointer_Button.None))
#assert(int(ui.Pointer_Button.Back) == int(rl.Pointer_Button.Back))

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

snapshot_clipboard :: proc(adapter: ^Adapter, input: ^ui.Ui_Input, text: string) {
	assert(adapter != nil && input != nil, "snapshot_clipboard: nil argument")
	count := ui.input_clip_utf8(text, len(adapter.clipboard))
	copy(adapter.clipboard[:count], text)
	input.clipboard = string(adapter.clipboard[:count])
	assert(len(input.clipboard) <= ui.INPUT_CLIPBOARD_CAP)
}

snapshot_pointer_events :: proc(
	input: ^ui.Ui_Input,
	events: []rl.Pointer_Event,
	overflowed: bool,
) {
	assert(input != nil, "snapshot_pointer_events: nil input")
	input.pointer_event_count = min(len(events), ui.INPUT_POINTER_EVENT_CAP)
	input.pointer_events_overflowed = overflowed || len(events) > ui.INPUT_POINTER_EVENT_CAP
	for index in 0 ..< input.pointer_event_count {
		event := events[index]
		input.pointer_events[index] = {
			id           = ui.Pointer_Id(event.id),
			position     = vec_to_ui(event.position),
			pressure     = event.pressure,
			buttons      = ui.Pointer_Buttons(event.buttons),
			kind         = ui.Pointer_Event_Kind(event.kind),
			pointer_type = ui.Pointer_Type(event.pointer_type),
			button       = ui.Pointer_Button(event.button),
			primary      = event.primary,
		}
	}
	assert(
		input.pointer_event_count >= 0 && input.pointer_event_count <= ui.INPUT_POINTER_EVENT_CAP,
	)
}

capture_clipboard_context :: proc(adapter: ^Adapter, input: ^ui.Ui_Input) {
	assert(
		adapter != nil && adapter.gfx_context != nil,
		"capture_clipboard_context: invalid adapter",
	)
	assert(input != nil, "capture_clipboard_context: nil input")
	paste := ui.input_key_pressed(input, .V) || ui.input_key_pressed_repeat(input, .V)
	modifier :=
		ui.input_key_down(input, .LEFT_CONTROL) ||
		ui.input_key_down(input, .RIGHT_CONTROL) ||
		ui.input_key_down(input, .LEFT_SUPER) ||
		ui.input_key_down(input, .RIGHT_SUPER)
	if !paste || !modifier do return
	clipboard := rl.context_get_clipboard_text(adapter.gfx_context)
	if clipboard == nil do return
	snapshot_clipboard(adapter, input, string(clipboard))
	assert(len(input.clipboard) <= ui.INPUT_CLIPBOARD_CAP)
}

capture_input_context :: proc(adapter: ^Adapter, input: ^ui.Ui_Input) {
	assert(adapter != nil && adapter.gfx_context != nil, "capture_input_context: invalid adapter")
	assert(input != nil, "capture_input_context: nil input")
	ctx := adapter.gfx_context
	input^ = {}
	input.screen_size = {f32(rl.context_screen_width(ctx)), f32(rl.context_screen_height(ctx))}
	input.dpi_scale = rl.context_window_scale_dpi(ctx).x
	input.frame_time = rl.context_frame_time(ctx)
	input.time = rl.context_time(ctx)
	input.fps = rl.context_fps(ctx)
	input.monitor_refresh = rl.context_monitor_refresh_rate(ctx)
	input.mouse_position = vec_to_ui(rl.context_get_mouse_position(ctx))
	input.mouse_delta = vec_to_ui(rl.context_get_mouse_delta(ctx))
	input.mouse_wheel = vec_to_ui(rl.context_get_mouse_wheel_move_v(ctx))
	input.window_focused = rl.context_window_focused(ctx)
	input.cursor_on_screen = rl.context_is_cursor_on_screen(ctx)
	input.window_fullscreen = rl.context_window_fullscreen(ctx)

	for index in 0 ..< ui.INPUT_KEY_COUNT {
		key := rl.KeyboardKey(index)
		input.keys_pressed[index] = rl.context_is_key_pressed(ctx, key)
		input.keys_repeat[index] = rl.context_is_key_pressed_repeat(ctx, key)
		input.keys_released[index] = rl.context_is_key_released(ctx, key)
		input.keys_down[index] = rl.context_is_key_down(ctx, key)
	}
	capture_clipboard_context(adapter, input)
	for index in 0 ..< ui.INPUT_MOUSE_BUTTON_COUNT {
		button := rl.MouseButton(index)
		input.mouse_pressed[index] = rl.context_is_mouse_button_pressed(ctx, button)
		input.mouse_released[index] = rl.context_is_mouse_button_released(ctx, button)
		input.mouse_down[index] = rl.context_is_mouse_button_down(ctx, button)
	}
	snapshot_pointer_events(
		input,
		rl.context_pointer_events(ctx),
		rl.context_pointer_events_overflowed(ctx),
	)
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
	preedit, preedit_caret := rl.context_get_preedit(ctx)
	input.preedit_len = min(len(preedit), ui.INPUT_PREEDIT_CAP)
	copy(input.preedit[:input.preedit_len], transmute([]u8)preedit)
	input.preedit_caret = clamp(preedit_caret, 0, input.preedit_len)
	pointer_snapshot_sanitize(input)
	assert(len(input.clipboard) <= ui.INPUT_CLIPBOARD_CAP)
}
