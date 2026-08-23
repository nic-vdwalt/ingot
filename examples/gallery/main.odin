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
//   - The gallery shell is a bounded fit.Canvas because this catalogue
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
	return fit.Theme_From_Palette(
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
		return fit.Theme_Retro_Ingot()
	case .Ingot_Dark:
		return fit.Theme_Retro_Ingot_Dark()
	case .Terra:
		return fit.Theme_Terra()
	case .Dark:
		return fit.Theme_Dark()
	case .Light:
		return fit.Theme_Light()
	case .Retro_Orange:
		return fit.Theme_Retro_Orange()
	case .Retro_Orange_Dark:
		return fit.Theme_Retro_Orange_Dark()
	case .Custom_Blue:
		return custom_blue_theme()
	case .High_Contrast:
		return fit.Theme_High_Contrast()
	}
	return fit.Theme_Retro_Ingot()
}

content_pane: fit.Pane_State
buttons_region: fit.Region
click_count := 0
headers_open := [3]bool{true, false, false}

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
		_ = fit.Run(
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
	fit.Input_Box_Destroy(&state.name)
	fit.Input_Box_Destroy(&state.pass)
	fit.Input_Box_Destroy(&state.notes)
	fit.Combobox_State_Destroy(&state.combo)
}

gallery_build :: proc(builder: ^fit.Builder, user_data: rawptr) {
	assert(builder != nil, "gallery_build: nil builder")
	if initial_theme_pending {
		apply_gallery_theme()
		initial_theme_pending = false
	}
	root := fit.Column(builder, {size = {width = fit.Grow(), height = fit.Grow()}})
	fit.Canvas_Leaf(
		root,
		{size = {width = fit.Grow(), height = fit.Grow()}},
		gallery_frame,
		user_data,
	)
}

