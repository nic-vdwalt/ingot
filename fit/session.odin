package fit

import "ingot:ui"
import "ingot:ui_gfx"

session_init :: proc(session: ^Session, config: Session_Config = {}) {
	assert(session != nil && !session.inner.initialized, "fit.session_init: invalid session")
	ui_gfx.session_init(&session.inner, config)
	debug_owner_prepare(&session.builder)
}

session_draw :: proc(session: ^Session, draw: Session_Draw_Proc, user_data: rawptr = nil) -> bool {
	assert(session != nil && session.inner.initialized, "fit.session_draw: invalid session")
	assert(draw != nil && session.draw == nil, "fit.session_draw: invalid callback")
	session.draw = draw
	session.user_data = user_data
	defer {
		session.draw = nil
		session.user_data = nil
	}
	return ui_gfx.session_draw(&session.inner, session_draw_bridge, session)
}

session_destroy :: proc(session: ^Session) {
	assert(session != nil && session.inner.initialized, "fit.session_destroy: invalid session")
	assert(!session.builder.bound && session.draw == nil, "fit.session_destroy: frame open")
	debug_owner_retire(&session.builder)
	epoch := session.builder.owner.epoch
	ui_gfx.session_destroy(&session.inner)
	session^ = {}
	session.builder.owner.epoch = epoch
}

session_set_scale :: proc(session: ^Session, scale: f32) {
	assert(session != nil && session.inner.initialized, "fit.session_set_scale: invalid session")
	ui_gfx.session_set_user_scale(&session.inner, scale)
}

session_scale :: proc(session: ^Session) -> f32 {
	assert(session != nil && session.inner.initialized, "fit.session_scale: invalid session")
	return ui_gfx.session_runtime(&session.inner).scale
}

session_set_theme :: proc(session: ^Session, theme: Theme) {
	assert(session != nil && session.inner.initialized, "fit.session_set_theme: invalid session")
	ui.ui_runtime_set_theme(ui_gfx.session_runtime(&session.inner), theme.inner)
}

session_try_set_theme :: proc(session: ^Session, theme: Theme) -> Theme_Validation {
	assert(
		session != nil && session.inner.initialized,
		"fit.session_try_set_theme: invalid session",
	)
	return ui.ui_runtime_try_set_theme(ui_gfx.session_runtime(&session.inner), theme.inner)
}

@(private = "file")
session_draw_bridge :: proc(inner: ^ui_gfx.Session, frame: ^ui.Ui_Frame, userdata: rawptr) {
	assert(inner != nil && frame != nil && userdata != nil, "fit session: invalid callback")
	session := cast(^Session)userdata
	assert(session.draw != nil && !session.builder.bound, "fit session: invalid state")
	size := ui_gfx.session_input(inner).screen_size
	rect := Rect{0, 0, i32(size.x), i32(size.y)}
	builder_open(&session.builder, frame, rect)
	session.draw(&session.builder, session.user_data)
	assert(session.builder.inner.prepared.depth == 0, "fit session: unbalanced builder")
	if !session.builder.inner.prepared.rendered do _ = render(&session.builder)
	builder_close(&session.builder)
}
