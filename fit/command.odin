package fit

import "ingot:action"
import "ingot:ui"

command_id_string :: proc(value: string) -> (Command_Id, bool) {
	return action.command_id_string(value)
}

command_context_id_string :: proc(value: string) -> (Command_Context_Id, bool) {
	return action.context_id_string(value)
}

command_keymap_set :: proc(keymap: ^Command_Keymap, bindings: []Command_Binding) -> bool {
	return action.keymap_set(keymap, bindings)
}

command_take :: proc(
	builder: ^Builder,
	keymap: ^Command_Keymap,
	context_id: Command_Context_Id = COMMAND_CONTEXT_NONE,
) -> Command_Id {
	assert(builder != nil && builder.bound, "fit.command_take: builder not bound")
	assert(keymap != nil, "fit.command_take: nil keymap")
	return ui.command_take(builder.root.frame, keymap, context_id)
}

surface_command_take :: proc(
	surface: ^Surface,
	keymap: ^Command_Keymap,
	context_id: Command_Context_Id = COMMAND_CONTEXT_NONE,
) -> Command_Id {
	assert(surface != nil, "fit.surface_command_take: nil surface")
	assert(keymap != nil, "fit.surface_command_take: nil keymap")
	return ui.command_take(surface_ui(surface).frame, keymap, context_id)
}