gallery_frame :: proc(surface: ^fit.Surface, root: fit.Rect, user_data: rawptr) -> bool {
	_ = user_data
	gallery_root = root
	fmt.eprintfln("[gallery] frame root = %v", root)
	sw := root.w
	sh := root.h

	when SMOKE do smoke_step()
	when CAPTURE do capture_step()

	if fit.Key_Pressed(surface, .F12) do debug_on = !debug_on

	header_h := fit.Get_Metrics(surface).tab_bar_height
	// One decision, taken in the parent and passed down (Tiger Style: push
	// ifs up). Below the breakpoint the sidebar would eat 170 of ~390
	// design units, so the nav becomes a horizontal strip instead.
	narrow := nav_uses_strip(surface, sw, sh - header_h)
	nav_h := draw_nav(surface, header_h, sw, sh, narrow)
	draw_content(surface, sw, header_h + nav_h, sh, narrow)

	if settings_open {
		res := fit.Surface_Scale_Settings(surface, &settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		fit.Surface_Debug_Overlay(
			surface,
			sw - fit.Px(surface, 290),
			header_h + fit.Px(surface, 10),
		)
	}

	_ = fit.Surface_App_Header(surface, "ingot gallery", sw)
	return false
}

shutdown :: proc() {
	input_state_destroy(&input_state)
}

apply_scale :: proc(scale: f32) {
	when CAPTURE {
		fit.Session_Set_Scale(&capture_session, scale)
	} else {
		fit.Set_Scale(&app, scale)
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
	return nav_sidebar_min_height_scale(f32(fit.Px(surface, 1000)) / 1000)
}

nav_uses_strip :: proc(surface: ^fit.Surface, width, available_height: i32) -> bool {
	assert(surface != nil, "nav_uses_strip: nil surface")
	scale := f32(fit.Px(surface, 1000)) / 1000
	return nav_uses_strip_scale(scale, width, available_height)
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
		return fmt.tprintf("Theme: %s", PALETTE_NAMES[palette])
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
		settings_sel = fit.Surface_Settings_Scale_Preset_Index(stored_scale)
	}
}

draw_nav :: proc(surface: ^fit.Surface, top, sw, sh: i32, narrow: bool) -> i32 {
	assert(surface != nil, "draw_nav: nil surface")
	if narrow do return draw_nav_strip(surface, top, sw)
	w := fit.Px(surface, NAV_W)
	theme := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, fit.Rect{0, top, w, sh - top}, theme.background_secondary)
	fit.Fill_Rect(surface, fit.Rect{w - 1, top, 1, sh - top}, theme.border_subtle)

	region: fit.Region
	u := fit.Region_Open(
		surface,
		&region,
		{0, top, w, sh - top},
		{gap = .XS, scope = "navigation"},
	)
	fit.Region_Padding(u, .SM)
	fit.Region_Label(&region, "ingot gallery", .Title)
	fit.Region_Separator(&region)
	for s in Section {
		style := fit.Button_Style.Primary if s == section else .Ghost
		fit.Region_Flex_Row_Begin(u, NAV_SIDEBAR_ROW_H, {fit.Grow()})
		if fit.Region_Button(u, SECTION_NAMES[s], SECTION_NAMES[s], style) {
			section = s
			fit.Pane_Reset(&content_pane)
		}
		fit.Region_Flex_Row_End(u)
	}
	fit.Region_Space(u, .SM)
	fit.Region_Separator(u)
	for control in Nav_Control {
		fit.Region_Flex_Row_Begin(u, NAV_SIDEBAR_ROW_H, {fit.Grow()})
		if fit.Region_Button(u, NAV_CONTROL_IDS[control], nav_control_label(control, false)) {
			nav_control_activate(control, surface)
		}
		fit.Region_Flex_Row_End(u)
	}
	_ = fit.Region_Close(u)
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
draw_nav_strip :: proc(surface: ^fit.Surface, top, sw: i32) -> i32 {
	assert(surface != nil, "draw_nav_strip: nil surface")
	assert(sw > 0, "draw_nav_strip: empty viewport")
	theme := fit.Get_Theme_Tokens(surface)
	pad := fit.Px(surface, 8)
	gap := fit.Px(surface, 6)
	row_h := fit.Px(surface, NAV_STRIP_ROW_H)
	cols := max((sw - pad * 2 + gap) / (fit.Px(surface, NAV_STRIP_CELL_W) + gap), 1)
	rows := (i32(len(Section)) + cols - 1) / cols
	height := pad * 2 + rows * row_h + (rows - 1) * gap + gap + row_h

	fit.Fill_Rect(surface, fit.Rect{0, top, sw, height}, theme.background_secondary)
	fit.Fill_Rect(surface, fit.Rect{0, top + height - 1, sw, 1}, theme.border_subtle)

	grid: fit.Grid_State
	fit.Grid_Begin(surface, &grid, {pad, top + pad, sw - pad * 2, 0}, cols, row_h, gap, gap)
	for s in Section {
		style := fit.Button_Style.Primary if s == section else .Ghost
		rect := fit.Grid_Next(&grid)
		widget := fit.Widget_Id(0x2000 + u64(s))
		if fit.Surface_Button(surface, widget, SECTION_NAMES[s], rect, style) {
			section = s
			fit.Pane_Reset(&content_pane)
		}
	}
	content := fit.Grid_End(&grid)

	controls: fit.Grid_State
	fit.Grid_Begin(
		surface,
		&controls,
		{pad, content.y + content.h + gap, sw - pad * 2, 0},
		i32(len(Nav_Control)),
		row_h,
		gap,
		gap,
	)
	for control in Nav_Control {
		rect := fit.Grid_Next(&controls)
		widget := fit.Widget_Id(0x1000 + u64(control))
		if fit.Surface_Button(surface, widget, nav_control_label(control, true), rect) {
			nav_control_activate(control, surface)
		}
	}
	_ = fit.Grid_End(&controls)
	return height
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
	fit.Theme_Set_Reduced_Motion(&t, reduced_motion)
	when CAPTURE {
		fit.Session_Set_Theme(&capture_session, t)
	} else {
		fit.Set_Theme(&app, t)
	}
	if surface != nil do fit.Request_Redraw(surface)
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
	theme := fit.Get_Theme_Tokens(surface)
	if theme.substrate == .None do return

	height := pane.y + pane.h - anchor
	if height <= 0 do return
	region := fit.Float_Rect{f32(pane.x), f32(anchor), f32(pane.w), f32(height)}

	switch theme.substrate {
	case .None:
	case .Ruled:
		fit.Draw_Rules(surface, region, fit.Get_Metrics(surface).line_height, theme.paper_rule)
	case .Grid, .Dots:
		spacing := fit.Get_Metrics(surface).line_height
		if fit.Surface_Dot_Grid_Fits(surface, region, spacing) {
			fit.Draw_Dot_Grid(surface, region, spacing, theme.paper_rule)
		}
	case .Tooth:
		fit.Draw_Paper_Tooth(surface, region, theme.paper_tooth)
	}

	if theme.margin_rule && !narrow {
		page := fit.Float_Rect{f32(pane.x), f32(pane.y), f32(pane.w), f32(pane.h)}
		fit.Draw_Margin_Rule(surface, page, MARGIN_INSET, theme.graphite)
	}
}

draw_content :: proc(surface: ^fit.Surface, sw, top, sh: i32, narrow: bool) {
	x := i32(0) if narrow else fit.Px(surface, NAV_W)
	w := sw - x
	pane_rect := fit.Rect{x, top, w, sh - top}
	y := fit.Pane_Begin(
		surface,
		&content_pane,
		pane_rect,
		padding = 14,
		keyboard = section != .Inputs,
	)
	draw_page_substrate(surface, pane_rect, y, narrow)
	inset := fit.Px(surface, 8 if narrow else 18)
	gutter := fit.Px(surface, 20 if narrow else 52)
	cx := x + inset
	cw := w - gutter
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
		result := fit.Surface_Markdown(
			surface,
			{cx, y, cw, 0},
			MARKDOWN_SAMPLE,
			fit.Get_Theme_Tokens(surface).foreground_primary,
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
	fit.Pane_End(surface, &content_pane, pane_rect, end_y, padding = 14)
}

draw_section_layer :: proc(surface: ^fit.Surface, x, y, w: i32) -> i32 {
	assert(surface != nil, "draw_section_layer: nil surface")
	band := fit.Get_Metrics(surface).line_height * 2
	region: fit.Region
	fit.Surface_Region_Begin(surface, &region, {x, y, w, band}, gap = .XS)
	fit.Region_Row_Begin(&region, 28, gap = .SM, align = .Center)
	_ = fit.Region_Status_Pill(&region, SECTION_LAYERS[section], .Accent)
	fit.Region_Label(&region, SECTION_AXES[section], .Body, .Secondary)
	fit.Region_Row_End(&region)
	_ = fit.Surface_Region_End(&region)
	return y + band
}

draw_buttons :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	assert(surface != nil, "draw_buttons: nil surface")
	u := fit.Region_Open(
		surface,
		&buttons_region,
		{x, y0, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "buttons"},
	)
	fit.Region_Section_Header(u, "BUTTON STYLES")
	fit.Region_Row_Begin(u, 32, gap = .SM)
	if fit.Region_Button(u, "primary", "Primary", .Primary) do click_count += 1
	if fit.Region_Button(u, "secondary", "Secondary", .Secondary) {
		click_count += 1
	}
	if fit.Region_Button(u, "danger", "Danger", .Danger) do click_count += 1
	if fit.Region_Button(u, "ghost", "Ghost", .Ghost) do click_count += 1
	fit.Region_Row_End(u)
	fit.Region_Row_Begin(u, 32, gap = .SM)
	_ = fit.Region_Button(u, "disabled", "Disabled", .Primary, false)
	if fit.Region_Icon_Button(u, "close", "\u2715") do click_count += 1
	if fit.Region_Back_Button(u, "back", "Back") do click_count += 1
	fit.Region_Row_End(u)
	fit.Region_Label(u, fmt.tprintf("clicks: %d", click_count), .Body, .Secondary)

	fit.Region_Section_Header(u, "KEYBOARD FOCUS (Tab shows ring, Space/Enter activates)")
	fit.Region_Row_Begin(u, 32, gap = .SM)
	for i in 0 ..< 3 {
		label := fmt.tprintf("Focusable %d", i + 1)
		if fit.Region_Button(u, u64(i + 1), label) do click_count += 1
	}
	fit.Region_Row_End(u)

	fit.Region_Section_Header(u, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := fmt.tprintf("Section %d", i + 1)
		_ = fit.Region_Collapsible_Header(
			u,
			fmt.tprintf("header:%d", i),
			label,
			&headers_open[i],
			{icon = 0x25C6, right_label = "Details"},
		)
		if headers_open[i] {
			fit.Region_Label(u, "Collapsed state is caller-owned.", .Body, .Secondary)
		}
	}
	fit.Region_Space(u, .LG)
	return fit.Region_Close(u)
}

draw_inputs :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, fit.Px(surface, 420))

	state := &input_state
	// One scope per section: identity is composed, never hand-numbered, so
	// adding or reordering a field cannot move focus to a different control.
	u := fit.Region_Open(
		surface,
		&input_region,
		{x, y, iw, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "inputs"},
	)
	fit.Region_Text_Input(
		u,
		"name",
		&state.name,
		"Your name (undo, selection, spellcheck)",
		{semantics = {name = "Name"}},
	)
	fit.Region_Text_Input(
		u,
		"password",
		&state.pass,
		"Password (masked)",
		{masked = true, semantics = {name = "Password"}},
	)
	fit.Region_Text_Input(
		u,
		"notes",
		&state.notes,
		"Notes… (multi-line: Enter for newlines)",
		{height = 90, semantics = {name = "Notes"}},
	)

	if fit.Region_Button(u, "reset", "Reset all") {
		fit.Input_Box_Reset(&state.name)
		fit.Input_Box_Reset(&state.pass)
		fit.Input_Box_Reset(&state.notes)
	}
	fit.Region_Space(u, .XS)

	summary := fmt.tprintf(
		"name: %q \u00b7 notes: %d bytes",
		fit.Input_Box_Text(&state.name),
		len(fit.Input_Box_Text(&state.notes)),
	)
	fit.Region_Label(u, summary, .Label, .Secondary)

	fit.Region_Space(u, .SM)
	fit.Region_Section_Header(u, "COMBOBOX (type to filter) + DATE PICKER")
	languages := []fit.Combobox_Item {
		{1, "Odin"},
		{2, "C"},
		{3, "Zig"},
		{4, "Rust"},
		{5, "Go"},
		{6, "Hare"},
	}
	_ = fit.Region_Combobox(
		u,
		"language",
		&state.combo,
		languages,
		&state.combo_selected,
		"Language\u2026",
		"Language",
	)
	_ = fit.Region_Date_Picker(
		u,
		"release",
		&state.date,
		&state.date_value,
		"Release date\u2026",
		"Release date",
	)
	date_text := "unset"
	if fit.Calendar_Date_Valid(state.date_value) {
		date_text = fit.Calendar_Format(state.date_value)
	}
	picked := fmt.tprintf("language id: %d \u00b7 date: %s", state.combo_selected, date_text)
	fit.Region_Label(u, picked, .Label, .Secondary)

	fit.Region_Space(u, .XL)
	return fit.Region_Close(u)
}

