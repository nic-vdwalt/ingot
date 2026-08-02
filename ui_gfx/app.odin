package ui_gfx

import "ingot:gfx"
import "ingot:ui"

App_State :: enum u8 {
	Empty,
	Ready,
	Running,
	Stopped,
}

App_Frame_Proc :: #type proc(app: ^App, frame: ^ui.Ui_Frame, userdata: rawptr)
App_Ui_Proc :: #type proc(app: ^App, u: ^ui.Ui, userdata: rawptr)
App_Shutdown_Proc :: #type proc(app: ^App, userdata: rawptr)

App_Config :: struct {
	width:         i32,
	height:        i32,
	title:         cstring,
	flags:         gfx.ConfigFlags,
	target_fps:    i32,
	event_waiting: bool,
	session:       Session_Config,
}

App_Callbacks :: struct {
	frame:    App_Frame_Proc,
	ui:       App_Ui_Proc,
	shutdown: App_Shutdown_Proc,
}

App :: struct {
	session:   Session,
	form:      ui.Ui,
	config:    App_Config,
	callbacks: App_Callbacks,
	userdata:  rawptr,
	state:     App_State,
}

@(private)
active_app: ^App

app_init :: proc(
	app: ^App,
	config: App_Config,
	callbacks: App_Callbacks,
	userdata: rawptr = nil,
) -> bool {
	assert(app != nil && app.state == .Empty, "app_init: invalid app")
	assert(config.width > 0 && config.height > 0, "app_init: invalid size")
	assert(config.title != nil, "app_init: missing title")
	assert(
		(callbacks.frame == nil) != (callbacks.ui == nil),
		"app_init: expected one frame callback",
	)
	assert(active_app == nil, "app_init: another application is active")
	gfx.SetConfigFlags(config.flags)
	initialized := gfx.context_init(
		gfx.default_context(),
		config.width,
		config.height,
		config.title,
	)
	if !initialized do return false
	if config.target_fps > 0 do gfx.SetTargetFPS(config.target_fps)
	if config.event_waiting do gfx.EnableEventWaiting()
	session_init(&app.session, config.session)
	app.config = config
	app.callbacks = callbacks
	app.userdata = userdata
	app.state = .Ready
	active_app = app
	return true
}

app_frame :: proc(app: ^App) -> bool {
	assert(app != nil && app.state == .Running, "app_frame: invalid app")
	gfx_frame, acquired := gfx.begin_frame()
	if !acquired do return false
	frame := session_begin_frame_context(&app.session, &gfx_frame)
	gfx.clear_frame(&gfx_frame, app_clear_color(app))
	if app.callbacks.ui != nil {
		app_ui_begin(app, frame, &app.form)
		app.callbacks.ui(app, &app.form, app.userdata)
		assert(app.form.open, "app_frame: UI callback closed the application root")
		ui.end(&app.form)
	} else {
		app.callbacks.frame(app, frame, app.userdata)
	}
	session_end_frame_context(&app.session, &gfx_frame)
	gfx.end_frame(&gfx_frame)
	free_all(context.temp_allocator)
	return true
}

@(private)
app_frame_active :: proc() {
	assert(active_app != nil, "app_frame_active: no application")
	_ = app_frame(active_app)
}

app_run :: proc(
	app: ^App,
	config: App_Config,
	callbacks: App_Callbacks,
	userdata: rawptr = nil,
) -> bool {
	assert(app != nil, "app_run: nil app")
	if !app_init(app, config, callbacks, userdata) do return false
	app.state = .Running
	gfx.run(app_frame_active)
	when ODIN_OS != .JS {
		app.state = .Stopped
		app_destroy(app)
	}
	return true
}

app_destroy :: proc(app: ^App) {
	assert(app != nil, "app_destroy: nil app")
	assert(app.state == .Ready || app.state == .Stopped, "app_destroy: invalid state")
	if app.callbacks.shutdown != nil do app.callbacks.shutdown(app, app.userdata)
	session_destroy(&app.session)
	gfx.context_close(gfx.default_context())
	if active_app == app do active_app = nil
	app^ = {}
}

app_screen_rect :: proc(app: ^App) -> ui.Rect_I32 {
	assert(app != nil && app.state != .Empty, "app_screen_rect: invalid app")
	ctx := gfx.default_context()
	return {0, 0, gfx.context_screen_width(ctx), gfx.context_screen_height(ctx)}
}

app_ui_begin :: proc(app: ^App, frame: ^ui.Ui_Frame, u: ^ui.Ui, gap: ui.Space = .None) {
	assert(app != nil && app.state == .Running, "app_ui_begin: application not running")
	assert(frame != nil && frame.open, "app_ui_begin: frame not open")
	assert(u != nil && !u.open, "app_ui_begin: invalid ui lifetime")
	assert(frame.runtime == &app.session.runtime, "app_ui_begin: frame belongs to another app")
	ui.begin(u, frame, app_screen_rect(app), gap)
	assert(u.open && u.frame == frame, "app_ui_begin: ui did not open")
}

app_ui_runtime :: proc(app: ^App) -> ^ui.Ui_Runtime {
	assert(app != nil && app.state != .Empty, "app_ui_runtime: invalid app")
	return session_runtime(&app.session)
}

app_font :: proc(app: ^App, size: i32) -> (gfx.Font, bool) {
	assert(app != nil && app.state != .Empty, "app_font: invalid app")
	assert(size > 0, "app_font: invalid size")
	id := adapter_font_for_size(&app.session.adapter, size)
	return adapter_font(&app.session.adapter, id)
}

// app_clear_color derives the window clear color from the active theme.
//
// It is derived rather than stored. App_Config used to carry a clear_color
// field, which made the window background a *copy* of theme.bg_app - and a
// copy that every theme switch had to remember to update. One demo forgot:
// chart_demo swapped to the light palette and kept a dark window, because
// nothing tied the two together. Deriving here means the window cannot
// disagree with the interface drawn on it, and deletes the six hardcoded
// literals and two hand-rolled sync blocks that existed to paper over the gap.
//
// The alpha is forced opaque because bg_app may be translucent on platforms
// with a vibrancy backdrop, and a translucent *clear* would accumulate the
// previous frame rather than replace it.
app_clear_color :: proc(app: ^App) -> gfx.Color {
	assert(app != nil && app.state != .Empty, "app_clear_color: invalid app")
	background := ui.ui_runtime_theme(app_ui_runtime(app)).bg_app
	color := color_to_gfx(background)
	color.a = 255
	return color
}
