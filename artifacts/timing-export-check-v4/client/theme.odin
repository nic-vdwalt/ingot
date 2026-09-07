// theme.odin is the single source of colour for this client.
//
// Every screen-space surface resolves its paint from one of two places: the
// fit palette published here through terra_theme (which fit's own widgets -
// buttons, caption buttons, focus rings - read automatically), or the UI_*
// constants below for the handful of things fit has no role for (the 3D
// world markers, the procedural cursor, the scanline wash).
//
// The palette is a phosphor-green CRT: a near-black glass ground, phosphor
// green as the primary information channel, amber strictly for cost and
// warning, and red-orange for refusal. Nothing else is allowed a colour.
//
// Two hard constraints shape the values:
//
//   - ui_runtime_set_theme asserts WCAG AA at runtime (ingot/ui/theme.odin):
//     fg_primary on bg_color and button_text on button_bg must both clear
//     4.5:1. A palette that misses either panics the game on load rather
//     than looking slightly wrong, so theme_test.odin pins both.
//   - fit exposes no font-registration API, so the retro read has to come
//     from palette, near-square chrome, corner ticks, scanlines and copy.
//     There is no bitmap font to load.
//
// The theme is authored here, in the reloadable library, and pulled by the
// host through the game_theme export. The host is not hot-reloadable, so a
// palette authored there would cost a host restart per colour tweak.
package main

import shared "../shared"
import fit "ingot:fit"
import rl "ingot:gfx"
import uilib "ingot:ui"

// Phosphor channel. fg_accent is the bright end of the same hue as
// fg_primary rather than a second colour: a CRT has one phosphor.
TERRA_PHOSPHOR :: fit.Color{176, 255, 206, 255}
TERRA_PHOSPHOR_BRIGHT :: fit.Color{120, 255, 170, 255}
TERRA_PHOSPHOR_DIM :: fit.Color{112, 190, 146, 255}
TERRA_PHOSPHOR_FAINT :: fit.Color{88, 150, 116, 255}
// Amber is reserved for cost and warning; using it for anything else
// destroys the one signal the palette carries beyond "on".
TERRA_AMBER :: fit.Color{255, 190, 90, 255}
TERRA_DANGER :: fit.Color{255, 106, 84, 255}
// CRT glass. bg_glass is the deepest ground; panels sit a step above it.
TERRA_GLASS :: fit.Color{6, 10, 8, 255}