draw_widget_choices :: proc(u: ^fit.Region, state: ^Widget_State) {
	assert(u != nil, "draw_widget_choices: nil region")
	assert(state != nil, "draw_widget_choices: nil state")
	fit.Region_Row_Begin(u, 32, gap = .SM)
	fit.Region_Checkbox(u, "enable", "Enable widgets", &state.check_a)
	fit.Region_Checkbox(u, "verbose", "Verbose logs", &state.check_b)
	fit.Region_Row_End(u)
	fit.Region_Row_Begin(u, 32, gap = .SM)
	fit.Region_Radio(u, "small", "Small", &state.radio_choice, 0)
	fit.Region_Radio(u, "medium", "Medium", &state.radio_choice, 1)
	fit.Region_Radio(u, "large", "Large", &state.radio_choice, 2)
	fit.Region_Row_End(u)
}

draw_widget_volume :: proc(u: ^fit.Region, surface: ^fit.Surface, state: ^Widget_State) {
	assert(u != nil, "draw_widget_volume: nil region")
	assert(surface != nil, "draw_widget_volume: nil surface")
	assert(state != nil, "draw_widget_volume: nil state")
	fit.Region_Row_Begin(u, 32, gap = .SM)
	_ = fit.Region_Slider(u, "volume", &state.slider, &state.volume, 0, 100, 5, 240, "Volume")
	fit.Region_Label(u, fmt.tprintf("%.0f%%", state.volume), fit.Text_Role.Body, fit.Ink.Secondary)
	fit.Region_Row_End(u)
}

