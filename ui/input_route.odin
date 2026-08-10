// LIB-CANDIDATE: imports only core:*.
package ui


MAX_ROUTE_CLAIMS :: 16

// Z_Order orders pointer input between stacked surfaces. It is floating point
// so a consumer can slot a surface between two named tiers without renumbering
// them; the named tiers are integer-valued so ordinary code reads as integers.
//
// A widget is occluded only by claims STRICTLY ABOVE its own z-order. Equal z
// does not occlude, which is what lets a surface claim its own rect - blocking
// everything beneath it - while staying interactive itself.
Z_Order :: distinct f32

Z_CONTENT :: Z_Order(0) // map canvas, 3D viewport, document body
Z_PANEL :: Z_Order(100) // docked and floating panels, toolbars, chrome
Z_POPUP :: Z_Order(200) // dropdown, combobox, context menu, date picker
Z_MODAL :: Z_Order(300) // modal dialogs
Z_TOAST :: Z_Order(400) // transient notifications
Z_TOOLTIP :: Z_Order(500) // hover tips (usually claim no input at all)

// Z_NONE is below every named tier, so "nothing covers this point" compares as
// unblocked against any surface depth.
Z_NONE :: Z_Order(min(f32))

Route_Claims :: struct {
	rects: [MAX_ROUTE_CLAIMS]Rectangle,
	zs:    [MAX_ROUTE_CLAIMS]Z_Order,
	count: int,
	all:   bool,
	// Highest z among claims dropped on overflow. Saturating to the maximum
	// over-occludes rather than under-occludes: making input inert is the safe
	// direction to fail, because the alternative is a click reaching a surface
	// the user cannot see.
	all_z: Z_Order,
}

Input_Route_State :: struct {
	prev: Route_Claims,
	cur:  Route_Claims,
}

route_begin_frame :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "route_begin_frame: nil frame")
	state := &frame.route
	assert(state.cur.count >= 0 && state.cur.count <= MAX_ROUTE_CLAIMS)
	state.prev = state.cur
	state.cur = {}
	assert(state.prev.count >= 0)
	assert(state.prev.count <= MAX_ROUTE_CLAIMS)
	assert(state.cur.count == 0)
}

// route_claim marks a rectangle as owned by the caller at z-order `z` for the
// NEXT frame, so widgets beneath it neither hover nor click.
//
// A widget is occluded only by claims STRICTLY ABOVE its own z-order, so a
// surface may claim its own rect and stay interactive: pair the claim with a
// z_scope_begin at the same z around the surface's own widgets. Claims default
// to Z_PANEL and the ambient scope defaults to Z_CONTENT, so an unscoped caller
// blocks ordinary content exactly as a flat claim always did.
route_claim :: proc(frame: ^Ui_Frame, rect: Rectangle, z: Z_Order = Z_PANEL) {
	assert(frame != nil && frame.open, "route_claim: invalid frame")
	assert(rect.width >= 0 && rect.height >= 0, "route_claim: negative rect")
	// A NaN z compares false against every other z, silently disabling this
	// claim's occlusion; reject it at the one entry point that stores a z.
	assert(z == z, "route_claim: z-order is NaN")
	state := &frame.route
	if state.cur.count >= MAX_ROUTE_CLAIMS {
		state.cur.all = true
		state.cur.all_z = max(state.cur.all_z, z)
		return
	}
	state.cur.rects[state.cur.count] = rect
	state.cur.zs[state.cur.count] = z
	state.cur.count += 1
	assert(state.cur.count > 0)
	assert(state.cur.count <= MAX_ROUTE_CLAIMS)
}

// route_claim_all occludes the whole surface at `z`, for a caller that owns
// every pointer position rather than a rectangle.
route_claim_all :: proc(frame: ^Ui_Frame, z: Z_Order = Z_PANEL) {
	assert(frame != nil && frame.open, "route_claim_all: invalid frame")
	assert(z == z, "route_claim_all: z-order is NaN")
	frame.route.cur.all = true
	frame.route.cur.all_z = max(frame.route.cur.all_z, z)
	assert(frame.route.cur.all)
}

route_reset :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "route_reset: nil frame")
	frame.route = {}
	assert(frame.route.prev.count == 0)
	assert(frame.route.cur.count == 0)
}

// route_block_z_in reports the highest z claiming `point`, or Z_NONE when no
// claim covers it. Occlusion is derived from this: a point is occluded for a
// surface at z when something strictly above z claims it.
//
// Separate from route_occluded_in because a press origin must be captured when
// the press happens but read by widgets at many different depths, so the depth
// comparison cannot be folded in at capture time.
route_block_z_in :: proc(claims: Route_Claims, point: Vector2) -> Z_Order {
	assert(claims.count >= 0 && claims.count <= MAX_ROUTE_CLAIMS)
	top := Z_NONE
	if claims.all do top = claims.all_z
	for i in 0 ..< claims.count {
		if point_in_rect(point, claims.rects[i]) do top = max(top, claims.zs[i])
	}
	return top
}

// route_block_z reports the highest z claiming `point` among the claims active
// this frame.
route_block_z :: proc(frame: ^Ui_Frame, point: Vector2) -> Z_Order {
	assert(frame != nil && frame.open, "route_block_z: invalid frame")
	return route_block_z_in(frame.route.prev, point)
}

// route_occluded_in reports whether `point` is covered by a claim strictly
// above `z`. Equal z does not occlude: that is what lets a surface claim its
// own rect without going inert.
route_occluded_in :: proc(claims: Route_Claims, point: Vector2, z: Z_Order = Z_CONTENT) -> bool {
	return route_block_z_in(claims, point) > z
}

// route_occluded tests against the ambient z-scope, so ordinary widgets need
// not know their own depth.
route_occluded :: proc(frame: ^Ui_Frame, point: Vector2) -> bool {
	assert(frame != nil && frame.open, "route_occluded: invalid frame")
	return route_occluded_in(frame.route.prev, point, frame_z(frame))
}

route_claim_count :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil, "route_claim_count: nil frame")
	if frame.route.prev.all do return max(frame.route.prev.count, 1)
	return frame.route.prev.count
}
