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
	command, ok := Command_Id_String("editor.save")
	testing.expect(t, ok)
	bindings := [1]Command_Binding {
		{command = command, stroke = {key = i32(Key.S), modifiers = {.Control}}},
	}
	keymap: Command_Keymap
	testing.expect(t, Command_Keymap_Set(&keymap, bindings[:]))
	testing.expect_value(t, Command_Take(&builder, &keymap), command)
}
