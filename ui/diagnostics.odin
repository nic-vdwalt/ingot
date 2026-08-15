package ui

import "core:time"

Prepared_Phase :: enum u8 {
	Measure_Natural,
	Resolve_Size,
	Measure_Resolved,
	Place,
	Render_Tree,
	Output_Clear,
	Finalize_Routes,
	Finalize_Semantics,
	Finalize_Lifetimes,
}

Prepared_Telemetry :: struct {
	phase_ns:                   [Prepared_Phase]i64,
	description_nodes:          u64,
	leaf_nodes:                 u64,
	container_nodes:            u64,
	maximum_depth:              u64,
	fixed_leaf_nodes:           u64,
	intrinsic_leaf_nodes:       u64,
	width_dependent_leaf_nodes: u64,
	dependency_node_visits:     u64,
	dependency_child_visits:    u64,
	natural_node_visits:        u64,
	resolve_node_visits:        u64,
	remeasure_node_visits:      u64,
	width_assignment_visits:    u64,
	resolved_measure_visits:    u64,
	placement_node_visits:      u64,
	render_node_visits:         u64,
	child_run_visits:           u64,
	specialized_nodes:          u64,
	generic_fallback_nodes:     u64,
	natural_leaf_measures:      u64,
	resolved_leaf_measures:     u64,
	fixed_leaf_measure_skips:   u64,
	container_measures:         u64,
	width_assignments:          u64,
	placed_nodes:               u64,
	rendered_nodes:             u64,
	activation_outputs:         u64,
	render_relayouts:           u64,
}

Ui_Frame_Output_Stats :: struct {
	main_command_count:    i32,
	main_text_bytes:       i32,
	overlay_command_count: i32,
	overlay_text_bytes:    i32,
	semantic_node_count:            i32,
	measure_cache_hits:             u64,
	measure_cache_misses:           u64,
	measure_cache_policy_bypasses:  u64,
}

Ui_Paint_Telemetry :: struct {
	command_append_count: u64,
	text_append_count:    u64,
	text_bytes_copied:    u64,
	command_growth_count: u64,
	text_growth_count:    u64,
}

Ui_Paint_Storage_Stats :: struct {
	command_bytes:          u64,
	list_bytes:             u64,
	output_bytes:           u64,
	command_capacity_bytes: u64,
	text_capacity_bytes:    u64,
	z_group_capacity:       i32,
	z_group_bytes:          u64,
}

paint_storage_stats :: proc() -> Ui_Paint_Storage_Stats {
	command_bytes := u64(size_of(Paint_Command))
	return {
		command_bytes = command_bytes,
		list_bytes = u64(size_of(Paint_List)),
		output_bytes = u64(size_of(Ui_Output)),
		command_capacity_bytes = command_bytes * PAINT_COMMAND_CAP,
		text_capacity_bytes = PAINT_TEXT_CAP,
		z_group_capacity = MAX_PAINT_Z_GROUPS,
		z_group_bytes = u64(size_of(Z_Order)) * MAX_PAINT_Z_GROUPS,
	}
}

Ui_Fit_Storage_Stats :: struct {
	prepared_node_capacity: i32,
	prepared_node_hard_max: i32,
	direct_flex_capacity:   i32,
	layout_depth_capacity:  i32,
	prepared_node_bytes:    u64,
	fit_output_bytes:       u64,
	caller_storage_bytes:   u64,
	prepared_bytes:         u64,
	builder_bytes:          u64,
	transition_rect_bytes:  u64,
}

fit_storage_stats :: proc(capacity: i32 = MAX_PREPARED_NODES) -> Ui_Fit_Storage_Stats {
	assert(capacity >= MAX_LAYOUT_DEPTH && capacity <= MAX_PREPARED_NODES_HARD)
	node_bytes := u64(size_of(Prepared_Node))
	output_bytes := u64(size_of(^bool))
	return {
		prepared_node_capacity = capacity,
		prepared_node_hard_max = MAX_PREPARED_NODES_HARD,
		direct_flex_capacity = MAX_LAYOUT_FLEX,
		layout_depth_capacity = MAX_LAYOUT_DEPTH,
		prepared_node_bytes = node_bytes,
		fit_output_bytes = output_bytes,
		caller_storage_bytes = u64(capacity) * (node_bytes + output_bytes),
		prepared_bytes = u64(size_of(Prepared_Ui)),
		builder_bytes = u64(size_of(Fit_Builder)),
		transition_rect_bytes = u64(size_of(Transition_Rect_State)),
	}
}

