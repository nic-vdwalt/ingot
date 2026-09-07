// Forgecore hot-reload host: owns the window, GPU context, and Fit
// session, and dispatches each frame into the reloadable game library.
// The window title is injected per demo with -define:GAME_TITLE=....
// Adapted from ingot/examples/hot_reload/host.
package main

import "core:dynlib"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"
import fit "ingot:fit"
import rl "ingot:gfx"
import shared "../shared"

when ODIN_OS == .Windows {
	LIBRARY_EXTENSION :: ".dll"
} else when ODIN_OS == .Darwin {
	LIBRARY_EXTENSION :: ".dylib"
} else {
	LIBRARY_EXTENSION :: ".so"
}

GAME_LIBRARY_DIRECTORY :: "build/"
GAME_LIBRARY_PATH :: GAME_LIBRARY_DIRECTORY + "game" + LIBRARY_EXTENSION

SCREEN_WIDTH :: 1280
SCREEN_HEIGHT :: 720
GAME_TITLE :: #config(GAME_TITLE, "Forgecore")
FORGE_FRAME_PACING_MODE :: #config(FORGE_FRAME_PACING_MODE, 0)
#assert(FORGE_FRAME_PACING_MODE >= 0 && FORGE_FRAME_PACING_MODE <= 2)

Frame_Pacing_Mode :: enum u8 {
	Fifo_Free = 0,
	Immediate_Display_Link = 1,
	Fifo_Display_Link = 2,
}

Game_API :: struct {
	lib:                dynlib.Library,
	init:               shared.Game_Init_Proc,
	prepare:            shared.Game_Prepare_Proc,
	draw:               shared.Game_Draw_Proc,
	uses_custom_cursor: shared.Game_Uses_Custom_Cursor_Proc,
	// should_quit is the library's exit request (the pause menu's confirmed
	// exit). ingot exposes no "ask the window to close" call, so the host
	// polls this once per frame and ends its own loop.
	should_quit:        shared.Game_Should_Quit_Proc,
	// theme is owned by the library so the palette reloads with it. The
	// host installs it on the session after every successful load.
	theme:              shared.Game_Theme_Proc,
	shutdown:           shared.Game_Shutdown_Proc,
	modified:           time.Time,
	version:            int,
}

Host :: struct {
	session: fit.Session,
	api:     Game_API,
	next:    int,
	pacer:           Frame_Pacer,
	pace:            bool,
	pacer_wait_last: f64,
	heartbeat_next: f64,
	// Last dylib mtime check. Statting the library every frame is many
	// syscall round-trips a second on the render thread for a dev-only
	// feature; 4 Hz is still imperceptible when republishing.
	checked:              time.Tick,
	refresh_checked:      time.Tick,
	monitor_refresh_rate: i32,
}

HOT_RELOAD_POLL :: 250 * time.Millisecond
REFRESH_RATE_POLL :: time.Second
REFRESH_RATE_FALLBACK :: i32(60)

host: Host

frame_pacing_mode :: proc(value: int) -> Frame_Pacing_Mode {
	if value == 1 do return .Immediate_Display_Link
	if value == 2 do return .Fifo_Display_Link
	return .Fifo_Free
}

frame_pacing_uses_display_link :: proc(mode: Frame_Pacing_Mode) -> bool {
	return mode == .Immediate_Display_Link || mode == .Fifo_Display_Link
}

frame_pacing_uses_immediate :: proc(mode: Frame_Pacing_Mode) -> bool {
	return mode == .Immediate_Display_Link
}

library_copy_path :: proc(version: int) -> string {
	assert(version >= 0, "library_copy_path: negative version")
	return fmt.tprintf(
		GAME_LIBRARY_DIRECTORY + "game_%d_%d" + LIBRARY_EXTENSION,
		os.get_pid(),
		version,
	)
}