draw_widget_form_controls :: proc(
	surface: ^fit.Surface,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_form_controls: nil state")
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"FORM CONTROLS (checkbox / radio / slider / dropdown)",
	)
	region: fit.Region
	u := fit.Region_Open(
		surface,
		&region,
		{x, y, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "form"},
	)
	draw_widget_choices(u, state)
	draw_widget_volume(u, surface, state)
	backends := []string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	fit.Region_Dropdown(
		u,
		"backend",
		backends,
		&state.dd_selected,
		&state.dropdown,
		a11y_label = "Graphics backend",
	)
	fit.Region_Space(u, .MD)
	return fit.Region_Close(u)
}

// The progress / spinner / pill section is pure facade: every widget carves
// its own slot from a Region, so no call site does arithmetic on x/y/w/h.
draw_widget_progress :: proc(surface: ^fit.Surface, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_progress: nil state")
	region: fit.Region
	u := fit.Region_Open(
		surface,
		&region,
		{x, y0, w, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "progress"},
	)
	fit.Region_Section_Header(u, "PROGRESS / SPINNER / PILLS")

	fit.Region_Row_Begin(u, 34, gap = .MD, align = .Start)
	fit.Region_Spinner(u, 28)
	fit.Region_Spinner(u, 20, {style = .Orbit_Dots, dot_radius = 2.5, speed = 6})
	_ = fit.Region_Status_Pill(u, "active", fit.Ink.Success)
	_ = fit.Region_Status_Pill(u, "warning", fit.Ink.Tool)
	_ = fit.Region_Status_Pill(u, "error", fit.Ink.Danger)
	fit.Region_Row_End(u)

	fit.Region_Progress_Bar(u, 0.65)
	fit.Region_Progress_Bar_Animated(u, progress_frac, &progress_anim, fit.Ink.Success)

	fit.Region_Row_Begin(u, 30, gap = .SM, align = .Start)
	if fit.Region_Button(u, "replay", "Replay") do progress_anim = 0
	fit.Region_Row_End(u)

	fit.Region_Space(u, .LG)
	return fit.Region_Close(u)
}

// The key/value rows are facade too: kv_row spans the container width, so the
// caller never measures the value to right-align it, and the default inks are
// the muted-key / emphasized-value pairing.
draw_widget_kv_rows :: proc(surface: ^fit.Surface, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_kv_rows: nil state")
	region: fit.Region
	u := &region
	width := min(w, fit.Px(surface, 360))
	fit.Surface_Region_Begin(surface, u, {x, y0, width, fit.ROOT_EXTENT_OPEN}, gap = .XS)
	fit.Region_Section_Header(u, "KV ROWS + LIST ROWS")
	fit.Region_Key_Value(u, "Renderer", "WebGPU")
	fit.Region_Key_Value(u, "State model", "caller-owned")
	fit.Region_Space(u, .SM)
	return fit.Surface_Region_End(u)
}

draw_widget_backend_list :: proc(
	surface: ^fit.Surface,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_backend_list: nil state")
	y := y0
	labels := [?]string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	width := min(w, fit.Px(surface, 360))
	step := fit.Px(surface, 26)
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
	result := fit.Surface_Listbox_Begin(surface, &state.listbox, config)
	for label, i in labels {
		rect := fit.Rect{x, y, width, fit.Px(surface, 24)}
		row := fit.Surface_Selectable_Row(
			surface,
			&state.listbox,
			config,
			{
				{x, y, width, fit.Px(surface, 24)},
				label,
				fmt.tprintf("gallery:backend:%d", i),
				i,
				false,
				"Rendering backend option",
			},
		)
		fit.Surface_List_Row_Background(surface, rect, row.selected, row.hovered)
		if row.activated do state.list_activated = i
		fit.Text(surface, label, x + fit.Px(surface, 8), y + fit.Px(surface, 4), .Label)
		y += step
	}
	fit.Surface_Listbox_End(surface, &state.listbox)
	if result.activated do state.list_activated = result.activated_index
	if state.list_activated >= 0 {
		assert(state.list_activated < len(labels), "draw_widget_backend_list: invalid index")
		fit.Text(
			surface,
			fmt.tprintf("activated: %s", labels[state.list_activated]),
			x,
			y,
			.Label,
			.Secondary,
		)
		y += step
	}
	return y + fit.Px(surface, 8)
}

draw_widget_truncation_card :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(surface, {x, y0, w, 0}, "CARD + SHADOW + TRUNCATION")
	card := fit.Rect{x, y, min(w, fit.Px(surface, 360)), fit.Px(surface, 64)}
	shadow := fit.Float_Rect{f32(card.x), f32(card.y), f32(card.w), f32(card.h)}
	fit.Draw_Shadow(surface, shadow, .MD, .Lifted)
	fit.Surface_Card_Background(
		surface,
		card,
		fit.Get_Theme_Tokens(surface).background_secondary,
		accent_width = fit.Px(surface, 3),
	)
	fit.Text_Truncated(
		surface,
		"A very long label that will be cut with an ellipsis when it overflows the card",
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 12),
		card.w - fit.Px(surface, 24),
		.Label,
		.Primary,
	)
	path := fit.Surface_Truncate_Path(
		surface,
		"ingot/examples/gallery/very/deep/dir/main.odin",
		card.w - fit.Px(surface, 24),
		fit.Get_Metrics(surface).font_label,
	)
	fit.Text(surface, path, x + fit.Px(surface, 12), y + fit.Px(surface, 34), .Label, .Secondary)
	return y + card.h + fit.Px(surface, 16)
}

