// ingot:gfx — additional raylib-named window/mouse/drag-drop procs used by
// consumer apps (alloy). GLFW-backed where meaningful.
package gfx

import "base:runtime"
import "core:strings"
import "vendor:glfw"

// --- mouse convenience -----------------------------------------------------

GetMouseX :: proc() -> i32 { return i32(g.inp.mouse.x) }
GetMouseY :: proc() -> i32 { return i32(g.inp.mouse.y) }

// raylib mouse coordinate offset/scale — unused by the GLFW-native path; kept
// for API parity (no-op).
SetMouseOffset :: proc(offsetX, offsetY: i32) {}

// --- window state ----------------------------------------------------------

IsWindowMinimized :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(g.win, glfw.ICONIFIED) != 0
}
IsWindowHidden :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(g.win, glfw.VISIBLE) == 0
}
IsWindowFullscreen :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowMonitor(g.win) != nil
}
RestoreWindow :: proc() {
	if g.win != nil do glfw.RestoreWindow(g.win)
}

// --- drag & drop -----------------------------------------------------------

FilePathList :: struct {
	capacity: u32,
	count:    u32,
	paths:    [^]cstring,
}

@(private) g_drop_paths: [dynamic]cstring
@(private) g_drop_ready: bool

@(private)
_drop_cb :: proc "c" (win: glfw.WindowHandle, count: i32, paths: [^]cstring) {
	context = runtime.default_context()
	for p in g_drop_paths do delete(p)
	clear(&g_drop_paths)
	for i in 0 ..< int(count) {
		append(&g_drop_paths, strings.clone_to_cstring(string(paths[i])))
	}
	g_drop_ready = true
}

IsFileDropped :: proc() -> bool { return g_drop_ready }

LoadDroppedFiles :: proc() -> FilePathList {
	return FilePathList{
		capacity = u32(len(g_drop_paths)),
		count    = u32(len(g_drop_paths)),
		paths    = raw_data(g_drop_paths),
	}
}

UnloadDroppedFiles :: proc(files: FilePathList) {
	g_drop_ready = false
}

// install the drop callback (called from InitWindow)
@(private)
_drop_init :: proc() {
	if g.win != nil do glfw.SetDropCallback(g.win, _drop_cb)
}

