#+build !js
package ui

import "core:testing"

@(test)
paint_storage_stats_match_bounded_representation :: proc(t: ^testing.T) {
	stats := ui_paint_storage_stats()
	testing.expect_value(t, stats.command_bytes, u64(size_of(Paint_Command)))
	testing.expect_value(t, stats.list_bytes, u64(size_of(Paint_List)))
	testing.expect_value(t, stats.output_bytes, u64(size_of(Ui_Output)))
	testing.expect_value(t, stats.command_capacity_bytes, stats.command_bytes * PAINT_COMMAND_CAP)
	testing.expect_value(t, stats.text_capacity_bytes, u64(PAINT_TEXT_CAP))
}

@(test)
frame_output_stats_require_completed_frame :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime)
	draw_rectangle(&frame, 0, 0, 10, 10, Color{255, 255, 255, 255})
	ui_frame_finalize(&frame)
	stats := ui_frame_output_stats(&frame)
	testing.expect_value(t, stats.main_command_count, i32(1))
	testing.expect_value(t, stats.main_text_bytes, i32(0))
	testing.expect_value(t, stats.semantic_node_count, i32(0))
	ui_frame_release(&frame)
	ui_frame_destroy(&frame)
}

@(test)
frame_diagnostics_aggregate_bounded_drops :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		characters_dropped = 2,
	}
	output := new(Ui_Output)
	defer free(output)
	output^ = {}
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	frame.degenerate_drops = 3
	frame.semantics.nodes_dropped = 4
	output.main.dropped_commands = 5
	output.overlay.dropped_text_bytes = 6
	output.platform.controls_dropped = 7
	diagnostics := ui_frame_diagnostics(&frame)
	testing.expect_value(t, diagnostics.input_characters_dropped, i32(2))
	testing.expect_value(t, diagnostics.degenerate_widgets_dropped, i32(3))
	testing.expect_value(t, diagnostics.semantic_nodes_dropped, i32(4))
	testing.expect_value(t, diagnostics.main_commands_dropped, i32(5))
	testing.expect_value(t, diagnostics.overlay_text_bytes_dropped, i32(6))
	testing.expect_value(t, diagnostics.platform_controls_dropped, i32(7))
	ui_frame_end(&frame)
	ui_frame_destroy(&frame)
}

@(test)
frame_telemetry_counts_and_resets_per_frame :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime)
	allocator := ui_frame_allocator(&frame)
	_ = make([]byte, 12, allocator)
	paint_push(&output.main, {kind = .Rectangle})
	paint_push_text(&output.main, {kind = .Text}, "main")
	paint_push_text(&output.overlay, {kind = .Text}, "over")
	box: Input_Box
	defer input_box_destroy(&box)
	_ = text_input_at(&frame, {0, 0, 120, 24}, &box, "input", false)
	ui_frame_finalize(&frame)
	telemetry := ui_frame_telemetry(&frame)
	when UI_TELEMETRY_ENABLED {
		testing.expect_value(t, telemetry.scratch_allocation_count, u64(1))
		testing.expect_value(t, telemetry.scratch_resize_count, u64(0))
		testing.expect_value(t, telemetry.scratch_allocation_request_bytes, u64(12))
		testing.expect_value(t, telemetry.scratch_resize_request_bytes, u64(0))
		testing.expect_value(t, telemetry.main.command_append_count, u64(7))
		testing.expect_value(t, telemetry.main.text_append_count, u64(2))
		testing.expect_value(t, telemetry.overlay.command_append_count, u64(1))
		testing.expect_value(t, telemetry.overlay.text_append_count, u64(1))
		testing.expect_value(t, telemetry.text_input_full_path_count, u64(1))
		testing.expect_value(t, telemetry.text_input_inactive_candidates, u64(1))
	}
	ui_frame_release(&frame)
	ui_frame_begin(&frame, &runtime)
	ui_frame_finalize(&frame)
	telemetry = ui_frame_telemetry(&frame)
	testing.expect_value(t, telemetry, Ui_Frame_Telemetry{})
	ui_frame_release(&frame)
	ui_frame_destroy(&frame)
}
