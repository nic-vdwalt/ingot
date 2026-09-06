package ui

import "ingot:action"

Command_Id :: action.Command_Id
Command_Context_Id :: action.Context_Id
Command_Keymap :: action.Keymap
Command_Binding :: action.Binding
COMMAND_ID_NONE :: action.COMMAND_ID_NONE
COMMAND_CONTEXT_NONE :: action.CONTEXT_ID_NONE

command_id :: proc(value: string) -> (Command_Id, bool) {
	return action.command_id_string(value)
}

command_context_id :: proc(value: string) -> (Command_Context_Id, bool) {
	return action.context_id_string(value)
}

command_take :: proc(
	frame: ^Ui_Frame,
	keymap: ^Command_Keymap,
	context_id: Command_Context_Id = COMMAND_CONTEXT_NONE,
) -> Command_Id {
	assert(frame != nil && frame.open, "command_take: invalid frame")
	assert(keymap != nil, "command_take: nil keymap")
	bindings := action.keymap_bindings(keymap)
	winner := -1
	for binding, index in bindings {
		if !command_context_matches(binding.context_id, context_id) do continue
		if !command_stroke_active(frame, binding.stroke) do continue
		if winner < 0 || command_binding_precedes(binding, bindings[winner], context_id) {
			winner = index
		}
	}
	if winner < 0 do return COMMAND_ID_NONE
	binding := bindings[winner]
	key := Key(binding.stroke.key)
	if binding.stroke.repeat do modal_key_consume(frame, key, .Repeated)
	else do key_pressed_consume(frame, key)
	frame_characters_consume(frame)
	request_redraw(frame)
	return binding.command
}

@(private = "file")
command_context_matches :: proc(binding, active: Command_Context_Id) -> bool {
	return binding == COMMAND_CONTEXT_NONE || binding == active
}

@(private = "file")
command_binding_precedes :: proc(
	candidate, current: Command_Binding,
	active: Command_Context_Id,
) -> bool {
	candidate_specific := candidate.context_id == active && active != COMMAND_CONTEXT_NONE
	current_specific := current.context_id == active && active != COMMAND_CONTEXT_NONE
	if candidate_specific != current_specific do return candidate_specific
	return candidate.priority > current.priority
}

@(private = "file")
command_stroke_active :: proc(frame: ^Ui_Frame, stroke: action.Keystroke) -> bool {
	assert(frame != nil && frame.open, "command stroke active: invalid frame")
	key := Key(stroke.key)
	active := is_key_pressed_repeat(frame, key) if stroke.repeat else is_key_pressed(frame, key)
	if !active do return false
	return command_modifiers(frame) == stroke.modifiers
}

@(private = "file")
command_modifiers :: proc(frame: ^Ui_Frame) -> action.Modifiers {
	assert(frame != nil && frame.open, "command modifiers: invalid frame")
	result: action.Modifiers
	if is_key_down(frame, .LEFT_SHIFT) || is_key_down(frame, .RIGHT_SHIFT) do result += {.Shift}
	if is_key_down(frame, .LEFT_CONTROL) || is_key_down(frame, .RIGHT_CONTROL) do result += {.Control}
	if is_key_down(frame, .LEFT_ALT) || is_key_down(frame, .RIGHT_ALT) do result += {.Alt}
	if is_key_down(frame, .LEFT_SUPER) || is_key_down(frame, .RIGHT_SUPER) do result += {.Super}
	return result
}