draw_widget_fit_card :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(surface, {x, y0, w, 0}, "FIT-CONTENT CARD")
	fit_w := min(w, fit.Px(surface, 360))
	pad := fit.Px(surface, 12)
	column: fit.Fit_Column_State
	fit.Fit_Column_Begin(
		surface,
		&column,
		x + pad,
		y + pad,
		fit_w - pad * 2,
		gap = fit.Px(surface, 6),
	)
	title := fit.Fit_Column_Next(&column, fit.Px(surface, 18))
	detail := fit.Fit_Column_Next(&column, fit.Px(surface, 18))
	content := fit.Fit_Column_End(&column)
	card := fit.Rect{x, y, fit_w, content.h + pad * 2}
	fit.Surface_Card_Background(surface, card, fit.Get_Theme_Tokens(surface).background_secondary)
	fit.Text(surface, "Geometry resolved before drawing", title.x, title.y, .Label)
	fit.Text(surface, "No retained tree or trailing gap", detail.x, detail.y, .Label, .Secondary)
	return y + card.h + fit.Px(surface, 16)
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
	width := min(w, fit.Px(surface, 420))
	u := fit.Region_Open(
		surface,
		&region,
		{x, y0, width, fit.ROOT_EXTENT_OPEN},
		{gap = .SM, scope = "data"},
	)

	fit.Region_Section_Header(u, "TAB BAR")
	tabs := []string{"Overview", "Details", "Logs"}
	_ = fit.Region_Tab_Bar(u, "tabs", tabs, &state.tab_active)
	fit.Region_Label(
		u,
		fmt.tprintf("active tab: %s \u00b7 state is one caller-owned i32", tabs[state.tab_active]),
		fit.Text_Role.Label,
		fit.Ink.Secondary,
	)

	fit.Region_Space(u, .SM)
	fit.Region_Section_Header(u, "TABLE (click headers to sort)")
	columns := WIDGET_TABLE_COLUMNS[:]
	_ = fit.Region_Table_Header(u, "table", columns, &state.table_sort)
	rows := slice.clone(WIDGET_TABLE_ROWS[:], context.temp_allocator)
	if state.table_sort.column >= 0 do slice.sort_by(rows, widget_table_less)
	row_h: i32 = 24
	tracks_buffer: [fit.TABLE_COLUMN_COUNT_MAX]fit.Track
	for row in rows {
		fit.Region_Flex_Row_Begin(
			u,
			row_h,
			fit.Table_Tracks(columns, tracks_buffer[:]),
			align = .Center,
		)
		draw_widget_table_cell(surface, fit.Region_Flex_Slot_Next(u, row_h), row.widget, false)
		draw_widget_table_cell(surface, fit.Region_Flex_Slot_Next(u, row_h), row.layer, false)
		draw_widget_table_cell(
			surface,
			fit.Region_Flex_Slot_Next(u, row_h),
			fmt.tprintf("%d", row.procs),
			true,
		)
		fit.Region_Flex_Row_End(u)
	}

	fit.Region_Space(u, .LG)
	return fit.Region_Close(u)
}

draw_widget_table_cell :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	label: string,
	numeric: bool,
) {
	if rect.w <= 0 || rect.h <= 0 do return
	pad := fit.Px(surface, 4)
	text_x := rect.x + pad
	if numeric do text_x = rect.x + rect.w - fit.Text_Width(surface, label, .Label) - pad
	text_y := rect.y + (rect.h - fit.Get_Metrics(surface).font_label) / 2
	fit.Text(surface, label, text_x, text_y, .Label)
}

draw_charts :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"LINE + BAR + SPARKLINE (hover for overlay tooltips)",
	)
	cw := min(w, fit.Px(surface, 560))
	series := [2]fit.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	fit.Surface_Line_Chart(
		surface,
		{x, y, cw, fit.Px(surface, 240)},
		series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	y += fit.Px(surface, 252)
	fit.Surface_Bar_Chart(
		surface,
		{x, y, cw, fit.Px(surface, 220)},
		series[:],
		&bar_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	y += fit.Px(surface, 232)
	fit.Text(surface, "sparkline:", x, y + fit.Px(surface, 6), .Label, .Secondary)
	fit.Surface_Sparkline(
		surface,
		{x + fit.Px(surface, 80), y, fit.Px(surface, 140), fit.Px(surface, 28)},
		spark[:],
	)
	return y + fit.Px(surface, 40)
}

draw_layout_demo :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"SINGLE-PASS LAYOUT (weights + flex + justify + flow)",
	)
	l: fit.Layout_State
	lw := min(w, fit.Px(surface, 520))
	fit.Layout_Begin(surface, &l, {x, y, lw, fit.Px(surface, 296)}, gap = fit.Px(surface, 8))

	fit.Layout_Row(&l, fit.Px(surface, 40), gap = fit.Px(surface, 8))
	fit.Layout_Weights(&l, {1, 2, 1})
	cell(surface, fit.Layout_Weighted(&l, 1), "1fr")
	cell(surface, fit.Layout_Weighted(&l, 2), "2fr")
	cell(surface, fit.Layout_Weighted(&l, 1), "1fr")
	fit.Layout_Pop(&l)

	fit.Layout_Row(&l, fit.Px(surface, 40), gap = fit.Px(surface, 8))
	cell(surface, fit.Layout_Next(&l, fit.Px(surface, 120)), "fixed 120")
	cell(surface, fit.Layout_Remaining(&l), "remaining")
	fit.Layout_Pop(&l)

	draw_layout_centered(surface, &l)

	fit.Layout_Row(&l, fit.Px(surface, 40), gap = fit.Px(surface, 8))
	fit.Layout_Flex(
		&l,
		{
			fit.Fixed(fit.Px(surface, 72)),
			fit.Fit(fit.Px(surface, 96), min_size = fit.Px(surface, 56)),
			fit.Percent(0.2),
			fit.Grow(),
		},
	)
	cell(surface, fit.Layout_Flex_Next(&l), "fixed")
	cell(surface, fit.Layout_Flex_Next(&l), "fit")
	cell(surface, fit.Layout_Flex_Next(&l), "20%")
	cell(surface, fit.Layout_Flex_Next(&l), "grow")
	fit.Layout_Pop(&l)

	// justify packs a declared run whose tracks leave free space; here the
	// leftover is distributed between three fixed cells.
	fit.Layout_Row(&l, fit.Px(surface, 40), gap = fit.Px(surface, 8))
	fit.Layout_Flex(
		&l,
		{
			fit.Fixed(fit.Px(surface, 90)),
			fit.Fixed(fit.Px(surface, 90)),
			fit.Fixed(fit.Px(surface, 90)),
		},
		justify = .Space_Between,
	)
	cell(surface, fit.Layout_Flex_Next(&l), "between")
	cell(surface, fit.Layout_Flex_Next(&l), "between")
	cell(surface, fit.Layout_Flex_Next(&l), "between")
	fit.Layout_Pop(&l)

	fit.Layout_End(&l)
	return draw_layout_flow(surface, x, y, lw)
}

