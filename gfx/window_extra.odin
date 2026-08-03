#+build !js
// ingot:gfx - additional raylib-named window/mouse/drag-drop procs used by
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
ToggleFullscreen :: proc() {
	if g.win == nil do return
	window := glfw.WindowHandle(g.win)
	monitor := glfw.GetWindowMonitor(window)
	if monitor == nil {
		g.drop.windowed_x, g.drop.windowed_y = glfw.GetWindowPos(window)
		g.drop.windowed_w, g.drop.windowed_h = glfw.GetWindowSize(window)
		monitor = glfw.GetPrimaryMonitor()
		mode := glfw.GetVideoMode(monitor)
		glfw.SetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
	} else {
		glfw.SetWindowMonitor(
			window,
			nil,
			g.drop.windowed_x,
			g.drop.windowed_y,
			max(g.drop.windowed_w, 1),
			max(g.drop.windowed_h, 1),
			0,
		)
	}
}
RestoreWindow :: proc() {
	if g.win != nil do glfw.RestoreWindow(glfw.WindowHandle(g.win))
}

// ShowWindow reveals a window created with the WINDOW_HIDDEN config flag. It
// pairs with that flag's deferred-show contract: create hidden, install any
// state that must precede the first show (e.g. the Windows AccessKit adapter),
// then call this exactly once to make the window visible.
context_show_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_show_window: nil context")
	assert(ctx.win != nil, "context_show_window: no window")
	glfw.ShowWindow(glfw.WindowHandle(ctx.win))
}
ShowWindow :: proc() {
	context_show_window(default_context())
}
context_focus_window :: proc(ctx: ^Context) {
	if ctx == nil || ctx.win == nil do return
	glfw.FocusWindow(glfw.WindowHandle(ctx.win))
}
FocusWindow :: proc() {
	context_focus_window(default_context())
}

// --- drag & drop -----------------------------------------------------------

@(private)
_drop_paths_clear_context :: proc(ctx: ^Context) {
	assert(ctx != nil, "_drop_paths_clear_context: nil context")
	for path in ctx.drop.paths do delete(path)
	delete(ctx.drop.paths)
	ctx.drop.paths = nil
}

@(private)
_drop_paths_clear :: proc() {
	_drop_paths_clear_context(g)
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
	g.drop.paths = make([dynamic]cstring, 0, len(paths))
	for path in paths do append(&g.drop.paths, strings.clone_to_cstring(path))
	_drop_complete()
	return true
}

@(private)
_drop_cb :: proc "c" (win: glfw.WindowHandle, count: i32, paths: [^]cstring) {
	context = runtime.default_context()
	ctx := _callback_context(win)
	if ctx == nil do return
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	_idle_note_activity(&ctx.idle)
	_drop_hover_stage_context(ctx, false)
	if count <= 0 || paths == nil do return
	accepted_count := min(int(count), MAX_DROPPED_FILES)
	accepted: [MAX_DROPPED_FILES]string
	for i in 0 ..< accepted_count do accepted[i] = string(paths[i])
	_drop_paths_replace(accepted[:accepted_count])
}

IsFileDropped :: proc() -> bool {return g.drop.ready}

LoadDroppedFiles :: proc() -> FilePathList {
	assert(len(g.drop.paths) <= MAX_DROPPED_FILES)
	return FilePathList {
		capacity = u32(len(g.drop.paths)),
		count = u32(len(g.drop.paths)),
		paths = raw_data(g.drop.paths),
	}
}

UnloadDroppedFiles :: proc(files: FilePathList) {
	g.drop.ready = false
	_drop_paths_clear()
}

// GetDroppedFileData returns the contents of dropped file `index`, allocated
// from `allocator` (caller frees), or nil on a bad index / read failure.
// Web parity: browsers deliver bytes without real paths, so target-portable
// consumers should read drops through this instead of opening paths.
GetDroppedFileData :: proc(index: i32, allocator := context.allocator) -> []byte {
	if index < 0 || int(index) >= len(g.drop.paths) do return nil
	path := string(g.drop.paths[index])
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
