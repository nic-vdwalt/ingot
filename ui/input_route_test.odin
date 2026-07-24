#+build !js
package ui

import "core:testing"
import rl "ingot:gfx"

@(test)
route_claims_behaviour :: proc(t: ^testing.T) {
	// Pure claim-set queries.
	c: Route_Claims
	testing.expect(t, !route_occluded_in(c, rl.Vector2{10, 10}))

	c.rects[0] = rl.Rectangle{100, 100, 50, 50}
	c.count = 1
	testing.expect(t, route_occluded_in(c, rl.Vector2{120, 120}))
	testing.expect(t, !route_occluded_in(c, rl.Vector2{99, 120}))
	testing.expect(t, !route_occluded_in(c, rl.Vector2{120, 151}))

	all: Route_Claims
	all.all = true
	testing.expect(t, route_occluded_in(all, rl.Vector2{0, 0}))
	testing.expect(t, route_occluded_in(all, rl.Vector2{9999, 9999}))

	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true

	// Double buffer: claims take effect next frame and expire when not renewed.
	route_reset(&frame)
	defer route_reset(&frame)
	p := rl.Vector2{5, 5}
	route_claim(&frame, rl.Rectangle{0, 0, 10, 10})
	testing.expect(t, !route_occluded(&frame, p)) // same frame: not yet occluding
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, p)) // next frame: occluding
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, p)) // not renewed: expired

	// Claim count reports the previous (active) frame.
	route_reset(&frame)
	route_claim(&frame, rl.Rectangle{0, 0, 1, 1})
	route_claim(&frame, rl.Rectangle{5, 5, 1, 1})
	testing.expect_value(t, route_claim_count(&frame), 0)
	route_begin_frame(&frame)
	testing.expect_value(t, route_claim_count(&frame), 2)

	// Overflow saturates to a whole-screen claim (over-blocking is the safe
	// failure mode) instead of dropping claims.
	route_reset(&frame)
	for _ in 0 ..< MAX_ROUTE_CLAIMS + 3 {
		route_claim(&frame, rl.Rectangle{0, 0, 1, 1})
	}
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, rl.Vector2{500, 500}))
}
