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

// Window_Handle is the opaque native window pointer. On the native target it is
// a glfw.WindowHandle; on web it is a non-nil sentinel (there is no OS window,
// only a canvas). Kept backend-agnostic so Context - and every shared gfx file
// - stays free of the windowing-backend import.
Window_Handle :: distinct rawptr

// Run_Proc is the per-frame application callback passed to run(). It should
// perform one frame: BeginDrawing → draw → EndDrawing.
Run_Proc :: proc()

// FilePathList mirrors raylib's dropped-file list. Its paths are borrowed until
// UnloadDroppedFiles, the next completed drop, or CloseWindow.
FilePathList :: struct {
	capacity: u32,
	count:    u32,
	paths:    [^]cstring,
}