load_game_api :: proc(version: int) -> (api: Game_API, ok: bool) {
	assert(version >= 0, "load_game_api: invalid version")
	modified, modified_error := os.last_write_time_by_name(GAME_LIBRARY_PATH)
	if modified_error != os.ERROR_NONE do return
	copy_path := library_copy_path(version)
	if os.copy_file(copy_path, GAME_LIBRARY_PATH) != nil do return
	_, initialized := dynlib.initialize_symbols(&api, copy_path, "game_", "lib")
	if !initialized {
		fmt.eprintfln("host: cannot load game API: %s", dynlib.last_error())
		_ = os.remove(copy_path)
		return
	}
	api.modified = modified
	api.version = version
	assert(api.lib != nil, "load_game_api: missing library")
	return api, true
}

unload_game_api :: proc(api: ^Game_API) {
	assert(api != nil, "unload_game_api: nil API")
	if api.lib != nil && !dynlib.unload_library(api.lib) {
		fmt.eprintfln("host: cannot unload game API: %s", dynlib.last_error())
	}
	if api.version >= 0 do _ = os.remove(library_copy_path(api.version))
	api^ = {}
	assert(api.lib == nil)
}

restart_game :: proc(state: ^Host, next: Game_API) -> bool {
	assert(state != nil && state.api.lib != nil && next.lib != nil, "restart_game: invalid arguments")
	state.api.shutdown()
	unload_game_api(&state.api)
	state.api = next
	if !state.api.init(rl.default_context()) {
		unload_game_api(&state.api)
		return false
	}
	// The palette lives in the library, so a reload has to republish it:
	// the session still holds the previous generation's theme otherwise,
	// and colour edits would appear to do nothing.
	fit.Session_Set_Theme(&state.session, state.api.theme())
	return true
}

reload_game :: proc(state: ^Host) {
	assert(state != nil && state.api.lib != nil, "reload_game: invalid host")
	next, loaded := load_game_api(state.next)
	if !loaded do return
	state.next += 1
	if !restart_game(state, next) do panic("host: game restart failed")
}

reload_if_changed :: proc(state: ^Host) {
	assert(state != nil && state.api.lib != nil, "reload_if_changed: invalid host")
	now := time.tick_now()
	if time.tick_diff(state.checked, now) < HOT_RELOAD_POLL do return
	state.checked = now
	modified, err := os.last_write_time_by_name(GAME_LIBRARY_PATH)
	if err != os.ERROR_NONE || modified == state.api.modified do return
	reload_game(state)
}

draw_game :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "draw_game: invalid argument")
	state := cast(^Host)userdata
	state.api.draw(builder)
}

Cursor_Owner :: enum u8 {
	OS,
	Game,
}

cursor_owner :: proc(uses_custom_cursor: bool) -> Cursor_Owner {
	return .Game if uses_custom_cursor else .OS
}

sync_cursor :: proc(state: ^Host) {
	assert(state != nil && state.api.lib != nil, "sync_cursor: invalid host")
	if cursor_owner(state.api.uses_custom_cursor()) == .Game {
		rl.HideCursor()
	} else {
		rl.ShowCursor()
	}
}

refresh_rate_or_fallback :: proc(refresh_rate: i32) -> i32 {
	return refresh_rate if refresh_rate > 0 else REFRESH_RATE_FALLBACK
}

refresh_rate_change :: proc(current, detected: i32) -> (refresh_rate: i32, changed: bool) {
	refresh_rate = refresh_rate_or_fallback(detected)
	return refresh_rate, refresh_rate != current
}

sync_refresh_rate :: proc(state: ^Host) {
	assert(state != nil, "sync_refresh_rate: nil host")
	now := time.tick_now()
	if state.monitor_refresh_rate > 0 &&
	   time.tick_diff(state.refresh_checked, now) < REFRESH_RATE_POLL {
		return
	}
	state.refresh_checked = now
	refresh_rate, changed := refresh_rate_change(
		state.monitor_refresh_rate,
		rl.context_monitor_refresh_rate(rl.default_context()),
	)
	if !changed do return
	state.monitor_refresh_rate = refresh_rate
}