draw_layout_centered :: proc(surface: ^fit.Surface, layout: ^fit.Layout_State) {
	fit.Layout_Row(layout, fit.Px(surface, 90), gap = fit.Px(surface, 8), align = .Center)
	rect := fit.Layout_Sized(layout, fit.Px(surface, 160), fit.Px(surface, 50))
	cell(surface, rect, "centered")
	fit.Layout_Pop(layout)
}

draw_layout_flow :: proc(surface: ^fit.Surface, x, y, width: i32) -> i32 {
	flow_y := y + fit.Px(surface, 306)
	flow: fit.Flow_State
	fit.Flow_Begin(
		surface,
		&flow,
		{x, flow_y, width, max(i32) - flow_y},
		fit.Px(surface, 8),
		fit.Px(surface, 8),
	)
	labels := [?]string{"measured", "single pass", "caller owned", "bounded", "responsive flow"}
	for label in labels {
		item_width := fit.Text_Width(surface, label, .Label) + fit.Px(surface, 24)
		item := fit.Flow_Next(&flow, item_width, fit.Px(surface, 32))
		cell(surface, item, label)
	}
	bounds := fit.Flow_End(&flow)
	return bounds.y + bounds.h + fit.Px(surface, 10)
}

cell :: proc(surface: ^fit.Surface, r: fit.Rect, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	theme := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, r, theme.background_active)
	fit.Stroke_Rect(surface, r, theme.border)
	tw := fit.Text_Width(surface, label, .Label)
	fit.Text(
		surface,
		label,
		r.x + (r.w - tw) / 2,
		r.y + (r.h - fit.Get_Metrics(surface).font_label) / 2,
		.Label,
		.Secondary,
	)
}

draw_overlay_controls :: proc(surface: ^fit.Surface, x, y: i32) -> i32 {
	// A two-column grid places the shielded stack and the action stack; no
	// call site does per-button x/y arithmetic and the columns stay aligned.
	gap := fit.Px(surface, 8)
	grid: fit.Grid_State
	fit.Grid_Begin(
		surface,
		&grid,
		{x, y, fit.Px(surface, 340), 0},
		columns = 2,
		row_height = fit.Px(surface, 30),
		gap_x = gap,
		gap_y = gap,
	)
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3001),
		"Shielded 1",
		fit.Grid_Next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3006),
		"Toggle popup",
		fit.Grid_Next(&grid),
		.Primary,
	) {
		popup_open = !popup_open
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3002),
		"Shielded 2",
		fit.Grid_Next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3003),
		"Open modal",
		fit.Grid_Next(&grid),
	) {
		fit.Modal_Open(&about_modal)
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3004),
		"Shielded 3",
		fit.Grid_Next(&grid),
	) {
		shielded_clicks += 1
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3005),
		"Push toast",
		fit.Grid_Next(&grid),
	) {
		toast_count += 1
		kind := fit.Toast_Kind(toast_count % 3)
		fit.Toast_Push(&toasts, kind, fmt.tprintf("Toast %d \u00b7 newest on top", toast_count))
	}
	// The shielded column has only three rows; skip its fourth cell so the
	// danger action stays in the action column.
	_ = fit.Grid_Next(&grid)
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3007),
		"Delete\u2026",
		fit.Grid_Next(&grid),
		.Danger,
	) {
		fit.Confirm_Dialog_Open(&confirm)
	}
	content := fit.Grid_End(&grid)
	info_y := content.y + content.h + gap
	summary := fmt.tprintf(
		"shielded clicks: %d (should not rise while the popup covers them)",
		shielded_clicks,
	)
	cursor: fit.Vertical_Cursor_State
	fit.Vertical_Cursor_Begin(surface, &cursor, x, info_y, fit.Px(surface, 340))
	_ = fit.Vertical_Cursor_Text(&cursor, summary, .Label, .Secondary)
	fit.Vertical_Cursor_Space(&cursor, gap)
	bounds := fit.Vertical_Cursor_End(&cursor)
	return bounds.y + bounds.h
}

