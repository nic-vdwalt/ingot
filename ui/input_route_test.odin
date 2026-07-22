#+build !js
package ui

import "core:testing"
import rl "ingot:gfx"

// Route claims live in module state, so all router behaviour is exercised in
// one sequential test (the runner executes @(test) procs in parallel).
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

	// Double buffer: claims take effect next frame and expire when not renewed.
	route_reset()
	defer route_reset()
	p := rl.Vector2{5, 5}
	route_claim(rl.Rectangle{0, 0, 10, 10})
	testing.expect(t, !route_occluded(p)) // same frame: not yet occluding
	route_begin_frame()
	testing.expect(t, route_occluded(p)) // next frame: occluding
	route_begin_frame()
	testing.expect(t, !route_occluded(p)) // not renewed: expired

	// Claim count reports the previous (active) frame.
	route_reset()
	route_claim(rl.Rectangle{0, 0, 1, 1})
	route_claim(rl.Rectangle{5, 5, 1, 1})
	testing.expect_value(t, route_claim_count(), 0)
	route_begin_frame()
	testing.expect_value(t, route_claim_count(), 2)

	// Overflow saturates to a whole-screen claim (over-blocking is the safe
	// failure mode) instead of dropping claims.
	route_reset()
	for _ in 0 ..< MAX_ROUTE_CLAIMS + 3 {
		route_claim(rl.Rectangle{0, 0, 1, 1})
	}
	route_begin_frame()
	testing.expect(t, route_occluded(rl.Vector2{500, 500}))
}
