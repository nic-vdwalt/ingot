package fit

import "ingot:ui"
import "ingot:ui_gfx"

Session_Init :: proc(session: ^Session, config: Session_Config = {}) {
	assert(session != nil && !session.inner.initialized, "Fit.Session_Init: invalid session")
	ui_gfx.session_init(&session.inner, to_session_config(config))
	ui.ui_runtime_set_scale_hooks(
		ui_gfx.session_runtime(&session.inner),
		config.scale_metrics,
		config.scale_invalidate,
	)
}

Session_Draw :: proc(session: ^Session, draw: Session_Draw_Proc, user_data: rawptr = nil) -> bool {
	assert(session != nil && session.inner.initialized, "Fit.Session_Draw: invalid session")
	assert(draw != nil && session.draw == nil, "Fit.Session_Draw: invalid callback")
	session.draw = draw
	session.user_data = user_data
	defer {
		session.draw = nil
		session.user_data = nil
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

Session_Scale :: proc(session: ^Session) -> f32 {
	assert(session != nil && session.inner.initialized, "Fit.Session_Scale: invalid session")
	return ui_gfx.session_runtime(&session.inner).scale
}

Session_Set_Theme :: proc(session: ^Session, theme: Theme) {
	assert(session != nil && session.inner.initialized, "Fit.Session_Set_Theme: invalid session")
	ui.ui_runtime_set_theme(ui_gfx.session_runtime(&session.inner), theme.inner)
}

Session_Try_Set_Theme :: proc(session: ^Session, theme: Theme) -> Theme_Validation {
	assert(
		session != nil && session.inner.initialized,
		"Fit.Session_Try_Set_Theme: invalid session",
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
	if !session.builder.inner.prepared.rendered do _ = Render(&session.builder)
	builder_close(&session.builder)
}