// terra_theme is the published palette. Derived from the dark theme so any
// role fit adds later inherits a sane value instead of a transparent one,
// then overridden field by field.
terra_theme :: proc() -> fit.Theme {
	theme := fit.Theme_Dark()
	style := &theme.inner

	// Glass surfaces. The windowed/fullscreen pairs must be set together:
	// ui_runtime_set_theme copies the windowed variants over the active
	// ones, and set_glass_fullscreen asserts the fullscreen ones are set.
	panel := fit.Color{9, 15, 12, 236}
	popup := fit.Color{7, 12, 10, 244}
	style.bg_app_windowed = ui_color(TERRA_GLASS)
	style.bg_chat_windowed = ui_color(panel)
	style.bg_panel_windowed = ui_color(panel)
	style.bg_app_fullscreen = ui_color(TERRA_GLASS)
	style.bg_chat_fullscreen = ui_color(fit.Color{9, 15, 12, 252})
	style.bg_panel_fullscreen = ui_color(fit.Color{9, 15, 12, 252})
	style.bg_app = style.bg_app_windowed
	style.bg_chat = style.bg_chat_windowed
	style.bg_panel = style.bg_panel_windowed

	style.bg_color = ui_color(TERRA_GLASS)
	style.bg_secondary = ui_color({13, 22, 18, 255})
	style.bg_active = ui_color({18, 44, 32, 255})
	style.bg_hover = ui_color({16, 34, 26, 255})
	style.bg_input = ui_color({5, 9, 8, 255})
	style.bg_code = ui_color({8, 14, 11, 255})
	style.bg_popup = ui_color(popup)
	style.bg_selection = ui_color({22, 62, 42, 255})
	style.bg_table_header = ui_color({12, 24, 18, 255})
	style.bg_tool_card = ui_color({11, 19, 15, 255})
	style.bg_tool_card_hover = ui_color({16, 30, 23, 255})
	style.bg_chip = ui_color({14, 28, 21, 255})
	style.bg_chip_hover = ui_color({20, 40, 30, 255})
	style.bg_user_card = ui_color({12, 24, 18, 255})
	style.bg_band_error = ui_color({42, 16, 12, 255})
	style.bg_plan_bar = ui_color({34, 26, 8, 255})
	style.bg_plan_title = ui_color({28, 22, 8, 255})
	style.bg_debug_title = ui_color({12, 24, 18, 255})
	style.bg_diff_add = ui_color({10, 32, 20, 255})
	style.bg_diff_remove = ui_color({42, 16, 12, 255})

	style.fg_primary = ui_color(TERRA_PHOSPHOR)
	style.fg_heading = ui_color({214, 255, 228, 255})
	style.fg_secondary = ui_color(TERRA_PHOSPHOR_DIM)
	style.fg_accent = ui_color(TERRA_PHOSPHOR_BRIGHT)
	style.fg_accent_light = ui_color({164, 255, 200, 255})
	style.fg_label = ui_color(TERRA_PHOSPHOR_FAINT)
	style.fg_muted_dim = ui_color(TERRA_PHOSPHOR_FAINT)
	style.fg_disabled = ui_color({52, 88, 70, 255})
	style.fg_user = ui_color(TERRA_PHOSPHOR)
	style.fg_assistant = ui_color(TERRA_PHOSPHOR_DIM)
	style.fg_bold = ui_color({214, 255, 228, 255})
	style.fg_bullet = ui_color(TERRA_PHOSPHOR_BRIGHT)
	style.fg_code_inline = ui_color(TERRA_AMBER)
	// Amber: cost, warning, and anything the player is being asked to
	// weigh. fg_tool and fg_plan are the two roles widgets reach for.
	style.fg_tool = ui_color(TERRA_AMBER)
	style.fg_plan = ui_color(TERRA_AMBER)
	style.fg_planning = ui_color(TERRA_AMBER)
	style.fg_debug_changed = ui_color(TERRA_AMBER)
	style.fg_debug = ui_color({164, 255, 200, 255})
	style.fg_debug_annotation = ui_color(TERRA_PHOSPHOR_DIM)
	style.fg_error = ui_color(TERRA_DANGER)
	style.fg_success = ui_color(TERRA_PHOSPHOR_BRIGHT)
	style.fg_diff_add = ui_color(TERRA_PHOSPHOR_BRIGHT)
	style.fg_diff_remove = ui_color(TERRA_DANGER)
	style.fg_diff_gutter = ui_color(TERRA_PHOSPHOR_FAINT)
	style.ink_faded = ui_color(TERRA_PHOSPHOR_FAINT)
	style.spell_error = ui_color(TERRA_DANGER)

	style.border_color = ui_color({46, 120, 86, 255})
	style.border_subtle = ui_color({26, 66, 48, 255})
	style.border_user_card = ui_color({26, 66, 48, 255})
	style.badge_color = ui_color(TERRA_AMBER)
	style.merge_link_color = ui_color({46, 120, 86, 255})

	// button_text is near-black on a mid phosphor fill: this is the pair
	// ui_runtime_set_theme checks second, and light-on-light would fail it.
	style.button_bg = ui_color({36, 150, 96, 255})
	style.button_hover = ui_color({52, 186, 122, 255})
	style.button_text = ui_color({4, 12, 8, 255})
	style.button_pressed = ui_color({96, 230, 152, 255})
	style.button_disabled_bg = ui_color({12, 22, 17, 255})
	style.button_danger_bg = ui_color({58, 20, 15, 255})
	style.button_danger_hover = ui_color({82, 28, 20, 255})
	style.button_danger_fg = ui_color({255, 158, 140, 255})
	style.surface_pressed = ui_color({30, 74, 54, 255})

	style.fg_on_accent = ui_color({4, 12, 8, 255})
	style.focus_ring = ui_color({120, 255, 170, 230})
	style.modal_dim = ui_color({2, 6, 4, 220})
	style.shadow_color = ui_color({0, 0, 0, 150})
	// A phosphor sheen across the top of a filled button reads as the
	// curved glass of a tube rather than as a gloss gradient.
	style.button_primary_grad_top = ui_color({176, 255, 206, 26})
	style.button_primary_grad_bottom = ui_color({0, 0, 0, 0})

	style.caption_hover = ui_color({18, 44, 32, 255})
	style.caption_pressed = ui_color({30, 74, 54, 255})
	style.caption_close_hover = ui_color({168, 46, 34, 255})
	style.caption_close_pressed = ui_color({210, 62, 46, 255})

	style.drop_zone_bg = ui_color({12, 30, 22, 235})
	style.drop_zone_border = ui_color(TERRA_PHOSPHOR_BRIGHT)
	style.wave_color_a = ui_color({26, 78, 54, 255})
	style.wave_color_b = ui_color(TERRA_PHOSPHOR_BRIGHT)

	// A faint grid behind panels: laboratory graph paper, not notebook
	// rules. margin_rule off - there is no text column to align to.
	style.substrate = {
		kind        = .Grid,
		margin_rule = false,
	}
	return theme
}

