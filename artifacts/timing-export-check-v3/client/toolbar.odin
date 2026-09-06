// toolbar.odin renders the in-game bottom toolbar. The left segment holds
// mode-switch tabs (Inspect/Build/Terraform); the right segment changes with
// the active mode: build lists every buildable kind with its cost, terraform
// offers Raise, Lower and Level tools, inspect offers Upgrade/Tune for the
// selected building. Buttons ride the ingot:fit Surface facade, mirroring the
// menu screen; toolbar_rect exists separately so game_frame can capture
// pointer input over the bar before any world systems run.
//
// Every constant below is authored at UI scale 1.0 and converted through
// ui_px at the point of use: on Windows fit's fonts and metrics grow with the
// monitor DPI while raw pixels do not (see ui_scale.odin).
package main

import shared "../shared"
import "core:fmt"
import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"

Terraform_Tool :: enum u8 {
	Raise,
	Lower,
	Level,
}

TOOLBAR_BUTTON_HEIGHT :: i32(44)
TOOLBAR_TAB_WIDTH :: i32(120)
TOOLBAR_OPTION_WIDTH :: i32(170)
// Terraform tool buttons are narrower than a build option: their labels are
// one short word, and the width they give up pays for the brush segment.
TOOLBAR_TOOL_WIDTH :: i32(96)
// One brush button. Square-ish, because it holds a span like "5x5" and a
// row of five wide buttons would push the bar off a 1280 window at 150%
// display scaling.
TOOLBAR_BRUSH_WIDTH :: i32(46)
TOOLBAR_GAP :: i32(8)
// Wider gap between the tab segment and the mode-dependent options.
TOOLBAR_SEGMENT_GAP :: i32(24)
TOOLBAR_PADDING :: i32(10)
// Distance from the bottom screen edge to the toolbar panel.
TOOLBAR_MARGIN :: i32(14)
// Floor for the terraform cost note / inspect hint slot. The real width comes
// from measuring the text (toolbar_note_width); this only keeps the segment
// from collapsing before the first measurement lands.
TOOLBAR_NOTE_MIN_WIDTH :: i32(150)

TOOLBAR_BUILDING_COUNT :: i32(len(shared.Building_Kind))
// Selectable brushes: 1x1, 3x3, 5x5, 7x7, 9x9.
TOOLBAR_BRUSH_COUNT :: i32(shared.TERRAFORM_RADIUS_MAX - shared.TERRAFORM_RADIUS_MIN + 1)

TOOLBAR_INSPECT_HINT :: "click a building to inspect"

MODE_TAB_LABELS :: [Mode]string {
	.Inspect   = "Inspect (Esc)",
	.Build     = "Build (1-4)",
	.Terraform = "Terraform (T)",
}

// toolbar_brush_label formats a brush span. Returned as a temp string so the
// measure pass and the draw pass produce byte-identical labels; a mismatch
// there is what makes a panel resize under the cursor.
toolbar_brush_label :: proc(radius: i32) -> string {
	assert(shared.terraform_radius_valid(radius), "toolbar_brush_label: radius out of range")
	span := shared.terraform_cell_span(radius)
	return fmt.tprintf("%dx%d", span, span)
}

// toolbar_brush_width is the pixel width of the whole brush segment.
@(private = "file")
toolbar_brush_width :: proc(value: ^Client_State) -> i32 {
	assert(value != nil, "toolbar_brush_width: nil state")
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	button := ui_px(value.ui_scale, TOOLBAR_BRUSH_WIDTH)
	return TOOLBAR_BRUSH_COUNT * button + (TOOLBAR_BRUSH_COUNT - 1) * gap
}

// toolbar_note_width_px is the measured note slot: last frame's text width
// plus a gap, never below the scaled floor.
@(private = "file")
toolbar_note_width_px :: proc(value: ^Client_State) -> i32 {
	assert(value != nil, "toolbar_note_width_px: nil state")
	measured := value.toolbar_note_width + ui_px(value.ui_scale, TOOLBAR_GAP)
	return max(measured, ui_px(value.ui_scale, TOOLBAR_NOTE_MIN_WIDTH))
}

