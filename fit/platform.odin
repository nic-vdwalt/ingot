package fit

import "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

Caption_Button :: ui.Caption_Button

Caption_Input :: struct {
	hover:     Caption_Button,
	pressed:   Caption_Button,
	maximized: bool,
}

apply_window_style :: proc() {
	ui.apply_window_style(gfx.GetWindowHandle())
}

titlebar_init :: proc() {
	ui.titlebar_init(gfx.GetWindowHandle())
}

titlebar_enabled :: proc() -> bool {
	return ui.titlebar_enabled()
}

titlebar_state :: proc() -> (hover, pressed: Caption_Button, maximized: bool) {
	hover_inner, pressed_inner, is_maximized := ui.titlebar_state()
	return Caption_Button(hover_inner), Caption_Button(pressed_inner), is_maximized
}

titlebar_set_layout :: proc(
	minimize, maximize, close: Float_Rect,
	interactive_right, caption_height: i32,
) {
	ui.titlebar_set_layout(minimize, maximize, close, interactive_right, caption_height)
}

titlebar_consume_activity :: proc() -> bool {
	return ui.titlebar_consume_activity()
}

surface_caption_buttons_width :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.caption_buttons_width(u.frame)
}

surface_caption_buttons :: proc(
	surface: ^Surface,
	screen_width: i32,
	input: Caption_Input,
) -> (
	minimize, maximize, close: Float_Rect,
) {
	u := surface_ui(surface)
	minimize_inner, maximize_inner, close_inner := ui.draw_caption_buttons(
		u.frame,
		screen_width,
		{hover = input.hover, pressed = input.pressed, maximized = input.maximized},
	)
	return Float_Rect(minimize_inner), Float_Rect(maximize_inner), Float_Rect(close_inner)
}

app_window_minimized :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "fit.app_window_minimized: invalid app")
	return gfx.context_is_window_minimized(app.inner.gfx_context)
}

app_window_hidden :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "fit.app_window_hidden: invalid app")
	return gfx.context_is_window_hidden(app.inner.gfx_context)
}

app_window_fullscreen :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "fit.app_window_fullscreen: invalid app")
	return gfx.context_is_window_fullscreen(app.inner.gfx_context)
}

app_request_redraw_in :: proc(app: ^App, seconds: f64) {
	assert(app != nil && app.inner.gfx_context != nil, "fit.app_request_redraw_in: invalid app")
	gfx.context_request_redraw_in(app.inner.gfx_context, seconds)
}

set_glass_fullscreen :: proc(app: ^App, fullscreen: bool) {
	assert(app != nil && app.inner.state != .Empty, "fit.set_glass_fullscreen: invalid app")
	ui.ui_runtime_set_glass_fullscreen(ui_gfx.app_ui_runtime(&app.inner), fullscreen)
}