// ui_color converts a fit.Color literal to the ui.Color the inner theme
// stores. Both are distinct [4]u8, so this is a cast with a name rather
// than a conversion; the name is what keeps the palette above readable as a
// list of colours instead of a list of casts. fit publishes no field-level
// theme setter, so reaching through fit.Theme.inner is the supported way to
// author a palette.
@(private = "file")
ui_color :: proc(value: fit.Color) -> uilib.Color {
	return uilib.Color(value)
}

// Colours fit has no palette role for: the 3D world markers, the procedural
// cursor, and the scanline wash. These are rl.Color because they are handed
// to the 3D renderer and to raylib's immediate-mode draw calls.

// Scanline wash over a panel. Deliberately black rather than a dark green:
// a CRT scanline is the *absence* of phosphor, and a tinted line reads as a
// pattern painted onto the panel instead of as the panel's own structure.
UI_SCANLINE :: rl.Color{0, 0, 0, 46}
// Phosphor bloom used for corner ticks and hairline emphasis.
UI_GLOW :: rl.Color{120, 255, 170, 255}
UI_AMBER :: rl.Color{255, 190, 90, 255}
UI_DANGER :: rl.Color{255, 106, 84, 255}
UI_RAIN :: rl.Color{166, 205, 232, 150}
UI_DEBUG_SCAN :: rl.Color{120, 255, 170, 150}
UI_DEBUG_SCAN_TRAIL :: rl.Color{120, 255, 170, 36}
UI_DEBUG_CHROME :: rl.Color{120, 255, 170, 150}
UI_DEBUG_SCOPE :: rl.Color{255, 190, 90, 150}
UI_DEBUG_MARKER_SHADOW :: rl.Color{3, 8, 6, 245}
UI_DEBUG_AXIS_X :: rl.Color{255, 106, 84, 255}
UI_DEBUG_AXIS_Y :: rl.Color{120, 255, 170, 255}
UI_DEBUG_AXIS_Z :: rl.Color{140, 220, 255, 255}
UI_LITHOSPHERE_OCEANIC :: rl.Color{45, 112, 190, 255}
UI_LITHOSPHERE_CONTINENTAL :: rl.Color{236, 220, 142, 255}
UI_LITHOSPHERE_SUBDUCTION :: rl.Color{142, 78, 188, 255}
UI_LITHOSPHERE_COLLISION :: rl.Color{224, 72, 54, 255}
UI_LITHOSPHERE_RIDGE :: rl.Color{58, 216, 210, 255}
UI_LITHOSPHERE_TRANSFORM :: rl.Color{232, 174, 52, 255}
UI_LITHOSPHERE_BOUNDARY :: rl.Color{38, 42, 48, 255}
UI_CUTAWAY_OCEAN :: rl.Color{40, 142, 220, 255}
UI_CUTAWAY_CRUST :: rl.Color{218, 196, 126, 255}
UI_CUTAWAY_MANTLE :: rl.Color{190, 78, 42, 255}
UI_CUTAWAY_OUTER_CORE :: rl.Color{244, 142, 48, 255}
UI_CUTAWAY_INNER_CORE :: rl.Color{255, 226, 142, 255}
UI_CUTAWAY_BOUNDARY :: rl.Color{18, 14, 12, 255}
UI_SELECTED_GRID :: rl.Color{120, 255, 170, 180}
UI_SELECTED_GRID_DIM :: rl.Color{104, 150, 126, 110}

// Terraform feedback. Raise pulls phosphor out of the ground, drop pushes
// it back in (amber), level is the neutral survey colour. The cursor and
// the 3D highlight mesh share these so the pointer and the footprint can
// never disagree about what the brush is about to do.
UI_TERRAFORM_RAISE :: rl.Color{120, 255, 170, 255}
UI_TERRAFORM_LOWER :: rl.Color{255, 190, 90, 255}
UI_TERRAFORM_LEVEL :: rl.Color{140, 220, 255, 255}
UI_TERRAFORM_NEUTRAL :: rl.Color{206, 240, 220, 255}

