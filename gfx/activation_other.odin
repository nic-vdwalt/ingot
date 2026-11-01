#+build linux
package gfx

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activate_window: nil context")
}

@(private)
_platform_activation_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activation_poll: nil context")
}

@(private)
_platform_modifier_reconcile :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_modifier_reconcile: nil context")
}

@(private)
_platform_activation_wait_timeout :: proc(ctx: ^Context, timeout: f64) -> f64 {
	assert(ctx != nil, "_platform_activation_wait_timeout: nil context")
	return timeout
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	_ = ctx
	return false, false
}

// Linux has no cross-application cursor hit test here, so the pointer is
// never treated as occluded and behaviour is unchanged.
@(private)
_platform_cursor_occluded :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_platform_cursor_occluded: nil context")
	return false
}
