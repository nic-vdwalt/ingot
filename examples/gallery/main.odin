// ingot widget gallery - the imgui_demo.cpp equivalent: living documentation,
// copy-paste cookbook, and regression/stress surface for every ui widget.
// Frames are event-driven (EnableEventWaiting). Build & run:
//
//	odin run examples/gallery -collection:ingot=.
//
// Keys: F12 toggles the metrics/debug overlay (renderer counters need
// -define:INGOT_RENDER_STATS=true). Tab cycles keyboard focus in the
// Buttons section.
//
// Conventions this gallery demonstrates (docs/api-layers.md):
//   - fit.App owns the ordinary one-window lifecycle and supplies fit.Builder.
//   - The gallery shell is a bounded fit.canvas because this catalogue
//     deliberately demonstrates controls and explicit geometry not yet exposed
//     as native Builder leaves.
//   - Explicit UI stays inside named islands where geometry or lifecycle is
//     behavior: panes, charts, layout, overlays, listboxes, and the stress grid.
//   - ingot:gfx is absent from this application UI; capture.odin alone uses it
//     for the render-target and PNG capabilities missing from UI paint.
//   - Facade dimensions are logical and scale once; anything handed to a *_at
//     entry point is already physical, so it goes through frame_sc first.
package main

import "core:fmt"
import "core:slice"
import fit "ingot:fit"
import gfx "ingot:gfx"
import "ingot:sys"

// SMOKE enables the self-driving crash harness in smoke.odin (native only;
// see scripts/smoke-gallery.sh).
SMOKE :: #config(INGOT_SMOKE, false)

// CAPTURE enables the media harness in capture.odin (native only; see
// scripts/capture-media.sh). The flag is declared here rather than in
// capture.odin because main.odin guards on it and is built for every target,
// including js, where capture.odin is excluded.
CAPTURE :: #config(INGOT_CAPTURE, false)

Section :: enum {
	Buttons,
	Inputs,
	Widgets,
	Charts,
	Markdown,
	Layout,
	Overlay,
	Stress,
	Theme,
}

SECTION_NAMES := [Section]string {
	.Buttons  = "Buttons",
	.Inputs   = "Inputs",
	.Widgets  = "Widgets",
	.Charts   = "Charts",
	.Markdown = "Markdown",
	.Layout   = "Layout",
	.Overlay  = "Overlay",
	.Stress   = "Stress",
	.Theme    = "Theme",
}

SECTION_LAYERS := [Section]string {
	.Buttons  = "FACADE LEAVES",
	.Inputs   = "FACADE LEAVES",
	.Widgets  = "FACADE + COMPOSITION",
	.Charts   = "FACADE WRAPPER \u2192 EXPLICIT LEAF",
	.Markdown = "EXPLICIT COMPOSITION",
	.Layout   = "APPLICATION-OWNED GEOMETRY",
	.Overlay  = "EXPLICIT LIFECYCLE",
	.Stress   = "APPLICATION-OWNED GEOMETRY",
	.Theme    = "APPLICATION-OWNED GEOMETRY",
}

SECTION_AXES := [Section]string {
	.Buttons  = "framework owns geometry",
	.Inputs   = "framework owns geometry",
	.Widgets  = "geometry and lifecycle owner",
	.Charts   = "delegation",
	.Markdown = "measurement lifecycle",
	.Layout   = "application owns geometry",
	.Overlay  = "application owns lifecycle",
	.Stress   = "application owns geometry",
	.Theme    = "palette and token resolution",
}

NAV_W :: 170

// Below this logical width the sidebar is not affordable: a portrait phone is
// about 390 CSS px, and 170 of those (44%) would leave 168 px of content once
// the pane padding is taken. The nav becomes a horizontal strip instead.
NARROW_WIDTH_MAX :: 640
// Strip geometry. The row height is a comfortable touch target rather than a
// desktop button height; the cell width fits the longest section name.
NAV_STRIP_ROW_H :: 34
NAV_STRIP_CELL_W :: 92
NAV_SIDEBAR_ROW_H :: 28
// The strip may take at most 1/NAV_STRIP_HEIGHT_SHARE_DEN of the height under
// the header. At 200% on a 390px phone the full grid is one column of nine
// 68px rows, taller than the whole canvas, which left the content pane with a
// negative height and trapped the wasm module on pane_begin's assertion.
NAV_STRIP_HEIGHT_SHARE_DEN :: 2
// Widget ids for the compact strip's previous / current / next buttons. They
// sit above the full grid's 0x2000 + Section range so the two cannot collide.
NAV_STRIP_COMPACT_ID_BASE :: 0x2100

// --- caller-owned state (the whole point: no hidden library state) ----------

// Palette is a single cycle over every appearance the gallery offers,
// including high contrast.
//
// It started as `dark: bool`, then grew a `high_contrast: bool` beside it.
// Two booleans span eight combinations, but only five were reachable:
// selecting high contrast had to force-clear the palette, because "high
// contrast *and* sketch warm" is not a thing - applying the high-contrast
// palette discards the other choice entirely. The flags were modelling one
// decision as two, and the force-clear was the workaround for that.
//
// One enum makes the exclusivity structural rather than enforced. Ordered so
// the button walks the branded palettes, then screen themes, then the
// accessibility palette last: a progression rather than a jumble.
Palette :: enum {
	Ingot,
	Ingot_Dark,
	Terra,
	Pixel,
	Dark,
	Light,
	Retro_Orange,
	Retro_Orange_Dark,
	Custom_Blue,
	High_Contrast,
}

PALETTE_NAMES := [Palette]string {
	.Ingot             = "Ingot",
	.Ingot_Dark        = "Ingot dark",
	.Terra             = "Terra",
	.Pixel             = "Pixel",
	.Dark              = "Dark",
	.Light             = "Light",
	.Retro_Orange      = "Retro orange",
	.Retro_Orange_Dark = "Retro orange dark",
	.Custom_Blue       = "Custom blue",
	.High_Contrast     = "High contrast",
}

palette := Palette.Ingot
reduced_motion := false
initial_theme_pending := false
section := Section.Buttons
debug_on := false
gallery_root: fit.Rect

// palette_next advances the cycle, wrapping at the end.
//
// Pure and total: every palette has a successor, so the button can never land
// on a state the enum does not name. The label reads `palette` directly rather
// than calling this, so the sidebar reports what is switched on rather than
// what pressing it would do - see nav_control_label.
palette_next :: proc(current: Palette) -> Palette {
	return Palette((int(current) + 1) % len(Palette))
}

custom_blue_theme :: proc() -> fit.Theme {
	return fit.theme_from_palette(
		{
			basis = .Dark,
			ground = {18, 20, 24, 255},
			surface = {28, 31, 36, 255},
			surface_raised = {38, 42, 48, 255},
			control = {48, 53, 61, 255},
			control_hover = {62, 69, 79, 255},
			control_pressed = {78, 87, 99, 255},
			foreground = {238, 241, 244, 255},
			foreground_muted = {174, 182, 190, 255},
			accent = {126, 200, 255, 255},
			foreground_on_accent = {17, 19, 24, 255},
			danger = {255, 145, 145, 255},
			foreground_on_danger = {17, 19, 24, 255},
			success = {142, 226, 166, 255},
			border = {104, 115, 126, 255},
			focus = {126, 200, 255, 230},
		},
	)
}

// palette_theme resolves a palette to its Theme value.
palette_theme :: proc(value: Palette) -> fit.Theme {
	switch value {
	case .Ingot:
		return fit.theme_retro_ingot()
	case .Ingot_Dark:
		return fit.theme_retro_ingot_dark()
	case .Terra:
		return fit.theme_terra()
	case .Pixel:
		return fit.theme_pixel()
	case .Dark:
		return fit.theme_dark()
	case .Light:
		return fit.theme_light()
	case .Retro_Orange:
		return fit.theme_retro_orange()
	case .Retro_Orange_Dark:
		return fit.theme_retro_orange_dark()
	case .Custom_Blue:
		return custom_blue_theme()
	case .High_Contrast:
		return fit.theme_high_contrast()
	}
	return fit.theme_retro_ingot()
}

content_pane: fit.Pane_State
buttons_region: fit.Region
click_count := 0
headers_open := [3]bool{true, false, false}
header_motion: [3]fit.Control_Motion_State
button_motion: [4]fit.Control_Motion_State

Input_State :: struct {
	name:           fit.Input_Box,
	pass:           fit.Input_Box,
	notes:          fit.Input_Box,
	combo:          fit.Combobox_State,
	combo_selected: u64,
	date:           fit.Date_Picker_State,
	date_value:     fit.Calendar_Date,
}

input_state: Input_State
input_region: fit.Region

