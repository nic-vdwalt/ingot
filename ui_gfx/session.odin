package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

App_Session_Config :: struct {
	user_scale:        f32,
	semantics_enabled: bool,
}

App_Session :: struct {
	runtime:     ui.Ui_Runtime,
	frame:       ui.Ui_Frame,
	input:       ui.Ui_Input,
	output:      ui.Ui_Output,
	adapter:     Adapter,
	config:      App_Session_Config,
	initialized: bool,
	frame_open:  bool,
}

app_session_init :: proc(session: ^App_Session, config: App_Session_Config = {}) {
	app_session_init_context(session, rl.default_context(), config)
}

app_session_init_context :: proc(
	session: ^App_Session,
	gfx_context: ^rl.Context,
	config: App_Session_Config = {},
) {
	assert(session != nil && !session.initialized, "app_session_init_context: invalid session")
	assert(gfx_context != nil, "app_session_init_context: nil graphics context")
	assert(config.user_scale >= 0, "app_session_init_context: negative user scale")
	ui.ui_runtime_init(&session.runtime)
	adapter_init_context(&session.adapter, gfx_context)
	ui.ui_runtime_apply_platform_dpi(&session.runtime, user_scale = config.user_scale)
	if config.semantics_enabled do _ = ui.a11y_init(&session.runtime)
	session.config = config
	session.initialized = true
}

app_session_begin_frame :: proc(session: ^App_Session) -> ^ui.Ui_Frame {
	assert(session != nil && session.initialized, "app_session_begin_frame: invalid session")
	assert(!session.frame_open, "app_session_begin_frame: frame already open")
	adapter_prepare_frame(&session.adapter, &session.runtime, &session.input)
	_ = ui.ui_runtime_dpi_refresh(
		&session.runtime,
		user_scale = session.config.user_scale,
		dpi_scale = session.input.dpi_scale,
	)
	adapter_open_frame(
		&session.adapter,
		&session.frame,
		&session.runtime,
		&session.input,
		&session.output,
	)
	session.frame_open = true
	return &session.frame
}

app_session_end_frame :: proc(session: ^App_Session) {
	assert(session != nil && session.initialized, "app_session_end_frame: invalid session")
	assert(session.frame_open, "app_session_end_frame: no open frame")
	ui.a11y_frame_end(&session.frame)
	adapter_end_frame(&session.adapter, &session.frame)
	session.frame_open = false
}

app_session_destroy :: proc(session: ^App_Session) {
	assert(session != nil && session.initialized, "app_session_destroy: invalid session")
	assert(!session.frame_open, "app_session_destroy: frame open")
	ui.ui_frame_destroy(&session.frame)
	adapter_destroy(&session.adapter)
	ui.ui_runtime_destroy(&session.runtime)
	session^ = {}
}
