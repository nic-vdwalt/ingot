package main

import fit "ingot:fit"

State :: struct {
	showing: bool,
	enabled: bool,
	items:   [3]u64,
}

app: fit.App
state := State {
	items = {101, 205, 309},
}

toggle_list :: proc(userdata: rawptr) {
	data := cast(^State)userdata
	assert(data != nil, "toggle_list: nil state")
	data.showing = !data.showing
}

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	_ = fit.Run(
		&app,
		{
			width = 720,
			height = 480,
			title = "Ingot hello",
			flags = flags,
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			event_waiting = true,
			session = {semantics_enabled = true},
		},
		draw,
		&state,
	)
}

draw :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil && userdata != nil, "draw: invalid argument")
	data := cast(^State)userdata
	root := fit.Center(builder, {gap = .SM, padding = .LG})
	fit.Label(root, "Hello from Ingot", {role = .Title})
	controls := fit.Row(root, {gap = .SM, align = .Center})
	fit.Label(controls, "Controls", {role = .Label, track = fit.Grow()})
	fit.Button(controls, "toggle", "Toggle list", fit.On(toggle_list, data))
	fit.Checkbox(root, "enabled", "Enabled", &data.enabled)
	if data.showing {
		items := fit.Column(root, {gap = .XS})
		for item in data.items do fit.Button(items, item, "Stable item")
	}
}
