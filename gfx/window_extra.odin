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

context_is_window_minimized :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	return glfw.GetWindowAttrib(glfw.WindowHandle(ctx.win), glfw.ICONIFIED) != 0
}
IsWindowMinimized :: proc() -> bool {return context_is_window_minimized(default_context())}
context_is_window_hidden :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	return glfw.GetWindowAttrib(glfw.WindowHandle(ctx.win), glfw.VISIBLE) == 0
}
IsWindowHidden :: proc() -> bool {return context_is_window_hidden(default_context())}
context_is_window_fullscreen :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	return glfw.GetWindowMonitor(glfw.WindowHandle(ctx.win)) != nil
}
IsWindowFullscreen :: proc() -> bool {return context_is_window_fullscreen(default_context())}
context_toggle_fullscreen_impl :: proc(ctx: ^Context) {
	if ctx == nil || ctx.win == nil do return
	window := glfw.WindowHandle(ctx.win)
	monitor := glfw.GetWindowMonitor(window)
	if monitor == nil {
		ctx.drop.windowed_x, ctx.drop.windowed_y = glfw.GetWindowPos(window)
		ctx.drop.windowed_w, ctx.drop.windowed_h = glfw.GetWindowSize(window)
		monitor = glfw.GetPrimaryMonitor()
		mode := glfw.GetVideoMode(monitor)
		glfw.SetWindowMonitor(window, monitor, 0, 0, mode.width, mode.height, mode.refresh_rate)
	} else {
		glfw.SetWindowMonitor(
			window,
			nil,
			ctx.drop.windowed_x,
			ctx.drop.windowed_y,
			max(ctx.drop.windowed_w, 1),
			max(ctx.drop.windowed_h, 1),
			0,
		)
	}
}
ToggleFullscreen :: proc() {
	context_toggle_fullscreen_impl(default_context())
}
context_restore_window :: proc(ctx: ^Context) {
	if ctx != nil && ctx.win != nil do glfw.RestoreWindow(glfw.WindowHandle(ctx.win))
}
RestoreWindow :: proc() {
	context_restore_window(default_context())
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
_drop_paths_replace_context :: proc(ctx: ^Context, paths: []string) -> bool {
	assert(ctx != nil, "_drop_paths_replace_context: nil context")
	assert(len(paths) <= MAX_DROPPED_FILES, "_drop_paths_replace_context: too many paths")
	total_bytes := 0
	for path in paths {
		if len(path) == 0 || len(path) > MAX_DROPPED_PATH_BYTES - total_bytes do return false
		total_bytes += len(path)
	}
	_drop_paths_clear_context(ctx)
	if len(paths) == 0 do return false
	ctx.drop.paths = make([dynamic]cstring, 0, len(paths))
	for path in paths do append(&ctx.drop.paths, strings.clone_to_cstring(path))
	_drop_complete_context(ctx)
	return true
}

@(private)
_drop_paths_replace :: proc(paths: []string) -> bool {
	return _drop_paths_replace_context(default_context(), paths)
}

@(private)
_drop_cb :: proc "c" (win: glfw.WindowHandle, count: i32, paths: [^]cstring) {
	context = runtime.default_context()
	ctx := _callback_context(win)
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	_drop_hover_stage_context(ctx, false)
	if count <= 0 || paths == nil do return
	accepted_count := min(int(count), MAX_DROPPED_FILES)
	accepted: [MAX_DROPPED_FILES]string
	for i in 0 ..< accepted_count do accepted[i] = string(paths[i])
	_drop_paths_replace_context(ctx, accepted[:accepted_count])
}

context_is_file_dropped :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.drop.ready
}

IsFileDropped :: proc() -> bool {return context_is_file_dropped(default_context())}

context_load_dropped_files :: proc(ctx: ^Context) -> FilePathList {
	if ctx == nil do return {}
	assert(len(ctx.drop.paths) <= MAX_DROPPED_FILES)
	return FilePathList {
		capacity = u32(len(ctx.drop.paths)),
		count = u32(len(ctx.drop.paths)),
		paths = raw_data(ctx.drop.paths),
	}
}

LoadDroppedFiles :: proc() -> FilePathList {
	return context_load_dropped_files(default_context())
}

context_unload_dropped_files :: proc(ctx: ^Context, files: FilePathList) {
	if ctx == nil do return
	ctx.drop.ready = false
	_drop_paths_clear_context(ctx)
}

UnloadDroppedFiles :: proc(files: FilePathList) {
	context_unload_dropped_files(default_context(), files)
}

// GetDroppedFileData returns the contents of dropped file `index`, allocated
// from `allocator` (caller frees), or nil on a bad index / read failure.
// Web parity: browsers deliver bytes without real paths, so target-portable
// consumers should read drops through this instead of opening paths.
context_get_dropped_file_data :: proc(
	ctx: ^Context,
	index: i32,
	allocator := context.allocator,
) -> []byte {
	if ctx == nil || index < 0 || int(index) >= len(ctx.drop.paths) do return nil
	path := string(ctx.drop.paths[index])
	assert(len(path) > 0, "GetDroppedFileData: empty dropped path")
	data, err := os.read_entire_file(path, allocator)
	if err != nil do return nil
	return data
}

GetDroppedFileData :: proc(index: i32, allocator := context.allocator) -> []byte {
	return context_get_dropped_file_data(default_context(), index, allocator)
}

@(private)
_drop_native_shutdown_context :: proc(ctx: ^Context) {
	assert(ctx != nil, "_drop_native_shutdown_context: nil context")
	_drop_paths_clear_context(ctx)
	_drop_state_reset_context(ctx)
}

@(private)
_drop_native_shutdown :: proc() {
	_drop_native_shutdown_context(default_context())
}
