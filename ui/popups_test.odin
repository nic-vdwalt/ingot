#+build !js
package ui

// Unit tests for popup input routing: the backdrop claim must occlude every
// point outside the panel while leaving the panel's own area interactive.

import "core:testing"

@(test)
route_claim_backdrop_occludes_only_outside_panel :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true
	route_reset(&frame)
	defer route_reset(&frame)

	screen_w, screen_h: i32 = 800, 600
	panel := Rect_I32{300, 200, 200, 200}
	route_claim_backdrop(&frame, panel, screen_w, screen_h)
	// Claims apply on the following frame.
	route_begin_frame(&frame)

	// Inside the panel stays interactive, including its edges.
	testing.expect(t, !route_occluded(&frame, Vector2{400, 300}), "panel center must stay live")
	testing.expect(t, !route_occluded(&frame, Vector2{300, 200}), "panel corner must stay live")
	testing.expect(
		t,
		!route_occluded(&frame, Vector2{499, 399}),
		"panel inner edge must stay live",
	)

	// Every band around the panel is claimed.
	testing.expect(t, route_occluded(&frame, Vector2{400, 100}), "above panel must be occluded")
	testing.expect(t, route_occluded(&frame, Vector2{400, 500}), "below panel must be occluded")
	testing.expect(t, route_occluded(&frame, Vector2{100, 300}), "left of panel must be occluded")
	testing.expect(t, route_occluded(&frame, Vector2{700, 300}), "right of panel must be occluded")
	testing.expect(t, route_occluded(&frame, Vector2{0, 0}), "corner must be occluded")
}

@(test)
route_claim_backdrop_handles_fullscreen_panel :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true
	route_reset(&frame)
	defer route_reset(&frame)

	// A panel covering the whole screen leaves four zero-area bands, which
	// must not claim anything or trip the negative-rect assertion.
	route_claim_backdrop(&frame, Rect_I32{0, 0, 400, 300}, 400, 300)
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, Vector2{200, 150}), "full-screen panel stays live")
	testing.expect(t, !route_occluded(&frame, Vector2{0, 0}), "no band should occlude")
}

@(test)
tooltip_wrapped_at_waits_then_emits_multiline_overlay :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	output := new(Ui_Output)
	defer free(output)
	input := Ui_Input {
		mouse_position = {20, 20},
		screen_size    = {120, 80},
	}
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	state: Tooltip_State
	target := Rect_I32{10, 10, 40, 20}
	text := "one two three four"
	tooltip_wrapped_at(&frame, &state, target, text, 120, 80, {max_width = 48})
	testing.expect_value(t, overlay_cmd_count(&frame), 0)
	input.time = TOOLTIP_DELAY
	tooltip_wrapped_at(&frame, &state, target, text, 120, 80, {max_width = 48})
	list := &output.overlay
	testing.expect_value(t, list.count, 6)
	testing.expect_value(t, list.commands[0].rect.x, f32(32))
	testing.expect_value(t, list.commands[0].rect.y, f32(0))
	testing.expect_value(t, list.commands[0].rect.width, f32(44))
	testing.expect_value(t, list.commands[0].rect.height, f32(100))
}
