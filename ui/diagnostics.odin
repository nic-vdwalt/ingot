package ui

Ui_Frame_Output_Stats :: struct {
	main_command_count:       i32,
	main_text_bytes:          i32,
	overlay_command_count:    i32,
	overlay_text_bytes:       i32,
	semantic_node_count:      i32,
	scratch_allocation_count: u64,
	scratch_peak_bytes:       u64,
	measure_cache_hits:       u64,
	measure_cache_misses:     u64,
}

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

ui_frame_output_stats :: proc(frame: ^Ui_Frame) -> Ui_Frame_Output_Stats {
	assert(frame != nil && frame.open, "ui_frame_output_stats: invalid frame")
	assert(frame.finalized, "ui_frame_output_stats: frame not finalized")
	hits, misses := measure_cache_telemetry_with(&frame.runtime.text)
	result := Ui_Frame_Output_Stats {
		semantic_node_count      = i32(frame.semantics.cur.count),
		scratch_allocation_count = frame.scratch.allocation_count,
		scratch_peak_bytes       = frame.scratch.peak_bytes,
		measure_cache_hits       = hits,
		measure_cache_misses     = misses,
	}
	if frame.output != nil {
		result.main_command_count = i32(frame.output.main.count)
		result.main_text_bytes = i32(frame.output.main.text_len)
		result.overlay_command_count = i32(frame.output.overlay.count)
		result.overlay_text_bytes = i32(frame.output.overlay.text_len)
	}
	return result
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
