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
test_window_initial_focus_policy :: proc(t: ^testing.T) {
	testing.expect(t, _window_wants_initial_focus({}), "default window requests focus")
	testing.expect(t, _window_should_activate({}), "ready visible window activates")
	testing.expect(
		t,
		!_window_wants_initial_focus({.WINDOW_UNFOCUSED}),
		"unfocused window does not request focus",
	)
	testing.expect(
		t,
		!_window_should_activate({.WINDOW_UNFOCUSED}),
		"ready unfocused window does not activate",
	)
	testing.expect(
		t,
		!_window_should_activate({.WINDOW_HIDDEN}),
		"ready hidden window does not activate",
	)
	testing.expect(
		t,
		!_window_should_activate({.WINDOW_HIDDEN, .WINDOW_UNFOCUSED}),
		"ready hidden unfocused window does not activate",
	)
	testing.expect(t, _window_should_focus_on_show({}), "shown default window requests focus")
	testing.expect(
		t,
		_window_should_focus_on_show({.WINDOW_HIDDEN}),
		"shown deferred window requests focus",
	)
	testing.expect(
		t,
		!_window_should_focus_on_show({.WINDOW_UNFOCUSED}),
		"shown unfocused window does not request focus",
	)
	testing.expect(
		t,
		!_window_should_focus_on_show({.WINDOW_HIDDEN, .WINDOW_UNFOCUSED}),
		"shown deferred unfocused window does not request focus",
	)
}

@(test)
test_window_focus_resolution :: proc(t: ^testing.T) {
	testing.expect(t, _window_focus_resolve(true, false, false), "GLFW focus is the fallback")
	testing.expect(t, !_window_focus_resolve(false, true, false), "GLFW blur is the fallback")
	testing.expect(
		t,
		_window_focus_resolve(false, true, true),
		"native focus repairs stale GLFW blur",
	)
	testing.expect(
		t,
		!_window_focus_resolve(true, false, true),
		"native blur overrides stale GLFW focus",
	)
}

@(test)
test_window_activation_retry_policy :: proc(t: ^testing.T) {
	pending := ACTIVATION_RETRY_LIMIT
	for attempt in 0 ..< int(ACTIVATION_RETRY_LIMIT) {
		next, retry := _activation_retry_advance(pending, false)
		testing.expect(t, retry, "unfocused window retries within the fixed budget")
		testing.expect_value(t, next, pending - 1)
		pending = next
		_ = attempt
	}
	next, retry := _activation_retry_advance(pending, false)
	testing.expect(t, !retry, "exhausted window does not keep stealing focus")
	testing.expect_value(t, next, u8(0))
	next, retry = _activation_retry_advance(ACTIVATION_RETRY_LIMIT, true)
	testing.expect(t, !retry, "focused window stops retrying immediately")
	testing.expect_value(t, next, u8(0))
}

@(test)
test_surface_reconfigure_policy :: proc(t: ^testing.T) {
	testing.expect(
		t,
		_surface_should_reconfigure(false, true, 800, 600),
		"forced startup reconfigures an unchanged framebuffer",
	)
	testing.expect(
		t,
		!_surface_should_reconfigure(false, false, 800, 600),
		"unchanged framebuffer does not reconfigure without a request",
	)
	testing.expect(
		t,
		!_surface_should_reconfigure(false, true, 0, 600),
		"zero-sized framebuffer waits before reconfiguring",
	)
}

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
	testing.expect(
		t,
		!_platform_native_fullscreen(windowless),
		"no window has no native fullscreen",
	)
	testing.expect(t, !platform_window_hovered(windowless), "no window is not hovered")
}
