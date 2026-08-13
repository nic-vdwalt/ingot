package main

import "core:fmt"
import ui "ingot:fit"
import ui_gfx "ingot:fit"
import gfx "ingot:gfx"

FIXTURE_FRAME_LIMIT :: 120

Fixture_State :: struct {
	color: ui.Color,
}

fixture_frame :: proc(app: ^ui_gfx.Host_App, form: ^ui.Ui, userdata: rawptr) {
	assert(app != nil && form != nil, "fixture_frame: invalid app")
	state := cast(^Fixture_State)userdata
	assert(state != nil, "fixture_frame: nil state")
	ui.label(form, "Multi-App context fixture")
	_ = ui.status_pill(form, "isolated", ui.Ink.Success)
}

main :: proc() {
	primary_context := new(gfx.Context)
	secondary_context := new(gfx.Context)
	primary_app := new(ui_gfx.Host_App)
	secondary_app := new(ui_gfx.Host_App)
	defer free(primary_context)
	defer free(secondary_context)
	defer free(primary_app)
	defer free(secondary_app)
	primary_state := Fixture_State {
		color = {48, 96, 176, 255},
	}
	secondary_state := Fixture_State {
		color = {176, 72, 88, 255},
	}
	callbacks := ui_gfx.Host_App_Callbacks {
		ui = fixture_frame,
	}
	primary_ok := ui_gfx.app_init_context(
		primary_app,
		primary_context,
		{width = 640, height = 360, title = "Ingot primary App"},
		callbacks,
		&primary_state,
	)
	secondary_ok := ui_gfx.app_init_context(
		secondary_app,
		secondary_context,
		{width = 480, height = 300, title = "Ingot secondary App"},
		callbacks,
		&secondary_state,
	)
	if !primary_ok || !secondary_ok {
		fmt.eprintln("multi_app_fixture: initialization failed")
		if primary_ok do ui_gfx.app_destroy(primary_app)
		if secondary_ok do ui_gfx.app_destroy(secondary_app)
		return
	}
	if !ui_gfx.app_start(primary_app) || !ui_gfx.app_start(secondary_app) {
		fmt.eprintln("multi_app_fixture: start failed")
		return
	}
	for frame_index in 0 ..< FIXTURE_FRAME_LIMIT {
		if !ui_gfx.app_tick(primary_app) || !ui_gfx.app_tick(secondary_app) do break
		if frame_index == FIXTURE_FRAME_LIMIT / 2 {
			_ = ui_gfx.app_stop(primary_app)
			ui_gfx.app_destroy(primary_app)
			for _ in frame_index ..< FIXTURE_FRAME_LIMIT {
				if !ui_gfx.app_tick(secondary_app) do break
			}
			break
		}
	}
	if primary_app.state == .Running do _ = ui_gfx.app_stop(primary_app)
	if primary_app.state != .Empty do ui_gfx.app_destroy(primary_app)
	if secondary_app.state == .Running do _ = ui_gfx.app_stop(secondary_app)
	if secondary_app.state != .Empty do ui_gfx.app_destroy(secondary_app)
}
