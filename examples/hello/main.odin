package main

import rl "ingot:gfx"
import ui "ingot:ui"
import "ingot:ui_gfx"

State :: struct {
	showing: bool,
	items:   [3]u64,
}

app: ui_gfx.App
state := State {
	items = {101, 205, 309},
}

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	_ = ui_gfx.app_run(
		&app,
		{
			width = 720,
			height = 480,
			title = "Ingot hello",
			flags = flags,
			target_fps = 60,
			event_waiting = true,
			clear_color = {24, 26, 32, 255},
			session = {semantics_enabled = true},
		},
		{ui = draw, shutdown = shutdown},
		&state,
	)
}

draw :: proc(app: ^ui_gfx.App, form: ^ui.Ui, userdata: rawptr) {
	assert(app != nil && form != nil, "draw: invalid app or UI")
	data := cast(^State)userdata
	ui.padding(form, .LG)
	ui.scope_begin(form, "hello")
	ui.label(form, "Hello from Ingot", ui.ui_frame_metrics(form.frame).FONT_SIZE_TITLE)
	ui.flex_row_begin(form, 32, {ui.fit(120), ui.grow()}, gap = .SM)
	ui.label(form, "Controls")
	if ui.button(form, "toggle", "Toggle list") {
		data.showing = !data.showing
	}
	ui.flex_row_end(form)
	if data.showing do ui.scope(form, "items", draw_items, &data.items)
	ui.scope_end(form)
}

draw_items :: proc(form: ^ui.Ui, userdata: rawptr) {
	assert(form != nil && userdata != nil, "draw_items: invalid state")
	items := cast(^[3]u64)userdata
	for item in items do _ = ui.button(form, item, "Stable item")
}

shutdown :: proc(app: ^ui_gfx.App, userdata: rawptr) {
	assert(app != nil && userdata != nil, "shutdown: invalid state")
}
