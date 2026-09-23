#+build !js
// ingot:gfx - window-state query regressions.
//
// The live-window halves of these paths (macOS NSWindowStyleMaskFullScreen,
// GLFW's HOVERED attribute) cannot run headless, so these tests pin the pure
// predicate and the nil-context contract; the platform halves are exercised
// manually. See fullscreen_darwin.odin and platform_window_hovered.
package gfx

import "core:testing"
import wg "vendor:wgpu"

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
test_window_topmost_policy :: proc(t: ^testing.T) {
	testing.expect(t, !_window_wants_topmost({}), "default window is not floating")
	testing.expect(t, _window_wants_topmost({.WINDOW_TOPMOST}), "topmost window floats")
	testing.expect(
		t,
		_window_wants_topmost({.WINDOW_TOPMOST, .WINDOW_UNFOCUSED}),
		"topmost is independent of focus",
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
	delays := ACTIVATION_RETRY_DELAYS
	pending := ACTIVATION_RETRY_LIMIT
	next_at := 0.0
	now := 10.0
	for attempt in 0 ..< int(ACTIVATION_RETRY_LIMIT) {
		if next_at > now {
			early_pending, early_at, early_retry := _activation_retry_advance(
				pending,
				next_at,
				next_at - 0.001,
				false,
			)
			testing.expect(t, !early_retry, "no retry before the scheduled deadline")
			testing.expect_value(t, early_pending, pending)
			testing.expect_value(t, early_at, next_at)
			now = next_at
		}
		next, due, retry := _activation_retry_advance(pending, next_at, now, false)
		testing.expect(t, retry, "unfocused window retries at its scheduled offset")
		testing.expect_value(t, next, pending - 1)
		if next > 0 {
			testing.expect_value(t, due, now + delays[attempt + 1])
		} else {
			testing.expect_value(t, due, now + ACTIVATION_REARM_COOLDOWN)
		}
		pending = next
		next_at = due
	}
	next, due, retry := _activation_retry_advance(pending, next_at, next_at + 100, false)
	testing.expect(t, !retry, "exhausted window does not keep stealing focus")
	testing.expect_value(t, next, u8(0))
	testing.expect_value(t, due, next_at)
	next, due, retry = _activation_retry_advance(ACTIVATION_RETRY_LIMIT, 0, now, true)
	testing.expect(t, !retry, "focused window stops retrying immediately")
	testing.expect_value(t, next, u8(0))
	testing.expect_value(t, due, 0.0)
}

when ODIN_OS == .Darwin {
	@(test)
	test_event_pumps_advance_activation_once :: proc(t: ^testing.T) {
		modes := [?]bool{false, true}
		for should_wait in modes {
			ctx := new(Context)
			ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
			ctx.activation_next_at = 0
			input_service_events(ctx, should_wait, 0.001)
			testing.expect_value(t, ctx.activation_retries_pending, ACTIVATION_RETRY_LIMIT - 1)
			for attempt in 0 ..< int(ACTIVATION_RETRY_LIMIT) {
				input_service_events(ctx, should_wait, 0.001)
				_ = attempt
			}
			testing.expect_value(
				t,
				ctx.activation_retries_pending,
				ACTIVATION_RETRY_LIMIT - 1,
			)
			free(ctx)
		}
	}
}

@(test)
test_activation_wait_timeout_clamps_to_retry :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	testing.expect_value(t, _platform_activation_wait_timeout(ctx, 1.0), 1.0)
	when ODIN_OS == .Darwin {
		ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
		ctx.activation_next_at = platform_now() + 0.25
		wait := _platform_activation_wait_timeout(ctx, 1.0)
		testing.expect(t, wait > 0 && wait <= 0.25, "wait ends at the next retry deadline")
		testing.expect_value(t, _platform_activation_wait_timeout(ctx, 0.1), 0.1)
		ctx.activation_next_at = 0
		testing.expect_value(t, _platform_activation_wait_timeout(ctx, 1.0), 0.0)
	}
}

@(test)
test_window_activation_rearm_policy :: proc(t: ^testing.T) {
	testing.expect(
		t,
		_activation_should_rearm(true, false, false, true, true, false, true, 0, 5),
		"application activation repairs a non-key eligible window",
	)
	testing.expect(
		t,
		!_activation_should_rearm(true, true, false, true, true, true, true, 10, 5),
		"an active application does not steal focus from its other key window",
	)
	testing.expect(
		t,
		!_activation_should_rearm(true, true, false, true, true, false, true, 4, 5),
		"an active application without a key window waits for the cooldown",
	)
	testing.expect(
		t,
		_activation_should_rearm(true, true, false, true, true, false, true, 5, 5),
		"an active application without a key window re-arms after the cooldown",
	)
	testing.expect(
		t,
		!_activation_should_rearm(true, false, true, true, true, false, true, 0, 0),
		"a key window needs no activation repair",
	)
	testing.expect(
		t,
		!_activation_should_rearm(true, false, false, true, false, false, true, 0, 0),
		"an unfocused or hidden window remains ineligible",
	)
	testing.expect(
		t,
		!_activation_should_rearm(true, false, false, true, true, false, false, 0, 0),
		"an invisible or minimized window does not re-arm",
	)
	testing.expect(
		t,
		!_activation_should_rearm(false, false, false, true, true, false, true, 10, 0),
		"an inactive application does not re-arm",
	)
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
test_surface_present_mode_is_explicit_and_capability_checked :: proc(t: ^testing.T) {
	supported := [?]wg.PresentMode{.Fifo, .Immediate}
	testing.expect_value(t, _surface_present_mode({}, supported[:]), wg.PresentMode.Fifo)
	testing.expect_value(
		t,
		_surface_present_mode({.PRESENT_IMMEDIATE}, supported[:]),
		wg.PresentMode.Immediate,
	)
	testing.expect_value(
		t,
		_surface_present_mode({.PRESENT_IMMEDIATE}, supported[:1]),
		wg.PresentMode.Fifo,
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
