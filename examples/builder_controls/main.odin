package main

import fit "ingot:fit"

Workspace_Preference :: struct {
	enabled: bool,
}

State :: struct {
	local_preferences:     [2]Workspace_Preference,
	notifications_enabled: bool,
	telemetry_enabled:     bool,
	quality:               i32,
	quality_dropdown:      fit.Dropdown_State,
	workspace:             u64,
	workspace_combobox:    fit.Combobox_State,
	active_tab:            i32,
}

TAB_LABELS := [3]string{"General", "Editor", "Account"}
QUALITY_LABELS := [3]string{"Balanced", "Performance", "Quality"}
WORKSPACE_ITEMS := [4]fit.Combobox_Item {
	{101, "Forge"},
	{205, "Atlas"},
	{309, "Foundry"},
	{412, "Sandbox"},
}

app: fit.App
state := State {
	notifications_enabled = true,
	quality               = 1,
	workspace             = 101,
}

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	_ = fit.Run(
		&app,
		{
			width = 760,
			height = 560,
			title = "Ingot Builder controls",
			flags = flags,
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			event_waiting = true,
			session = {semantics_enabled = true},
		},
		draw,
		&state,
	)
	when ODIN_OS != .JS do destroy_state(&state)
}

destroy_state :: proc(data: ^State) {
	assert(data != nil, "builder controls destroy: nil state")
	fit.Combobox_State_Destroy(&data.workspace_combobox)
}

draw_preference :: proc(parent: fit.Parent, stable_key: u64, data: ^Workspace_Preference) {
	assert(data != nil, "builder controls preference: nil state")
	assert(stable_key != 0, "builder controls preference: zero key")
	scoped := fit.Scope(parent, stable_key)
	fit.Checkbox(scoped, "enabled", "Enable local settings", &data.enabled)
}

draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "builder controls draw: invalid argument")
	data := cast(^State)user_data
	root := fit.Column(
		builder,
		{gap = .MD, padding = .XL, size = {width = fit.Grow(), height = fit.Grow()}},
	)
	fit.Label(root, "Workspace settings", {role = .Title})
	fit.Label(
		root,
		"Caller-owned state rebuilt through the recommended Fit Builder API.",
		{ink = .Secondary},
	)
	fit.Tabs(root, "settings.tabs", TAB_LABELS[:], &data.active_tab)
	content := fit.Card(root, {container = {padding = .LG, size = {width = fit.Grow()}}})
	switch data.active_tab {
	case 0:
		draw_general(content, data)
	case 1:
		draw_editor(content, data)
	case 2:
		draw_account(content, data)
	}
	fit.Label(root, status_text(data), {ink = .Secondary})
}

draw_general :: proc(parent: fit.Parent, data: ^State) {
	assert(data != nil, "builder controls general: nil state")
	fit.Label(parent, "General", {role = .Title})
	fit.Toggle(parent, "notifications", "Enable notifications", &data.notifications_enabled)
	fit.Dropdown(
		parent,
		"quality",
		QUALITY_LABELS[:],
		&data.quality,
		&data.quality_dropdown,
		"Rendering quality",
	)
}

draw_editor :: proc(parent: fit.Parent, data: ^State) {
	assert(data != nil, "builder controls editor: nil state")
	fit.Label(parent, "Editor", {role = .Title})
	fit.Combobox(
		parent,
		"workspace",
		&data.workspace_combobox,
		WORKSPACE_ITEMS[:],
		&data.workspace,
		"Choose workspace...",
		"Workspace",
	)
	fit.Checkbox(parent, "telemetry", "Share diagnostics", &data.telemetry_enabled)
}

draw_account :: proc(parent: fit.Parent, data: ^State) {
	assert(data != nil, "builder controls account: nil state")
	fit.Label(parent, "Account", {role = .Title})
	fit.Label(parent, "Account settings are synchronized with the selected workspace.")
	fit.Progress(parent, 0.75)
	fit.Canvas_Leaf(parent, {intrinsic = {w = 160, h = 48}}, preview_render)
	draw_preference(parent, 101, &data.local_preferences[0])
	draw_preference(parent, 205, &data.local_preferences[1])
}

status_text :: proc(data: ^State) -> string {
	assert(data != nil, "builder controls status: nil state")
	if data.active_tab == 0 {
		return "General settings are stored directly in State."
	}
	if data.active_tab == 1 {
		return "Editor selections are stored directly in State."
	}
	return "Account progress is passive Builder output."
}
