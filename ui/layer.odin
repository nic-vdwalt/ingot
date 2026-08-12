package ui

// A layer is a raised surface: one call couples input occlusion (route claim),
// paint order (z tier via the ambient z scope), and coordinates (screen space
// for every draw_* call inside). Higher z paints later and blocks input below.
//
// claim with area makes the surface modal over its rect; the zero rect opens a
// passive, paint-only layer (tooltips, toasts, drag ghosts).
layer_begin :: proc(frame: ^Ui_Frame, z: Z_Order, claim: Rectangle = {}) {
	assert(frame != nil && frame.open, "layer_begin: invalid frame")
	assert(claim.width >= 0 && claim.height >= 0, "layer_begin: negative claim")
	if claim.width > 0 && claim.height > 0 do route_claim(frame, claim, z)
	z_scope_begin(frame, z)
	// Reset the cumulative pane origin to zero: raised surfaces position in
	// screen space no matter how deep in panes the opener sits.
	ui_frame_pane_push(frame, -frame_pane_origin(frame))
	assert(frame.z_count > 0 && frame.pane_count > 0)
}

layer_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "layer_end: invalid frame")
	assert(frame.z_count > 0 && frame.pane_count > 0, "layer_end: no layer open")
	ui_frame_pane_pop(frame)
	z_scope_end(frame)
}
