package ui_gfx

import rl "ingot:gfx"
import "ingot:ui"

Session_Config :: struct {
	user_scale:        f32,
	semantics_enabled: bool,
}

Session_Frame :: struct {
	owner:      ^Session,
	ui:         ^ui.Ui_Frame,
	generation: u64,
}

Session :: struct {
	runtime:          ui.Ui_Runtime,
	frame:            ui.Ui_Frame,
	input:            ui.Ui_Input,
	output:           ui.Ui_Output,
	adapter:          Adapter,
	config:           Session_Config,
	gfx_scope:        rl.Context_Scope,
	frame_generation: u64,
	initialized:      bool,
	frame_open:       bool,
	graphics_open:    bool,
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
	adapter_init_context(&session.adapter, gfx_context)
	ui.ui_runtime_apply_platform_dpi(&session.runtime, user_scale = config.user_scale)
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
	assert(session.frame.open)
	assert(session.frame_open)
	return &session.frame
}

session_acquire_frame :: proc(session: ^Session) -> (frame: Session_Frame, acquired: bool) {
	assert(session != nil && session.initialized, "session_acquire_frame: invalid session")
	assert(!session.frame_open && !session.frame.open, "session_acquire_frame: frame already open")
	assert(!session.graphics_open && !session.adapter.graphics_open)
	assert(session.frame_generation < max(u64), "session_acquire_frame: generation overflow")
	session.gfx_scope = rl.context_scope_enter(session.adapter.gfx_context)
	rl.BeginDrawing()
	if !rl.context_frame_available(session.adapter.gfx_context) {
		rl.EndDrawing()
		rl.context_scope_leave(&session.gfx_scope)
		return {}, false
	}
	session.graphics_open = true
	session.adapter.graphics_open = true
	session.frame_generation += 1
	ui_frame := session_begin_frame(session)
	frame = {
		owner      = session,
		ui         = ui_frame,
		generation = session.frame_generation,
	}
	assert(frame.generation > 0 && frame.ui == &session.frame)
	return frame, true
}

session_end_frame :: proc(session: ^Session) {
	assert(session != nil && session.initialized, "session_end_frame: invalid session")
	assert(session.frame_open, "session_end_frame: no open frame")
	ui.a11y_frame_end(&session.frame)
	adapter_end_frame(&session.adapter, &session.frame)
	session.frame_open = false
	assert(!session.frame.open && !session.frame_open)
}

session_present_frame :: proc(frame: ^Session_Frame) {
	assert(frame != nil, "session_present_frame: nil frame")
	assert(frame.owner != nil, "session_present_frame: missing owner")
	session := frame.owner
	assert(session.initialized, "session_present_frame: invalid session")
	assert(session.frame_open, "session_present_frame: no open frame")
	assert(frame.generation > 0, "session_present_frame: invalid generation")
	assert(frame.generation == session.frame_generation, "session_present_frame: stale frame")
	assert(frame.ui == &session.frame, "session_present_frame: UI frame mismatch")
	assert(session.graphics_open && session.adapter.graphics_open)
	session_end_frame(session)
	session.adapter.graphics_open = false
	rl.EndDrawing()
	rl.context_scope_leave(&session.gfx_scope)
	session.graphics_open = false
	frame^ = {}
	free_all(context.temp_allocator)
	assert(!session.frame_open && !session.graphics_open)
	assert(!session.adapter.graphics_open && frame.owner == nil)
}

session_destroy :: proc(session: ^Session) {
	assert(session != nil && session.initialized, "session_destroy: invalid session")
	assert(!session.frame_open, "session_destroy: frame open")
	assert(!session.frame.open, "session_destroy: UI frame open")
	assert(!session.graphics_open, "session_destroy: graphics frame open")
	assert(!session.adapter.graphics_open, "session_destroy: adapter graphics open")
	ui.ui_frame_destroy(&session.frame)
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
	ui.ui_runtime_apply_platform_dpi(&session.runtime, user_scale)
}
