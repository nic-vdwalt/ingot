#+build !js
package action

import "core:testing"

@(test)
command_names_are_bounded_and_stable :: proc(t: ^testing.T) {
	first, ok := command_id_string("editor.save")
	testing.expect(t, ok)
	second, ok_second := command_id_string("editor.save")
	testing.expect(t, ok_second)
	testing.expect_value(t, first, second)
	testing.expect(t, first != COMMAND_ID_NONE)
	ctx, context_ok := context_id_string("editor")
	testing.expect(t, context_ok)
	testing.expect(t, ctx != CONTEXT_ID_NONE)

	_, empty_ok := command_id_string("")
	testing.expect(t, !empty_ok)
	too_long: [COMMAND_NAME_BYTE_MAX + 1]u8
	_, long_ok := command_id_string(string(too_long[:]))
	testing.expect(t, !long_ok)
}

@(test)
bindings_reject_reserved_commands_and_negative_keys :: proc(t: ^testing.T) {
	valid := Binding {
		command = command_id(1),
		stroke = {key = 65, modifiers = {.Control}},
	}
	testing.expect(t, binding_valid(valid))
	valid.command = COMMAND_ID_NONE
	testing.expect(t, !binding_valid(valid))
	valid.command = command_id(1)
	valid.stroke.key = -1
	testing.expect(t, !binding_valid(valid))
}

@(test)
keymap_replacement_is_bounded_and_transactional :: proc(t: ^testing.T) {
	keymap: Keymap
	original := [1]Binding{{command = command_id(1), stroke = {key = 65}}}
	testing.expect(t, keymap_set(&keymap, original[:]))
	testing.expect_value(t, keymap.count, 1)

	invalid := [1]Binding{{command = COMMAND_ID_NONE, stroke = {key = 66}}}
	testing.expect(t, !keymap_set(&keymap, invalid[:]))
	testing.expect_value(t, keymap.count, 1)
	testing.expect_value(t, keymap.bindings[0], original[0])
}

@(test)
keymap_rejects_duplicate_triggers :: proc(t: ^testing.T) {
	keymap: Keymap
	bindings := [2]Binding {
		{command = command_id(1), stroke = {key = 83, modifiers = {.Control}}},
		{command = command_id(2), stroke = {key = 83, modifiers = {.Control}}},
	}
	testing.expect(t, !keymap_set(&keymap, bindings[:]))
	testing.expect_value(t, keymap.count, 0)
}
