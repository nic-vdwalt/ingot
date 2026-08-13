package main

import fit "ingot:fit"
import rl "ingot:gfx"

session: fit.Session
click_count: u64
clicked: bool

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
	rl.SetConfigFlags(flags)
	rl.InitWindow(720, 480, "Ingot Fit session loop")
	fit.Session_Init(&session, {semantics_enabled = true})
	rl.run(frame)
	when ODIN_OS != .JS {
		fit.Session_Destroy(&session)
		rl.CloseWindow()
	}
}

frame :: proc() {
	if clicked {
		click_count += 1
		clicked = false
	}
	_ = fit.Session_Draw(&session, draw)
}

draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil, "draw: nil builder")
	_ = userdata
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Custom Fit session loop", {role = .Title})
	fit.Button(builder, "count", "Count clicks", &clicked)
	fit.End(builder)
}