progress_anim: f32
progress_frac: f32 = 0.35

line_state: fit.Chart_State
bar_state: fit.Chart_State
revenue := [12]f32{12.4, 14.1, 13.2, 16.8, 18.9, 17.4, 21.0, 22.6, 20.1, 24.3, 26.8, 25.2}
costs := [12]f32{8.1, 8.4, 9.0, 9.7, 10.2, 11.5, 11.1, 12.4, 12.0, 13.6, 13.1, 14.0}
MONTHS := [12]string {
	"Jan",
	"Feb",
	"Mar",
	"Apr",
	"May",
	"Jun",
	"Jul",
	"Aug",
	"Sep",
	"Oct",
	"Nov",
	"Dec",
}
spark := [10]f32{3, 4, 3.6, 5, 6.2, 5.8, 7, 8.4, 8.1, 9.3}

settings_open := false
settings_sel := 0
stored_scale: f32 = 0 // 0 = auto
app: fit.App

Widget_State :: struct {
	check_a:        bool,
	check_b:        bool,
	radio_choice:   i32,
	volume:         f32,
	slider:         fit.Slider_State,
	dd_selected:    i32,
	dropdown:       fit.Dropdown_State,
	tooltip:        fit.Tooltip_State,
	listbox:        fit.Listbox_State,
	list_selected:  int,
	list_activated: int,
	tab_active:     i32,
	table_sort:     fit.Table_Sort,
	toggle:         bool,
	toggle_motion:  fit.Control_Motion_State,
	slider_motion:  fit.Control_Motion_State,
	tabs_motion:    fit.Control_Motion_State,
}

widget_state := Widget_State {
	check_a = true,
	volume = 40,
	list_activated = -1,
	table_sort = {column = -1},
}

// Generic modal + context menu (Overlay section).
about_modal: fit.Modal_State
user_data_menu: fit.Context_Menu_State
user_data_note := "right-click in this section for a context menu"

// Toasts + confirm dialog (Overlay section). Zero values are ready to use.
toasts: fit.Toast_State
confirm: fit.Confirm_Dialog_State
toast_count := 0

popup_open := false
shielded_clicks := 0
leaked_clicks := 0

// Docked-panel-over-canvas journey. The canvas counters must not advance while
// the pointer is over the panel: that is the whole claim of z-ordered input.
dock_canvas_wheel := 0
dock_canvas_clicks := 0
dock_panel_clicks := 0
dock_panel_pane: fit.Pane_State

stress_clicked := -1


MARKDOWN_SAMPLE ::
	`# Markdown widget

Inline **bold**, *italic*, ` +
	"`code`" +
	`, and [links](https://example.com).

| Widget | State | Notes |
| ------ | ----- | ----- |
| btn | caller-owned | release-over activates |
| scrollbar | Scrollbar_State | shared interact protocol |
| text input | Input_Box | pills, undo, spellcheck |

- caller owns all state
- no ID stack, identity is your pointer
- one-frame overlay + routing claims
`

main :: proc() {
	// Capture mode owns its own loop: widget paint replays after the frame
	// callback returns, so the render target has to bracket the whole session
	// frame (capture.odin).
	when CAPTURE {
		capture_main()
	} else {
		initial_theme_pending = true
		_ = fit.run(
			&app,
			{
				width = 1100,
				height = 760,
				title = "ingot widget gallery",
				frame_pacing = .Monitor_Refresh,
				target_fps = 60,
				event_waiting = !SMOKE,
				session = {semantics_enabled = true},
			},
			gallery_build,
		)
		shutdown()
	}
}

input_state_destroy :: proc(state: ^Input_State) {
	assert(state != nil, "input_state_destroy: nil state")
	fit.input_box_destroy(&state.name)
	fit.input_box_destroy(&state.pass)
	fit.input_box_destroy(&state.notes)
	fit.combobox_state_destroy(&state.combo)
}

gallery_build :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil, "gallery_build: nil builder")
	if initial_theme_pending {
		apply_gallery_theme()
		initial_theme_pending = false
	}
	root := fit.column(builder, {size = {width = fit.grow(), height = fit.grow()}})
	fit.canvas_leaf(
		root,
		{size = {width = fit.grow(), height = fit.grow()}},
		gallery_frame,
		user_data,
	)
}

