#+build !js
package ui

import "core:testing"


@(test)
route_claims_behaviour :: proc(t: ^testing.T) {
	// Pure claim-set queries. A hand-built set must state its z: the zero value
	// is Z_CONTENT, and a claim only occludes what sits strictly below it.
	c: Route_Claims
	testing.expect(t, !route_occluded_in(c, Vector2{10, 10}))

	c.rects[0] = Rectangle{100, 100, 50, 50}
	c.zs[0] = Z_PANEL
	c.count = 1
	testing.expect(t, route_occluded_in(c, Vector2{120, 120}))
	testing.expect(t, !route_occluded_in(c, Vector2{99, 120}))
	testing.expect(t, !route_occluded_in(c, Vector2{120, 151}))
	// A widget at the claim's own z is not occluded by it.
	testing.expect(t, !route_occluded_in(c, Vector2{120, 120}, Z_PANEL))

	all: Route_Claims
	all.all = true
	all.all_z = Z_PANEL
	testing.expect(t, route_occluded_in(all, Vector2{0, 0}))
	testing.expect(t, route_occluded_in(all, Vector2{9999, 9999}))
	testing.expect(t, !route_occluded_in(all, Vector2{0, 0}, Z_MODAL))

	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	frame.runtime = &runtime
	frame.open = true

	// Double buffer: claims take effect next frame and expire when not renewed.
	route_reset(&frame)
	defer route_reset(&frame)
	p := Vector2{5, 5}
	route_claim(&frame, Rectangle{0, 0, 10, 10})
	testing.expect(t, !route_occluded(&frame, p)) // same frame: not yet occluding
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, p)) // next frame: occluding
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, p)) // not renewed: expired

	// Claim count reports the previous (active) frame.
	route_reset(&frame)
	route_claim(&frame, Rectangle{0, 0, 1, 1})
	route_claim(&frame, Rectangle{5, 5, 1, 1})
	testing.expect_value(t, route_claim_count(&frame), 0)
	route_begin_frame(&frame)
	testing.expect_value(t, route_claim_count(&frame), 2)

	// Overflow saturates to a whole-screen claim (over-blocking is the safe
	// failure mode) instead of dropping claims.
	route_reset(&frame)
	for _ in 0 ..< MAX_ROUTE_CLAIMS + 3 {
		route_claim(&frame, Rectangle{0, 0, 1, 1})
	}
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, Vector2{500, 500}))
}

@(test)
route_block_z_reports_the_topmost_claim :: proc(t: ^testing.T) {
	// An uncovered point is blocked by nothing, which must compare as
	// unblocked even against the lowest named tier.
	c: Route_Claims
	testing.expect_value(t, route_block_z_in(c, Vector2{10, 10}), Z_NONE)
	testing.expect(t, route_block_z_in(c, Vector2{10, 10}) <= Z_CONTENT)

	// A single claim reports its own z, and only inside its rect.
	c.rects[0] = Rectangle{100, 100, 50, 50}
	c.zs[0] = Z_PANEL
	c.count = 1
	testing.expect_value(t, route_block_z_in(c, Vector2{120, 120}), Z_PANEL)
	testing.expect_value(t, route_block_z_in(c, Vector2{99, 120}), Z_NONE)

	// Overlapping claims report the highest, whatever order they were made in.
	c.rects[1] = Rectangle{110, 110, 50, 50}
	c.zs[1] = Z_MODAL
	c.count = 2
	testing.expect_value(t, route_block_z_in(c, Vector2{120, 120}), Z_MODAL)
	c.zs[0] = Z_TOAST
	testing.expect_value(t, route_block_z_in(c, Vector2{120, 120}), Z_TOAST)

	// An overflowed set claims everywhere at its saturated z.
	all: Route_Claims
	all.all = true
	all.all_z = Z_POPUP
	testing.expect_value(t, route_block_z_in(all, Vector2{0, 0}), Z_POPUP)
	testing.expect_value(t, route_block_z_in(all, Vector2{9999, 9999}), Z_POPUP)
}

@(test)
route_occluded_matches_route_block_z :: proc(t: ^testing.T) {
	// route_occluded_in is defined as "something strictly above me claims this
	// point". Pin that identity so the two cannot drift apart.
	sets: [3]Route_Claims
	sets[1].rects[0] = Rectangle{0, 0, 100, 100}
	sets[1].zs[0] = Z_PANEL
	sets[1].count = 1
	sets[2].all = true
	sets[2].all_z = Z_MODAL

	points := [3]Vector2{{10, 10}, {50, 50}, {500, 500}}
	zs := [6]Z_Order{Z_CONTENT, Z_PANEL, Z_POPUP, Z_MODAL, Z_TOAST, Z_TOOLTIP}
	for claims in sets {
		for point in points {
			for z in zs {
				testing.expect_value(
					t,
					route_occluded_in(claims, point, z),
					route_block_z_in(claims, point) > z,
				)
			}
		}
	}
}
