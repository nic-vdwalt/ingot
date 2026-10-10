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

toggle_list :: proc(user_data: rawptr) {
	data := cast(^State)user_data
	assert(data != nil, "toggle_list: nil state")
	data.showing = !data.showing
}

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	_ = fit.run(
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

draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "draw: invalid argument")
	data := cast(^State)user_data
	root := fit.center(builder, {gap = .SM, padding = .LG})
	fit.label(root, "Hello from Ingot", {role = .Title})
	controls := fit.row(root, {gap = .SM, align = .Center})
	fit.label(controls, "Controls", {role = .Label, track = fit.grow()})
	fit.button(controls, "toggle", "Toggle list", fit.action(toggle_list, data))
	fit.checkbox(root, "enabled", "Enabled", &data.enabled)
	if data.showing {
		items := fit.column(root, {gap = .XS})
		for item in data.items do fit.button(items, item, "Stable item")
	}
}
