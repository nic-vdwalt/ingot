package ui_gfx

import "ingot:gfx"
import "ingot:ui"

App_State :: enum u8 {
	Empty,
	Ready,
	Running,
	Stopped,
}

App_Frame_Pacing :: enum u8 {
	Fixed,
	Uncapped,
	Monitor_Refresh,
}

App_Frame_Proc :: #type proc(app: ^App, frame: ^ui.Ui_Frame, userdata: rawptr)
App_Ui_Proc :: #type proc(app: ^App, u: ^ui.Ui, userdata: rawptr)
App_Shutdown_Proc :: #type proc(app: ^App, userdata: rawptr)

App_Config :: struct {
	width:         i32,
	height:        i32,
	title:         cstring,
	flags:         gfx.ConfigFlags,
	frame_pacing:  App_Frame_Pacing,
	target_fps:    i32,
	event_waiting: bool,
	session:       Session_Config,
}

@(private)
app_resolve_target_fps :: proc(config: App_Config, monitor_refresh: i32) -> i32 {
	assert(config.target_fps >= 0, "app_resolve_target_fps: negative target")
	#partial switch config.frame_pacing {
	case .Fixed:
		return config.target_fps
	case .Uncapped:
		return 0
	case .Monitor_Refresh:
		if monitor_refresh > 0 do return monitor_refresh
		return config.target_fps
	}
	return 0
}

@(private)
app_apply_frame_pacing :: proc(app: ^App) {
	assert(app != nil && app.gfx_context != nil, "app_apply_frame_pacing: invalid app")
	when ODIN_OS != .JS {
		refresh := gfx.context_monitor_refresh_rate(app.gfx_context)
		target := app_resolve_target_fps(app.config, refresh)
		gfx.context_set_target_fps(app.gfx_context, target)
		assert(target >= 0, "app_apply_frame_pacing: invalid target")
	}
}

App_Callbacks :: struct {
	frame:    App_Frame_Proc,
	ui:       App_Ui_Proc,
	shutdown: App_Shutdown_Proc,
}

App :: struct {
	gfx_context: ^gfx.Context,
	session:     Session,
	form:        ui.Ui,
	config:      App_Config,
	callbacks:   App_Callbacks,
	userdata:    rawptr,
	state:       App_State,
}

app_init :: proc(
	app: ^App,
	config: App_Config,
	callbacks: App_Callbacks,
	userdata: rawptr = nil,
) -> bool {
	return app_init_context(app, gfx.default_context(), config, callbacks, userdata)
}

app_init_context :: proc(
	app: ^App,
	gfx_context: ^gfx.Context,
	config: App_Config,
	callbacks: App_Callbacks,
	userdata: rawptr = nil,
) -> bool {
	assert(app != nil && app.state == .Empty, "app_init_context: invalid app")
	assert(gfx_context != nil, "app_init_context: nil graphics context")
	assert(config.width > 0 && config.height > 0, "app_init_context: invalid size")
	assert(config.title != nil, "app_init_context: missing title")
	assert(config.target_fps >= 0, "app_init_context: negative target FPS")
	assert(
		(callbacks.frame == nil) != (callbacks.ui == nil),
		"app_init_context: expected one frame callback",
	)
	window_flags := config.flags
	when ODIN_OS == .Windows do window_flags += {.WINDOW_HIDDEN}
	gfx.context_set_config_flags(gfx_context, window_flags)
	if !gfx.context_init(gfx_context, config.width, config.height, config.title) do return false
	if config.event_waiting do gfx.context_set_frame_strategy(gfx_context, .Event_Driven)
	session_init_context(&app.session, gfx_context, config.session)
	when ODIN_OS == .Windows do gfx.context_show_window(gfx_context)
	app.gfx_context = gfx_context
	app.config = config
	app_apply_frame_pacing(app)
	app.callbacks = callbacks
	app.userdata = userdata
	app.state = .Ready
	assert(app.session.adapter.gfx_context == app.gfx_context)
	return true
}

