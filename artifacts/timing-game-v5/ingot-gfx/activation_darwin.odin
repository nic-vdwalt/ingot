#+build darwin
package gfx

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSWindow")
@(private = "file")
Focus_NS_Window :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
_darwin_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_darwin_activate_window: nil context")
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return
	application := NS.Application_sharedApplication()
	if application == nil do return
	_ = NS.Application_setActivationPolicy(application, .Regular)
	NS.Application_activateIgnoringOtherApps(application, true)
	intrinsics.objc_send(nil, window, "makeKeyAndOrderFront:", rawptr(nil))
}

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activate_window: nil context")
	ctx.activation_retries_pending = ACTIVATION_RETRY_LIMIT
	_darwin_activate_window(ctx)
	assert(ctx.activation_retries_pending == ACTIVATION_RETRY_LIMIT)
}

@(private)
_platform_activation_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activation_poll: nil context")
	focused, known := _platform_native_window_focus(ctx)
	next, retry := _activation_retry_advance(ctx.activation_retries_pending, known && focused)
	ctx.activation_retries_pending = next
	if retry do _darwin_activate_window(ctx)
	assert(ctx.activation_retries_pending <= ACTIVATION_RETRY_LIMIT)
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	if ctx == nil || ctx.win == nil do return false, false
	window := cast(^Focus_NS_Window)context_get_window_handle(ctx)
	if window == nil do return false, false
	is_key := intrinsics.objc_send(NS.BOOL, window, "isKeyWindow")
	return bool(is_key), true
}
