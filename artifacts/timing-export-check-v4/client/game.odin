package main

import shared "../shared"
import fit "ingot:fit"
import rl "ingot:gfx"

g: ^Client_State

TIMING_DIAGNOSTIC_SECONDS :: #config(FORGE_TIMING_DIAGNOSTIC_SECONDS, 25)
#assert(TIMING_DIAGNOSTIC_SECONDS > 0 && TIMING_DIAGNOSTIC_SECONDS <= 30)

@(export)
game_init: shared.Game_Init_Proc : proc(ctx: ^rl.Context) -> bool {
	assert(ctx != nil, "game_init: nil graphics context")
	_ = rl.set_default_context(ctx)
	assert(g == nil, "game_init: state already initialized")
	g = new(Client_State)
	if g == nil do return false
	// The first frame has not published a scale yet; 1.0 keeps every layout
	// computed from input handlers valid until ui_scale_sync overwrites it.
	g.ui_scale = 1
	settings_load(g)
	telemetry_init(&g.telemetry)
	g.screen = .Loading
	return true
}

@(export)
game_prepare: shared.Game_Prepare_Proc : proc() {
	assert(g != nil, "game_prepare: missing state")
	when PROFILE_ENABLED && rl.GPU_TIMING_DIAGNOSTICS {
		if rl.GetTime() >= TIMING_DIAGNOSTIC_SECONDS do g.quit_requested = true
	}
	game_prepare_frame(g)
}

game_cursor_frame_begin :: proc(value: ^Client_State) {
	assert(value != nil, "game cursor frame: missing state")
	value.cursor.drawn_this_frame = false
}

@(export)
game_draw: shared.Game_Draw_Proc : proc(builder: ^fit.Builder) {
	assert(builder != nil, "game_draw: nil builder")
	assert(g != nil, "game_draw: missing state")
	game_cursor_frame_begin(g)
	fit.Canvas(builder, game_surface, g)
}

game_custom_cursor_active_for :: proc(
	value: ^Client_State,
	window_focused: bool,
) -> bool {
	assert(value != nil, "game custom cursor: missing state")
	return(
		value.screen == .Playing &&
		value.graphics_ready &&
		!value.balance.active &&
		!value.pause.open &&
		window_focused \
	)
}

game_custom_cursor_active :: proc(value: ^Client_State) -> bool {
	return game_custom_cursor_active_for(value, rl.IsWindowFocused())
}

@(export)
game_uses_custom_cursor: shared.Game_Uses_Custom_Cursor_Proc : proc() -> bool {
	assert(g != nil, "game_uses_custom_cursor: missing state")
	return g.cursor.drawn_this_frame
}

// game_should_quit reports the pause menu's confirmed exit. The host owns
// the frame loop and the window, so the library cannot end the session
// itself; it raises a flag the host reads once per frame.
@(export)
game_should_quit: shared.Game_Should_Quit_Proc : proc() -> bool {
	assert(g != nil, "game_should_quit: missing state")
	return g.quit_requested
}

// game_theme publishes the palette the host installs on the fit session.
// It lives in the reloadable library rather than the host so a colour
// change costs a `bash build.sh hot` instead of a host restart; the host
// re-reads it on every reload.
@(export)
game_theme: shared.Game_Theme_Proc : proc() -> fit.Theme {
	return terra_theme()
}

game_surface :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	assert(surface != nil && userdata != nil, "game_surface: invalid argument")
	value := cast(^Client_State)userdata
	assert(rect.w > 0 && rect.h > 0, "game_surface: invalid viewport")
	ui_scale_sync(value, surface)
	switch value.screen {
	case .Menu:
		menu_frame(value, surface, rect.w, rect.h)
	case .Playing:
		game_frame(value, surface)
	case .Loading, .Loading_Graphics:
		loading_frame(value, surface, rect.w, rect.h)
	}
	// Drawn last so the window strip and its caption buttons sit above every
	// screen, including the console popup layer.
	header_frame(value, surface)
	return false
}

@(export)
game_shutdown: shared.Game_Shutdown_Proc : proc() {
	assert(g != nil, "game_shutdown: missing state")
	shutdown(g)
	free(g)
	g = nil
	assert(g == nil)
}