// toolbar_options_width returns the pixel width of the mode-dependent
// segment, so the rect can be computed without drawing.
toolbar_options_width :: proc(value: ^Client_State) -> i32 {
	assert(value != nil, "toolbar_options_width: nil state")
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	option := ui_px(value.ui_scale, TOOLBAR_OPTION_WIDTH)
	tool := ui_px(value.ui_scale, TOOLBAR_TOOL_WIDTH)
	switch value.mode {
	case .Inspect:
		return toolbar_note_width_px(value)
	case .Build:
		return TOOLBAR_BUILDING_COUNT * option + (TOOLBAR_BUILDING_COUNT - 1) * gap
	case .Terraform:
		// Three tools, the brush segment, then the cost note. Every term is
		// counted here because toolbar_rect drives pointer capture: a
		// segment missing from this sum is a strip of the bar that clicks
		// straight through to the world.
		return 3 * tool + 2 * gap + toolbar_brush_width(value) + 2 * gap + toolbar_note_width_px(value)
	}
	return 0
}

// toolbar_inspect_target reports whether the inspect segment has a selected
// building to act on.
toolbar_inspect_target :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "toolbar_inspect_target: nil state")
	if value.selected == ecs.ENTITY_NIL do return false
	return ecs.has(&value.world.buildings, value.selected)
}

// toolbar_rect computes the full panel bounds, anchored bottom-center. Used
// both for drawing and for pointer capture before any world input runs. The
// Inspect tab is hidden while inspect mode is active, so the tab segment
// width follows the visible tab count. A scaled-up toolbar can be wider than
// a small window, so the panel is clamped to the viewport rather than
// hanging off both edges.
toolbar_rect :: proc(value: ^Client_State) -> fit.Rect {
	assert(value != nil, "toolbar_rect: nil state")
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	padding := ui_px(value.ui_scale, TOOLBAR_PADDING)
	tab_width := ui_px(value.ui_scale, TOOLBAR_TAB_WIDTH)
	tab_count := i32(2) if value.mode == .Inspect else i32(3)
	tabs_width := tab_count * tab_width + (tab_count - 1) * gap
	width :=
		padding * 2 +
		tabs_width +
		ui_px(value.ui_scale, TOOLBAR_SEGMENT_GAP) +
		toolbar_options_width(value)
	height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT) + padding * 2
	screen_width := rl.GetScreenWidth()
	width = min(width, max(screen_width, 0))
	x := max((screen_width - width) / 2, 0)
	y := rl.GetScreenHeight() - height - ui_px(value.ui_scale, TOOLBAR_MARGIN)
	return fit.Rect{x, y, width, height}
}

// toolbar_contains is the pointer-capture test for the panel bounds.
toolbar_contains :: proc(value: ^Client_State, point: rl.Vector2) -> bool {
	assert(value != nil, "toolbar_contains: nil state")
	rect := toolbar_rect(value)
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

// toolbar_note_text is the inspect segment's hint: the selected building's
// name, or a prompt when nothing is selected. Shared by the measure pass and
// the draw pass so the panel is always sized for the string it renders.
toolbar_note_text :: proc(value: ^Client_State) -> string {
	assert(value != nil, "toolbar_note_text: nil state")
	if toolbar_inspect_target(value) {
		if building, ok := ecs.get(&value.world.buildings, value.selected); ok {
			names := BUILDING_NAMES
			return fmt.tprintf("%s selected", names[building.kind])
		}
	}
	return TOOLBAR_INSPECT_HINT
}

// toolbar_terraform_note is the cost readout for the current brush. Shared
// by the measure pass and the draw pass so the panel is always sized for
// the string it renders.
toolbar_terraform_note :: proc(value: ^Client_State) -> string {
	assert(value != nil, "toolbar_terraform_note: nil state")
	return fmt.tprintf("%d ore / use", shared.terraform_cost_ore(value.terraform_radius))
}

// toolbar_measure_note records the width the note segment needs this frame.
// Every candidate string is measured, not just the active one, so the panel
// neither resizes when the selection changes under the cursor nor jumps when
// the player switches between inspect and terraform - and, since the brush
// changes the cost, every brush's cost string is measured too.
@(private = "file")
toolbar_measure_note :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "toolbar_measure_note: nil state")
	assert(surface != nil, "toolbar_measure_note: nil surface")
	width := fit.Text_Width(surface, TOOLBAR_INSPECT_HINT, .Note)
	width = max(width, fit.Text_Width(surface, toolbar_note_text(value), .Note))
	for radius in shared.TERRAFORM_RADIUS_MIN ..= shared.TERRAFORM_RADIUS_MAX {
		note := fmt.tprintf("%d ore / use", shared.terraform_cost_ore(radius))
		width = max(width, fit.Text_Width(surface, note, .Note))
	}
	value.toolbar_note_width = width
}

