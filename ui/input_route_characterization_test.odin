#+build !js
package ui

import "core:testing"


// Characterization of the router's behaviour BEFORE z-order was introduced.
// These procedures pin the contract every existing widget already relies on, so
// that adding a z-order to claims can be proven not to change it: the default
// ambient z is Z_CONTENT and the default claim z is Z_PANEL, so a strictly-above
// occlusion test must reproduce every outcome recorded here.
//
// They deliberately duplicate a little of route_claims_behaviour. That test
// mixes four concerns in one procedure; these name one property each, so a
// regression points at the property rather than at a line number.

@(private = "file")
route_test_frame :: proc(runtime: ^Ui_Runtime) -> Ui_Frame {
	assert(runtime != nil, "route_test_frame: nil runtime")
	frame: Ui_Frame
	frame.runtime = runtime
	frame.open = true
	return frame
}

// A claim blocks the point it covers and nothing else. This is the property the
// map canvas depends on: the panel's rect goes inert, the canvas beside it does
// not.
@(test)
route_claim_blocks_only_the_covered_point :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	route_claim(&frame, Rectangle{640, 0, 360, 600})
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, Vector2{800, 300}), "inside the claim")
	testing.expect(t, !route_occluded(&frame, Vector2{639, 300}), "left of the claim")
	testing.expect(t, !route_occluded(&frame, Vector2{800, 600}), "below the claim")
}

// The claim set is flat: a claimant cannot exempt itself, because occlusion
// carries no notion of ownership. This is the exact defect z-order removes, so
// it is recorded here as current behaviour rather than as a desired one.
@(test)
route_claim_occludes_its_own_claimant :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	panel := Rectangle{640, 0, 360, 600}
	route_claim(&frame, panel)
	route_begin_frame(&frame)
	// The claimant asks about a point inside its own panel and is told the
	// point is occluded, so its own widgets go inert.
	testing.expect(t, route_occluded(&frame, Vector2{700, 100}), "claimant occludes itself")
}

// Claims are one frame late by construction: the router answers from the
// previous frame's set, so an immediate-mode caller never depends on draw order
// within a frame.
@(test)
route_claims_activate_next_frame_and_expire_when_not_renewed :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	point := Vector2{5, 5}
	route_claim(&frame, Rectangle{0, 0, 10, 10})
	testing.expect(t, !route_occluded(&frame, point), "same frame does not occlude")
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, point), "next frame occludes")
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, point), "unrenewed claim expires")
}

// Overflow saturates rather than dropping claims. Over-occluding makes input
// inert, which is the safe direction: the alternative is a click reaching a
// surface the user cannot see.
@(test)
route_claim_overflow_saturates_to_the_whole_screen :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	for _ in 0 ..< MAX_ROUTE_CLAIMS + 3 {
		route_claim(&frame, Rectangle{0, 0, 1, 1})
	}
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, Vector2{5000, 5000}), "far outside every claim")
	testing.expect_value(t, route_claim_count(&frame), MAX_ROUTE_CLAIMS)
}

// The backdrop helper is the existing workaround for self-occlusion: it claims
// the four bands around a panel so the panel itself stays live. Recorded so the
// z-order replacement can be shown to subsume it.
@(test)
route_backdrop_blocks_around_the_panel_but_not_the_panel :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	panel := Rect_I32{300, 200, 200, 200}
	route_claim_backdrop(&frame, panel, 800, 600)
	route_begin_frame(&frame)
	testing.expect(t, !route_occluded(&frame, Vector2{400, 300}), "inside the panel stays live")
	testing.expect(t, route_occluded(&frame, Vector2{100, 100}), "above-left is blocked")
	testing.expect(t, route_occluded(&frame, Vector2{400, 100}), "above is blocked")
	testing.expect(t, route_occluded(&frame, Vector2{400, 500}), "below is blocked")
	testing.expect(t, route_occluded(&frame, Vector2{100, 300}), "left is blocked")
	testing.expect(t, route_occluded(&frame, Vector2{700, 300}), "right is blocked")
}

// --- z-order -----------------------------------------------------------------

// The defect recorded in route_claim_occludes_its_own_claimant, fixed: a panel
// claims its own rect at Z_PANEL and stays interactive inside a matching scope,
// while the canvas beneath it at Z_CONTENT goes inert.
@(test)
route_claim_does_not_occlude_its_own_z_scope :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	inside := Vector2{700, 100}
	route_claim(&frame, Rectangle{640, 0, 360, 600}, Z_PANEL)
	route_begin_frame(&frame)

	// Ambient Z_CONTENT: the canvas underneath is blocked.
	testing.expect(t, route_occluded(&frame, inside), "content below the panel is inert")

	// Inside the panel's own scope the same point is live.
	z_scope_begin(&frame, Z_PANEL)
	testing.expect(t, !route_occluded(&frame, inside), "the panel's own widgets stay live")
	z_scope_end(&frame)

	testing.expect(t, route_occluded(&frame, inside), "scope end restores content depth")
}