Ui_Frame_Telemetry :: struct {
	scratch_allocation_count:         u64,
	scratch_resize_count:             u64,
	scratch_allocation_request_bytes: u64,
	scratch_resize_request_bytes:     u64,
	main:                             Ui_Paint_Telemetry,
	overlay:                          Ui_Paint_Telemetry,
	text_input_full_path_count:       u64,
	text_input_inactive_candidates:   u64,
	prepared:                         Prepared_Telemetry,
	measure_cache_hits:               u64,
	measure_cache_misses:             u64,
	measure_cache_policy_bypasses:    u64,
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
	hits, misses, policy_bypasses := measure_cache_telemetry_with(&frame.runtime.text)
	result := Ui_Frame_Output_Stats {
		semantic_node_count           = i32(frame.semantics.cur.count),
		measure_cache_hits            = hits,
		measure_cache_misses          = misses,
		measure_cache_policy_bypasses = policy_bypasses,
	}
	if frame.output != nil {
		result.main_command_count = i32(frame.output.main.count)
		result.main_text_bytes = i32(frame.output.main.text_len)
		result.overlay_command_count = i32(frame.output.overlay.count)
		result.overlay_text_bytes = i32(frame.output.overlay.text_len)
	}
	return result
}

@(private = "file")
paint_telemetry :: proc(list: ^Paint_List) -> Ui_Paint_Telemetry {
	assert(list != nil, "paint_telemetry: nil list")
	return {
		command_append_count = list.command_append_count,
		text_append_count = list.text_append_count,
		text_bytes_copied = list.text_bytes_copied,
		command_growth_count = list.command_growth_count,
		text_growth_count = list.text_growth_count,
	}
}

ui_frame_telemetry :: proc(frame: ^Ui_Frame) -> Ui_Frame_Telemetry {
	assert(frame != nil && frame.open, "ui_frame_telemetry: invalid frame")
	assert(frame.finalized, "ui_frame_telemetry: frame not finalized")
	hits, misses, policy_bypasses := measure_cache_telemetry_with(&frame.runtime.text)
	result := Ui_Frame_Telemetry {
		scratch_allocation_count         = frame.scratch.allocation_count,
		scratch_resize_count             = frame.scratch.resize_count,
		scratch_allocation_request_bytes = frame.scratch.allocation_request_bytes,
		scratch_resize_request_bytes     = frame.scratch.resize_request_bytes,
		text_input_full_path_count       = frame.text_input_full_path_count,
		text_input_inactive_candidates   = frame.text_input_inactive_candidates,
		prepared                         = frame.prepared_telemetry,
		measure_cache_hits               = hits,
		measure_cache_misses             = misses,
		measure_cache_policy_bypasses    = policy_bypasses,
	}
	if frame.output != nil {
		result.main = paint_telemetry(&frame.output.main)
		result.overlay = paint_telemetry(&frame.output.overlay)
	}
	return result
}

prepared_phase_begin :: proc(frame: ^Ui_Frame, phase: Prepared_Phase) -> i64 {
	assert(frame != nil && frame.open, "prepared phase: invalid frame")
	assert(int(phase) >= 0 && int(phase) < len(Prepared_Phase), "prepared phase: invalid phase")
	if UI_TELEMETRY_ENABLED do return time.tick_now()._nsec
	return 0
}

prepared_phase_end :: proc(frame: ^Ui_Frame, phase: Prepared_Phase, started: i64) {
	assert(frame != nil && frame.open, "prepared phase: invalid frame")
	assert(int(phase) >= 0 && int(phase) < len(Prepared_Phase), "prepared phase: invalid phase")
	if UI_TELEMETRY_ENABLED {
		finished := time.tick_now()._nsec
		assert(finished >= started, "prepared phase: non-monotonic time")
		frame.prepared_telemetry.phase_ns[phase] += finished - started
	}
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
