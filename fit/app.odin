package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

init :: proc(app: ^App, config: Config, callbacks: Callbacks, user_data: rawptr = nil) -> bool {
	assert(app != nil, "fit.init: nil app")
	return init_context(app, nil, config, callbacks, user_data)
}

init_context :: proc(
	app: ^App,
	gfx_context: ^gfx.Context,
	config: Config,
	callbacks: Callbacks,
	user_data: rawptr = nil,
) -> bool {
	assert(app != nil, "fit.init_context: nil app")
	assert(callbacks.draw != nil, "fit.init_context: nil draw callback")
	assert(app.inner.state == .Empty, "fit.init_context: app already initialized")
	assert(app.draw == nil, "fit.init_context: draw callback already bound")
	assert(app.shutdown == nil, "fit.init_context: shutdown callback already bound")
	assert(app.user_data == nil, "fit.init_context: context already bound")
	initialized := false
	if gfx_context == nil {
		initialized = ui_gfx.app_init(
			&app.inner,
			to_app_config(config),
			{ui = app_draw, shutdown = app_shutdown},
			app,
		)
	} else {
		initialized = ui_gfx.app_init_context(
			&app.inner,
			gfx_context,
			to_app_config(config),
			{ui = app_draw, shutdown = app_shutdown},
			app,
		)
	}
	if !initialized do return app_init_finish(app, callbacks, user_data, false)
	return app_init_finish(app, callbacks, user_data, true)
}

@(private = "package")
app_init_finish :: proc(
	app: ^App,
	callbacks: Callbacks,
	user_data: rawptr,
	initialized: bool,
) -> bool {
	assert(app != nil, "fit app init: nil app")
	assert(callbacks.draw != nil, "fit app init: nil draw callback")
	if !initialized {
		assert(app.inner.state == .Empty, "fit app init: failed app not empty")
		assert(app.draw == nil && app.shutdown == nil && app.user_data == nil)
		return false
	}
	assert(app.inner.state == .Ready, "fit app init: initialized app not ready")
	app.draw = callbacks.draw
	app.shutdown = callbacks.shutdown
	app.user_data = user_data
	assert(app.draw != nil, "fit app init: draw callback not bound")
	debug_owner_prepare(&app.builder)
	return true
}

start :: proc(app: ^App) -> bool {
	assert(app != nil, "fit.start: nil app")
	return ui_gfx.app_start(&app.inner)
}

tick :: proc(app: ^App) -> bool {
	assert(app != nil, "fit.tick: nil app")
	return ui_gfx.app_tick(&app.inner)
}

stop :: proc(app: ^App) -> bool {
	assert(app != nil, "fit.stop: nil app")
	return ui_gfx.app_stop(&app.inner)
}

// destroy returns false when the graphics context refused to close; see
// ui_gfx.app_destroy. Retry before releasing the app or its context storage.
destroy :: proc(app: ^App) -> bool {
	assert(app != nil, "fit.destroy: nil app")
	debug_owner_assert_quiescent(&app.builder)
	if !ui_gfx.app_destroy(&app.inner) do return false
	debug_owner_retire(&app.builder)
	return true
}

run :: proc(app: ^App, config: Config, draw: Draw_Proc, user_data: rawptr = nil) -> bool {
	assert(app != nil, "fit.run: nil app")
	assert(draw != nil, "fit.run: nil draw callback")
	assert(app.inner.state == .Empty, "fit.run: app already initialized")
	assert(app.draw == nil, "fit.run: draw callback already bound")
	assert(app.shutdown == nil, "fit.run: shutdown callback already bound")
	assert(app.user_data == nil, "fit.run: context already bound")
	app.draw = draw
	app.user_data = user_data
	ok := ui_gfx.app_run(
		&app.inner,
		to_app_config(config),
		{ui = app_draw, shutdown = app_shutdown},
		app,
	)
	if app.inner.state == .Empty do app_callbacks_reset(app)
	return ok
}

set_theme :: proc(app: ^App, theme: Theme) {
	assert(app != nil, "fit.set_theme: nil app")
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app.inner), theme.inner)
}

