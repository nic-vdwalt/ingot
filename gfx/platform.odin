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
