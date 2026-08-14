package main

import fit "ingot:fit"

app: fit.App
click_count: u64
clicked: bool

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	started := fit.Init(
		&app,
		{
			width = 720,
			height = 480,
			title = "Ingot Fit application loop",
			flags = flags,
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			session = {semantics_enabled = true},
		},
		{draw = draw},
	)
	if !started do return
	defer fit.Destroy(&app)
	if !fit.Start(&app) do return
	// tigerstyle: allow-unbounded-loop -- the application runs until the window closes
	for fit.Get_State(&app) == .Running {
		if !fit.Tick(&app) do break
	}
	if fit.Get_State(&app) == .Running do _ = fit.Stop(&app)
}

draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil, "draw: nil builder")
	_ = userdata
	if clicked {
		click_count += 1
		clicked = false
	}
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Custom Fit application loop", {role = .Title})
	fit.Label(builder, "The caller owns Init, Start, Tick, Stop, and Destroy.")
	fit.Button(builder, "count", "Count clicks", &clicked)
	fit.End(builder)
}