draw_overlay_context_menu :: proc(surface: ^fit.Surface, x, info_y: i32) {
	if fit.Mouse_Pressed(surface, .Right) &&
	   !fit.Context_Menu_Is_Open(&user_data_menu) &&
	   !fit.Modal_Is_Open(&about_modal) &&
	   !fit.Confirm_Dialog_Is_Open(&confirm) {
		mouse := fit.Mouse_Position(surface)
		fit.Context_Menu_Open(&user_data_menu, mouse)
	}
	if fit.Context_Menu_Is_Open(&user_data_menu) {
		items := []fit.Menu_Item {
			{label = "Reset shielded clicks"},
			{label = "Unavailable action", disabled = true},
			{separator = true},
			{label = "Close menu"},
		}
		chosen := fit.Surface_Context_Menu(surface, &user_data_menu, items)
		if chosen == 0 {
			shielded_clicks = 0
			user_data_note = "shielded clicks reset via context menu"
		}
	}
	fit.Text(surface, user_data_note, x, info_y + fit.Px(surface, 22), .Label, .Label)
}

draw_overlay_modal :: proc(surface: ^fit.Surface) {
	if !fit.Modal_Is_Open(&about_modal) do return
	body := fit.Surface_Modal_Begin(
		surface,
		&about_modal,
		"Generic modal",
		{fit.Px(surface, 420), fit.Px(surface, 190)},
	)
	metrics := fit.Get_Metrics(surface)
	fit.Text_Wrapped(
		surface,
		"The settings panel is built on this same modal_begin/modal_end pair. " +
		"Escape or a click outside dismisses it.",
		body.x + metrics.padding,
		body.y + fit.Px(surface, 4),
		body.w - metrics.padding * 2,
		fit.Get_Theme_Tokens(surface).foreground_primary,
		metrics.font_body,
		metrics.line_height,
	)
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_U64(0x3008),
		"Close",
		{
			body.x + metrics.padding,
			body.y + body.h - fit.Px(surface, 44),
			fit.Px(surface, 90),
			fit.Px(surface, 28),
		},
		.Primary,
	) {
		fit.Modal_Close(&about_modal)
	}
	fit.Surface_Modal_End(surface, &about_modal)
}

draw_overlay_demo :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"OVERLAY + INPUT ROUTING (popup occludes the buttons under it)",
	)
	info_y := draw_overlay_controls(surface, x, y)
	info_y = draw_docked_panel_over_canvas(surface, x, info_y, w)
	draw_overlay_context_menu(surface, x, info_y)
	if popup_open {
		draw_demo_popup(surface, x - fit.Px(surface, 8), y - fit.Px(surface, 8))
	}
	draw_overlay_modal(surface)
	draw_overlay_confirm(surface)
	fit.Surface_Toasts(surface, &toasts)
	return info_y + fit.Px(surface, 52)
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
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		"Z-ORDERED INPUT (canvas counters stay put under the docked panel)",
	)
	canvas_h := fit.Px(surface, 150)
	panel_w := min(fit.Px(surface, 190), w)
	canvas := fit.Rect{x, y, w, canvas_h}
	panel := fit.Rect{x + w - panel_w, y, panel_w, canvas_h}
	if w <= 0 || canvas_h <= 0 do return y

	fit.Draw_Surface(
		surface,
		{f32(canvas.x), f32(canvas.y), f32(canvas.w), f32(canvas.h)},
		.Panel,
		radius = .SM,
		border = .Hairline,
	)
	canvas_hit := fit.Interact(
		surface,
		{f32(canvas.x), f32(canvas.y), f32(canvas.w), f32(canvas.h)},
	)
	if canvas_hit.hovered && fit.Wheel(surface) != 0 do dock_canvas_wheel += 1
	if canvas_hit.clicked do dock_canvas_clicks += 1
	metrics := fit.Get_Metrics(surface)
	fit.Text(
		surface,
		fmt.tprintf("canvas wheel: %d", dock_canvas_wheel),
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 12),
	)
	fit.Text(
		surface,
		fmt.tprintf("canvas clicks: %d", dock_canvas_clicks),
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 12) + metrics.line_height,
	)
	fit.Text(
		surface,
		"wheel and click here, then over the panel",
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 12) + metrics.line_height * 2,
		.Note,
		.Secondary,
	)

	draw_dock_panel(surface, panel)
	return y + canvas_h + fit.Px(surface, 12)
}

draw_dock_panel :: proc(surface: ^fit.Surface, panel: fit.Rect) {
	assert(surface != nil, "draw_dock_panel: nil surface")
	assert(panel.w > 0 && panel.h > 0, "draw_dock_panel: empty panel")
	claim := fit.Float_Rect{f32(panel.x), f32(panel.y), f32(panel.w), f32(panel.h)}
	fit.Draw_Surface(surface, claim, .Panel, radius = .SM, border = .Hairline)
	fit.Layer_Begin(surface, fit.Z_PANEL, claim = claim)
	defer fit.Layer_End(surface)

	content_y := fit.Pane_Begin(surface, &dock_panel_pane, panel, padding = 10)
	region: fit.Region
	u := fit.Region_Open(
		surface,
		&region,
		{
			panel.x + fit.Px(surface, 10),
			content_y,
			panel.w - fit.Px(surface, 24),
			fit.ROOT_EXTENT_OPEN,
		},
		{gap = .XS, scope = "dock-panel"},
	)
	fit.Region_Label(u, "DOCKED PANEL", .Label, .Heading)
	fit.Region_Label(u, "Claims Z_PANEL over the canvas.", .Note, .Secondary)
	if fit.Region_Button(u, "dock-a", "Panel button A") do dock_panel_clicks += 1
	if fit.Region_Button(u, "dock-b", "Panel button B") do dock_panel_clicks += 1
	fit.Region_Label(u, fmt.tprintf("panel clicks: %d", dock_panel_clicks))
	for row in 0 ..< 8 do fit.Region_Label(u, fmt.tprintf("scroll row %d", row), .Note, .Secondary)
	end_y := fit.Region_Close(u)
	fit.Pane_End(surface, &dock_panel_pane, panel, end_y, padding = 10)
}