try_set_theme :: proc(app: ^App, theme: Theme) -> Theme_Validation {
	assert(app != nil, "fit.try_set_theme: nil app")
	return ui.ui_runtime_try_set_theme(ui_gfx.app_ui_runtime(&app.inner), theme.inner)
}

set_scale :: proc(app: ^App, scale: f32) {
	assert(app != nil, "fit.set_scale: nil app")
	ui_gfx.session_set_user_scale(&app.inner.session, scale)
}

scale :: proc(app: ^App) -> f32 {
	assert(app != nil && app.inner.state != .Empty, "fit.scale: invalid app")
	return ui_gfx.app_ui_runtime(&app.inner).scale
}

get_state :: proc(app: ^App) -> State {
	assert(app != nil, "fit.get_state: nil app")
	return app.inner.state
}

last_error :: proc(app: ^App) -> Error {
	assert(app != nil, "fit.last_error: nil app")
	return ui_gfx.app_error(&app.inner)
}

last_graphics_error :: proc(app: ^App) -> Graphics_Error {
	assert(app != nil, "fit.last_graphics_error: nil app")
	return ui_gfx.app_graphics_error(&app.inner)
}

screen_rect :: proc(app: ^App) -> Rect {
	assert(app != nil, "fit.screen_rect: nil app")
	return ui_gfx.app_screen_rect(&app.inner)
}

clear_color :: proc(app: ^App) -> Color {
	assert(app != nil, "fit.clear_color: nil app")
	return Color(ui_gfx.app_clear_color(&app.inner))
}

renderer_peak_usage :: proc() -> Renderer_Peaks {
	usage := gfx.renderer_peak_usage()
	return {
		vertices = usage.vertices,
		vertices_capacity = usage.vertices_capacity,
		indices = usage.indices,
		indices_capacity = usage.indices_capacity,
		geometry_stream_bytes = usage.geometry_stream_bytes,
		geometry_capacity_bytes = usage.geometry_capacity_bytes,
		uniform_stream_bytes = usage.uniform_stream_bytes,
		uniform_capacity_bytes = usage.uniform_capacity_bytes,
	}
}

paint_peak_usage :: proc(app: ^App) -> Paint_Peaks {
	assert(app != nil && app.inner.state != .Empty, "fit.paint_peak_usage: invalid app")
	output := ui_gfx.session_output(&app.inner.session)
	return {
		main_commands = output.main.peak_count,
		main_text_bytes = output.main.peak_text_len,
		overlay_commands = output.overlay.peak_count,
		overlay_text_bytes = output.overlay.peak_text_len,
	}
}

@(private = "file")
app_draw :: proc(inner: ^ui_gfx.App, root: ^ui.Ui, userdata: rawptr) {
	assert(inner != nil && root != nil && userdata != nil, "fit app: invalid callback")
	app := cast(^App)userdata
	assert(app.draw != nil, "fit app: nil draw callback")
	assert(!app.builder.bound, "fit app: builder already bound")
	debug_owner_prepare(&app.builder)
	app.builder.frame_ticket = ui.ui_frame_ticket(root.frame)
	app.builder.root = root^
	app.builder.bound = true
	begin(&app.builder)
	app.draw(&app.builder, app.user_data)
	assert(app.builder.inner.prepared.depth == 0, "fit app: unbalanced builder")
	if !app.builder.inner.prepared.rendered do _ = render(&app.builder)
	root^ = app.builder.root
	app.builder.bound = false
	app.builder.frame_ticket = {}
}

@(private = "file")
app_callbacks_reset :: proc(app: ^App) {
	assert(app != nil, "fit app: nil callback reset")
	assert(!app.builder.bound, "fit app: builder bound during callback reset")
	app.draw = nil
	app.shutdown = nil
	app.user_data = nil
}

@(private = "file")
app_shutdown :: proc(inner: ^ui_gfx.App, userdata: rawptr) {
	assert(inner != nil && userdata != nil, "fit app: invalid shutdown")
	app := cast(^App)userdata
	assert(!app.builder.bound, "fit app: builder still bound")
	if app.shutdown != nil do app.shutdown(app, app.user_data)
	app_callbacks_reset(app)
}