app_frame :: proc(app: ^App) -> bool {
	assert(app != nil && app.state == .Running, "app_frame: invalid app")
	frame, acquired := session_acquire_frame(&app.session)
	if !acquired do return false
	gfx.clear_frame(frame.gfx, app_clear_color(app))
	if app.callbacks.ui != nil {
		app_ui_begin(app, frame.ui, &app.form)
		app.callbacks.ui(app, &app.form, app.userdata)
		assert(app.form.open, "app_frame: UI callback closed the application root")
		ui.end(&app.form)
	} else {
		app.callbacks.frame(app, frame.ui, app.userdata)
	}
	session_present_frame(&frame)
	return true
}

app_start :: proc(app: ^App) -> bool {
	if app == nil || app.state != .Ready do return false
	// context_live, not context_ready: on the web the GPU device is still
	// resolving on the browser event loop at this point and readiness is
	// necessarily false. Requiring readiness here made app_run treat every
	// web startup as a failure and call app_destroy, whose context_close
	// cancelled the in-flight adapter request - a black canvas, silently,
	// for every ui_gfx.App app in a browser. Frames simply do not run until
	// the device lands; gfx.step gates the callback on that.
	if !gfx.context_live(app.gfx_context) do return false
	app.state = .Running
	assert(app.session.initialized, "app_start: session not initialized")
	assert(app.gfx_context == app.session.adapter.gfx_context, "app_start: context mismatch")
	return true
}

app_tick :: proc(app: ^App) -> bool {
	if app == nil || app.state != .Running do return false
	if gfx.context_should_close(app.gfx_context) do return false
	if app.config.frame_pacing == .Monitor_Refresh do app_apply_frame_pacing(app)
	return app_frame(app)
}

app_stop :: proc(app: ^App) -> bool {
	if app == nil || app.state != .Running do return false
	assert(!app.session.frame_open, "app_stop: frame open")
	app.state = .Stopped
	assert(app.state == .Stopped)
	return true
}

@(private)
app_frame_data :: proc(userdata: rawptr) {
	app := cast(^App)userdata
	assert(app != nil && app.state == .Running, "app_frame_data: invalid app")
	_ = app_tick(app)
}

app_run :: proc(
	app: ^App,
	config: App_Config,
	callbacks: App_Callbacks,
	userdata: rawptr = nil,
) -> bool {
	assert(app != nil, "app_run: nil app")
	if !app_init(app, config, callbacks, userdata) do return false
	if !app_start(app) {
		app_destroy(app)
		return false
	}
	if !gfx.run_data(app_frame_data, app) {
		_ = app_stop(app)
		app_destroy(app)
		return false
	}
	when ODIN_OS != .JS {
		if !app_stop(app) do return false
		app_destroy(app)
	}
	return true
}

app_destroy :: proc(app: ^App) {
	assert(app != nil, "app_destroy: nil app")
	assert(app.state == .Ready || app.state == .Stopped, "app_destroy: invalid state")
	if app.callbacks.shutdown != nil do app.callbacks.shutdown(app, app.userdata)
	session_destroy(&app.session)
	gfx.context_close(app.gfx_context)
	app^ = {}
}

app_screen_rect :: proc(app: ^App) -> ui.Rect_I32 {
	assert(app != nil && app.state != .Empty, "app_screen_rect: invalid app")
	return {
		0,
		0,
		gfx.context_screen_width(app.gfx_context),
		gfx.context_screen_height(app.gfx_context),
	}
}

app_ui_begin :: proc(
	app: ^App,
	frame: ^ui.Ui_Frame,
	u: ^ui.Ui,
	gap: ui.Space = .None,
	tab_navigation: bool = true,
) {
	assert(app != nil && app.state == .Running, "app_ui_begin: application not running")
	assert(frame != nil && frame.open, "app_ui_begin: frame not open")
	assert(u != nil && !u.open, "app_ui_begin: invalid ui lifetime")
	assert(frame.runtime == &app.session.runtime, "app_ui_begin: frame belongs to another app")
	ui.begin(u, frame, app_screen_rect(app), gap, tab_navigation)
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
