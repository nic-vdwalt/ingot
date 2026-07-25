#+build !js
// ingot:gfx — native window-handle accessor (raylib GetWindowHandle parity).
// Returns the platform window object apps need for OS chrome (NSWindow on
// macOS, HWND on Windows) — used by ingot's window_style_*/titlebar_* glue.
// Native-only; the web target provides GetWindowHandle in platform_web.odin.
package gfx

import "vendor:glfw"

when ODIN_OS == .Darwin {
	GetWindowHandle :: proc() -> rawptr {
		if g.win == nil do return nil
		_ = glfw.GetCurrentContext()
		return rawptr(glfw.GetCocoaWindow(glfw.WindowHandle(g.win)))
	}
} else when ODIN_OS == .Windows {
	GetWindowHandle :: proc() -> rawptr {
		if g.win == nil do return nil
		return rawptr(glfw.GetWin32Window(glfw.WindowHandle(g.win)))
	}
} else {
	GetWindowHandle :: proc() -> rawptr {
		return rawptr(g.win)
	}
}
