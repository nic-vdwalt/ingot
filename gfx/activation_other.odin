#+build linux
package gfx

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	_ = ctx
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	_ = ctx
	return false, false
}