// A surface is occluded by anything strictly above it, so a popup opened from a
// panel still blocks that panel.
@(test)
route_higher_z_occludes_lower_surfaces :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	point := Vector2{50, 50}
	route_claim(&frame, Rectangle{0, 0, 200, 200}, Z_POPUP)
	route_begin_frame(&frame)

	z_scope_begin(&frame, Z_CONTENT)
	testing.expect(t, route_occluded(&frame, point), "content is below the popup")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_PANEL)
	testing.expect(t, route_occluded(&frame, point), "a panel is still below the popup")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_POPUP)
	testing.expect(t, !route_occluded(&frame, point), "the popup itself is live")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_MODAL)
	testing.expect(t, !route_occluded(&frame, point), "a modal above the popup is live")
	z_scope_end(&frame)
}

// Overflow saturates at the highest dropped z, so the fallback over-occludes
// rather than letting a click through to a surface the user cannot see.
@(test)
route_overflow_saturates_at_the_highest_dropped_z :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	for _ in 0 ..< MAX_ROUTE_CLAIMS do route_claim(&frame, Rectangle{0, 0, 1, 1}, Z_PANEL)
	route_claim(&frame, Rectangle{0, 0, 1, 1}, Z_MODAL) // dropped, raises all_z
	route_begin_frame(&frame)

	far := Vector2{5000, 5000}
	z_scope_begin(&frame, Z_POPUP)
	testing.expect(t, route_occluded(&frame, far), "a popup is below the dropped modal")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_MODAL)
	testing.expect(t, !route_occluded(&frame, far), "the modal's own depth is not occluded")
	z_scope_end(&frame)
}

// The ambient scope is a stack, and nesting may only ascend.
@(test)
z_scope_stack_nests_and_restores :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)

	testing.expect_value(t, frame_z(&frame), Z_CONTENT)
	z_scope_begin(&frame, Z_PANEL)
	testing.expect_value(t, frame_z(&frame), Z_PANEL)
	z_scope_begin(&frame, Z_MODAL)
	testing.expect_value(t, frame_z(&frame), Z_MODAL)
	z_scope_end(&frame)
	testing.expect_value(t, frame_z(&frame), Z_PANEL)
	z_scope_end(&frame)
	testing.expect_value(t, frame_z(&frame), Z_CONTENT)
	testing.expect_value(t, frame.z_count, 0)
}

// Z_Order is floating point so an application tier can sit between two named
// tiers without renumbering them.
@(test)
z_order_admits_a_tier_between_two_named_tiers :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	between := Z_Order(150) // above a panel, below a popup
	testing.expect(t, Z_PANEL < between && between < Z_POPUP, "tier sits between two named tiers")

	point := Vector2{10, 10}
	route_claim(&frame, Rectangle{0, 0, 100, 100}, between)
	route_begin_frame(&frame)

	z_scope_begin(&frame, Z_PANEL)
	testing.expect(t, route_occluded(&frame, point), "a panel is below the new tier")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_POPUP)
	testing.expect(t, !route_occluded(&frame, point), "a popup is above the new tier")
	z_scope_end(&frame)
}

// The z-order replacement for route_claim_backdrop: one full-screen claim at
// Z_MODAL blocks everything below it everywhere, while the modal's own widgets
// stay live inside a matching scope. This subsumes the four-band construction,
// which only blocked the region it had been told to compute.
@(test)
route_modal_claim_blocks_everything_below_and_nothing_above :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame := route_test_frame(&runtime)
	route_reset(&frame)
	defer route_reset(&frame)

	route_claim(&frame, Rectangle{0, 0, 800, 600}, Z_MODAL)
	route_begin_frame(&frame)

	inside_panel := Vector2{400, 300}
	outside_panel := Vector2{100, 100}

	z_scope_begin(&frame, Z_CONTENT)
	testing.expect(t, route_occluded(&frame, inside_panel), "content under the panel is inert")
	testing.expect(t, route_occluded(&frame, outside_panel), "content beside the panel is inert")
	z_scope_end(&frame)

	z_scope_begin(&frame, Z_MODAL)
	testing.expect(t, !route_occluded(&frame, inside_panel), "the modal's own widgets are live")
	z_scope_end(&frame)
}
