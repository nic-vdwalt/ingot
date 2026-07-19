// ingot:gfx — native window-handle accessor (raylib GetWindowHandle parity).
// Returns the platform window object apps need for OS chrome (NSWindow on
// macOS, HWND on Windows) — used by ingot's window_style_*/titlebar_* glue.
package gfx

import "vendor:glfw"

when ODIN_OS == .Darwin {
	GetWindowHandle :: proc() -> rawptr {
		if g.win == nil do return nil
		return rawptr(glfw.GetCocoaWindow(g.win))
	}
} else when ODIN_OS == .Windows {
	GetWindowHandle :: proc() -> rawptr {
		if g.win == nil do return nil
		return rawptr(glfw.GetWin32Window(g.win))
	}
} else {
	GetWindowHandle :: proc() -> rawptr {
		return rawptr(g.win)
	}
}
