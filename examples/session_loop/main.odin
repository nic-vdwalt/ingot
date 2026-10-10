package main

import fit "ingot:fit"

app: fit.App
click_count: u64

count_click :: proc(user_data: rawptr) {
	_ = user_data
	click_count += 1
}

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	started := fit.init(
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
	defer fit.destroy(&app)
	if !fit.start(&app) do return
	// tigerstyle: allow-unbounded-loop -- the application runs until the window closes
	for fit.get_state(&app) == .Running {
		if !fit.tick(&app) do break
	}
	if fit.get_state(&app) == .Running do _ = fit.stop(&app)
}

draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil, "draw: nil builder")
	_ = user_data
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Custom Fit application loop", {role = .Title})
	fit.label(root, "The caller owns Init, Start, Tick, Stop, and Destroy.")
	fit.button(root, "count", "Count clicks", fit.action(count_click))
}