gallery_frame :: proc(surface: ^fit.Surface, root: fit.Rect, user_data: rawptr) -> bool {
	_ = user_data
	gallery_root = root
	sw := root.w
	sh := root.h
	// A browser can hand over an empty box mid-rotation or while the tab is
	// being hidden. Every layout below assumes positive extents, and on the
	// web their assertions trap the whole module rather than one frame.
	if sw <= 0 || sh <= 0 do return false

	when SMOKE do smoke_step()
	when CAPTURE do capture_step()

	if fit.key_pressed(surface, .F12) do debug_on = !debug_on

	header_h := fit.get_metrics(surface).tab_bar_height
	// One decision, taken in the parent and passed down (Tiger Style: push
	// ifs up). Below the breakpoint the sidebar would eat 170 of ~390
	// design units, so the nav becomes a horizontal strip instead.
	narrow := nav_uses_strip(surface, sw, sh - header_h)
	nav_h := draw_nav(surface, header_h, sw, sh, narrow)
	draw_content(surface, sw, header_h + nav_h, sh, narrow)

	if settings_open {
		res := fit.surface_scale_settings(surface, &settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
			settings_open = false
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		fit.surface_debug_overlay(
			surface,
			sw - fit.px(surface, 290),
			header_h + fit.px(surface, 10),
		)
	}

	_ = fit.surface_app_header(surface, "ingot gallery", sw)
	return false
}

shutdown :: proc() {
	input_state_destroy(&input_state)
}

apply_scale :: proc(scale: f32) {
	when CAPTURE {
		fit.session_set_scale(&capture_session, scale)
	} else {
		fit.set_scale(&app, scale)
	}
}

gallery_scaled :: proc(value: i32, scale: f32) -> i32 {
	assert(scale >= 0.5 && scale <= 3, "gallery_scaled: invalid scale")
	return i32(f32(value) * scale + 0.5)
}

nav_sidebar_min_height_scale :: proc(scale: f32) -> i32 {
	padding := gallery_scaled(8, scale)
	gap := gallery_scaled(4, scale)
	row_h := gallery_scaled(NAV_SIDEBAR_ROW_H, scale)
	line_height := gallery_scaled(22, scale)
	row_count := i32(len(Section) + len(Nav_Control))
	item_count := row_count + 3
	return padding * 3 + line_height + 2 + row_count * row_h + (item_count - 1) * gap
}

nav_uses_strip_scale :: proc(scale: f32, width, available_height: i32) -> bool {
	assert(width >= 0, "nav_uses_strip_scale: negative width")
	return(
		width <= gallery_scaled(NARROW_WIDTH_MAX, scale) ||
		available_height < nav_sidebar_min_height_scale(scale) \
	)
}

nav_sidebar_min_height :: proc(surface: ^fit.Surface) -> i32 {
	assert(surface != nil, "nav_sidebar_min_height: nil surface")
	return nav_sidebar_min_height_scale(f32(fit.px(surface, 1000)) / 1000)
}

nav_uses_strip :: proc(surface: ^fit.Surface, width, available_height: i32) -> bool {
	assert(surface != nil, "nav_uses_strip: nil surface")
	scale := f32(fit.px(surface, 1000)) / 1000
	return nav_uses_strip_scale(scale, width, available_height)
}

// nav_strip_full_height_scale is the height of the full wrapped section grid
// plus the controls row. Pure, so the phone geometry is testable without a frame.
nav_strip_full_height_scale :: proc(scale: f32, width: i32) -> i32 {
	assert(width > 0, "nav_strip_full_height_scale: empty width")
	pad := gallery_scaled(8, scale)
	gap := gallery_scaled(6, scale)
	row_h := gallery_scaled(NAV_STRIP_ROW_H, scale)
	cell := gallery_scaled(NAV_STRIP_CELL_W, scale)
	cols := max((width - pad * 2 + gap) / (cell + gap), 1)
	rows := (i32(len(Section)) + cols - 1) / cols
	height := pad * 2 + rows * row_h + (rows - 1) * gap + gap + row_h
	assert(height > 0, "nav_strip_full_height_scale: non-positive height")
	return height
}

// nav_strip_compact_height_scale is one previous/current/next row plus the
// controls row.
nav_strip_compact_height_scale :: proc(scale: f32) -> i32 {
	pad := gallery_scaled(8, scale)
	row_h := gallery_scaled(NAV_STRIP_ROW_H, scale)
	height := pad * 2 + row_h * 2 + gallery_scaled(6, scale)
	assert(height > 0, "nav_strip_compact_height_scale: non-positive height")
	return height
}

nav_strip_uses_compact_scale :: proc(scale: f32, width, available_height: i32) -> bool {
	assert(width > 0, "nav_strip_uses_compact_scale: empty width")
	assert(available_height >= 0, "nav_strip_uses_compact_scale: negative height")
	share := available_height / NAV_STRIP_HEIGHT_SHARE_DEN
	return nav_strip_full_height_scale(scale, width) > share
}

// nav_strip_height_scale is the height the strip actually occupies. It never
// exceeds the space under the header, so the content pane cannot go negative.
nav_strip_height_scale :: proc(scale: f32, width, available_height: i32) -> i32 {
	available := max(available_height, 0)
	compact := nav_strip_uses_compact_scale(scale, width, available)
	wanted :=
		nav_strip_compact_height_scale(scale) if compact else nav_strip_full_height_scale(scale, width)
	height := min(wanted, available)
	assert(height >= 0 && height <= available, "nav_strip_height_scale: escapes viewport")
	return height
}

// nav_select_section is the one place a nav switches section, so the sidebar,
// the full strip and the compact strip cannot disagree about the side effects.
nav_select_section :: proc(s: Section) {
	if s != section do gfx.web_mark(fmt.tprintf("section %s", SECTION_NAMES[s]))
	section = s
	fit.pane_reset(&content_pane)
	assert(section == s, "nav_select_section: section not applied")
}

// draw_nav renders the section switcher and returns the vertical space it
// consumed. Wide viewports get the sidebar (0 vertical space, it lives beside
// the content); narrow ones get a horizontal strip whose height the caller
// must subtract from the content area.
// Nav_Control is the set of non-section buttons both nav layouts carry. It
// exists so the sidebar and the narrow strip cannot disagree about which
// controls exist or what they do: an earlier revision duplicated these four
// as inline button blocks in each layout, and the strip silently
// lost Motion. Adding a fifth control now lands in both layouts by
// construction.
Nav_Control :: enum {
	Theme,
	Motion,
	Scale,
}

// nav_control_label returns the button text for a control. `compact` selects
// the short form the narrow strip needs, where a full sentence would not fit
// a phone-width cell. Pure: no frame, no side effects.
nav_control_label :: proc(control: Nav_Control, compact: bool) -> string {
	switch control {
	case .Theme:
		// Naming the palette you are *in*, not the one the button leads to.
		//
		// This previously showed palette_next(palette), on the theory that a
		// button is an action and should be labelled with what it does. The
		// theory does not survive contact with the control sitting directly
		// beneath it: Motion reports its current state ("Motion: full"), so a
		// Theme button reporting its *next* state made two adjacent controls
		// in one list read in opposite directions. Selecting "Sketch warm"
		// left the sidebar saying "Sketch grey", which reads as the wrong mode
		// having been applied.
		//
		// Consistency within the list beats the theory. Both controls now
		// answer the same question: what is switched on right now.
		if compact do return PALETTE_NAMES[palette]
		return label_join("Theme: ", PALETTE_NAMES[palette])
	case .Motion:
		if compact do return "Motion"
		return "Motion: reduced" if reduced_motion else "Motion: full"
	case .Scale:
		if compact do return "Scale\u2026"
		return "UI scale\u2026"
	}
	return ""
}

// nav_control_activate applies one control's effect. The single owner of these
// state transitions, so the two layouts cannot drift apart again.
nav_control_activate :: proc(control: Nav_Control, surface: ^fit.Surface) {
	assert(surface != nil, "nav_control_activate: nil surface")
	switch control {
	case .Theme:
		// No force-clear needed: high contrast is a palette now, so choosing
		// another one leaves it by construction rather than by cleanup.
		palette = palette_next(palette)
		apply_gallery_theme(surface)
	case .Motion:
		reduced_motion = !reduced_motion
		apply_gallery_theme(surface)
	case .Scale:
		settings_open = true
		settings_sel = fit.surface_settings_scale_preset_index(stored_scale)
	}
}

draw_nav :: proc(surface: ^fit.Surface, top, sw, sh: i32, narrow: bool) -> i32 {
	assert(surface != nil, "draw_nav: nil surface")
	if narrow do return draw_nav_strip(surface, top, sw, sh)
	w := fit.px(surface, NAV_W)
	theme := fit.get_theme_tokens(surface)
	fit.fill_rect(surface, fit.Rect{0, top, w, sh - top}, theme.background_secondary)
	fit.fill_rect(surface, fit.Rect{w - 1, top, 1, sh - top}, theme.border_subtle)

	region: fit.Region
	u := fit.region_open(
		surface,
		&region,
		{0, top, w, sh - top},
		{gap = .XS, scope = "navigation"},
	)
	fit.region_padding(u, .SM)
	fit.region_label(&region, "ingot gallery", .Title)
	fit.region_separator(&region)
	for s in Section {
		style := fit.Button_Style.Primary if s == section else .Ghost
		fit.region_flex_row_begin(u, NAV_SIDEBAR_ROW_H, {fit.grow()})
		if fit.region_button(u, SECTION_NAMES[s], SECTION_NAMES[s], style) {
			nav_select_section(s)
		}
		fit.region_flex_row_end(u)
	}
	fit.region_space(u, .SM)
	fit.region_separator(u)
	for control in Nav_Control {
		fit.region_flex_row_begin(u, NAV_SIDEBAR_ROW_H, {fit.grow()})
		if fit.region_button(u, NAV_CONTROL_IDS[control], nav_control_label(control, false)) {
			nav_control_activate(control, surface)
		}
		fit.region_flex_row_end(u)
	}
	_ = fit.region_close(u)
	return 0
}

// Stable widget identities for the shared controls. Derived from the enum so a
// new control cannot be added without one.
NAV_CONTROL_IDS := [Nav_Control]string {
	.Theme  = "theme",
	.Motion = "motion",
	.Scale  = "scale",
}

// draw_nav_strip is the narrow-viewport nav: wrapped rows of section buttons
// under the header, so every section stays reachable on a phone without
// spending 44% of the width on a sidebar. It carries the same Nav_Control set
// the sidebar does - a demo that hides its own features on mobile is worse
// than one that scrolls.
//
// On a short viewport the full grid would crowd out the content, so the strip
// switches to a compact previous / current / next row, and its height is
// clamped to the space under the header in every case.
draw_nav_strip :: proc(surface: ^fit.Surface, top, sw, sh: i32) -> i32 {
	assert(surface != nil, "draw_nav_strip: nil surface")
	assert(sw > 0, "draw_nav_strip: empty viewport")
	scale := f32(fit.px(surface, 1000)) / 1000
	available := max(sh - top, 0)
	height := nav_strip_height_scale(scale, sw, available)
	if height <= 0 do return 0
	compact := nav_strip_uses_compact_scale(scale, sw, available)
	theme := fit.get_theme_tokens(surface)
	pad := gallery_scaled(8, scale)
	gap := gallery_scaled(6, scale)
	row_h := gallery_scaled(NAV_STRIP_ROW_H, scale)

	fit.fill_rect(surface, fit.Rect{0, top, sw, height}, theme.background_secondary)
	fit.fill_rect(surface, fit.Rect{0, top + height - 1, sw, 1}, theme.border_subtle)

	content := draw_nav_strip_sections(
		surface,
		{pad, top + pad, sw - pad * 2, row_h},
		gap,
		compact,
	)

	controls: fit.Grid_State
	fit.grid_begin(
		surface,
		&controls,
		{pad, content.y + content.h + gap, sw - pad * 2, 0},
		i32(len(Nav_Control)),
		row_h,
		gap,
		gap,
	)
	for control in Nav_Control {
		rect := fit.grid_next(&controls)
		widget := fit.Widget_Id(0x1000 + u64(control))
		if fit.surface_button(surface, widget, nav_control_label(control, true), rect) {
			nav_control_activate(control, surface)
		}
	}
	_ = fit.grid_end(&controls)
	return height
}

// draw_nav_strip_sections draws the section switcher inside `area` (whose h is
// one row height): either the full wrapped grid or, when that grid would take
// more than its share of a short viewport, one row of previous / current /
// next. Returns the rect the rows covered.
draw_nav_strip_sections :: proc(
	surface: ^fit.Surface,
	area: fit.Rect,
	gap: i32,
	compact: bool,
) -> fit.Rect {
	assert(surface != nil, "draw_nav_strip_sections: nil surface")
	assert(area.h > 0, "draw_nav_strip_sections: empty row")
	scale := f32(fit.px(surface, 1000)) / 1000
	cell := gallery_scaled(NAV_STRIP_CELL_W, scale)
	cols := i32(3) if compact else max((area.w + gap) / (cell + gap), 1)
	grid: fit.Grid_State
	fit.grid_begin(surface, &grid, {area.x, area.y, area.w, 0}, cols, area.h, gap, gap)
	if compact {
		count := i32(len(Section))
		prev := Section((i32(section) + count - 1) % count)
		next := Section((i32(section) + 1) % count)
		prev_id := fit.Widget_Id(NAV_STRIP_COMPACT_ID_BASE)
		if fit.surface_button(surface, prev_id, "<", fit.grid_next(&grid), .Ghost) {
			nav_select_section(prev)
		}
		current_id := fit.Widget_Id(NAV_STRIP_COMPACT_ID_BASE + 1)
		current_rect := fit.grid_next(&grid)
		_ = fit.surface_button(surface, current_id, SECTION_NAMES[section], current_rect, .Primary)
		next_id := fit.Widget_Id(NAV_STRIP_COMPACT_ID_BASE + 2)
		if fit.surface_button(surface, next_id, ">", fit.grid_next(&grid), .Ghost) {
			nav_select_section(next)
		}
		return fit.grid_end(&grid)
	}
	for s in Section {
		style := fit.Button_Style.Primary if s == section else .Ghost
		rect := fit.grid_next(&grid)
		widget := fit.Widget_Id(0x2000 + u64(s))
		if fit.surface_button(surface, widget, SECTION_NAMES[s], rect, style) {
			nav_select_section(s)
		}
	}
	return fit.grid_end(&grid)
}

apply_gallery_theme :: proc(surface: ^fit.Surface = nil) {
	// One lookup. High contrast used to be an override checked ahead of the
	// palette; folding it into the enum removed the branch along with the
	// force-clear that kept the two in step.
	//
	// reduced_motion stays separate because it genuinely is orthogonal: it
	// applies to every palette, including high contrast, and a user who needs
	// both must be able to have both.
	t := palette_theme(palette)
	fit.theme_set_reduced_motion(&t, reduced_motion)
	when CAPTURE {
		fit.session_set_theme(&capture_session, t)
	} else {
		fit.set_theme(&app, t)
	}
	if surface != nil do fit.request_redraw(surface)
}

// MARGIN_INSET is where the vertical margin rule sits, in design units.
// Wide enough for a right-aligned annotation at note size, narrow enough not
// to steal content width. Dropped entirely on narrow viewports: a 390px phone
// cannot afford 56 of them.
MARGIN_INSET :: 56

// draw_page_substrate lays the page texture behind the content.
//
// It is drawn *after* pane_begin and anchored to the content origin the pane
// returns, which is already scroll-adjusted. That matters for any substrate
// with structure: a texture pinned to the viewport would stay put while the
// content slid over it, which reads as a rendering fault rather than as paper.
//
// Switching on kind keeps every substrate reachable. The built-in sketch
// palettes ask for Tooth, but the ruled path stays available for a consumer
// who wants writing paper - the materials are sound, they are simply not the
// aesthetic these themes chose.
//
// Screen palettes set kind = .None and zero the material colors, so this costs
// them one comparison and no draw calls.
draw_page_substrate :: proc(surface: ^fit.Surface, pane: fit.Rect, anchor: i32, narrow: bool) {
	assert(surface != nil, "draw_page_substrate: nil surface")
	theme := fit.get_theme_tokens(surface)
	if theme.substrate == .None do return

	height := pane.y + pane.h - anchor
	if height <= 0 do return
	region := fit.Float_Rect{f32(pane.x), f32(anchor), f32(pane.w), f32(height)}

	switch theme.substrate {
	case .None:
	case .Ruled:
		fit.draw_rules(surface, region, fit.get_metrics(surface).line_height, theme.paper_rule)
	case .Grid, .Dots:
		spacing := fit.get_metrics(surface).line_height
		if fit.surface_dot_grid_fits(surface, region, spacing) {
			fit.draw_dot_grid(surface, region, spacing, theme.paper_rule)
		}
	case .Tooth:
		fit.draw_paper_tooth(surface, region, theme.paper_tooth)
	}

	if theme.margin_rule && !narrow {
		page := fit.Float_Rect{f32(pane.x), f32(pane.y), f32(pane.w), f32(pane.h)}
		fit.draw_margin_rule(surface, page, MARGIN_INSET, theme.graphite)
	}
}

draw_content :: proc(surface: ^fit.Surface, sw, top, sh: i32, narrow: bool) {
	x := i32(0) if narrow else fit.px(surface, NAV_W)
	w := max(sw - x, 0)
	pane_rect := fit.Rect{x, top, w, max(sh - top, 0)}
	// Nothing to show: pane_begin asserts non-negative extents, and a zero
	// pane would still clip and route input for no visible content.
	if pane_rect.w == 0 || pane_rect.h == 0 do return
	y := fit.pane_begin(
		surface,
		&content_pane,
		pane_rect,
		padding = 14,
		keyboard = section != .Inputs,
	)
	draw_page_substrate(surface, pane_rect, y, narrow)
	inset := fit.px(surface, 8 if narrow else 18)
	gutter := fit.px(surface, 20 if narrow else 52)
	cx := x + inset
	cw := w - gutter
	// A viewport narrower than the gutter leaves no column to lay sections
	// into, and several of them assert a positive width.
	if cw <= 0 {
		fit.pane_end(surface, &content_pane, pane_rect, y, padding = 14)
		return
	}
	y = draw_section_layer(surface, cx, y, cw)

	end_y: i32
	switch section {
	case .Buttons:
		end_y = draw_buttons(surface, cx, y, cw)
	case .Inputs:
		end_y = draw_inputs(surface, cx, y, cw)
	case .Widgets:
		end_y = draw_widgets(surface, cx, y, cw)
	case .Charts:
		end_y = draw_charts(surface, cx, y, cw)
	case .Markdown:
		result := fit.surface_markdown(
			surface,
			{cx, y, cw, 0},
			MARKDOWN_SAMPLE,
			fit.get_theme_tokens(surface).foreground_primary,
		)
		end_y = y + result.height
		if result.link_activated {
			status := sys.open_url(result.link_target)
			if status != .Opened {
				fmt.eprintfln("gallery: open %s failed (%v)", result.link_target, status)
			}
		}
	case .Layout:
		end_y = draw_layout_demo(surface, cx, y, cw)
	case .Overlay:
		end_y = draw_overlay_demo(surface, cx, y, cw)
	case .Stress:
		end_y = draw_stress(surface, cx, y, cw)
	case .Theme:
		end_y = draw_theme_section(surface, cx, y, cw)
	}
	fit.pane_end(surface, &content_pane, pane_rect, end_y, padding = 14)
}

draw_section_layer :: proc(surface: ^fit.Surface, x, y, w: i32) -> i32 {
	assert(surface != nil, "draw_section_layer: nil surface")
	band := fit.get_metrics(surface).line_height * 2
	region: fit.Region
	fit.surface_region_begin(surface, &region, {x, y, w, band}, gap = .XS)
	fit.region_row_begin(&region, 28, gap = .SM, align = .Center)
	_ = fit.region_status_pill(&region, SECTION_LAYERS[section], .Accent)
	fit.region_label(&region, SECTION_AXES[section], .Body, .Secondary)
	fit.region_row_end(&region)
	_ = fit.surface_region_end(&region)
	return y + band
}

draw_buttons :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	assert(surface != nil, "draw_buttons: nil surface")
	u := fit.region_open(
		surface,
		&buttons_region,
		{x, y0, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "buttons"},
	)
	fit.region_section_header(u, "BUTTON STYLES")
	fit.region_row_begin(u, 32, gap = .SM)
	if fit.region_button(u, "primary", "Primary", .Primary, motion = &button_motion[0]) {
		click_count += 1
	}
	if fit.region_button(u, "secondary", "Secondary", .Secondary, motion = &button_motion[1]) {
		click_count += 1
	}
	if fit.region_button(u, "danger", "Danger", .Danger, motion = &button_motion[2]) {
		click_count += 1
	}
	if fit.region_button(u, "ghost", "Ghost", .Ghost, motion = &button_motion[3]) do click_count += 1
	fit.region_row_end(u)
	fit.region_row_begin(u, 32, gap = .SM)
	_ = fit.region_button(u, "disabled", "Disabled", .Primary, false)
	if fit.region_icon_button(u, "close", "\u2715") do click_count += 1
	if fit.region_back_button(u, "back", "Back") do click_count += 1
	fit.region_row_end(u)
	fit.region_label(u, label_int("clicks: ", i64(click_count)), .Body, .Secondary)

	fit.region_section_header(u, "KEYBOARD FOCUS (Tab shows ring, Space/Enter activates)")
	fit.region_row_begin(u, 32, gap = .SM)
	for i in 0 ..< 3 {
		label := label_int("Focusable ", i64(i + 1))
		if fit.region_button(u, u64(i + 1), label) do click_count += 1
	}
	fit.region_row_end(u)

	fit.region_section_header(u, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := label_int("Section ", i64(i + 1))
		_ = fit.region_collapsible_header(
			u,
			label_int("header:", i64(i)),
			label,
			&headers_open[i],
			{icon = 0x25C6, right_label = "Details", motion = &header_motion[i]},
		)
		if headers_open[i] {
			fit.region_label(u, "Collapsed state is caller-owned.", .Body, .Secondary)
		}
	}
	fit.region_space(u, .LG)
	return fit.region_close(u)
}