UI_CURSOR_VALID :: rl.Color{176, 255, 206, 255}
UI_CURSOR_INVALID :: rl.Color{255, 106, 84, 255}
UI_CURSOR_NEUTRAL :: rl.Color{104, 150, 126, 255}
UI_CURSOR_SHADOW :: rl.Color{2, 8, 5, 200}
UI_CURSOR_OUTLINE :: rl.Color{4, 14, 9, 255}

// Placement grid. Same two colours the cursor uses for validity, so a
// refused tile and a refused pointer are one signal, not two.
UI_PLACE_VALID :: rl.Color{120, 255, 170, 255}
UI_PLACE_INVALID :: rl.Color{255, 106, 84, 255}

// Terminal caret. Half-alpha phosphor: a block caret at full opacity hides
// the glyph underneath it, which is exactly the character being edited.
UI_CARET :: rl.Color{176, 255, 206, 130}

// Scrim behind a modal. Translucent rather than opaque so the world stays
// visible as context; fit's own modal_dim role is not exposed through
// Theme_Tokens, so the one client modal carries its own value.
UI_MODAL_DIM :: rl.Color{2, 6, 4, 220}

// Console ground and default text channel. The console is the one surface
// where a terminal's own colours can appear, so a cell that carries none
// has to land on the same phosphor as the rest of the UI rather than on a
// generic light grey. These are rl.Color because console_cell_colors
// compares them against libvterm's converted RGB.
UI_CONSOLE_GROUND :: rl.Color{7, 12, 10, 244}
UI_CONSOLE_TEXT :: rl.Color{176, 255, 206, 255}

// Selection outline: the brightest phosphor in the palette, which is what
// makes it read as "this one" against a world of muted terrain.
UI_SELECTED_OUTLINE :: rl.Color{160, 255, 210, 255}
// Hovered-but-unselected outline: the same hue, two steps down.
UI_HOVER_OUTLINE :: rl.Color{120, 190, 156, 255}

// Building accents. Held to the palette's four channels - phosphor, amber,
// danger, and a cool survey blue - rather than four arbitrary hues, so a
// base full of buildings still reads as one instrument panel.
BUILDING_COLORS := [shared.Building_Kind]rl.Color {
	.Headquarters = {160, 255, 210, 255},
	.Mine         = {255, 190, 90, 255},
	.Solar_Array  = {255, 226, 138, 255},
	.Habitat      = {140, 220, 255, 255},
}

// Panel chrome.
//
// Panel_Kind selects a chrome recipe, not just a colour: a toolbar, a
// hover card and a modal want different corner radii and border weights,
// and letting each call site choose is how five panels ended up with four
// different radii before this existed.
Panel_Kind :: enum u8 {
	Toolbar,
	Card,
	Popup,
	Modal,
}

// Near-square corners. The previous 0.18 ratio produced a visibly rounded
// consumer-app card; instrument panels are cut, not moulded.
UI_PANEL_ROUNDNESS :: f32(0.03)
UI_PANEL_SEGMENTS :: i32(4)
// Corner tick length at UI scale 1.0.
UI_TICK_LENGTH :: i32(10)
// Scanline pitch at UI scale 1.0. Three device pixels is the finest pitch
// that still reads as lines rather than as a flat darkening.
UI_SCANLINE_PITCH :: i32(3)
// Hard ceiling on rules per panel. fit.Draw_Rules asserts against
// SUBSTRATE_RULES_MAX (256) internally; staying well under it here means a
// tall panel on a 4K display widens its pitch instead of tripping an
// assertion the player would experience as a crash.
UI_SCANLINE_MAX :: i32(200)