frame :: proc() {
	started := time.tick_now()
	reload_if_changed(&host)
	sync_refresh_rate(&host)
	_ = fit.Session_Draw(&host.session, draw_game, &host)
	host.api.prepare()
	sync_cursor(&host)
	elapsed := time.duration_seconds(time.tick_since(started))
	rl.context_frame_delivery_record_host(rl.default_context(), elapsed, host.pacer_wait_last)
	when #config(FORGE_HOST_HEARTBEAT, false) {
		now := rl.GetTime()
		if now >= host.heartbeat_next {
			host.heartbeat_next = now + 1
			ctx := rl.default_context()
			fmt.eprintln("host-heartbeat", time.now(), now, ctx.frame.has_frame,
				ctx.frame.surf_tex.status, ctx.fb_width, ctx.fb_height,
				ctx.config.presentMode, host.monitor_refresh_rate)
		}
	}
}

// run_frames replaces rl.run so the library can end the session. rl.run only
// stops when the window itself is asked to close, and ingot publishes no
// request-close call at the pinned revision, so an in-game "exit" has to be
// a flag the host polls. Teardown after this returns is the same path a
// window close takes.
run_frames :: proc() {
	assert(host.api.lib != nil, "run_frames: game library not loaded")
	// tigerstyle: allow-unbounded-loop -- window close terminates the application lifetime
	for !rl.WindowShouldClose() {
		host.pacer_wait_last = 0
		if host.pace do host.pacer_wait_last = frame_pacer_wait(&host.pacer)
		frame()
		if host.api.should_quit() do break
	}
}

main :: proc() {
	executable_directory := filepath.dir(string(os.args[0]))
	if os.set_working_directory(executable_directory) != nil {
		fmt.eprintln("host: cannot use the project directory")
		return
	}
	api, loaded := load_game_api(0)
	if !loaded {
		fmt.eprintln("host: build the game library before starting the host")
		return
	}
	host.api = api
	host.next = 1
	// Seed the poll clock so the first check is one interval in, rather
	// than comparing against a zero tick.
	host.checked = time.tick_now()
	mode := frame_pacing_mode(FORGE_FRAME_PACING_MODE)
	flags := rl.ConfigFlags{.VSYNC_HINT, .WINDOW_RESIZABLE}
	if frame_pacing_uses_immediate(mode) do flags += {.PRESENT_IMMEDIATE}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	when ODIN_OS == .Windows do flags += {.WINDOW_HIDDEN}
	rl.SetConfigFlags(flags)
	rl.InitWindow(SCREEN_WIDTH, SCREEN_HEIGHT, GAME_TITLE)
	rl.SetTargetFPS(0)
	if frame_pacing_uses_display_link(mode) {
		host.pace = frame_pacer_start(&host.pacer)
		if !host.pace do fmt.eprintln("host: display-link pacing unavailable; running unpaced")
	}
	sync_refresh_rate(&host)
	// Windows only: dark Mica frame plus ingot's custom title bar, which
	// strips the non-client frame and hands hit-testing to the client's
	// auto-hiding header strip. Deliberately not applied on macOS, where
	// apply_window_style swaps in a translucent NSVisualEffectView content
	// view - wrong for an opaque 3D game.
	when ODIN_OS == .Windows {
		fit.Apply_Window_Style()
		fit.Titlebar_Init()
	}
	fit.Session_Init(&host.session, {semantics_enabled = true})
	fit.Session_Set_Theme(&host.session, host.api.theme())
	when ODIN_OS == .Windows do rl.ShowWindow()
	if !host.api.init(rl.default_context()) {
		fit.Session_Destroy(&host.session)
		rl.CloseWindow()
		unload_game_api(&host.api)
		return
	}
	run_frames()
	frame_pacer_stop(&host.pacer)
	host.api.shutdown()
	fit.Session_Destroy(&host.session)
	rl.ShowCursor()
	rl.CloseWindow()
	unload_game_api(&host.api)
}

@(export)
NvOptimusEnablement: u32 = 1

@(export)
AmdPowerXpressRequestHighPerformance: i32 = 1