draw_inputs :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, fit.px(surface, 420))

	state := &input_state
	// One scope per section: identity is composed, never hand-numbered, so
	// adding or reordering a field cannot move focus to a different control.
	u := fit.region_open(
		surface,
		&input_region,
		{x, y, iw, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "inputs"},
	)
	fit.region_text_input(
		u,
		"name",
		&state.name,
		"Your name (undo, selection, spellcheck)",
		{semantics = {name = "Name"}},
	)
	fit.region_text_input(
		u,
		"password",
		&state.pass,
		"Password (masked)",
		{masked = true, semantics = {name = "Password"}},
	)
	fit.region_text_input(
		u,
		"notes",
		&state.notes,
		"Notes… (multi-line: Enter for newlines)",
		{height = 90, semantics = {name = "Notes"}},
	)

	if fit.region_button(u, "reset", "Reset all") {
		fit.input_box_reset(&state.name)
		fit.input_box_reset(&state.pass)
		fit.input_box_reset(&state.notes)
	}
	fit.region_space(u, .XS)

	summary := label_join(
		"name: ",
		label_quoted(fit.input_box_text(&state.name)),
		label_int(" \u00b7 notes: ", i64(len(fit.input_box_text(&state.notes))), " bytes"),
	)
	fit.region_label(u, summary, .Label, .Secondary)

	fit.region_space(u, .SM)
	fit.region_section_header(u, "COMBOBOX (type to filter) + DATE PICKER")
	languages := []fit.Combobox_Item {
		{1, "Odin"},
		{2, "C"},
		{3, "Zig"},
		{4, "Rust"},
		{5, "Go"},
		{6, "Hare"},
	}
	_ = fit.region_combobox(
		u,
		"language",
		&state.combo,
		languages,
		&state.combo_selected,
		"Language\u2026",
		"Language",
	)
	_ = fit.region_date_picker(
		u,
		"release",
		&state.date,
		&state.date_value,
		"Release date\u2026",
		"Release date",
	)
	date_text := "unset"
	if fit.calendar_date_valid(state.date_value) {
		date_text = fit.calendar_format(state.date_value)
	}
	picked := label_join(
		label_int("language id: ", i64(state.combo_selected)),
		" \u00b7 date: ",
		date_text,
	)
	fit.region_label(u, picked, .Label, .Secondary)

	fit.region_space(u, .XL)
	return fit.region_close(u)
}

