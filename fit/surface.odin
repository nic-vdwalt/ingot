package fit

import "ingot:ui"

Surface_Frame :: proc(surface: ^Surface) -> rawptr {
	assert(surface != nil && surface.inner != nil, "Fit.Surface_Frame: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface_Frame: closed surface")
	return surface.inner.frame
}

Surface_Viewport :: proc(surface: ^Surface) -> Rect {
	assert(surface != nil && surface.inner != nil, "Fit.Surface_Viewport: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface_Viewport: closed surface")
	return ui.frame_viewport(surface.inner.frame)
}

Surface_Pane_Origin :: proc(surface: ^Surface) -> ui.Vector2 {
	assert(surface != nil && surface.inner != nil, "Fit.Surface_Pane_Origin: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Surface_Pane_Origin: closed surface")
	return ui.frame_pane_origin(surface.inner.frame)
}

Request_Redraw :: proc(surface: ^Surface) {
	assert(surface != nil && surface.inner != nil, "Fit.Request_Redraw: invalid surface")
	assert(surface.inner.open && surface.inner.frame != nil, "Fit.Request_Redraw: closed surface")
	ui.request_redraw(surface.inner.frame)
}
