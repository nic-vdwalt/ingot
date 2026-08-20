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

Apply_Window_Style :: proc() {
	ui.apply_window_style(gfx.GetWindowHandle())
}

Titlebar_Init :: proc() {
	ui.titlebar_init(gfx.GetWindowHandle())
}

Titlebar_Enabled :: proc() -> bool {
	return ui.titlebar_enabled()
}

Titlebar_State :: proc() -> (hover, pressed: Caption_Button, maximized: bool) {
	hover_inner, pressed_inner, is_maximized := ui.titlebar_state()
	return Caption_Button(hover_inner), Caption_Button(pressed_inner), is_maximized
}

Titlebar_Set_Layout :: proc(
	minimize, maximize, close: Float_Rect,
	interactive_right, caption_height: i32,
) {
	ui.titlebar_set_layout(
		to_float_rect(minimize),
		to_float_rect(maximize),
		to_float_rect(close),
		interactive_right,
		caption_height,
	)
}

Titlebar_Consume_Activity :: proc() -> bool {
	return ui.titlebar_consume_activity()
}

Surface_Caption_Buttons_Width :: proc(surface: ^Surface) -> i32 {
	u := surface_ui(surface)
	return ui.caption_buttons_width(u.frame)
}

Surface_Caption_Buttons :: proc(
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
		{
			hover = ui.Caption_Button(input.hover),
			pressed = ui.Caption_Button(input.pressed),
			maximized = input.maximized,
		},
	)
	return Float_Rect(minimize_inner), Float_Rect(maximize_inner), Float_Rect(close_inner)
}

App_Window_Minimized :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "Fit.App_Window_Minimized: invalid app")
	return gfx.context_is_window_minimized(app.inner.gfx_context)
}

App_Window_Hidden :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "Fit.App_Window_Hidden: invalid app")
	return gfx.context_is_window_hidden(app.inner.gfx_context)
}

App_Window_Fullscreen :: proc(app: ^App) -> bool {
	assert(app != nil && app.inner.gfx_context != nil, "Fit.App_Window_Fullscreen: invalid app")
	return gfx.context_is_window_fullscreen(app.inner.gfx_context)
}

App_Request_Redraw_In :: proc(app: ^App, seconds: f64) {
	assert(app != nil && app.inner.gfx_context != nil, "Fit.App_Request_Redraw_In: invalid app")
	gfx.context_request_redraw_in(app.inner.gfx_context, seconds)
}

Set_Glass_Fullscreen :: proc(app: ^App, fullscreen: bool) {
	assert(app != nil && app.inner.state != .Empty, "Fit.Set_Glass_Fullscreen: invalid app")
	ui.ui_runtime_set_glass_fullscreen(ui_gfx.app_ui_runtime(&app.inner), fullscreen)
}
