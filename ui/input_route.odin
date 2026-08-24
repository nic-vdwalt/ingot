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

// Paint tiers bucket the continuous Z_Order space into the six named bands.
// A command's tier decides which replay scan paints it; within a tier,
// submission order is preserved. An application z between two named tiers
// (e.g. Z_PANEL + 50) paints with the band below it.
PAINT_TIER_COUNT :: 6

z_paint_tier :: proc(z: Z_Order) -> u8 {
	// NaN compares false against every threshold and would silently land in
	// tier 0; reject it like z_scope_begin does.
	assert(z == z, "z_paint_tier: z-order is NaN")
	thresholds := [PAINT_TIER_COUNT - 1]Z_Order{Z_PANEL, Z_POPUP, Z_MODAL, Z_TOAST, Z_TOOLTIP}
	tier := u8(0)
	for threshold in thresholds do if z >= threshold do tier += 1
	assert(int(tier) < PAINT_TIER_COUNT, "z_paint_tier: tier out of range")
	return tier
}

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
// current frame and, when renewed, the next frame. Queries combine current and
// previous claims so late-submitted overlays cannot expose lower content.
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

// route_block_z reports the highest active current- or previous-frame claim.
route_block_z :: proc(frame: ^Ui_Frame, point: Vector2) -> Z_Order {
	assert(frame != nil && frame.open, "route_block_z: invalid frame")
	assert(frame.route.prev.count >= 0 && frame.route.prev.count <= MAX_ROUTE_CLAIMS)
	assert(frame.route.cur.count >= 0 && frame.route.cur.count <= MAX_ROUTE_CLAIMS)
	previous := route_block_z_in(frame.route.prev, point)
	current := route_block_z_in(frame.route.cur, point)
	return max(previous, current)
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
	return route_block_z(frame, point) > frame_z(frame)
}

route_claim_count :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil, "route_claim_count: nil frame")
	count := frame.route.prev.count + frame.route.cur.count
	if frame.route.prev.all || frame.route.cur.all do count = max(count, 1)
	return min(count, MAX_ROUTE_CLAIMS)
}
