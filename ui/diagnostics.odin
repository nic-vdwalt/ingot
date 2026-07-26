package ui

Ui_Frame_Diagnostics :: struct {
	input_characters_dropped:   i32,
	degenerate_widgets_dropped: i32,
	semantic_nodes_dropped:     i32,
	semantic_focus_dropped:     i32,
	semantic_actions_dropped:   i32,
	semantic_id_collisions:     i32,
	semantic_text_truncations:  i32,
	main_commands_dropped:      i32,
	main_text_bytes_dropped:    i32,
	overlay_commands_dropped:   i32,
	overlay_text_bytes_dropped: i32,
	platform_controls_dropped:  i32,
}

ui_frame_diagnostics :: proc(frame: ^Ui_Frame) -> Ui_Frame_Diagnostics {
	assert(frame != nil && frame.open, "ui_frame_diagnostics: invalid frame")
	assert(frame.input != nil, "ui_frame_diagnostics: missing input")
	result := Ui_Frame_Diagnostics {
		input_characters_dropped   = i32(frame.input.characters_dropped),
		degenerate_widgets_dropped = i32(frame.degenerate_drops),
		semantic_nodes_dropped     = i32(frame.semantics.nodes_dropped),
		semantic_focus_dropped     = i32(frame.semantics.focus_dropped),
		semantic_actions_dropped   = i32(frame.semantics.action_targets_dropped),
		semantic_id_collisions     = i32(frame.semantics.id_collisions),
		semantic_text_truncations  = i32(frame.semantics.text_truncations),
	}
	if frame.output != nil {
		result.main_commands_dropped = i32(frame.output.main.dropped_commands)
		result.main_text_bytes_dropped = i32(frame.output.main.dropped_text_bytes)
		result.overlay_commands_dropped = i32(frame.output.overlay.dropped_commands)
		result.overlay_text_bytes_dropped = i32(frame.output.overlay.dropped_text_bytes)
		result.platform_controls_dropped = i32(frame.output.platform.controls_dropped)
	}
	return result
}
