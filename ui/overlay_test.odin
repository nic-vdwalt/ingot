#+build !js
package ui

import "core:testing"
import rl "ingot:gfx"

// The overlay recorder lives in module state, so all recorder behaviour is
// exercised in one sequential test (the runner executes @(test) procs in
// parallel and interleaved resets would race).
@(test)
overlay_recorder_behaviour :: proc(t: ^testing.T) {
	overlay_reset()
	route_reset()
	defer overlay_reset()
	defer route_reset()

	// Commands record in order.
	overlay_begin(rl.Rectangle{0, 0, 100, 100}, claim_input = false)
	overlay_rect(rl.Rectangle{0, 0, 10, 10}, rl.Color{1, 2, 3, 255})
	overlay_text("hello", 5, 5, 13, rl.Color{255, 255, 255, 255})
	overlay_rounded(rl.Rectangle{1, 1, 8, 8}, 0.5, 4, rl.Color{9, 9, 9, 255})
	overlay_end()
	testing.expect_value(t, overlay_cmd_count(), 3)
	testing.expect_value(t, overlay_dropped(), 0)

	// Reset discards everything.
	overlay_reset()
	testing.expect_value(t, overlay_cmd_count(), 0)
	testing.expect_value(t, overlay_dropped(), 0)

	// Command buffer is bounded: overflow drops, never crashes or allocates.
	overlay_begin(rl.Rectangle{0, 0, 10, 10}, claim_input = false)
	for _ in 0 ..< MAX_OVERLAY_CMDS + 5 {
		overlay_rect(rl.Rectangle{0, 0, 1, 1}, rl.Color{})
	}
	overlay_end()
	testing.expect_value(t, overlay_cmd_count(), MAX_OVERLAY_CMDS)
	testing.expect_value(t, overlay_dropped(), 5)
	overlay_reset()

	// Text buffer is bounded: an overlong string drops its command.
	overlay_begin(rl.Rectangle{0, 0, 10, 10}, claim_input = false)
	big := make([]u8, OVERLAY_TEXT_CAP)
	defer delete(big)
	for &b in big do b = 'a'
	overlay_text(string(big), 0, 0, 13, rl.Color{})
	testing.expect_value(t, overlay_cmd_count(), 0)
	testing.expect_value(t, overlay_dropped(), 1)
	overlay_end()
	overlay_reset()

	// A claiming group registers its rect with the input router.
	overlay_begin(rl.Rectangle{20, 20, 40, 40}, claim_input = true)
	overlay_end()
	route_begin_frame()
	testing.expect(t, route_occluded(rl.Vector2{30, 30}))
	testing.expect(t, !route_occluded(rl.Vector2{5, 5}))

	// Flush resets the buffers. No frame is active in tests: gfx draw procs
	// are no-ops, so flush only exercises the replay loop and the reset.
	overlay_begin(rl.Rectangle{0, 0, 10, 10}, claim_input = false)
	overlay_rect(rl.Rectangle{0, 0, 1, 1}, rl.Color{})
	overlay_text("x", 0, 0, 13, rl.Color{})
	overlay_end()
	overlay_flush()
	testing.expect_value(t, overlay_cmd_count(), 0)
}