draw_widget_choices :: proc(u: ^fit.Region, state: ^Widget_State) {
	assert(u != nil, "draw_widget_choices: nil region")
	assert(state != nil, "draw_widget_choices: nil state")
	fit.region_row_begin(u, 32, gap = .SM)
	fit.region_checkbox(u, "enable", "Enable widgets", &state.check_a)
	fit.region_checkbox(u, "verbose", "Verbose logs", &state.check_b)
	fit.region_row_end(u)
	_ = fit.region_toggle(u, "toggle", "Live preview", &state.toggle, &state.toggle_motion)
	fit.region_row_begin(u, 32, gap = .SM)
	fit.region_radio(u, "small", "Small", &state.radio_choice, 0)
	fit.region_radio(u, "medium", "Medium", &state.radio_choice, 1)
	fit.region_radio(u, "large", "Large", &state.radio_choice, 2)
	fit.region_row_end(u)
}

draw_widget_volume :: proc(u: ^fit.Region, surface: ^fit.Surface, state: ^Widget_State) {
	assert(u != nil, "draw_widget_volume: nil region")
	assert(surface != nil, "draw_widget_volume: nil surface")
	assert(state != nil, "draw_widget_volume: nil state")
	fit.region_row_begin(u, 32, gap = .SM)
	_ = fit.region_slider(
		u,
		"volume",
		&state.slider,
		&state.volume,
		0,
		100,
		5,
		240,
		"Volume",
		&state.slider_motion,
	)
	fit.region_label(
		u,
		label_float("", f64(state.volume), 0, "%"),
		fit.Text_Role.Body,
		fit.Ink.Secondary,
	)
	fit.region_row_end(u)
}

draw_widget_form_controls :: proc(
	surface: ^fit.Surface,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_form_controls: nil state")
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"FORM CONTROLS (checkbox / radio / slider / dropdown)",
	)
	region: fit.Region
	u := fit.region_open(
		surface,
		&region,
		{x, y, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "form"},
	)
	draw_widget_choices(u, state)
	draw_widget_volume(u, surface, state)
	backends := []string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	fit.region_dropdown(
		u,
		"backend",
		backends,
		&state.dd_selected,
		&state.dropdown,
		a11y_label = "Graphics backend",
	)
	fit.region_space(u, .MD)
	return fit.region_close(u)
}

// The progress / spinner / pill section is pure facade: every widget carves
// its own slot from a Region, so no call site does arithmetic on x/y/w/h.
draw_widget_progress :: proc(surface: ^fit.Surface, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_progress: nil state")
	region: fit.Region
	u := fit.region_open(
		surface,
		&region,
		{x, y0, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "progress"},
	)
	fit.region_section_header(u, "PROGRESS / SPINNER / PILLS")

	fit.region_row_begin(u, 34, gap = .MD, align = .Start)
	fit.region_spinner(u, 28)
	fit.region_spinner(u, 20, {style = .Orbit_Dots, dot_radius = 2.5, speed = 6})
	_ = fit.region_status_pill(u, "active", fit.Ink.Success)
	_ = fit.region_status_pill(u, "warning", fit.Ink.Tool)
	_ = fit.region_status_pill(u, "error", fit.Ink.Danger)
	fit.region_row_end(u)

	fit.region_progress_bar(u, 0.65)
	fit.region_progress_bar_animated(u, progress_frac, &progress_anim, fit.Ink.Success)

	fit.region_row_begin(u, 30, gap = .SM, align = .Start)
	if fit.region_button(u, "replay", "Replay") do progress_anim = 0
	fit.region_row_end(u)

	fit.region_space(u, .LG)
	return fit.region_close(u)
}

// The key/value rows are facade too: kv_row spans the container width, so the
// caller never measures the value to right-align it, and the default inks are
// the muted-key / emphasized-value pairing.
draw_widget_kv_rows :: proc(surface: ^fit.Surface, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_kv_rows: nil state")
	region: fit.Region
	u := &region
	width := min(w, fit.px(surface, 360))
	fit.surface_region_begin(surface, u, {x, y0, width, fit.ROOT_EXTENT_OPEN}, gap = .XS)
	fit.region_section_header(u, "KV ROWS + LIST ROWS")
	fit.region_key_value(u, "Renderer", "WebGPU")
	fit.region_key_value(u, "State model", "caller-owned")
	fit.region_space(u, .SM)
	return fit.surface_region_end(u)
}

draw_widget_backend_list :: proc(
	surface: ^fit.Surface,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_backend_list: nil state")
	y := y0
	labels := [?]string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	width := min(w, fit.px(surface, 360))
	step := fit.px(surface, 26)
	config := fit.Listbox_Config {
		rect         = {x, y, width, step * i32(len(labels))},
		label        = "Rendering backends",
		stable_id    = "gallery:backends",
		count        = len(labels),
		selected     = &state.list_selected,
		wrap         = true,
		hover_select = true,
		keys         = .Focused,
		page_rows    = len(labels),
	}
	result := fit.surface_listbox_begin(surface, &state.listbox, config)
	for label, i in labels {
		rect := fit.Rect{x, y, width, fit.px(surface, 24)}
		row := fit.surface_selectable_row(
			surface,
			&state.listbox,
			config,
			{
				{x, y, width, fit.px(surface, 24)},
				label,
				label_int("gallery:backend:", i64(i)),
				i,
				false,
				"Rendering backend option",
			},
		)
		fit.surface_list_row_background(surface, rect, row.selected, row.hovered)
		if row.activated do state.list_activated = i
		fit.text(surface, label, x + fit.px(surface, 8), y + fit.px(surface, 4), .Label)
		y += step
	}
	fit.surface_listbox_end(surface, &state.listbox)
	if result.activated do state.list_activated = result.activated_index
	if state.list_activated >= 0 {
		assert(state.list_activated < len(labels), "draw_widget_backend_list: invalid index")
		fit.text(
			surface,
			label_join("activated: ", labels[state.list_activated]),
			x,
			y,
			.Label,
			.Secondary,
		)
		y += step
	}
	return y + fit.px(surface, 8)
}

