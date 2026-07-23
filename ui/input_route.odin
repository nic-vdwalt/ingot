// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Frame-scoped input routing / occlusion ("resolve hot once, topmost wins").
// Overlays (popups, modals, menus) claim rects; base widgets consult the
// claims before reporting hover, so a click on a popup never leaks through to
// the widgets underneath. Claims live one frame in a bounded double buffer:
// claims registered on frame N occlude on frame N+1, which keeps the layout
// single-pass (the one frame of hover latency matches Dear ImGui's own
// window-ordering latency and is invisible in practice). Claimants themselves
// keep hit-testing raw input — claims occlude non-claimant widgets only.
package ui

import rl "ingot:gfx"

// MAX_ROUTE_CLAIMS bounds overlay claims per frame (Tiger Style: put a limit
// on everything). Real UIs show a handful of popups at most.
MAX_ROUTE_CLAIMS :: 16

// Route_Claims is one frame's set of occluding rects (screen space).
Route_Claims :: struct {
	rects: [MAX_ROUTE_CLAIMS]rl.Rectangle,
	count: int,
	all:   bool, // modal: the whole screen is claimed
}

@(private = "file")
route_prev: Route_Claims
@(private = "file")
route_cur: Route_Claims

// route_begin_frame rotates the claim double buffer. Called once per frame
// from begin_cursor_frame, before any UI is drawn.
route_begin_frame :: proc() {
	assert(
		route_cur.count >= 0 && route_cur.count <= MAX_ROUTE_CLAIMS,
		"route_begin_frame: corrupt claim count",
	)
	route_prev = route_cur
	route_cur = {}
}

// route_claim registers an occluding rect (screen space) for the next frame.
// Saturates to a whole-screen claim when the bounded buffer is full — over-
// blocking is the safe failure mode for input.
route_claim :: proc(rect: rl.Rectangle) {
	assert(rect.width >= 0 && rect.height >= 0, "route_claim: negative rect")
	if route_cur.count >= MAX_ROUTE_CLAIMS {
		route_cur.all = true
		return
	}
	route_cur.rects[route_cur.count] = rect
	route_cur.count += 1
}

// route_claim_all claims the entire screen (modal dim layers).
route_claim_all :: proc() {
	route_cur.all = true
}

// route_reset clears both claim buffers (tests / teardown).
route_reset :: proc() {
	route_prev = {}
	route_cur = {}
}

// route_occluded_in reports whether a screen-space point is covered by a
// claim set. Pure — unit-testable without a window.
route_occluded_in :: proc(c: Route_Claims, p: rl.Vector2) -> bool {
	assert(c.count >= 0 && c.count <= MAX_ROUTE_CLAIMS, "route_occluded_in: corrupt count")
	if c.all do return true
	for i in 0 ..< c.count {
		if rl.CheckCollisionPointRec(p, c.rects[i]) do return true
	}
	return false
}

// route_occluded reports whether a screen-space point is covered by an
// overlay claimed last frame.
route_occluded :: proc(p: rl.Vector2) -> bool {
	return route_occluded_in(route_prev, p)
}

// route_claim_count returns the number of active (previous-frame) claims,
// counting a modal whole-screen claim as one. For debug introspection.
route_claim_count :: proc() -> int {
	if route_prev.all do return max(route_prev.count, 1)
	return route_prev.count
}
