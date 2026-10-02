#+build !js
// ingot:gfx - focus-follows-mouse on pointer entry (both native backends).
//
// Backend callbacks only record enter/leave/motion on the Context; the focus
// request itself runs here, from the event poll, outside any "c" callback.
package gfx

@(private)
_hover_focus_enter :: proc "contextless" (ctx: ^Context, inside: bool) {
	if ctx == nil do return
	ctx.pointer_inside = inside
	ctx.hover_focus_armed = inside
	if !inside do ctx.hover_focus_motion = false
}

@(private)
_hover_focus_buttons_down :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_hover_focus_buttons_down: nil context")
	for button in 0 ..< i32(Pointer_Button.Back) + 1 {
		if platform_mouse_button(ctx, button) do return true
	}
	return false
}

@(private)
_platform_hover_focus_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_hover_focus_poll: nil context")
	defer ctx.hover_focus_motion = false
	if ctx.win == nil || !ctx.hover_focus_armed do return
	visible := !context_is_window_hidden(ctx) && !context_is_window_minimized(ctx)
	request, armed := _hover_focus_step(
		ctx.hover_focus_armed,
		_window_focus_on_hover(ctx.config_flags),
		ctx.pointer_inside,
		ctx.hover_focus_motion,
		platform_window_focused(ctx),
		visible,
		_hover_focus_buttons_down(ctx),
	)
	ctx.hover_focus_armed = armed
	if request do context_focus_window(ctx)
	assert(!request || !ctx.hover_focus_armed)
}
