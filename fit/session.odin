package fit

import rl "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

Session_Init :: proc(session: ^Session, config: Session_Config = {}) {
	assert(session != nil && !session.inner.initialized, "Fit.Session_Init: invalid session")
	ui_gfx.session_init(&session.inner, config)
}

Session_Begin :: proc(session: ^Session) -> (^Builder, bool) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Begin: invalid session")
	assert(!session.open && !session.builder.bound, "Fit.Session_Begin: frame already open")
	frame, acquired := ui_gfx.session_acquire_frame(&session.inner)
	if !acquired do return nil, false
	session.frame = frame
	rect := Rect{0, 0, rl.GetScreenWidth(), rl.GetScreenHeight()}
	builder_open(&session.builder, frame.ui, rect)
	session.open = true
	return &session.builder, true
}

Session_End :: proc(session: ^Session) {
	assert(session != nil && session.inner.initialized, "Fit.Session_End: invalid session")
	assert(session.open && session.builder.bound, "Fit.Session_End: no open frame")
	assert(session.builder.inner.prepared.depth == 0, "Fit.Session_End: unbalanced builder")
	_ = Render(&session.builder)
	builder_close(&session.builder)
	ui_gfx.session_present_frame(&session.frame)
	session.open = false
}

Session_Destroy :: proc(session: ^Session) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Destroy: invalid session")
	assert(!session.open && !session.builder.bound, "Fit.Session_Destroy: frame open")
	ui_gfx.session_destroy(&session.inner)
	session^ = {}
}

Session_Set_Scale :: proc(session: ^Session, scale: f32) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Set_Scale: invalid session")
	ui_gfx.session_set_user_scale(&session.inner, scale)
}

Session_Set_Theme :: proc(session: ^Session, theme: ui.Theme) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Set_Theme: invalid session")
	ui.ui_runtime_set_theme(ui_gfx.session_runtime(&session.inner), theme)
}