// toolbar_frame draws the panel, the mode tabs, and the mode-dependent
// option buttons, and applies their click handlers.
toolbar_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "toolbar_frame: nil state")
	assert(surface != nil, "toolbar_frame: nil surface")
	// Measured before toolbar_rect so the panel is sized for this frame's
	// text rather than the previous frame's.
	toolbar_measure_note(value, surface)
	rect := toolbar_rect(value)
	panel := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	ui_panel_draw(value, surface, panel, .Toolbar)
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	tab_width := ui_px(value.ui_scale, TOOLBAR_TAB_WIDTH)
	button_height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT)
	padding := ui_px(value.ui_scale, TOOLBAR_PADDING)
	x := rect.x + padding
	y := rect.y + padding
	labels := MODE_TAB_LABELS
	for mode in Mode {
		// The active-mode tab for Inspect is pointless (Inspect is the neutral
		// default), so it hides while inspect mode is active; toolbar_rect
		// shrinks the tab segment to match.
		if mode == .Inspect && value.mode == .Inspect do continue
		tab := fit.Rect{x, y, tab_width, button_height}
		style: fit.Button_Style = .Primary if value.mode == mode else .Secondary
		widget := fit.Widget_Id_From_U64(u64(mode) + 1)
		if fit.Surface_Button(surface, widget, labels[mode], tab, style) && value.mode != mode {
			if mode == .Build {
				build_mode_enter(value, value.selected_kind)
			} else {
				mode_set(value, mode)
			}
		}
		x += tab_width + gap
	}
	x += ui_px(value.ui_scale, TOOLBAR_SEGMENT_GAP) - gap
	// Right edge the option segment may not cross, so a note can never paint
	// onto the game canvas even if the measurement above is bypassed.
	limit := rect.x + rect.w - padding
	switch value.mode {
	case .Inspect:
		_toolbar_inspect(value, surface, x, y, limit)
	case .Build:
		_toolbar_build(value, surface, x, y)
	case .Terraform:
		_toolbar_terraform(value, surface, x, y, limit)
	}
}

// _toolbar_build lists one button per building kind: shortcut digit, name,
// and level-1 placement cost. Unaffordable kinds render in the Ghost style
// but stay clickable; the sim validates again on placement.
_toolbar_build :: proc(value: ^Client_State, surface: ^fit.Surface, start_x, y: i32) {
	assert(value != nil, "_toolbar_build: nil state")
	assert(surface != nil, "_toolbar_build: nil surface")
	names := BUILDING_NAMES
	ore, energy := stockpile_amounts(value)
	option_width := ui_px(value.ui_scale, TOOLBAR_OPTION_WIDTH)
	button_height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT)
	x := start_x
	for kind in shared.Building_Kind {
		cost := shared.building_cost(kind, 1)
		foot_w, foot_h := shared.building_footprint(kind)
		label: string
		if cost[.Energy] > 0 {
			label = fmt.tprintf(
				"%d %s %dx%d  %do %de",
				int(kind) + 1,
				names[kind],
				foot_w,
				foot_h,
				cost[.Ore],
				cost[.Energy],
			)
		} else {
			label = fmt.tprintf(
				"%d %s %dx%d  %do",
				int(kind) + 1,
				names[kind],
				foot_w,
				foot_h,
				cost[.Ore],
			)
		}
		affordable := cost[.Ore] <= ore && cost[.Energy] <= energy
		style: fit.Button_Style = .Ghost
		if affordable do style = .Secondary
		if value.selected_kind == kind do style = .Primary
		button := fit.Rect{x, y, option_width, button_height}
		if fit.Surface_Button(surface, fit.Widget_Id_From_U64(100 + u64(kind)), label, button, style) {
			build_mode_enter(value, kind)
		}
		x += option_width + ui_px(value.ui_scale, TOOLBAR_GAP)
	}
}

