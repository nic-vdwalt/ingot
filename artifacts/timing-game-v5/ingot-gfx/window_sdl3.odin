#+build !js
package gfx

@(require) import "base:intrinsics"
@(require) import "core:os"
@(require) import "core:strings"
@(require) import sdl "vendor:sdl3"

when INGOT_GFX_SDL3 {

	when ODIN_OS == .Darwin {
		context_get_window_handle :: proc(ctx: ^Context) -> rawptr {
			if ctx == nil || ctx.win == nil do return nil
			props := sdl.GetWindowProperties(_sdl_window(ctx))
			return sdl.GetPointerProperty(props, sdl.PROP_WINDOW_COCOA_WINDOW_POINTER, nil)
		}
	} else when ODIN_OS == .Windows {
		context_get_window_handle :: proc(ctx: ^Context) -> rawptr {
			if ctx == nil || ctx.win == nil do return nil
			props := sdl.GetWindowProperties(_sdl_window(ctx))
			return sdl.GetPointerProperty(props, sdl.PROP_WINDOW_WIN32_HWND_POINTER, nil)
		}
	} else {
		context_get_window_handle :: proc(ctx: ^Context) -> rawptr {
			if ctx == nil do return nil
			return rawptr(ctx.win)
		}
	}

	GetWindowHandle :: proc() -> rawptr {
		return context_get_window_handle(default_context())
	}

	context_is_window_minimized :: proc(ctx: ^Context) -> bool {
		return ctx != nil && ctx.win != nil && .MINIMIZED in sdl.GetWindowFlags(_sdl_window(ctx))
	}

	IsWindowMinimized :: proc() -> bool {return context_is_window_minimized(default_context())}

	context_is_window_hidden :: proc(ctx: ^Context) -> bool {
		return ctx != nil && ctx.win != nil && .HIDDEN in sdl.GetWindowFlags(_sdl_window(ctx))
	}

	IsWindowHidden :: proc() -> bool {return context_is_window_hidden(default_context())}

	context_is_window_fullscreen :: proc(ctx: ^Context) -> bool {
		return ctx != nil && ctx.win != nil && .FULLSCREEN in sdl.GetWindowFlags(_sdl_window(ctx))
	}

	IsWindowFullscreen :: proc() -> bool {return context_is_window_fullscreen(default_context())}

	context_toggle_fullscreen_impl :: proc(ctx: ^Context) {
		if ctx == nil || ctx.win == nil do return
		fullscreen := !context_is_window_fullscreen(ctx)
		_ = sdl.SetWindowFullscreen(_sdl_window(ctx), fullscreen)
	}

	ToggleFullscreen :: proc() {context_toggle_fullscreen_impl(default_context())}

	context_restore_window :: proc(ctx: ^Context) {
		if ctx != nil && ctx.win != nil do _ = sdl.RestoreWindow(_sdl_window(ctx))
	}

	RestoreWindow :: proc() {context_restore_window(default_context())}

	context_show_window :: proc(ctx: ^Context) {
		assert(ctx != nil && ctx.win != nil, "context_show_window: invalid context")
		_ = sdl.ShowWindow(_sdl_window(ctx))
		if .WINDOW_UNFOCUSED not_in ctx.config_flags do context_focus_window(ctx)
	}

	ShowWindow :: proc() {context_show_window(default_context())}

	context_focus_window :: proc(ctx: ^Context) {
		if ctx == nil || ctx.win == nil do return
		_platform_activate_window(ctx)
		_ = sdl.RaiseWindow(_sdl_window(ctx))
	}

	FocusWindow :: proc() {context_focus_window(default_context())}

	@(private)
	_drop_paths_clear_context :: proc(ctx: ^Context) {
		assert(ctx != nil, "_drop_paths_clear_context: nil context")
		for path in ctx.drop.paths do delete(path)
		delete(ctx.drop.paths)
		ctx.drop.paths = nil
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

	context_is_file_dropped :: proc(ctx: ^Context) -> bool {
		return ctx != nil && ctx.drop.ready
	}

	IsFileDropped :: proc() -> bool {return context_is_file_dropped(default_context())}

	context_load_dropped_files :: proc(ctx: ^Context) -> FilePathList {
		if ctx == nil do return {}
		assert(len(ctx.drop.paths) <= MAX_DROPPED_FILES)
		return {
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

	context_get_dropped_file_data :: proc(
		ctx: ^Context,
		index: i32,
		allocator := context.allocator,
	) -> []byte {
		if ctx == nil || index < 0 || int(index) >= len(ctx.drop.paths) do return nil
		path := string(ctx.drop.paths[index])
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

	when ODIN_OS == .Darwin {
		NS_WINDOW_STYLE_MASK_FULLSCREEN :: uint(1) << 14

		@(objc_class = "NSWindow")
		FS_SDL_NS_Window :: struct {
			using _: intrinsics.objc_object,
		}

		@(private)
		_platform_native_fullscreen :: proc(ctx: ^Context) -> bool {
			window := cast(^FS_SDL_NS_Window)context_get_window_handle(ctx)
			if window == nil do return false
			style_mask := intrinsics.objc_send(uint, window, "styleMask")
			return style_mask & NS_WINDOW_STYLE_MASK_FULLSCREEN != 0
		}
	} else {
		@(private)
		_platform_native_fullscreen :: proc(ctx: ^Context) -> bool {return false}
	}

}
