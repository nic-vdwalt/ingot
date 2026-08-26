package fit

import "ingot:action"
import "ingot:ui"

Command_Id_String :: proc(value: string) -> (Command_Id, bool) {
	return action.command_id_string(value)
}

Command_Context_Id_String :: proc(value: string) -> (Command_Context_Id, bool) {
	return action.context_id_string(value)
}

Command_Keymap_Set :: proc(keymap: ^Command_Keymap, bindings: []Command_Binding) -> bool {
	return action.keymap_set(keymap, bindings)
}

Command_Take :: proc(
	builder: ^Builder,
	keymap: ^Command_Keymap,
	context_id: Command_Context_Id = COMMAND_CONTEXT_NONE,
) -> Command_Id {
	assert(builder != nil && builder.bound, "Fit.Command_Take: builder not bound")
	assert(keymap != nil, "Fit.Command_Take: nil keymap")
	return ui.command_take(builder.root.frame, keymap, context_id)
}

Surface_Command_Take :: proc(
	surface: ^Surface,
	keymap: ^Command_Keymap,
	context_id: Command_Context_Id = COMMAND_CONTEXT_NONE,
) -> Command_Id {
	assert(surface != nil, "Fit.Surface_Command_Take: nil surface")
	assert(keymap != nil, "Fit.Surface_Command_Take: nil keymap")
	return ui.command_take(surface_ui(surface).frame, keymap, context_id)
}