// _toolbar_terraform offers three mutually exclusive operations, the brush
// size selector, and the cost of one apply at the selected brush.
_toolbar_terraform :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	start_x, y, limit: i32,
) {
	assert(value != nil, "_toolbar_terraform: nil state")
	assert(surface != nil, "_toolbar_terraform: nil surface")
	tool_width := ui_px(value.ui_scale, TOOLBAR_TOOL_WIDTH)
	button_height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT)
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	x := start_x
	raise := fit.Rect{x, y, tool_width, button_height}
	raise_style: fit.Button_Style = .Primary if value.terraform_tool == .Raise else .Secondary
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(200),
		"Raise (R)",
		raise,
		raise_style,
	) {
		value.terraform_tool = .Raise
	}
	x += tool_width + gap
	lower := fit.Rect{x, y, tool_width, button_height}
	lower_style: fit.Button_Style = .Primary if value.terraform_tool == .Lower else .Secondary
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(201),
		"Lower (F)",
		lower,
		lower_style,
	) {
		value.terraform_tool = .Lower
	}
	x += tool_width + gap
	level := fit.Rect{x, y, tool_width, button_height}
	level_style: fit.Button_Style = .Primary if value.terraform_tool == .Level else .Secondary
	if fit.Surface_Button(surface, fit.Widget_Id_From_U64(202), "Level (L)", level, level_style) {
		value.terraform_tool = .Level
	}
	x += tool_width + 2 * gap
	x = _toolbar_brush(value, surface, x, y)
	x += gap
	// The cost is drawn in the danger ink when the player cannot pay, so a
	// refused click is visible on the bar as well as on the ground.
	ink: fit.Ink = .Tool
	if !terraform_affordable(value) do ink = .Danger
	_toolbar_note_draw(surface, toolbar_terraform_note(value), x, y, limit, button_height, ink)
}

// _toolbar_brush draws the five brush-size buttons and returns the x the
// next segment starts at. Sizes are odd spans only: the mound is anchored
// on a heightfield vertex, so an even brush has no centre to fall away from.
@(private = "file")
_toolbar_brush :: proc(value: ^Client_State, surface: ^fit.Surface, start_x, y: i32) -> i32 {
	assert(value != nil, "_toolbar_brush: nil state")
	assert(surface != nil, "_toolbar_brush: nil surface")
	button_width := ui_px(value.ui_scale, TOOLBAR_BRUSH_WIDTH)
	button_height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT)
	gap := ui_px(value.ui_scale, TOOLBAR_GAP)
	x := start_x
	for radius in shared.TERRAFORM_RADIUS_MIN ..= shared.TERRAFORM_RADIUS_MAX {
		style: fit.Button_Style = .Secondary
		if radius == value.terraform_radius do style = .Primary
		button := fit.Rect{x, y, button_width, button_height}
		if fit.Surface_Button(
			surface,
			fit.Widget_Id_From_U64(300 + u64(radius)),
			toolbar_brush_label(radius),
			button,
			style,
		) {
			terraform_brush_set(value, radius)
		}
		x += button_width + gap
	}
	// The trailing gap belongs to the caller's spacing, not to this segment.
	return x - gap
}

// _toolbar_inspect shows a hint note: the selected building's name (its
// options live in the inspect panel above), or a prompt when nothing is
// selected.
_toolbar_inspect :: proc(value: ^Client_State, surface: ^fit.Surface, start_x, y, limit: i32) {
	assert(value != nil, "_toolbar_inspect: nil state")
	assert(surface != nil, "_toolbar_inspect: nil surface")
	button_height := ui_px(value.ui_scale, TOOLBAR_BUTTON_HEIGHT)
	_toolbar_note_draw(
		surface,
		toolbar_note_text(value),
		start_x,
		y,
		limit,
		button_height,
		.Secondary,
	)
}

// _toolbar_note_draw centers a note in the button row and clips it to the
// panel. fit.Text would happily paint past the panel edge onto the game
// canvas; fit.Text_Truncated ellipsises instead, matching how the buttons
// already handle an over-long label.
@(private = "file")
_toolbar_note_draw :: proc(
	surface: ^fit.Surface,
	note: string,
	x, y, limit, button_height: i32,
	ink: fit.Ink,
) {
	assert(surface != nil, "_toolbar_note_draw: nil surface")
	note_y := y + (button_height - fit.Text_Size(surface, .Note)) / 2
	fit.Text_Truncated(surface, note, x, note_y, max(limit - x, 0), .Note, ink)
}
