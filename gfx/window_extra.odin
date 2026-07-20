#+build !js
// ingot:gfx — additional raylib-named window/mouse/drag-drop procs used by
// consumer apps (alloy). GLFW-backed; native-only. The web target provides the
// window-state and drag-drop equivalents in platform_web.odin.
package gfx

import "base:runtime"
import "core:strings"
import "vendor:glfw"

// --- window state ----------------------------------------------------------

IsWindowMinimized :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(glfw.WindowHandle(g.win), glfw.ICONIFIED) != 0
}
IsWindowHidden :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowAttrib(glfw.WindowHandle(g.win), glfw.VISIBLE) == 0
}
IsWindowFullscreen :: proc() -> bool {
	if g.win == nil do return false
	return glfw.GetWindowMonitor(glfw.WindowHandle(g.win)) != nil
}
RestoreWindow :: proc() {
	if g.win != nil do glfw.RestoreWindow(glfw.WindowHandle(g.win))
}

// --- drag & drop -----------------------------------------------------------

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
