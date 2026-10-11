package main

import fit "ingot:fit"

Workspace_Preference :: struct {
	enabled: bool,
}

State :: struct {
	local_preferences:     [2]Workspace_Preference,
	preference_keys:       [2]u64,
	reset_count:           int,
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
	preference_keys       = {101, 205},
	notifications_enabled = true,
	quality               = 1,
	workspace             = 101,
}

main :: proc() {
	flags: fit.Window_Flags = {.Resizable, .Vsync}
	when ODIN_OS == .Darwin do flags += {.High_Dpi}
	_ = fit.run(
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
	fit.combobox_state_destroy(&data.workspace_combobox)
}

draw_preference :: proc(parent: fit.Parent, stable_key: u64, data: ^Workspace_Preference) {
	assert(data != nil, "builder controls preference: nil state")
	assert(stable_key != 0, "builder controls preference: zero key")
	scoped := fit.scope(parent, stable_key)
	fit.checkbox(scoped, "enabled", "Enable local settings", &data.enabled)
}

draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil, "builder controls draw: invalid argument")
	data := cast(^State)user_data
	root := fit.column(
		builder,
		{gap = .MD, padding = .XL, size = {width = fit.grow(), height = fit.grow()}},
	)
	fit.label(root, "Workspace settings", {role = .Title})
	fit.label(
		root,
		"Caller-owned state rebuilt through the recommended Fit Builder API.",
		{ink = .Secondary},
	)
	fit.tabs(root, "settings.tabs", TAB_LABELS[:], &data.active_tab)
	content := fit.card(root, {container = {padding = .LG, size = {width = fit.grow()}}})
	switch data.active_tab {
	case 0:
		draw_general(content, data)
	case 1:
		draw_editor(content, data)
	case 2:
		draw_account(content, data)
	}
	fit.label(root, status_text(data), {ink = .Secondary})
}

draw_general :: proc(parent: fit.Parent, data: ^State) {
	assert(data != nil, "builder controls general: nil state")
	fit.label(parent, "General", {role = .Title})
	fit.toggle(parent, "notifications", "Enable notifications", &data.notifications_enabled)
	fit.dropdown(
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
	fit.label(parent, "Editor", {role = .Title})
	fit.combobox(
		parent,
		"workspace",
		&data.workspace_combobox,
		WORKSPACE_ITEMS[:],
		&data.workspace,
		"Choose workspace...",
		"Workspace",
	)
	fit.checkbox(parent, "telemetry", "Share diagnostics", &data.telemetry_enabled)
}

reset_preference :: proc(user_data: rawptr, stable_key: u64) {
	assert(user_data != nil)
	assert(stable_key != 0)
	data := cast(^State)user_data
	for key, index in data.preference_keys {
		if key != stable_key do continue
		data.local_preferences[index].enabled = false
		data.reset_count += 1
		return
	}
}

draw_preference_reset :: proc(parent: fit.Parent, stable_key: u64, data: ^State) {
	assert(data != nil)
	assert(stable_key != 0)
	scoped := fit.scope(parent, stable_key)
	fit.button(
		scoped,
		"reset",
		"Reset local settings",
		fit.action(reset_preference, data, stable_key),
	)
}

draw_account :: proc(parent: fit.Parent, data: ^State) {
	assert(data != nil, "builder controls account: nil state")
	fit.label(parent, "Account", {role = .Title})
	fit.label(parent, "Account settings are synchronized with the selected workspace.")
	fit.progress(parent, 0.75)
	fit.canvas_leaf(parent, {intrinsic = {w = 160, h = 48}}, preview_render)
	for key, index in data.preference_keys {
		if key == 0 do continue
		draw_preference(parent, key, &data.local_preferences[index])
		draw_preference_reset(parent, key, data)
	}
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
