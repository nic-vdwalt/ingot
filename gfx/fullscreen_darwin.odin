#+build darwin
// ingot:gfx - macOS native-fullscreen detection seam.
//
// GLFW only knows about the fullscreen it created itself (SetWindowMonitor),
// which it reports through GetWindowMonitor. macOS has a second, more common
// path: the green traffic-light button / View > Enter Full Screen / any
// -[NSWindow toggleFullScreen:] call moves the window to its own Space while
// leaving it a regular windowed GLFW window on no monitor. The only reliable
// signal for that state is NSWindowStyleMaskFullScreen on the window's style
// mask, so query it directly.
package gfx

import "base:intrinsics"
import "vendor:glfw"

// NSWindowStyleMaskFullScreen (AppKit). Set by AppKit for the duration of a
// native fullscreen session, cleared when the window returns to its Space.
@(private = "file")
NS_WINDOW_STYLE_MASK_FULLSCREEN :: uint(1) << 14

@(objc_class = "NSWindow")
@(private = "file")
FS_NS_Window :: struct {
	using _: intrinsics.objc_object,
}

@(private)
_platform_native_fullscreen :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	window := (^FS_NS_Window)(rawptr(glfw.GetCocoaWindow(glfw.WindowHandle(ctx.win))))
	if window == nil do return false
	style_mask := intrinsics.objc_send(uint, window, "styleMask")
	return style_mask & NS_WINDOW_STYLE_MASK_FULLSCREEN != 0
}
