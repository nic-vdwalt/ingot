#+build !js
package ui

import "core:testing"


@(test)
overlay_recorder_behaviour :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.runtime = &runtime
	frame.output = output
	frame.open = true
	overlay_reset(&frame)
	route_reset(&frame)
	defer overlay_reset(&frame)
	defer route_reset(&frame)

	// Commands record in order.
	overlay_begin(&frame, Rectangle{0, 0, 100, 100}, claim_input = false)
	overlay_rect(&frame, Rectangle{0, 0, 10, 10}, Color{1, 2, 3, 255})
	overlay_text(&frame, "hello", 5, 5, 13, Color{255, 255, 255, 255})
	overlay_rounded(&frame, Rectangle{1, 1, 8, 8}, 0.5, 4, Color{9, 9, 9, 255})
	overlay_end(&frame)
	testing.expect_value(t, overlay_cmd_count(&frame), 3)
	testing.expect_value(t, overlay_dropped(&frame), 0)

	// Reset discards everything.
	overlay_reset(&frame)
	testing.expect_value(t, overlay_cmd_count(&frame), 0)
	testing.expect_value(t, overlay_dropped(&frame), 0)

	// Command buffer is bounded: overflow drops, never crashes or allocates.
	overlay_begin(&frame, Rectangle{0, 0, 10, 10}, claim_input = false)
	for _ in 0 ..< PAINT_COMMAND_CAP + 5 {
		overlay_rect(&frame, Rectangle{0, 0, 1, 1}, Color{})
	}
	overlay_end(&frame)
	testing.expect_value(t, overlay_cmd_count(&frame), PAINT_COMMAND_CAP)
	testing.expect_value(t, overlay_dropped(&frame), 5)
	overlay_reset(&frame)

	// Text buffer is bounded: an overlong string drops its command.
	overlay_begin(&frame, Rectangle{0, 0, 10, 10}, claim_input = false)
	big := make([]u8, PAINT_TEXT_CAP + 1)
	defer delete(big)
	for &b in big do b = 'a'
	overlay_text(&frame, string(big), 0, 0, 13, Color{})
	testing.expect_value(t, overlay_cmd_count(&frame), 0)
	testing.expect_value(t, overlay_dropped(&frame), 1)
	overlay_end(&frame)
	overlay_reset(&frame)

	// A claiming group registers its rect with the input router.
	overlay_begin(&frame, Rectangle{20, 20, 40, 40}, claim_input = true)
	overlay_end(&frame)
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, Vector2{30, 30}))
	testing.expect(t, !route_occluded(&frame, Vector2{5, 5}))

	// Flush preserves commands for backend replay.
	overlay_begin(&frame, Rectangle{0, 0, 10, 10}, claim_input = false)
	overlay_rect(&frame, Rectangle{0, 0, 1, 1}, Color{})
	overlay_end(&frame)
	overlay_flush(&frame)
	testing.expect_value(t, overlay_cmd_count(&frame), 1)

	// Main paint can stream immediately while preserving its diagnostic buffer.
	sink_count := 0
	sink :: proc(list: ^Paint_List, command: Paint_Command, userdata: rawptr) {
		assert(list != nil, "overlay_recorder_behaviour: nil sink list")
		assert(command.kind == .Rectangle, "overlay_recorder_behaviour: wrong sink command")
		count := (^int)(userdata)
		count^ += 1
	}
	paint_list_set_sink(&output.main, sink, &sink_count)
	paint_push(&output.main, {kind = .Rectangle})
	testing.expect_value(t, sink_count, 1)
	testing.expect_value(t, output.main.count, 1)
	paint_list_set_sink(&output.main, nil, nil)
}
