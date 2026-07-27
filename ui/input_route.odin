// LIB-CANDIDATE: imports only core:*.
package ui


MAX_ROUTE_CLAIMS :: 16

Route_Claims :: struct {
	rects: [MAX_ROUTE_CLAIMS]Rectangle,
	count: int,
	all:   bool,
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


route_claim :: proc(frame: ^Ui_Frame, rect: Rectangle) {
	assert(frame != nil && frame.open, "route_claim: invalid frame")
	assert(rect.width >= 0 && rect.height >= 0, "route_claim: negative rect")
	state := &frame.route
	if state.cur.count >= MAX_ROUTE_CLAIMS {
		state.cur.all = true
		return
	}
	state.cur.rects[state.cur.count] = rect
	state.cur.count += 1
	assert(state.cur.count > 0)
	assert(state.cur.count <= MAX_ROUTE_CLAIMS)
}

route_claim_all :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "route_claim_all: invalid frame")
	frame.route.cur.all = true
	assert(frame.route.cur.all)
}

route_reset :: proc(frame: ^Ui_Frame) {
	assert(frame != nil, "route_reset: nil frame")
	frame.route = {}
	assert(frame.route.prev.count == 0)
	assert(frame.route.cur.count == 0)
}

route_occluded_in :: proc(claims: Route_Claims, point: Vector2) -> bool {
	assert(claims.count >= 0 && claims.count <= MAX_ROUTE_CLAIMS)
	if claims.all do return true
	for i in 0 ..< claims.count {
		if point_in_rect(point, claims.rects[i]) do return true
	}
	return false
}

route_occluded :: proc(frame: ^Ui_Frame, point: Vector2) -> bool {
	assert(frame != nil && frame.open, "route_occluded: invalid frame")
	return route_occluded_in(frame.route.prev, point)
}

route_claim_count :: proc(frame: ^Ui_Frame) -> int {
	assert(frame != nil, "route_claim_count: nil frame")
	if frame.route.prev.all do return max(frame.route.prev.count, 1)
	return frame.route.prev.count
}
