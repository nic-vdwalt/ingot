package main

import rl "ingot:gfx"
import ui "ingot:ui"
import "ingot:ui_gfx"

session: ui_gfx.Session
click_count: u64

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	rl.SetConfigFlags(flags)
	rl.InitWindow(720, 480, "Ingot custom session loop")
	ui_gfx.session_init(&session, {semantics_enabled = true})
	rl.run(frame)
	when ODIN_OS != .JS {
		ui_gfx.session_destroy(&session)
		rl.CloseWindow()
	}
}

frame :: proc() {
	frame, acquired := ui_gfx.session_acquire_frame(&session)
	if !acquired do return

	rl.clear_frame(frame.gfx, rl.Color{22, 24, 32, 255})
	ui.text(frame.ui, "Custom Session loop", 32, 32, .Title)
	if ui.button_at(frame.ui, {32, 80, 160, 36}, "Count clicks", .Primary) {
		click_count += 1
	}

	ui_gfx.session_present_frame(&frame)
}
