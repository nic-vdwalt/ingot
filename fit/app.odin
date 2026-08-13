package fit

import "ingot:ui"
import "ingot:ui_gfx"

Init :: proc(app: ^App, config: Config, callbacks: Callbacks, userdata: rawptr = nil) -> bool {
	assert(app != nil, "Fit.Init: nil app")
	assert(callbacks.draw != nil, "Fit.Init: nil draw callback")
	assert(app.draw == nil, "Fit.Init: app already initialized")
	app.draw = callbacks.draw
	app.userdata = userdata
	return ui_gfx.app_init(&app.inner, config, {ui = app_draw, shutdown = app_shutdown}, app)
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
	app.draw = draw
	app.userdata = userdata
	return ui_gfx.app_run(&app.inner, config, {ui = app_draw, shutdown = app_shutdown}, app)
}

Set_Theme :: proc(app: ^App, theme: ui.Theme) {
	assert(app != nil, "Fit.Set_Theme: nil app")
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app.inner), theme)
}

Set_Scale :: proc(app: ^App, scale: f32) {
	assert(app != nil, "Fit.Set_Scale: nil app")
	ui_gfx.session_set_user_scale(&app.inner.session, scale)
}

Dark_Theme :: ui.theme_dark
Light_Theme :: ui.theme_light

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
app_shutdown :: proc(inner: ^ui_gfx.App, userdata: rawptr) {
	assert(inner != nil && userdata != nil, "fit app: invalid shutdown")
	app := cast(^App)userdata
	assert(!app.builder.bound, "fit app: builder still bound")
	app.draw = nil
	app.userdata = nil
}
