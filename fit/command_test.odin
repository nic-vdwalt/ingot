#+build !js
package fit

import "core:testing"
import "ingot:ui"

@(test)
fit_command_take_uses_the_bound_builder_frame :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	input: ui.Ui_Input
	input.keys_pressed[ui.input_key_index(.S)] = true
	input.keys_down[ui.input_key_index(.LEFT_CONTROL)] = true
	frame: ui.Ui_Frame
	ui.ui_frame_begin(&frame, &runtime, &input)
	defer ui.ui_frame_end(&frame)

	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	defer builder_close(&builder)
	command, ok := command_id_string("editor.save")
	testing.expect(t, ok)
	bindings := [1]Command_Binding {
		{command = command, stroke = {key = i32(Key.S), modifiers = {.Control}}},
	}
	keymap: Command_Keymap
	testing.expect(t, command_keymap_set(&keymap, bindings[:]))
	testing.expect_value(t, command_take(&builder, &keymap), command)
}