draw_widget_truncation_card :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(surface, {x, y0, w, 0}, "CARD + SHADOW + TRUNCATION")
	card := fit.Rect{x, y, min(w, fit.px(surface, 360)), fit.px(surface, 64)}
	shadow := fit.Float_Rect{f32(card.x), f32(card.y), f32(card.w), f32(card.h)}
	fit.draw_shadow(surface, shadow, .MD, .Lifted)
	fit.surface_card_background(
		surface,
		card,
		fit.get_theme_tokens(surface).background_secondary,
		accent_width = fit.px(surface, 3),
	)
	fit.text_truncated(
		surface,
		"A very long label that will be cut with an ellipsis when it overflows the card",
		x + fit.px(surface, 12),
		y + fit.px(surface, 12),
		card.w - fit.px(surface, 24),
		.Label,
		.Primary,
	)
	path := fit.surface_truncate_path(
		surface,
		"ingot/examples/gallery/very/deep/dir/main.odin",
		card.w - fit.px(surface, 24),
		fit.get_metrics(surface).font_label,
	)
	fit.text(surface, path, x + fit.px(surface, 12), y + fit.px(surface, 34), .Label, .Secondary)
	return y + card.h + fit.px(surface, 16)
}

draw_widget_fit_card :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(surface, {x, y0, w, 0}, "FIT-CONTENT CARD")
	fit_w := min(w, fit.px(surface, 360))
	pad := fit.px(surface, 12)
	column: fit.Fit_Column_State
	fit.fit_column_begin(
		surface,
		&column,
		x + pad,
		y + pad,
		fit_w - pad * 2,
		gap = fit.px(surface, 6),
	)
	title := fit.fit_column_next(&column, fit.px(surface, 18))
	detail := fit.fit_column_next(&column, fit.px(surface, 18))
	content := fit.fit_column_end(&column)
	card := fit.Rect{x, y, fit_w, content.h + pad * 2}
	fit.surface_card_background(surface, card, fit.get_theme_tokens(surface).background_secondary)
	fit.text(surface, "Geometry resolved before drawing", title.x, title.y, .Label)
	fit.text(surface, "No retained tree or trailing gap", detail.x, detail.y, .Label, .Secondary)
	return y + card.h + fit.px(surface, 16)
}

draw_widgets :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	state := &widget_state
	y := draw_widget_form_controls(surface, x, y0, w, state)
	y = draw_widget_progress(surface, x, y, w, state)
	y = draw_widget_kv_rows(surface, x, y, w, state)
	y = draw_widget_backend_list(surface, x, y, w, state)
	y = draw_widget_tabs_table(surface, x, y, w, state)
	y = draw_widget_truncation_card(surface, x, y, w)
	return draw_widget_fit_card(surface, x, y, w)
}

// The tab bar keeps only a caller-owned active index; the table header owns
// click-to-sort while the caller owns the data, the sorting, and the rows.
Widget_Table_Row :: struct {
	widget: string,
	layer:  string,
	procs:  i32,
}

WIDGET_TABLE_ROWS := [5]Widget_Table_Row {
	{"button", "facade leaf", 2},
	{"combobox", "facade + popup", 2},
	{"listbox", "explicit composite", 3},
	{"toast", "explicit lifecycle", 3},
	{"chart", "facade wrapper", 6},
}

widget_table_less :: proc(a, b: Widget_Table_Row) -> bool {
	sort := widget_state.table_sort
	lhs, rhs := a, b
	if sort.descending do lhs, rhs = rhs, lhs
	switch sort.column {
	case 0:
		return lhs.widget < rhs.widget
	case 1:
		return lhs.layer < rhs.layer
	case:
		return lhs.procs < rhs.procs
	}
}

WIDGET_TABLE_COLUMNS := [3]fit.Table_Column {
	{label = "Widget", track = {kind = .Grow, weight = 1}},
	{label = "Layer", track = {kind = .Fixed, basis = 150}},
	{label = "Procs", track = {kind = .Fixed, basis = 60}, numeric = true},
}

draw_widget_tabs_table :: proc(surface: ^fit.Surface, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_tabs_table: nil state")
	region: fit.Region
	width := min(w, fit.px(surface, 420))
	u := fit.region_open(
		surface,
		&region,
		{x, y0, width, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "data"},
	)

	fit.region_section_header(u, "TAB BAR")
	tabs := []string{"Overview", "Details", "Logs"}
	_ = fit.region_tab_bar(u, "tabs", tabs, &state.tab_active, &state.tabs_motion)
	fit.region_label(
		u,
		label_join(
			"active tab: ",
			tabs[state.tab_active],
			" \u00b7 state is one caller-owned i32",
		),
		fit.Text_Role.Label,
		fit.Ink.Secondary,
	)

	fit.region_space(u, .SM)
	fit.region_section_header(u, "TABLE (click headers to sort)")
	columns := WIDGET_TABLE_COLUMNS[:]
	_ = fit.region_table_header(u, "table", columns, &state.table_sort)
	rows := slice.clone(WIDGET_TABLE_ROWS[:], context.temp_allocator)
	if state.table_sort.column >= 0 do slice.sort_by(rows, widget_table_less)
	row_h: i32 = 24
	tracks_buffer: [fit.TABLE_COLUMN_COUNT_MAX]fit.Track
	for row in rows {
		fit.region_flex_row_begin(
			u,
			row_h,
			fit.table_tracks(columns, tracks_buffer[:]),
			align = .Center,
		)
		draw_widget_table_cell(surface, fit.region_flex_slot_next(u, row_h), row.widget, false)
		draw_widget_table_cell(surface, fit.region_flex_slot_next(u, row_h), row.layer, false)
		draw_widget_table_cell(
			surface,
			fit.region_flex_slot_next(u, row_h),
			label_int("", i64(row.procs)),
			true,
		)
		fit.region_flex_row_end(u)
	}

	fit.region_space(u, .LG)
	return fit.region_close(u)
}

draw_widget_table_cell :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	label: string,
	numeric: bool,
) {
	if rect.w <= 0 || rect.h <= 0 do return
	pad := fit.px(surface, 4)
	text_x := rect.x + pad
	if numeric do text_x = rect.x + rect.w - fit.text_width(surface, label, .Label) - pad
	text_y := rect.y + (rect.h - fit.get_metrics(surface).font_label) / 2
	fit.text(surface, label, text_x, text_y, .Label)
}

draw_charts :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"LINE + BAR + SPARKLINE (hover for overlay tooltips)",
	)
	cw := min(w, fit.px(surface, 560))
	series := [2]fit.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	fit.surface_line_chart(
		surface,
		{x, y, cw, fit.px(surface, 240)},
		series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	y += fit.px(surface, 252)
	fit.surface_bar_chart(
		surface,
		{x, y, cw, fit.px(surface, 220)},
		series[:],
		&bar_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	y += fit.px(surface, 232)
	fit.text(surface, "sparkline:", x, y + fit.px(surface, 6), .Label, .Secondary)
	fit.surface_sparkline(
		surface,
		{x + fit.px(surface, 80), y, fit.px(surface, 140), fit.px(surface, 28)},
		spark[:],
	)
	return y + fit.px(surface, 40)
}

draw_layout_demo :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"SINGLE-PASS LAYOUT (weights + flex + justify + flow)",
	)
	l: fit.Layout_State
	lw := min(w, fit.px(surface, 520))
	fit.layout_begin(surface, &l, {x, y, lw, fit.px(surface, 296)}, gap = fit.px(surface, 8))

	fit.layout_row(&l, fit.px(surface, 40), gap = fit.px(surface, 8))
	fit.layout_weights(&l, {1, 2, 1})
	cell(surface, fit.layout_weighted(&l, 1), "1fr")
	cell(surface, fit.layout_weighted(&l, 2), "2fr")
	cell(surface, fit.layout_weighted(&l, 1), "1fr")
	fit.layout_pop(&l)

	fit.layout_row(&l, fit.px(surface, 40), gap = fit.px(surface, 8))
	cell(surface, fit.layout_next(&l, fit.px(surface, 120)), "fixed 120")
	cell(surface, fit.layout_remaining(&l), "remaining")
	fit.layout_pop(&l)

	draw_layout_centered(surface, &l)

	fit.layout_row(&l, fit.px(surface, 40), gap = fit.px(surface, 8))
	fit.layout_flex(
		&l,
		{
			fit.fixed(fit.px(surface, 72)),
			fit.fit(fit.px(surface, 96), min_size = fit.px(surface, 56)),
			fit.percent(0.2),
			fit.grow(),
		},
	)
	cell(surface, fit.layout_flex_next(&l), "fixed")
	cell(surface, fit.layout_flex_next(&l), "fit")
	cell(surface, fit.layout_flex_next(&l), "20%")
	cell(surface, fit.layout_flex_next(&l), "grow")
	fit.layout_pop(&l)

	// justify packs a declared run whose tracks leave free space; here the
	// leftover is distributed between three fixed cells.
	fit.layout_row(&l, fit.px(surface, 40), gap = fit.px(surface, 8))
	fit.layout_flex(
		&l,
		{
			fit.fixed(fit.px(surface, 90)),
			fit.fixed(fit.px(surface, 90)),
			fit.fixed(fit.px(surface, 90)),
		},
		justify = .Space_Between,
	)
	cell(surface, fit.layout_flex_next(&l), "between")
	cell(surface, fit.layout_flex_next(&l), "between")
	cell(surface, fit.layout_flex_next(&l), "between")
	fit.layout_pop(&l)

	fit.layout_end(&l)
	return draw_layout_flow(surface, x, y, lw)
}

