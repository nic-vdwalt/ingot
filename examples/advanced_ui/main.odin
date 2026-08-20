package main

import "core:fmt"
import ui "ingot:ui"
import "ingot:ui_gfx"

App_State :: struct {
	button_clicks: u64,
}

app: ui_gfx.App
state: App_State

main :: proc() {
	_ = ui_gfx.app_run(
		&app,
		{
			width = 960,
			height = 640,
			title = "Ingot advanced UI",
			session = {semantics_enabled = true},
		},
		{ui = draw},
		&state,
	)
}

draw :: proc(app: ^ui_gfx.App, form: ^ui.Ui, user_data: rawptr) {
	assert(app != nil && form != nil && user_data != nil, "draw: invalid argument")
	data := cast(^App_State)user_data
	ui.padding(form, .LG)
	ui.label(form, "Hello from Ingot", ui.ui_frame_metrics(form.frame).FONT_SIZE_TITLE)
	ui.label(form, fmt.tprintf("Button clicks: %d", data.button_clicks))
	if ui.button(form, "continue", "Continue") {
		data.button_clicks += 1
	}
}
