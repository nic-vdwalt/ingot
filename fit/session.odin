package fit

import "ingot:ui"
import "ingot:ui_gfx"

Session_Init :: proc(session: ^Session, config: Session_Config = {}) {
	assert(session != nil && !session.inner.initialized, "Fit.Session_Init: invalid session")
	ui_gfx.session_init(&session.inner, to_session_config(config))
}

Session_Draw :: proc(session: ^Session, draw: Session_Draw_Proc, userdata: rawptr = nil) -> bool {
	assert(session != nil && session.inner.initialized, "Fit.Session_Draw: invalid session")
	assert(draw != nil && session.draw == nil, "Fit.Session_Draw: invalid callback")
	session.draw = draw
	session.userdata = userdata
	defer {
		session.draw = nil
		session.userdata = nil
	}
	return ui_gfx.session_draw(&session.inner, session_draw_bridge, session)
}

Session_Destroy :: proc(session: ^Session) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Destroy: invalid session")
	assert(!session.builder.bound && session.draw == nil, "Fit.Session_Destroy: frame open")
	ui_gfx.session_destroy(&session.inner)
	session^ = {}
}

Session_Set_Scale :: proc(session: ^Session, scale: f32) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Set_Scale: invalid session")
	ui_gfx.session_set_user_scale(&session.inner, scale)
}

Session_Set_Theme :: proc(session: ^Session, theme: Theme) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Set_Theme: invalid session")
	ui.ui_runtime_set_theme(ui_gfx.session_runtime(&session.inner), theme)
}

@(private = "file")
session_draw_bridge :: proc(inner: ^ui_gfx.Session, frame: ^ui.Ui_Frame, userdata: rawptr) {
	assert(inner != nil && frame != nil && userdata != nil, "fit session: invalid callback")
	session := cast(^Session)userdata
	assert(session.draw != nil && !session.builder.bound, "fit session: invalid state")
	size := ui_gfx.session_input(inner).screen_size
	rect := Rect{0, 0, i32(size.x), i32(size.y)}
	builder_open(&session.builder, frame, rect)
	session.draw(&session.builder, session.userdata)
	assert(session.builder.inner.prepared.depth == 0, "fit session: unbalanced builder")
	if !session.builder.inner.prepared.rendered do _ = Render(&session.builder)
	builder_close(&session.builder)
}