// draw_overlay_confirm runs the built-in confirm dialog and reports the
// outcome through a toast, chaining the two lifecycle widgets together.
draw_overlay_confirm :: proc(surface: ^fit.Surface) {
	if !fit.Confirm_Dialog_Is_Open(&confirm) do return
	choice := fit.Surface_Confirm_Dialog(
		surface,
		&confirm,
		"Delete everything?",
		"confirm_dialog wraps the same modal pair; Escape or a click outside cancels.",
		"Delete",
	)
	switch choice {
	case .Confirmed:
		fit.Toast_Push(&toasts, .Error, "Deleted (nothing was actually deleted)")
	case .Canceled:
		fit.Toast_Push(&toasts, .Info, "Delete canceled")
	case .None:
	}
}

// draw_demo_popup records a popup on its own layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(surface: ^fit.Surface, x, y: i32) {
	w := fit.Px(surface, 220)
	h := fit.Px(surface, 130)
	rect := fit.Float_Rect{f32(x), f32(y), f32(w), f32(h)}
	fit.Layer_Begin(surface, fit.Z_POPUP, claim = rect)
	fit.Fill_Rounded_Rect(surface, rect, 0.1, 6, fit.Get_Theme_Tokens(surface).background_popup)
	theme := fit.Get_Theme_Tokens(surface)
	fit.Stroke_Rounded_Rect(surface, rect, 0.1, 6, 1, theme.border)
	fit.Text(surface, "Overlay popup", x + fit.Px(surface, 12), y + fit.Px(surface, 10))
	fit.Text(
		surface,
		"Recorded during the frame,",
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 36),
		.Label,
		.Secondary,
	)
	fit.Text(
		surface,
		"replayed above everything.",
		x + fit.Px(surface, 12),
		y + fit.Px(surface, 54),
		.Label,
		.Secondary,
	)
	// Close row: the popup sits in its own Z_POPUP scope, so its own claim
	// does not occlude it and the ordinary interaction path applies.
	row := fit.Float_Rect {
		f32(x + fit.Px(surface, 12)),
		f32(y + h - fit.Px(surface, 30)),
		f32(w - fit.Px(surface, 24)),
		f32(fit.Px(surface, 22)),
	}
	close := fit.Interact(surface, row)
	if close.hovered {
		fit.Fill_Rect(surface, row, fit.Get_Theme_Tokens(surface).background_active)
		fit.Request_Cursor(surface, .Pointing_Hand)
	}
	fit.Text(
		surface,
		"Close",
		x + fit.Px(surface, 18),
		y + h - fit.Px(surface, 28),
		.Label,
		.Accent,
	)
	if close.clicked {
		popup_open = false
	}
	fit.Layer_End(surface)
}

// STRESS_BUTTONS is the grid size the section advertises. Every one of them is
// laid out and measured for the scroll range; only the on-screen rows are
// built and painted (see draw_stress).
STRESS_BUTTONS :: 1000

draw_stress :: proc(surface: ^fit.Surface, x, y0, w: i32) -> i32 {
	// The grid owns cell geometry: exact column division, no per-button math.
	cols := max(w / fit.Px(surface, 110), 1)
	gap := fit.Px(surface, 6)
	row_h := fit.Px(surface, 26)
	// The header's height does not depend on its text, so the grid's origin
	// is known before the label is built - which is what lets the label
	// report the drawn count.
	header_h := fit.Get_Metrics(surface).font_label + fit.Px(surface, 11)
	bounds := fit.Rect{x, y0 + header_h, w, 0}
	// Only the rows intersecting the pane's cull band are built. Without this
	// the section constructs 1000 labels, measures and interacts with all of
	// them, and emits ~11 MB of vertex data per frame for the ~25 buttons on
	// screen - enough to exhaust the geometry stream on a phone.
	top, bottom := fit.Cull_Bounds(surface)
	visible := fit.Grid_Visible_Range(
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
	y := fit.Surface_Section_Header(
		surface,
		{x, y0, w, 0},
		fmt.tprintf(
			"STRESS: %d BUTTONS (batcher, hover-anim bound, culling: %d drawn)",
			STRESS_BUTTONS,
			end - first,
		),
	)
	assert(y == bounds.y, "draw_stress: header height mismatch")
	grid: fit.Grid_State
	fit.Grid_Begin(surface, &grid, bounds, cols, row_h, gap, gap)
	fit.Grid_Skip_To(&grid, first)
	for i in first ..< end {
		label := fmt.tprintf("btn %d", i)
		if fit.Surface_Button(
			surface,
			fit.Widget_Id_From_U64(0x4000 + u64(i)),
			label,
			fit.Grid_Next(&grid),
		) {
			stress_clicked = int(i)
		}
	}
	// Advance the cursor past the skipped tail so grid_end still measures the
	// full content height - the pane's scroll range depends on it.
	fit.Grid_Skip_To(&grid, STRESS_BUTTONS)
	content := fit.Grid_End(&grid)
	y = content.y + content.h + fit.Px(surface, 10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		fit.Text(surface, msg, x, y, .Label, .Secondary)
		y += fit.Px(surface, 24)
	}
	return y
}