draw_layout_centered :: proc(surface: ^fit.Surface, layout: ^fit.Layout_State) {
	fit.layout_row(layout, fit.px(surface, 90), gap = fit.px(surface, 8), align = .Center)
	rect := fit.layout_sized(layout, fit.px(surface, 160), fit.px(surface, 50))
	cell(surface, rect, "centered")
	fit.layout_pop(layout)
}

draw_layout_flow :: proc(surface: ^fit.Surface, x, y, width: i32) -> i32 {
	flow_y := y + fit.px(surface, 306)
	flow: fit.Flow_State
	fit.flow_begin(
		surface,
		&flow,
		{x, flow_y, width, max(i32) - flow_y},
		fit.px(surface, 8),
		fit.px(surface, 8),
	)
	labels := [?]string{"measured", "single pass", "caller owned", "bounded", "responsive flow"}
	for label in labels {
		item_width := fit.text_width(surface, label, .Label) + fit.px(surface, 24)
		item := fit.flow_next(&flow, item_width, fit.px(surface, 32))
		cell(surface, item, label)
	}
	bounds := fit.flow_end(&flow)
	return bounds.y + bounds.h + fit.px(surface, 10)
}

cell :: proc(surface: ^fit.Surface, r: fit.Rect, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	theme := fit.get_theme_tokens(surface)
	fit.fill_rect(surface, r, theme.background_active)
	fit.stroke_rect(surface, r, theme.border)
	tw := fit.text_width(surface, label, .Label)
	fit.text(
		surface,
		label,
		r.x + (r.w - tw) / 2,
		r.y + (r.h - fit.get_metrics(surface).font_label) / 2,
		.Label,
		.Secondary,
	)
}

draw_overlay_controls :: proc(surface: ^fit.Surface, x, y: i32) -> i32 {
	// A two-column grid places the shielded stack and the action stack; no
	// call site does per-button x/y arithmetic and the columns stay aligned.
	gap := fit.px(surface, 8)
	grid: fit.Grid_State
	fit.grid_begin(
		surface,
		&grid,
		{x, y, fit.px(surface, 340), 0},
		columns = 2,
		row_height = fit.px(surface, 30),
		gap_x = gap,
		gap_y = gap,
	)
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3001),
		"Shielded 1",
		fit.grid_next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3006),
		"Toggle popup",
		fit.grid_next(&grid),
		.Primary,
	) {
		popup_open = !popup_open
	}
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3002),
		"Shielded 2",
		fit.grid_next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3003),
		"Open modal",
		fit.grid_next(&grid),
	) {
		fit.modal_open(&about_modal)
	}
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3004),
		"Shielded 3",
		fit.grid_next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3005),
		"Push toast",
		fit.grid_next(&grid),
	) {
		toast_count += 1
		kind := fit.Toast_Kind(toast_count % 3)
		fit.toast_push(&toasts, kind, fmt.tprintf("Toast %d \u00b7 newest on top", toast_count))
	}
	// The shielded column has only three rows; skip its fourth cell so the
	// danger action stays in the action column.
	_ = fit.grid_next(&grid)
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3007),
		"Delete\u2026",
		fit.grid_next(&grid),
		.Danger,
	) {
		fit.confirm_dialog_open(&confirm)
	}
	content := fit.grid_end(&grid)
	info_y := content.y + content.h + gap
	summary := label_int(
		"shielded clicks: ",
		i64(shielded_clicks),
		" (should not rise while the popup covers them)",
	)
	cursor: fit.Vertical_Cursor_State
	fit.vertical_cursor_begin(surface, &cursor, x, info_y, fit.px(surface, 340))
	_ = fit.vertical_cursor_text(&cursor, summary, .Label, .Secondary)
	fit.vertical_cursor_space(&cursor, gap)
	bounds := fit.vertical_cursor_end(&cursor)
	return bounds.y + bounds.h
}

draw_overlay_context_menu :: proc(surface: ^fit.Surface, x, info_y: i32) {
	if fit.mouse_pressed(surface, .Right) &&
	   !fit.context_menu_is_open(&user_data_menu) &&
	   !fit.modal_is_open(&about_modal) &&
	   !fit.confirm_dialog_is_open(&confirm) {
		mouse := fit.mouse_position(surface)
		fit.context_menu_open(&user_data_menu, mouse)
	}
	if fit.context_menu_is_open(&user_data_menu) {
		items := []fit.Menu_Item {
			{label = "Reset shielded clicks"},
			{label = "Unavailable action", disabled = true},
			{separator = true},
			{label = "Close menu"},
		}
		chosen := fit.surface_context_menu(surface, &user_data_menu, items)
		if chosen == 0 {
			shielded_clicks = 0
			user_data_note = "shielded clicks reset via context menu"
		}
	}
	fit.text(surface, user_data_note, x, info_y + fit.px(surface, 22), .Label, .Label)
}

draw_overlay_modal :: proc(surface: ^fit.Surface) {
	if !fit.modal_is_open(&about_modal) do return
	body := fit.surface_modal_begin(
		surface,
		&about_modal,
		"Bottom modal sheet",
		{fit.px(surface, 420), fit.px(surface, 190)},
		{placement = .Bottom, dismiss_escape = true, dismiss_outside = true},
	)
	metrics := fit.get_metrics(surface)
	fit.text_wrapped(
		surface,
		"The settings panel is built on this same modal_begin/modal_end pair. " +
		"Escape or a click outside dismisses it.",
		body.x + metrics.padding,
		body.y + fit.px(surface, 4),
		body.w - metrics.padding * 2,
		fit.get_theme_tokens(surface).foreground_primary,
		metrics.font_body,
		metrics.line_height,
	)
	if fit.surface_button(
		surface,
		fit.widget_id_from_u64(0x3008),
		"Close",
		{
			body.x + metrics.padding,
			body.y + body.h - fit.px(surface, 44),
			fit.px(surface, 90),
			fit.px(surface, 28),
		},
		.Primary,
	) {
		fit.modal_close(&about_modal)
	}
	fit.surface_modal_end(surface, &about_modal)
}

draw_overlay_demo :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"OVERLAY + INPUT ROUTING (popup occludes the buttons under it)",
	)
	info_y := draw_overlay_controls(surface, x, y)
	info_y = draw_docked_panel_over_canvas(surface, x, info_y, w)
	draw_overlay_context_menu(surface, x, info_y)
	if popup_open {
		draw_demo_popup(surface, x - fit.px(surface, 8), y - fit.px(surface, 8))
	}
	draw_overlay_modal(surface)
	draw_overlay_confirm(surface)
	fit.surface_toasts(surface, &toasts)
	return info_y + fit.px(surface, 52)
}

