package main

import fit "ingot:fit"

// Gallery command palette (Ctrl/Cmd+K). Items are a fixed table built from
// the section tables, so adding a section adds its "Go to" command with no
// edit here. Command ids are stable constants: a section's id is its ordinal
// above PALETTE_SECTION_BASE, and actions sit in their own range.

PALETTE_SECTION_BASE :: 0x100
PALETTE_ACTION_BASE :: 0x200

Palette_Action :: enum {
	Next_Theme,
	Toggle_Motion,
	Open_Scale,
	Toggle_Debug,
	Toggle_Rotation,
}

PALETTE_ACTION_LABELS := [Palette_Action]string {
	.Next_Theme      = "Next theme",
	.Toggle_Motion   = "Toggle reduced motion",
	.Open_Scale      = "Open scale settings",
	.Toggle_Debug    = "Toggle debug overlay (F12)",
	.Toggle_Rotation = "Pause or resume model rotation",
}

PALETTE_ACTION_NOTES := [Palette_Action]string {
	.Next_Theme      = "Cycle to the next palette",
	.Toggle_Motion   = "Snap animations to their targets",
	.Open_Scale      = "Choose a UI scale preset",
	.Toggle_Debug    = "Renderer and paint counters",
	.Toggle_Rotation = "Showcase auto-rotate",
}

PALETTE_ACTION_KEYWORDS := [Palette_Action]string {
	.Next_Theme      = "palette color appearance dark light",
	.Toggle_Motion   = "animation accessibility",
	.Open_Scale      = "zoom dpi size",
	.Toggle_Debug    = "metrics fps stats",
	.Toggle_Rotation = "model planet 3d spin showcase",
}

PALETTE_SECTION_LABELS := [Section]string {
	.Showcase = "Go to Showcase",
	.Buttons  = "Go to Buttons",
	.Inputs   = "Go to Inputs",
	.Widgets  = "Go to Widgets",
	.Charts   = "Go to Charts",
	.Markdown = "Go to Markdown",
	.Layout   = "Go to Layout",
	.Overlay  = "Go to Overlay",
	.Stress   = "Go to Stress",
}

PALETTE_ITEM_COUNT :: len(Section) + len(Palette_Action)
#assert(PALETTE_ITEM_COUNT <= 256, "palette items exceed COMMAND_PALETTE_ITEM_MAX")

palette_items: [PALETTE_ITEM_COUNT]fit.Command_Palette_Item
palette_items_ready := false
command_palette_state: fit.Command_Palette_State
command_palette_modal: fit.Modal_State

palette_section_command :: proc(s: Section) -> fit.Command_Id {
	return fit.Command_Id(PALETTE_SECTION_BASE + u64(s))
}

palette_action_command :: proc(a: Palette_Action) -> fit.Command_Id {
	return fit.Command_Id(PALETTE_ACTION_BASE + u64(a))
}

palette_items_build :: proc() {
	if palette_items_ready do return
	index := 0
	for s in Section {
		palette_items[index] = {
			command     = palette_section_command(s),
			label       = PALETTE_SECTION_LABELS[s],
			description = SECTION_BLURBS[s],
			keywords    = SECTION_LAYERS[s],
		}
		index += 1
	}
	for a in Palette_Action {
		palette_items[index] = {
			command     = palette_action_command(a),
			label       = PALETTE_ACTION_LABELS[a],
			description = PALETTE_ACTION_NOTES[a],
			keywords    = PALETTE_ACTION_KEYWORDS[a],
		}
		index += 1
	}
	assert(index == PALETTE_ITEM_COUNT, "palette_items_build: table size drifted")
	palette_items_ready = true
}

// palette_shortcut_pressed reports Ctrl+K, or Cmd+K on macOS, this frame.
// Both are accepted everywhere so a browser on a Mac and a native Linux build
// each work with the key the user expects.
palette_shortcut_pressed :: proc(surface: ^fit.Surface) -> bool {
	assert(surface != nil, "palette_shortcut_pressed: nil surface")
	if !fit.key_pressed(surface, .K) do return false
	control :=
		fit.surface_key_down(surface, .Left_Control) ||
		fit.surface_key_down(surface, .Right_Control)
	super :=
		fit.surface_key_down(surface, .Left_Super) || fit.surface_key_down(surface, .Right_Super)
	return control || super
}

// palette_apply dispatches one activated command. Section commands reuse
// nav_select_section and actions reuse nav_control_activate, so the palette
// cannot drift from what the sidebar does.
palette_apply :: proc(surface: ^fit.Surface, command: fit.Command_Id) {
	assert(surface != nil, "palette_apply: nil surface")
	value := u64(command)
	if value >= PALETTE_SECTION_BASE && value < PALETTE_SECTION_BASE + u64(len(Section)) {
		nav_select_section(Section(value - PALETTE_SECTION_BASE))
		return
	}
	if value < PALETTE_ACTION_BASE || value >= PALETTE_ACTION_BASE + u64(len(Palette_Action)) {
		return
	}
	switch Palette_Action(value - PALETTE_ACTION_BASE) {
	case .Next_Theme:
		nav_control_activate(.Theme, surface)
	case .Toggle_Motion:
		nav_control_activate(.Motion, surface)
	case .Open_Scale:
		nav_control_activate(.Scale, surface)
	case .Toggle_Debug:
		debug_on = !debug_on
	case .Toggle_Rotation:
		showcase.auto_rotate = !showcase.auto_rotate
	}
	fit.request_redraw(surface)
}

// draw_gallery_palette handles the shortcut and draws the palette when open.
// It runs after the content and before the settings modal so the palette
// layers above the page and below a scale dialog it opened.
draw_gallery_palette :: proc(surface: ^fit.Surface) {
	assert(surface != nil, "draw_gallery_palette: nil surface")
	palette_items_build()
	if palette_shortcut_pressed(surface) {
		command_palette_open = !command_palette_open
		fit.request_redraw(surface)
	}
	result := fit.surface_command_palette(
		surface,
		&command_palette_state,
		&command_palette_modal,
		palette_items[:],
		&command_palette_open,
		{title = "Go to anything", placeholder = "Search sections and actions\u2026"},
	)
	if result.activated != {} do palette_apply(surface, result.activated)
}

palette_destroy :: proc() {
	fit.command_palette_state_destroy(&command_palette_state)
}
