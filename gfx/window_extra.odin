#+build !js
// ingot:gfx — additional raylib-named window/mouse/drag-drop procs used by
// consumer apps (alloy). GLFW-backed; native-only. The web target provides the
// window-state and drag-drop equivalents in platform_web.odin.
package gfx

import "base:runtime"
import "core:os"
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

@(private)
_drop_paths_clear :: proc() {
	for path in g_drop_paths do delete(path)
	delete(g_drop_paths)
	g_drop_paths = nil
}

@(private)
_drop_paths_replace :: proc(paths: []string) -> bool {
	assert(len(paths) <= MAX_DROPPED_FILES, "_drop_paths_replace: too many paths")
	total_bytes := 0
	for path in paths {
		if len(path) == 0 || len(path) > MAX_DROPPED_PATH_BYTES - total_bytes do return false
		total_bytes += len(path)
	}
	_drop_paths_clear()
	if len(paths) == 0 do return false
	g_drop_paths = make([dynamic]cstring, 0, len(paths))
	for path in paths do append(&g_drop_paths, strings.clone_to_cstring(path))
	_drop_complete()
	return true
}

@(private)
_drop_cb :: proc "c" (win: glfw.WindowHandle, count: i32, paths: [^]cstring) {
	context = runtime.default_context()
	_idle_note_activity(&g.idle)
	_drop_hover_stage(false)
	if count <= 0 || paths == nil do return
	accepted_count := min(int(count), MAX_DROPPED_FILES)
	accepted: [MAX_DROPPED_FILES]string
	for i in 0 ..< accepted_count do accepted[i] = string(paths[i])
	_drop_paths_replace(accepted[:accepted_count])
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
	_drop_paths_clear()
}

// GetDroppedFileData returns the contents of dropped file `index`, allocated
// from `allocator` (caller frees), or nil on a bad index / read failure.
// Web parity: browsers deliver bytes without real paths, so target-portable
// consumers should read drops through this instead of opening paths.
GetDroppedFileData :: proc(index: i32, allocator := context.allocator) -> []byte {
	if index < 0 || int(index) >= len(g_drop_paths) do return nil
	path := string(g_drop_paths[index])
	assert(len(path) > 0, "GetDroppedFileData: empty dropped path")
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return nil
	return data
}

@(private)
_drop_native_shutdown :: proc() {
	_drop_paths_clear()
	_drop_state_reset()
}
