#+build !js
package ui

import "core:testing"
import "ingot:action"

@(private = "file")
command_test_frame :: proc(
	runtime: ^Ui_Runtime,
	frame: ^Ui_Frame,
	input: ^Ui_Input,
	key: Key,
	modifiers: action.Modifiers = {},
) {
	assert(runtime != nil && frame != nil && input != nil)
	input.keys_pressed[input_key_index(key)] = true
	if .Shift in modifiers do input.keys_down[input_key_index(.LEFT_SHIFT)] = true
	if .Control in modifiers do input.keys_down[input_key_index(.LEFT_CONTROL)] = true
	if .Alt in modifiers do input.keys_down[input_key_index(.LEFT_ALT)] = true
	if .Super in modifiers do input.keys_down[input_key_index(.LEFT_SUPER)] = true
	ui_frame_begin(frame, runtime, input)
}

@(test)
command_take_prefers_the_active_context :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	frame: Ui_Frame
	command_test_frame(&runtime, &frame, &input, .S, {.Control})
	defer ui_frame_end(&frame)

	global := action.command_id(1)
	local := action.command_id(2)
	ctx := action.context_id(7)
	bindings := [2]action.Binding {
		{command = global, stroke = {key = i32(Key.S), modifiers = {.Control}}},
		{command = local, context_id = ctx, stroke = {key = i32(Key.S), modifiers = {.Control}}},
	}
	keymap: action.Keymap
	testing.expect(t, action.keymap_set(&keymap, bindings[:]))
	testing.expect_value(t, command_take(&frame, &keymap, ctx), local)
	testing.expect(t, !is_key_pressed(&frame, .S))
}

@(test)
command_take_does_not_steal_unmatched_text :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.characters[0] = 's'
	input.character_count = 1
	frame: Ui_Frame
	command_test_frame(&runtime, &frame, &input, .S)
	defer ui_frame_end(&frame)

	bindings := [1]action.Binding {
		{command = action.command_id(1), stroke = {key = i32(Key.S), modifiers = {.Control}}},
	}
	keymap: action.Keymap
	testing.expect(t, action.keymap_set(&keymap, bindings[:]))
	testing.expect_value(t, command_take(&frame, &keymap), COMMAND_ID_NONE)
	testing.expect_value(t, len(frame_characters(&frame)), 1)
}

@(test)
command_take_consumes_matching_printable_input :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.characters[0] = 's'
	input.character_count = 1
	frame: Ui_Frame
	command_test_frame(&runtime, &frame, &input, .S, {.Control})
	defer ui_frame_end(&frame)

	command := action.command_id(1)
	bindings := [1]action.Binding {
		{command = command, stroke = {key = i32(Key.S), modifiers = {.Control}}},
	}
	keymap: action.Keymap
	testing.expect(t, action.keymap_set(&keymap, bindings[:]))
	testing.expect_value(t, command_take(&frame, &keymap), command)
	testing.expect_value(t, len(frame_characters(&frame)), 0)
}
