// ingot:gfx - platform seam (shared declarations).
//
// The shared gfx core (context/input/texture) carries no windowing-backend
// import; instead it calls the `platform_*` procs declared conceptually here
// and implemented per target:
//   - platform_native.odin  (#+build !js)  - GLFW / desktop
//   - platform_web.odin      (#+build js)  - canvas + DOM / browser
//
// This file holds only the backend-neutral types both targets share.
package gfx

INGOT_GFX_SDL3 :: #config(INGOT_GFX_SDL3, false)
#assert(ODIN_OS != .JS || !INGOT_GFX_SDL3)

ACTIVATION_RETRY_LIMIT :: u8(5)
// Seconds to wait before each attempt, so retries span AppKit's activation
// latency instead of being spent on consecutive event pumps.
ACTIVATION_RETRY_DELAYS :: [ACTIVATION_RETRY_LIMIT]f64{0.0, 0.05, 0.15, 0.4, 1.0}
ACTIVATION_REARM_COOLDOWN :: 2.0

@(private)
_activation_retry_advance :: proc(
	pending: u8,
	next_at, now: f64,
	focused: bool,
) -> (
	next_pending: u8,
	next_next_at: f64,
	retry: bool,
) {
	assert(pending <= ACTIVATION_RETRY_LIMIT, "activation retry count out of range")
	if focused do return 0, 0, false
	if pending == 0 do return 0, next_at, false
	if now < next_at do return pending, next_at, false
	delays := ACTIVATION_RETRY_DELAYS
	attempt := int(ACTIVATION_RETRY_LIMIT - pending)
	next_pending = pending - 1
	if next_pending > 0 {
		next_next_at = now + delays[attempt + 1]
	} else {
		next_next_at = now + ACTIVATION_REARM_COOLDOWN
	}
	assert(next_pending < pending, "activation retry count did not decrease")
	return next_pending, next_next_at, true
}

// Re-arm on an application activation edge, or when the application is active
// but owns no key window at all (so a sibling window's focus is never stolen),
// rate-limited by the cooldown deadline left behind by the previous budget.
@(private)
_activation_should_rearm :: proc(
	app_active, app_was_active, focused, known, eligible, app_has_key_window, visible: bool,
	now, next_at: f64,
) -> bool {
	if !(eligible && known && visible && app_active && !focused) do return false
	if !app_was_active do return true
	return !app_has_key_window && now >= next_at
}

@(private)
_window_wants_initial_focus :: proc(flags: ConfigFlags) -> bool {
	return .WINDOW_UNFOCUSED not_in flags
}

@(private)
_window_should_activate :: proc(flags: ConfigFlags) -> bool {
	return _window_wants_initial_focus(flags) && .WINDOW_HIDDEN not_in flags
}

@(private)
_window_should_focus_on_show :: proc(flags: ConfigFlags) -> bool {
	return _window_wants_initial_focus(flags)
}

@(private)
_window_wants_topmost :: proc(flags: ConfigFlags) -> bool {
	return .WINDOW_TOPMOST in flags
}

@(private)
_window_focus_resolve :: proc(backend_focused, native_focused, native_known: bool) -> bool {
	if native_known do return native_focused
	return backend_focused
}

// Window_Handle is the opaque native window pointer. On the native target it is
// a glfw.WindowHandle; on web it is a non-nil sentinel (there is no OS window,
// only a canvas). Kept backend-agnostic so Context - and every shared gfx file
// - stays free of the windowing-backend import.
Window_Handle :: distinct rawptr

// Run_Proc is the per-frame application callback passed to run(). It should
// perform one frame: BeginDrawing → draw → EndDrawing.
Run_Proc :: proc()
Run_Data_Proc :: #type proc(userdata: rawptr)

Run_Callback :: struct {
	frame:    Run_Data_Proc,
	userdata: rawptr,
	active:   bool,
}

// FilePathList mirrors raylib's dropped-file list. Its paths are borrowed until
// UnloadDroppedFiles, the next completed drop, or CloseWindow.
FilePathList :: struct {
	capacity: u32,
	count:    u32,
	paths:    [^]cstring,
}
