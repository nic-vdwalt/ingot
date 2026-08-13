package main

import fit "ingot:fit"
import rl "ingot:gfx"

State :: struct {
	showing: bool,
	toggle:  bool,
	enabled: bool,
	items:   [3]u64,
}

app: fit.App
state := State {
	items = {101, 205, 309},
}

main :: proc() {
	flags: rl.ConfigFlags = {.WINDOW_RESIZABLE, .VSYNC_HINT}
	when ODIN_OS == .Darwin do flags += {.WINDOW_HIGHDPI}
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
	if data.toggle {
		data.showing = !data.showing
		data.toggle = false
	}
	fit.Column(builder, {gap = .SM, padding = .LG})
	fit.Label(builder, "Hello from Ingot", {role = .Title})
	fit.Row(builder, {gap = .SM, align = .Center})
	fit.Label(builder, "Controls", {role = .Label, track = fit.Grow()})
	fit.Button(builder, "toggle", "Toggle list", &data.toggle)
	fit.End(builder)
	fit.Checkbox(builder, "enabled", "Enabled", &data.enabled)
	if data.showing {
		fit.Column(builder, {gap = .XS})
		for item in data.items do fit.Button(builder, item, "Stable item")
		fit.End(builder)
	}
	fit.End(builder)
}
