#+build !darwin
package gfx

@(private)
_platform_activate_application :: proc() {}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	_ = ctx
	return false, false
}
