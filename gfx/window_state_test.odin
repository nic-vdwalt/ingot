#+build !js
// ingot:gfx - window-state query regressions.
//
// The live-window halves of these paths (macOS NSWindowStyleMaskFullScreen,
// GLFW's HOVERED attribute) cannot run headless, so these tests pin the pure
// predicate and the nil-context contract; the platform halves are exercised
// manually. See fullscreen_darwin.odin and platform_window_hovered.
package gfx

import "core:testing"

@(test)
test_pointer_inside_window :: proc(t: ^testing.T) {
	testing.expect(t, _pointer_inside_window(0, 0, 800, 600), "top-left corner is inside")
	testing.expect(t, _pointer_inside_window(400, 300, 800, 600), "centre is inside")
	testing.expect(t, _pointer_inside_window(799.9, 599.9, 800, 600), "just inside far edge")

	testing.expect(t, !_pointer_inside_window(800, 300, 800, 600), "far edge is exclusive")
	testing.expect(t, !_pointer_inside_window(400, 600, 800, 600), "bottom edge is exclusive")
	testing.expect(t, !_pointer_inside_window(-1, 300, 800, 600), "negative x is outside")
	testing.expect(t, !_pointer_inside_window(400, -1, 800, 600), "negative y is outside")

	// A minimised or zero-sized window contains nothing, even at the origin.
	testing.expect(t, !_pointer_inside_window(0, 0, 0, 600), "zero width contains nothing")
	testing.expect(t, !_pointer_inside_window(0, 0, 800, 0), "zero height contains nothing")
	testing.expect(t, !_pointer_inside_window(0, 0, -800, -600), "negative size contains nothing")
}

@(test)
test_window_state_queries_nil_safe :: proc(t: ^testing.T) {
	testing.expect(t, !context_is_window_fullscreen(nil), "nil context is not fullscreen")
	testing.expect(t, !_platform_native_fullscreen(nil), "nil context has no native fullscreen")
	testing.expect(t, !platform_window_hovered(nil), "nil context is not hovered")
	testing.expect(t, !context_is_window_minimized(nil), "nil context is not minimized")
	testing.expect(t, !context_is_window_hidden(nil), "nil context is not hidden")

	// Context is far too large for the stack; the queries only touch ctx.win.
	windowless := new(Context)
	defer free(windowless)
	testing.expect(t, !context_is_window_fullscreen(windowless), "no window is not fullscreen")
	testing.expect(t, !_platform_native_fullscreen(windowless), "no window has no native fullscreen")
	testing.expect(t, !platform_window_hovered(windowless), "no window is not hovered")
}