// ui_panel_draw is the one entry point for a themed panel: shadow, fill,
// hairline border, scanlines, corner ticks, in that order. A border drawn
// before its fill would be half-covered by it.
ui_panel_draw :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	rect: fit.Float_Rect,
	kind: Panel_Kind,
) {
	assert(value != nil, "ui_panel_draw: nil state")
	assert(surface != nil, "ui_panel_draw: nil surface")
	if rect.width <= 0 || rect.height <= 0 do return
	tokens := fit.Get_Theme_Tokens(surface)
	fill := tokens.background_panel
	border := tokens.border
	elevation: fit.Elevation = .Lifted
	switch kind {
	case .Toolbar:
		elevation = .Lifted
	case .Card:
		fill = tokens.background_tool_card
		border = tokens.border_subtle
		elevation = .Lifted
	case .Popup:
		fill = tokens.background_popup
		elevation = .Overlay
	case .Modal:
		fill = tokens.background_popup
		elevation = .Modal
	}
	fit.Draw_Shadow(surface, rect, .SM, elevation)
	fit.Fill_Rounded_Rect(surface, rect, UI_PANEL_ROUNDNESS, UI_PANEL_SEGMENTS, fill)
	ui_scanlines(value, surface, rect)
	fit.Stroke_Rounded_Rect(surface, rect, UI_PANEL_ROUNDNESS, UI_PANEL_SEGMENTS, 1, border)
	ui_corner_ticks(value, surface, rect, ui_px(value.ui_scale, UI_TICK_LENGTH))
}

// ui_scanlines washes a panel with horizontal rules.
//
// The pitch widens on tall panels rather than the count being clamped: a
// half-drawn scanline field is invisible in a screenshot and only appears
// on displays larger than the author's, which is exactly the failure mode
// fit.Draw_Rules' own assertion exists to prevent.
ui_scanlines :: proc(value: ^Client_State, surface: ^fit.Surface, rect: fit.Float_Rect) {
	assert(value != nil, "ui_scanlines: nil state")
	assert(surface != nil, "ui_scanlines: nil surface")
	if rect.height <= 0 do return
	pitch := max(ui_px(value.ui_scale, UI_SCANLINE_PITCH), 1)
	minimum := i32(rect.height) / UI_SCANLINE_MAX + 1
	pitch = max(pitch, minimum)
	assert(i32(rect.height) / pitch <= UI_SCANLINE_MAX, "ui_scanlines: pitch too fine")
	fit.Draw_Rules(surface, rect, pitch, fit.Color(UI_SCANLINE))
}

// ui_corner_ticks draws four L-brackets inset at the panel's corners. This
// is the cheapest mark that reads as instrument housing rather than as a
// rounded card, and it costs eight lines regardless of panel size.
ui_corner_ticks :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	rect: fit.Float_Rect,
	length: i32,
) {
	assert(value != nil, "ui_corner_ticks: nil state")
	assert(surface != nil, "ui_corner_ticks: nil surface")
	assert(length >= 0, "ui_corner_ticks: negative tick length")
	reach := f32(length)
	if reach <= 0 do return
	// A tick longer than half the panel would meet its opposite number and
	// read as a full border, which is not the mark being made.
	reach = min(reach, min(rect.width, rect.height) / 2)
	inset := f32(max(ui_px(value.ui_scale, 3), 1))
	thickness := f32(1)
	color := fit.Color(UI_GLOW)
	left := rect.x + inset
	top := rect.y + inset
	right := rect.x + rect.width - inset
	bottom := rect.y + rect.height - inset
	fit.Line(surface, {left, top}, {left + reach, top}, thickness, color)
	fit.Line(surface, {left, top}, {left, top + reach}, thickness, color)
	fit.Line(surface, {right - reach, top}, {right, top}, thickness, color)
	fit.Line(surface, {right, top}, {right, top + reach}, thickness, color)
	fit.Line(surface, {left, bottom}, {left + reach, bottom}, thickness, color)
	fit.Line(surface, {left, bottom - reach}, {left, bottom}, thickness, color)
	fit.Line(surface, {right - reach, bottom}, {right, bottom}, thickness, color)
	fit.Line(surface, {right, bottom - reach}, {right, bottom}, thickness, color)
}

// ui_readout draws one instrument row: a dim uppercase label followed by a
// bright value. The split is what makes a HUD line scannable - the eye
// finds the value because the label is deliberately quieter, not because
// the value is bigger.
ui_readout :: proc(
	surface: ^fit.Surface,
	label: string,
	value: string,
	x, y: i32,
	ink: fit.Ink = .Primary,
) -> i32 {
	assert(surface != nil, "ui_readout: nil surface")
	fit.Text(surface, label, x, y, .Note, .Label)
	cursor := x + fit.Text_Width(surface, label, .Note)
	fit.Text(surface, value, cursor, y, .Note, ink)
	return cursor + fit.Text_Width(surface, value, .Note)
}
