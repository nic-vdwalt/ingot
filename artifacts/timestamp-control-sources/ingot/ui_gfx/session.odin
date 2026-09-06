package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

Session_Config :: struct {
	user_scale:        f32,
	semantics_enabled: bool,
	scale_metrics:     proc(scale: f32),
	scale_invalidate:  proc(),
}

Session_Draw_Proc :: #type proc(session: ^Session, frame: ^ui.Ui_Frame, userdata: rawptr)

Session :: struct {
	runtime:       ui.Ui_Runtime,
	frame:         ui.Ui_Frame,
	input:         ui.Ui_Input,
	output:        ui.Ui_Output,
	adapter:       Adapter,
	config:        Session_Config,
	pending_scale: bool,
	initialized:   bool,
	frame_open:    bool,
	graphics_open: bool,
}

session_init :: proc(session: ^Session, config: Session_Config = {}) {
	assert(session != nil, "session_init: nil session")
	session_init_context(session, rl.default_context(), config)
}

session_init_context :: proc(
	session: ^Session,
	gfx_context: ^rl.Context,
	config: Session_Config = {},
) {
	assert(session != nil && !session.initialized, "session_init_context: invalid session")
	assert(gfx_context != nil, "session_init_context: nil graphics context")
	assert(config.user_scale >= 0, "session_init_context: negative user scale")
	ui.ui_runtime_init(&session.runtime)
	adapter_init_context(&session.adapter, gfx_context, config.semantics_enabled)
	ui.ui_runtime_apply_platform_dpi(&session.runtime, user_scale = config.user_scale)
	ui.ui_runtime_set_scale_hooks(&session.runtime, config.scale_metrics, config.scale_invalidate)
	if config.semantics_enabled do _ = ui.a11y_init(&session.runtime)
	session.config = config
	session.initialized = true
	assert(session.runtime.initialized)
	assert(session.adapter.initialized)
	assert(session.initialized)
}

session_begin_frame :: proc(session: ^Session) -> ^ui.Ui_Frame {
	assert(session != nil && session.initialized, "session_begin_frame: invalid session")
	assert(!session.frame_open, "session_begin_frame: frame already open")
	assert(!session.frame.open, "session_begin_frame: UI frame already open")
	adapter_prepare_frame(&session.adapter, &session.runtime, &session.input)
	if session.pending_scale {
		ui.ui_runtime_apply_platform_dpi(
			&session.runtime,
			user_scale = session.config.user_scale,
			dpi_scale = session.input.dpi_scale,
		)
		session.pending_scale = false
	} else {
		_ = ui.ui_runtime_dpi_refresh(
			&session.runtime,
			user_scale = session.config.user_scale,
			dpi_scale = session.input.dpi_scale,
		)
	}
	adapter_open_frame(
		&session.adapter,
		&session.frame,
		&session.runtime,
		&session.input,
		&session.output,
	)
	session.frame_open = true
	assert(session.frame.open)
	assert(session.frame_open)
	return &session.frame
}

session_draw :: proc(session: ^Session, draw: Session_Draw_Proc, userdata: rawptr = nil) -> bool {
	assert(session != nil && session.initialized, "session_draw: invalid session")
	assert(draw != nil, "session_draw: nil callback")
	assert(!session.frame_open && !session.frame.open, "session_draw: frame already open")
	assert(!session.graphics_open && !session.adapter.graphics_open)
	graphics_frame: rl.Frame
	if !rl.frame_begin(&graphics_frame, session.adapter.gfx_context) {
		rl.frame_end(&graphics_frame)
		return true
	}
	session.graphics_open = true
	session.adapter.graphics_open = true
	session.adapter.gfx_frame = &graphics_frame
	frame := session_begin_frame(session)
	defer session_draw_finish(session, &graphics_frame)
	draw(session, frame, userdata)
	return true
}

session_end_frame :: proc(session: ^Session) {
	assert(session != nil && session.initialized, "session_end_frame: invalid session")
	assert(session.frame_open, "session_end_frame: no open frame")
	ui.a11y_frame_end(&session.frame)
	adapter_end_frame(&session.adapter, &session.frame)
	session.frame_open = false
	assert(!session.frame.open && !session.frame_open)
}

@(private = "file")
session_draw_finish :: proc(session: ^Session, graphics_frame: ^rl.Frame) {
	assert(session != nil && session.initialized, "session_draw_finish: invalid session")
	assert(graphics_frame != nil && rl.frame_available(graphics_frame))
	assert(session.frame_open && session.graphics_open, "session_draw_finish: no open frame")
	assert(session.adapter.graphics_open, "session_draw_finish: adapter frame closed")
	session_end_frame(session)
	session.adapter.gfx_frame = nil
	session.adapter.graphics_open = false
	rl.frame_end(graphics_frame)
	session.graphics_open = false
	assert(!session.frame_open && !session.graphics_open)
	assert(!session.adapter.graphics_open && session.adapter.gfx_frame == nil)
}

session_destroy :: proc(session: ^Session) {
	assert(session != nil && session.initialized, "session_destroy: invalid session")
	assert(!session.frame_open, "session_destroy: frame open")
	assert(!session.frame.open, "session_destroy: UI frame open")
	assert(!session.graphics_open, "session_destroy: graphics frame open")
	assert(!session.adapter.graphics_open, "session_destroy: adapter graphics open")
	ui.ui_frame_destroy(&session.frame)
	adapter_detach_runtime(&session.adapter, &session.runtime)
	adapter_destroy(&session.adapter)
	ui.ui_runtime_destroy(&session.runtime)
	session^ = {}
	assert(!session.initialized)
	assert(!session.frame_open)
}

session_runtime :: proc(session: ^Session) -> ^ui.Ui_Runtime {
	assert(session != nil && session.initialized, "session_runtime: invalid session")
	return &session.runtime
}

session_frame :: proc(session: ^Session) -> ^ui.Ui_Frame {
	assert(session != nil && session.initialized, "session_frame: invalid session")
	return &session.frame
}

session_input :: proc(session: ^Session) -> ^ui.Ui_Input {
	assert(session != nil && session.initialized, "session_input: invalid session")
	return &session.input
}

session_output :: proc(session: ^Session) -> ^ui.Ui_Output {
	assert(session != nil && session.initialized, "session_output: invalid session")
	return &session.output
}

session_set_user_scale :: proc(session: ^Session, user_scale: f32) {
	assert(session != nil && session.initialized, "session_set_user_scale: invalid session")
	assert(user_scale >= 0, "session_set_user_scale: negative scale")
	session.config.user_scale = user_scale
	if session.frame_open || session.graphics_open {
		session.pending_scale = true
		return
	}
	ui.ui_runtime_apply_platform_dpi(&session.runtime, user_scale)
}
