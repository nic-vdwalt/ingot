package main

import fit "ingot:fit"

State :: struct {
	showing: bool,
	toggle:  fit.Signal,
	enabled: bool,
	items:   [3]u64,
}

app: fit.App
state := State {
	items = {101, 205, 309},
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
	root_container: {
		fit.Center(builder, {gap = .SM, padding = .LG})
		defer fit.End(builder)
		fit.Label(builder, "Hello from Ingot", {role = .Title})
		controls_container: {
			fit.Row(builder, {gap = .SM, align = .Center})
			defer fit.End(builder)
			fit.Label(builder, "Controls", {role = .Label, track = fit.Grow()})
			if fit.Button(builder, "toggle", "Toggle list", &data.toggle) {
				data.showing = !data.showing
			}
		}
		fit.Checkbox(builder, "enabled", "Enabled", &data.enabled)
		if data.showing {
			fit.Column(builder, {gap = .XS})
			defer fit.End(builder)
			for item in data.items do fit.Button(builder, item, "Stable item")
		}
	}
}
