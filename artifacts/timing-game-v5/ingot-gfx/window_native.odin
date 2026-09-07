#+build !js
// ingot:gfx - native window-handle accessor (raylib GetWindowHandle parity).
// Returns the platform window object apps need for OS chrome (NSWindow on
// macOS, HWND on Windows) - used by ingot's window_style_*/titlebar_* glue.
// Native-only; the web target provides GetWindowHandle in platform_web.odin.
package gfx

// glfw is used only under the Darwin/Windows branches; @(require) keeps the
// import legal on Linux where the generic branch returns the context window directly.
@(require) import "vendor:glfw"

when !INGOT_GFX_SDL3 {

	when ODIN_OS == .Darwin {
		context_get_window_handle :: proc(ctx: ^Context) -> rawptr {
			if ctx == nil || ctx.win == nil do return nil
			_ = glfw.GetCurrentContext()
			return rawptr(glfw.GetCocoaWindow(glfw.WindowHandle(ctx.win)))
		}
	} else when ODIN_OS == .Windows {
		context_get_window_handle :: proc(ctx: ^Context) -> rawptr {
			if ctx == nil || ctx.win == nil do return nil
			_ = glfw.GetCurrentContext()
			return rawptr(glfw.GetWin32Window(glfw.WindowHandle(ctx.win)))
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

}