// draw_docked_panel_over_canvas is the z-ordered input journey: a full-width
// canvas with a panel docked over its right edge. The panel claims its own rect
// at Z_PANEL and draws inside a matching z scope, so the canvas beneath it goes
// inert while the panel's own buttons and scroll pane keep working.
//
// Acceptance is mechanical and on screen: the canvas counters must not advance
// while the pointer is over the panel. Before z-ordering, a panel that claimed
// its own rect went inert, and one that did not claim leaked input to the canvas
// underneath - there was no third option.
draw_docked_panel_over_canvas :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	assert(surface != nil, "draw_docked_panel_over_canvas: nil surface")
	assert(w >= 0, "draw_docked_panel_over_canvas: negative width")
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		"Z-ORDERED INPUT (canvas counters stay put under the docked panel)",
	)
	canvas_h := fit.px(surface, 150)
	panel_w := min(fit.px(surface, 190), w)
	canvas := fit.Rect{x, y, w, canvas_h}
	panel := fit.Rect{x + w - panel_w, y, panel_w, canvas_h}
	if w <= 0 || canvas_h <= 0 do return y

	fit.draw_surface(
		surface,
		{f32(canvas.x), f32(canvas.y), f32(canvas.w), f32(canvas.h)},
		.Panel,
		radius = .SM,
		border = .Hairline,
	)
	canvas_hit := fit.interact(
		surface,
		{f32(canvas.x), f32(canvas.y), f32(canvas.w), f32(canvas.h)},
	)
	if canvas_hit.hovered && fit.wheel(surface) != 0 do dock_canvas_wheel += 1
	if canvas_hit.clicked do dock_canvas_clicks += 1
	metrics := fit.get_metrics(surface)
	fit.text(
		surface,
		label_int("canvas wheel: ", i64(dock_canvas_wheel)),
		x + fit.px(surface, 12),
		y + fit.px(surface, 12),
	)
	fit.text(
		surface,
		label_int("canvas clicks: ", i64(dock_canvas_clicks)),
		x + fit.px(surface, 12),
		y + fit.px(surface, 12) + metrics.line_height,
	)
	fit.text(
		surface,
		"wheel and click here, then over the panel",
		x + fit.px(surface, 12),
		y + fit.px(surface, 12) + metrics.line_height * 2,
		.Note,
		.Secondary,
	)

	draw_dock_panel(surface, panel)
	return y + canvas_h + fit.px(surface, 12)
}

draw_dock_panel :: proc(surface: ^fit.Surface, panel: fit.Rect) {
	assert(surface != nil, "draw_dock_panel: nil surface")
	assert(panel.w > 0 && panel.h > 0, "draw_dock_panel: empty panel")
	claim := fit.Float_Rect{f32(panel.x), f32(panel.y), f32(panel.w), f32(panel.h)}
	fit.draw_surface(surface, claim, .Panel, radius = .SM, border = .Hairline)
	fit.layer_begin(surface, fit.Z_PANEL, claim = claim)
	defer fit.layer_end(surface)

	content_y := fit.pane_begin(surface, &dock_panel_pane, panel, padding = 10)
	region: fit.Region
	u := fit.region_open(
		surface,
		&region,
		{
			panel.x + fit.px(surface, 10),
			content_y,
			panel.w - fit.px(surface, 24),
			fit.ROOT_EXTENT_OPEN,
		},
		{gap = .XS, scope = "dock-panel"},
	)
	fit.region_label(u, "DOCKED PANEL", .Label, .Heading)
	fit.region_label(u, "Claims Z_PANEL over the canvas.", .Note, .Secondary)
	if fit.region_button(u, "dock-a", "Panel button A") do dock_panel_clicks += 1
	if fit.region_button(u, "dock-b", "Panel button B") do dock_panel_clicks += 1
	fit.region_label(u, label_int("panel clicks: ", i64(dock_panel_clicks)))
	for row in 0 ..< 8 do fit.region_label(u, label_int("scroll row ", i64(row)), .Note, .Secondary)
	end_y := fit.region_close(u)
	fit.pane_end(surface, &dock_panel_pane, panel, end_y, padding = 10)
}

// draw_overlay_confirm runs the built-in confirm dialog and reports the
// outcome through a toast, chaining the two lifecycle widgets together.
draw_overlay_confirm :: proc(surface: ^fit.Surface) {
	if !fit.confirm_dialog_is_open(&confirm) do return
	choice := fit.surface_confirm_dialog(
		surface,
		&confirm,
		"Delete everything?",
		"confirm_dialog wraps the same modal pair; Escape or a click outside cancels.",
		"Delete",
	)
	switch choice {
	case .Confirmed:
		fit.toast_push(&toasts, .Error, "Deleted (nothing was actually deleted)")
	case .Canceled:
		fit.toast_push(&toasts, .Info, "Delete canceled")
	case .None:
	}
}

// draw_demo_popup records a popup on its own layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(surface: ^fit.Surface, x, y: i32) {
	w := fit.px(surface, 220)
	h := fit.px(surface, 130)
	rect := fit.Float_Rect{f32(x), f32(y), f32(w), f32(h)}
	fit.layer_begin(surface, fit.Z_POPUP, claim = rect)
	fit.fill_rounded_rect(surface, rect, 0.1, 6, fit.get_theme_tokens(surface).background_popup)
	theme := fit.get_theme_tokens(surface)
	fit.stroke_rounded_rect(surface, rect, 0.1, 6, 1, theme.border)
	fit.text(surface, "Overlay popup", x + fit.px(surface, 12), y + fit.px(surface, 10))
	fit.text(
		surface,
		"Recorded during the frame,",
		x + fit.px(surface, 12),
		y + fit.px(surface, 36),
		.Label,
		.Secondary,
	)
	fit.text(
		surface,
		"replayed above everything.",
		x + fit.px(surface, 12),
		y + fit.px(surface, 54),
		.Label,
		.Secondary,
	)
	// Close row: the popup sits in its own Z_POPUP scope, so its own claim
	// does not occlude it and the ordinary interaction path applies.
	row := fit.Float_Rect {
		f32(x + fit.px(surface, 12)),
		f32(y + h - fit.px(surface, 30)),
		f32(w - fit.px(surface, 24)),
		f32(fit.px(surface, 22)),
	}
	close := fit.interact(surface, row)
	if close.hovered {
		fit.fill_rect(surface, row, fit.get_theme_tokens(surface).background_active)
		fit.request_cursor(surface, .Pointing_Hand)
	}
	fit.text(
		surface,
		"Close",
		x + fit.px(surface, 18),
		y + h - fit.px(surface, 28),
		.Label,
		.Accent,
	)
	if close.clicked {
		popup_open = false
	}
	fit.layer_end(surface)
}

// STRESS_BUTTONS is the grid size the section advertises. Every one of them is
// laid out and measured for the scroll range; only the on-screen rows are
// built and painted (see draw_stress).
STRESS_BUTTONS :: 1000

draw_stress :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	// The grid owns cell geometry: exact column division, no per-button math.
	cols := max(w / fit.px(surface, 110), 1)
	gap := fit.px(surface, 6)
	row_h := fit.px(surface, 26)
	// The header's height does not depend on its text, so the grid's origin
	// is known before the label is built - which is what lets the label
	// report the drawn count.
	header_h := fit.get_metrics(surface).font_label + fit.px(surface, 11)
	bounds := fit.Rect{x, y0 + header_h, w, 0}
	// Only the rows intersecting the pane's cull band are built. Without this
	// the section constructs 1000 labels, measures and interacts with all of
	// them, and emits ~11 MB of vertex data per frame for the ~25 buttons on
	// screen - enough to exhaust the geometry stream on a phone.
	top, bottom := fit.cull_bounds(surface)
	visible := fit.grid_visible_range(
		surface,
		bounds,
		cols,
		row_h,
		gap,
		STRESS_BUTTONS,
		top,
		bottom,
	)
	first, end := visible.first, visible.end
	y := fit.surface_section_header(
		surface,
		{x, y0, w, 0},
		label_join(
			label_int("STRESS: ", i64(STRESS_BUTTONS), " BUTTONS"),
			label_int(" (batcher, hover-anim bound, culling: ", i64(end - first), " drawn)"),
		),
	)
	assert(y == bounds.y, "draw_stress: header height mismatch")
	grid: fit.Grid_State
	fit.grid_begin(surface, &grid, bounds, cols, row_h, gap, gap)
	fit.grid_skip_to(&grid, first)
	for i in first ..< end {
		label := label_int("btn ", i64(i))
		if fit.surface_button(
			surface,
			fit.widget_id_from_u64(0x4000 + u64(i)),
			label,
			fit.grid_next(&grid),
		) {
			stress_clicked = int(i)
		}
	}
	// Advance the cursor past the skipped tail so grid_end still measures the
	// full content height - the pane's scroll range depends on it.
	fit.grid_skip_to(&grid, STRESS_BUTTONS)
	content := fit.grid_end(&grid)
	y = content.y + content.h + fit.px(surface, 10)
	if stress_clicked >= 0 {
		msg := label_int("last clicked: btn ", i64(stress_clicked))
		fit.text(surface, msg, x, y, .Label, .Secondary)
		y += fit.px(surface, 24)
	}
	return y
}
