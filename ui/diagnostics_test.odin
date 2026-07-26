#+build !js
package ui

import "core:testing"

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
