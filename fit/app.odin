package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

Init :: proc(app: ^App, config: Config, callbacks: Callbacks, userdata: rawptr = nil) -> bool {
	assert(app != nil, "Fit.Init: nil app")
	return Init_Context(app, nil, config, callbacks, userdata)
}

Init_Context :: proc(
	app: ^App,
	gfx_context: ^gfx.Context,
	config: Config,
	callbacks: Callbacks,
	userdata: rawptr = nil,
) -> bool {
	assert(app != nil, "Fit.Init_Context: nil app")
	assert(callbacks.draw != nil, "Fit.Init_Context: nil draw callback")
	assert(app.inner.state == .Empty, "Fit.Init_Context: app already initialized")
	assert(app.draw == nil, "Fit.Init_Context: draw callback already bound")
	assert(app.shutdown == nil, "Fit.Init_Context: shutdown callback already bound")
	assert(app.userdata == nil, "Fit.Init_Context: userdata already bound")
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
	if !initialized do return false
	app.draw = callbacks.draw
	app.shutdown = callbacks.shutdown
	app.userdata = userdata
	ui.ui_runtime_set_scale_hooks(
		ui_gfx.app_ui_runtime(&app.inner),
		config.session.scale_metrics,
		config.session.scale_invalidate,
	)
	assert(app.inner.state == .Ready, "Fit.Init_Context: invalid initialized state")
	assert(app.draw != nil, "Fit.Init_Context: draw callback not bound")
	return true
}

Start :: proc(app: ^App) -> bool {
	assert(app != nil, "Fit.Start: nil app")
	return ui_gfx.app_start(&app.inner)
}

Tick :: proc(app: ^App) -> bool {
	assert(app != nil, "Fit.Tick: nil app")
	return ui_gfx.app_tick(&app.inner)
}

Stop :: proc(app: ^App) -> bool {
	assert(app != nil, "Fit.Stop: nil app")
	return ui_gfx.app_stop(&app.inner)
}

Destroy :: proc(app: ^App) {
	assert(app != nil, "Fit.Destroy: nil app")
	ui_gfx.app_destroy(&app.inner)
}

Run :: proc(app: ^App, config: Config, draw: Draw_Proc, userdata: rawptr = nil) -> bool {
	assert(app != nil, "Fit.Run: nil app")
	assert(draw != nil, "Fit.Run: nil draw callback")
	assert(app.inner.state == .Empty, "Fit.Run: app already initialized")
	assert(app.draw == nil, "Fit.Run: draw callback already bound")
	assert(app.shutdown == nil, "Fit.Run: shutdown callback already bound")
	assert(app.userdata == nil, "Fit.Run: userdata already bound")
	app.draw = draw
	app.userdata = userdata
	ok := ui_gfx.app_run(
		&app.inner,
		to_app_config(config),
		{ui = app_draw, shutdown = app_shutdown},
		app,
	)
	if app.inner.state == .Empty do app_callbacks_reset(app)
	return ok
}

Set_Theme :: proc(app: ^App, theme: Theme) {
	assert(app != nil, "Fit.Set_Theme: nil app")
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app.inner), theme.inner)
}

Set_Scale :: proc(app: ^App, scale: f32) {
	assert(app != nil, "Fit.Set_Scale: nil app")
	ui_gfx.session_set_user_scale(&app.inner.session, scale)
}

Scale :: proc(app: ^App) -> f32 {
	assert(app != nil && app.inner.state != .Empty, "Fit.Scale: invalid app")
	return ui_gfx.app_ui_runtime(&app.inner).scale
}

Get_State :: proc(app: ^App) -> State {
	assert(app != nil, "Fit.Get_State: nil app")
	return State(app.inner.state)
}

Screen_Rect :: proc(app: ^App) -> Rect {
	assert(app != nil, "Fit.Screen_Rect: nil app")
	return from_rect(ui_gfx.app_screen_rect(&app.inner))
}

Clear_Color :: proc(app: ^App) -> Color {
	assert(app != nil, "Fit.Clear_Color: nil app")
	return Color(ui_gfx.app_clear_color(&app.inner))
}

Renderer_Peak_Usage :: proc() -> Renderer_Peaks {
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

Paint_Peak_Usage :: proc(app: ^App) -> Paint_Peaks {
	assert(app != nil && app.inner.state != .Empty, "Fit.Paint_Peak_Usage: invalid app")
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
	app.builder.root = root^
	app.builder.bound = true
	Begin(&app.builder)
	app.draw(&app.builder, app.userdata)
	assert(app.builder.inner.prepared.depth == 0, "fit app: unbalanced builder")
	_ = Render(&app.builder)
	root^ = app.builder.root
	app.builder.bound = false
}

@(private = "file")
app_callbacks_reset :: proc(app: ^App) {
	assert(app != nil, "fit app: nil callback reset")
	assert(!app.builder.bound, "fit app: builder bound during callback reset")
	app.draw = nil
	app.shutdown = nil
	app.userdata = nil
}

@(private = "file")
app_shutdown :: proc(inner: ^ui_gfx.App, userdata: rawptr) {
	assert(inner != nil && userdata != nil, "fit app: invalid shutdown")
	app := cast(^App)userdata
	assert(!app.builder.bound, "fit app: builder still bound")
	if app.shutdown != nil do app.shutdown(app, app.userdata)
	app_callbacks_reset(app)
}
