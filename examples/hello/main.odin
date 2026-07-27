package main

import rl "ingot:gfx"
import ui "ingot:ui"
import "ingot:ui_gfx"

State :: struct {
	form:    ui.Ui,
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
		{frame = draw, shutdown = shutdown},
		&state,
	)
}

draw :: proc(app: ^ui_gfx.App, frame: ^ui.Ui_Frame, userdata: rawptr) {
	data := cast(^State)userdata
	root := ui_gfx.app_screen_rect(app)
	ui.begin(&data.form, frame, root, gap = .SM)
	ui.padding(&data.form, .LG)
	ui.scope_begin(&data.form, "hello")
	ui.label(&data.form, "Hello from Ingot", ui.ui_frame_metrics(frame).FONT_SIZE_LARGE)
	ui.flex_row_begin(&data.form, 32, {ui.fit(120), ui.grow()}, gap = .SM)
	ui.label(&data.form, "Controls")
	if ui.button(&data.form, ui.id(&data.form, "toggle"), "Toggle list") {
		data.showing = !data.showing
	}
	ui.flex_row_end(&data.form)
	if data.showing {
		ui.scope_begin(&data.form, "items")
		for item in data.items {
			_ = ui.button(&data.form, ui.id(&data.form, item), "Stable item")
		}
		ui.scope_end(&data.form)
	}
	ui.scope_end(&data.form)
	ui.end(&data.form)
}

shutdown :: proc(app: ^ui_gfx.App, userdata: rawptr) {
	assert(app != nil && userdata != nil, "shutdown: invalid state")
}
