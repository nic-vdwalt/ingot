#+build darwin
package gfx

import "base:intrinsics"
@(require) import "core:fmt"
import NS "core:sys/darwin/Foundation"

INGOT_FOCUS_TRACE :: #config(INGOT_FOCUS_TRACE, false)

@(objc_class = "NSWindow")
@(private = "file")
Focus_NS_Window :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
_darwin_activate_application :: proc(application: ^NS.Application) {
	assert(application != nil, "_darwin_activate_application: nil application")
	// macOS 14+ ignores activateIgnoringOtherApps:; activate is the cooperative
	// replacement and is honoured when the system grants activation.
	if bool(NS.respondsToSelector(cast(^NS.Object)application, NS.sel_registerName("activate"))) {
		NS.Application_activate(application)
	} else {
		NS.Application_activateIgnoringOtherApps(application, true)
	}
}

// A key window whose first responder is the window itself routes keystrokes to
// -[NSWindow noResponderFor:], which beeps. setStyleMask: and content-view
// swaps can leave it there, so hand input back to the backend's view.
@(private = "file")
_darwin_repair_first_responder :: proc(ctx: ^Context, window: ^Focus_NS_Window) {
	assert(ctx != nil, "_darwin_repair_first_responder: nil context")
	if window == nil || ctx.activation_view == nil do return
	responder := intrinsics.objc_send(rawptr, window, "firstResponder")
	if responder != nil && responder != rawptr(window) do return
	repaired := intrinsics.objc_send(NS.BOOL, window, "makeFirstResponder:", ctx.activation_view)
	when INGOT_FOCUS_TRACE {
		fmt.eprintfln("[ingot focus] first responder repaired=%v", bool(repaired))
	} else {
		_ = repaired
	}
}

@(private = "file")
_darwin_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_darwin_activate_window: nil context")
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return
	application := NS.Application_sharedApplication()
	if application == nil do return
	_ = NS.Application_setActivationPolicy(application, .Regular)
	_darwin_activate_application(application)
	intrinsics.objc_send(nil, window, "makeKeyAndOrderFront:", rawptr(nil))
	_darwin_repair_first_responder(ctx, window)
	when INGOT_FOCUS_TRACE {
		fmt.eprintfln(
			"[ingot focus] activate: app_active=%v key_window=%p is_key=%v first_responder=%p pending=%d",
			bool(NS.Application_active(application)),
			NS.Application_keyWindow(application),
			bool(intrinsics.objc_send(NS.BOOL, window, "isKeyWindow")),
			intrinsics.objc_send(rawptr, window, "firstResponder"),
			ctx.activation_retries_pending,
		)
	}
}

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activate_window: nil context")
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	// The first call happens at window-ready time, before applications may wrap
	// the content view, so this captures the backend's input view.
	if ctx.activation_view == nil && window != nil {
		ctx.activation_view = intrinsics.objc_send(rawptr, window, "contentView")
	}
	ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
	ctx.activation_next_at = 0
	_platform_activation_poll(ctx)
	assert(ctx.activation_retries_pending <= ACTIVATION_RETRY_LIMIT)
}

@(private)
_platform_activation_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activation_poll: nil context")
	now := platform_now()
	focused, known := _platform_native_window_focus(ctx)
	visible := !_platform_native_window_hidden(ctx) && !_platform_native_window_minimized(ctx)
	application := NS.Application_sharedApplication()
	app_active := application != nil && bool(NS.Application_active(application))
	app_has_key_window := application != nil && NS.Application_keyWindow(application) != nil
	rearm := _activation_should_rearm(
		app_active,
		ctx.application_was_active,
		focused,
		known,
		_window_should_activate(ctx.config_flags),
		app_has_key_window,
		visible,
		now,
		ctx.activation_next_at,
	)
	ctx.application_was_active = app_active
	if ctx.activation_retries_pending == 0 && rearm {
		ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
		ctx.activation_next_at = now
	}
	next, next_at, retry := _activation_retry_advance(
		ctx.activation_retries_pending,
		ctx.activation_next_at,
		now,
		known && focused,
	)
	ctx.activation_retries_pending = next
	ctx.activation_next_at = next_at
	if retry {
		_darwin_activate_window(ctx)
	} else if known && focused {
		_darwin_repair_first_responder(ctx, cast(^Focus_NS_Window)context_get_window_handle(ctx))
	}
	assert(ctx.activation_retries_pending <= ACTIVATION_RETRY_LIMIT)
	assert(!(known && focused) || ctx.activation_retries_pending == 0)
}

// _platform_activation_wait_timeout shortens an idle wait so a scheduled
// activation retry runs on time even when no native event arrives.
@(private)
_platform_activation_wait_timeout :: proc(ctx: ^Context, timeout: f64) -> f64 {
	assert(ctx != nil, "_platform_activation_wait_timeout: nil context")
	if ctx.activation_retries_pending == 0 do return timeout
	return clamp(ctx.activation_next_at - platform_now(), 0, timeout)
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	if ctx == nil || ctx.win == nil do return false, false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false, false
	is_key := intrinsics.objc_send(NS.BOOL, window, "isKeyWindow")
	return bool(is_key), true
}

@(private)
_platform_native_window_minimized :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false
	return bool(intrinsics.objc_send(NS.BOOL, window, "isMiniaturized"))
}

@(private)
_platform_native_window_hidden :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx.win == nil do return false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false
	return !bool(intrinsics.objc_send(NS.BOOL, window, "isVisible"))
}
