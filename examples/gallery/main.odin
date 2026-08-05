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
//   - ui_gfx.App owns the ordinary one-window lifecycle.
//   - ui.Ui is the default for application chrome, forms, and widgets. It owns
//     slot carving, scaling, stable identity, focus, semantics, and UI paint.
//   - Explicit UI stays inside named islands where geometry or lifecycle is
//     behavior: panes, charts, layout, overlays, listboxes, and the stress grid.
//   - ingot:gfx is absent from this application UI; capture.odin alone uses it
//     for the render-target and PNG capabilities missing from UI paint.
//   - Facade dimensions are logical and scale once; anything handed to a *_at
//     entry point is already physical, so it goes through frame_sc first.
package main

import "core:fmt"
import "core:slice"
import "core:strings"
import "ingot:sys"
import "ingot:ui"
import "ingot:ui_gfx"

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
// the button walks screen themes, then sketchbook, then the accessibility
// palette last: a progression rather than a jumble.
Palette :: enum {
	Dark,
	Light,
	Sketch_Warm,
	Sketch_Grey,
	High_Contrast,
}

PALETTE_NAMES := [Palette]string {
	.Dark          = "Dark",
	.Light         = "Light",
	.Sketch_Warm   = "Sketch warm",
	.Sketch_Grey   = "Sketch grey",
	.High_Contrast = "High contrast",
}

palette := Palette.Dark
reduced_motion := false
section := Section.Buttons
debug_on := false

// palette_next advances the cycle, wrapping at the end.
//
// Pure and total: every palette has a successor, so the button can never land
// on a state the enum does not name. The label reads `palette` directly rather
// than calling this, so the sidebar reports what is switched on rather than
// what pressing it would do - see nav_control_label.
palette_next :: proc(current: Palette) -> Palette {
	return Palette((int(current) + 1) % len(Palette))
}

// palette_theme resolves a palette to its Theme value.
palette_theme :: proc(value: Palette) -> ui.Theme {
	switch value {
	case .Dark:
		return ui.theme_dark()
	case .Light:
		return ui.theme_light()
	case .Sketch_Warm:
		return ui.theme_sketch_warm()
	case .Sketch_Grey:
		return ui.theme_sketch_grey()
	case .High_Contrast:
		return ui.theme_high_contrast()
	}
	return ui.theme_dark()
}

nav_ui: ui.Ui
buttons_ui: ui.Ui
badge_ui: ui.Ui
content_pane: ui.Pane
click_count := 0
headers_open := [3]bool{true, false, false}

Input_State :: struct {
	ctx:            ui.Ui,
	name:           ui.Input_Box,
	pass:           ui.Input_Box,
	notes:          ui.Input_Box,
	combo:          ui.Combobox_State,
	combo_selected: u64,
	date:           ui.Date_Picker_State,
	date_value:     ui.Calendar_Date,
}

input_state: Input_State

progress_anim: f32
progress_frac: f32 = 0.35

line_state: ui.Chart_State
bar_state: ui.Chart_State
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
app: ui_gfx.App

Widget_State :: struct {
	// One Ui per independently positioned block. Each is a caller-owned
	// layout and focus context; the gallery keeps them separate because the
	// section's own y cursor places the blocks, not a single root.
	ctx:            ui.Ui,
	progress_ctx:   ui.Ui,
	kv_ctx:         ui.Ui,
	data_ctx:       ui.Ui,
	check_a:        bool,
	check_b:        bool,
	radio_choice:   i32,
	volume:         f32,
	slider:         ui.Slider_State,
	dd_selected:    i32,
	dropdown:       ui.Dropdown_State,
	tooltip:        ui.Tooltip_State,
	listbox:        ui.Listbox_State,
	list_selected:  int,
	list_activated: int,
	tab_active:     i32,
	table_sort:     ui.Table_Sort,
}

widget_state := Widget_State {
	check_a = true,
	volume = 40,
	list_activated = -1,
	table_sort = {column = -1},
}

// Generic modal + context menu (Overlay section).
about_modal: ui.Modal_State
ctx_menu: ui.Context_Menu_State
ctx_note := "right-click in this section for a context menu"

// Toasts + confirm dialog (Overlay section). Zero values are ready to use.
toasts: ui.Toast_State
confirm: ui.Confirm_Dialog_State
toast_count := 0

popup_open := false
shielded_clicks := 0
leaked_clicks := 0

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
		_ = ui_gfx.app_run(
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
			{frame = gallery_frame, shutdown = shutdown},
		)
	}
}

input_state_destroy :: proc(state: ^Input_State) {
	assert(state != nil, "input_state_destroy: nil state")
	ui.input_box_destroy(&state.name)
	ui.input_box_destroy(&state.pass)
	ui.input_box_destroy(&state.notes)
	ui.combobox_state_destroy(&state.combo)
}

gallery_frame :: proc(app: ^ui_gfx.App, frame: ^ui.Ui_Frame, userdata: rawptr) {
	_ = userdata
	root := ui_gfx.app_screen_rect(app)
	when CAPTURE do root = {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT}
	sw := root.w
	sh := root.h

	when SMOKE do smoke_step()
	when CAPTURE do capture_step()

	if ui.is_key_pressed(frame, .F12) do debug_on = !debug_on

	header_h := ui.ui_frame_metrics(frame).TAB_BAR_HEIGHT
	// One decision, taken in the parent and passed down (Tiger Style: push
	// ifs up). Below the breakpoint the sidebar would eat 170 of ~390
	// logical pixels, so the nav becomes a horizontal strip instead.
	narrow := nav_uses_strip(frame, sw, sh - header_h)
	nav_h := draw_nav(frame, header_h, sw, sh, narrow)
	draw_content(frame, sw, header_h + nav_h, sh, narrow)

	if settings_open {
		res := ui.draw_scale_settings_panel(frame, &settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		ui.draw_debug_overlay(
			frame,
			sw - ui.ui_frame_sc(frame, 290),
			header_h + ui.ui_frame_sc(frame, 10),
		)
	}

	_ = ui.draw_app_header(frame, "ingot gallery", sw)
}

shutdown :: proc(app: ^ui_gfx.App, userdata: rawptr) {
	assert(app != nil, "shutdown: nil app")
	_ = userdata
	input_state_destroy(&input_state)
}

apply_scale :: proc(scale: f32) {
	resolved := scale if scale > 0 else ui.settings_auto_scale(&app.session.input)
	ui.ui_runtime_set_scale(ui_gfx.app_ui_runtime(&app), resolved)
}

nav_sidebar_min_height :: proc(frame: ^ui.Ui_Frame) -> i32 {
	assert(frame != nil, "nav_sidebar_min_height: nil frame")
	padding := ui.ui_frame_sc(frame, 8)
	gap := ui.ui_frame_sc(frame, 4)
	row_h := ui.ui_frame_sc(frame, NAV_SIDEBAR_ROW_H)
	row_count := i32(len(Section) + len(Nav_Control))
	item_count := row_count + 3
	return padding * 3 + ui.ui_frame_metrics(frame).LINE_HEIGHT + 2 + row_count * row_h +
		(item_count - 1) * gap
}

nav_uses_strip :: proc(frame: ^ui.Ui_Frame, width, available_height: i32) -> bool {
	assert(frame != nil, "nav_uses_strip: nil frame")
	assert(width >= 0, "nav_uses_strip: negative width")
	return width <= ui.ui_frame_sc(frame, NARROW_WIDTH_MAX) ||
		available_height < nav_sidebar_min_height(frame)
}

// draw_nav renders the section switcher and returns the vertical space it
// consumed. Wide viewports get the sidebar (0 vertical space, it lives beside
// the content); narrow ones get a horizontal strip whose height the caller
// must subtract from the content area.
// Nav_Control is the set of non-section buttons both nav layouts carry. It
// exists so the sidebar and the narrow strip cannot disagree about which
// controls exist or what they do: an earlier revision duplicated these four
// as inline `if ui.button(...)` blocks in each layout, and the strip silently
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
nav_control_activate :: proc(control: Nav_Control, frame: ^ui.Ui_Frame) {
	assert(frame != nil, "nav_control_activate: nil frame")
	switch control {
	case .Theme:
		// No force-clear needed: high contrast is a palette now, so choosing
		// another one leaves it by construction rather than by cleanup.
		palette = palette_next(palette)
		apply_gallery_theme(frame)
	case .Motion:
		reduced_motion = !reduced_motion
		apply_gallery_theme(frame)
	case .Scale:
		settings_open = true
		settings_sel = ui.settings_scale_preset_index(stored_scale)
	}
}

draw_nav :: proc(frame: ^ui.Ui_Frame, top, sw, sh: i32, narrow: bool) -> i32 {
	assert(frame != nil, "draw_nav: nil frame")
	if narrow do return draw_nav_strip(frame, top, sw)
	w := ui.ui_frame_sc(frame, NAV_W)
	theme := ui.ui_frame_theme(frame)
	ui.draw_rectangle(frame, 0, top, w, sh - top, theme.bg_secondary)
	ui.draw_rectangle(frame, w - 1, top, 1, sh - top, theme.border_subtle)

	u := &nav_ui
	ui.begin(u, frame, {0, top, w, sh - top}, gap = .XS)
	ui.padding(u, .SM)
	ui.scope_begin(u, "navigation")
	ui.label(u, "ingot gallery", ui.Text_Role.Title)
	ui.separator(u)
	for s in Section {
		style := ui.Btn_Style.Primary if s == section else .Ghost
		ui.flex_row_begin(u, NAV_SIDEBAR_ROW_H, {ui.grow()})
		if ui.button(u, SECTION_NAMES[s], SECTION_NAMES[s], style) {
			section = s
			ui.pane_reset(&content_pane)
		}
		ui.flex_row_end(u)
	}
	ui.space(u, .SM)
	ui.separator(u)
	for control in Nav_Control {
		ui.flex_row_begin(u, NAV_SIDEBAR_ROW_H, {ui.grow()})
		if ui.button(u, NAV_CONTROL_IDS[control], nav_control_label(control, false)) {
			nav_control_activate(control, frame)
		}
		ui.flex_row_end(u)
	}
	ui.scope_end(u)
	ui.end(u)
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
draw_nav_strip :: proc(frame: ^ui.Ui_Frame, top, sw: i32) -> i32 {
	assert(frame != nil, "draw_nav_strip: nil frame")
	assert(sw > 0, "draw_nav_strip: empty viewport")
	theme := ui.ui_frame_theme(frame)
	pad := ui.ui_frame_sc(frame, 8)
	gap := ui.ui_frame_sc(frame, 6)
	row_h := ui.ui_frame_sc(frame, NAV_STRIP_ROW_H)
	// Section buttons wrap into as many rows as the width needs; the control
	// row always follows on its own line.
	cols := max((sw - pad * 2 + gap) / (ui.ui_frame_sc(frame, NAV_STRIP_CELL_W) + gap), 1)
	rows := (i32(len(Section)) + cols - 1) / cols
	height := pad * 2 + rows * row_h + (rows - 1) * gap + gap + row_h

	ui.draw_rectangle(frame, 0, top, sw, height, theme.bg_secondary)
	ui.draw_rectangle(frame, 0, top + height - 1, sw, 1, theme.border_subtle)

	grid: ui.Grid
	ui.grid_begin(&grid, {pad, top + pad, sw - pad * 2, 0}, cols, row_h, gap, gap)
	for s in Section {
		style := ui.Btn_Style.Primary if s == section else .Ghost
		if ui.button_at(frame, ui.grid_next(&grid), SECTION_NAMES[s], style) {
			section = s
			ui.pane_reset(&content_pane)
		}
	}
	content := ui.grid_end(&grid)

	// One cell per control, using the compact labels: four short words fit
	// where the sidebar's full sentences would not.
	controls: ui.Grid
	ui.grid_begin(
		&controls,
		{pad, content.y + content.h + gap, sw - pad * 2, 0},
		i32(len(Nav_Control)),
		row_h,
		gap,
		gap,
	)
	for control in Nav_Control {
		if ui.button_at(frame, ui.grid_next(&controls), nav_control_label(control, true)) {
			nav_control_activate(control, frame)
		}
	}
	_ = ui.grid_end(&controls)
	return height
}

apply_gallery_theme :: proc(frame: ^ui.Ui_Frame = nil) {
	// One lookup. High contrast used to be an override checked ahead of the
	// palette; folding it into the enum removed the branch along with the
	// force-clear that kept the two in step.
	//
	// reduced_motion stays separate because it genuinely is orthogonal: it
	// applies to every palette, including high contrast, and a user who needs
	// both must be able to have both.
	t := palette_theme(palette)
	t.reduced_motion = reduced_motion
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app), t)
	if frame != nil do ui.request_redraw(frame)
}

// MARGIN_INSET is where the vertical margin rule sits, in logical pixels.
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
draw_page_substrate :: proc(frame: ^ui.Ui_Frame, pane: ui.Rect_I32, anchor: i32, narrow: bool) {
	assert(frame != nil, "draw_page_substrate: nil frame")
	theme := ui.ui_frame_theme(frame)
	if theme.substrate.kind == .None do return

	// The texture runs from the content anchor to the bottom of the pane, so
	// it scrolls with the content rather than under it.
	height := pane.y + pane.h - anchor
	if height <= 0 do return
	region := ui.Rectangle{f32(pane.x), f32(anchor), f32(pane.w), f32(height)}

	switch theme.substrate.kind {
	case .None:
	// Handled above; listed so a new kind cannot be silently ignored.
	case .Ruled:
		ui.draw_rule_lines(frame, region, color = theme.paper_rule)
	case .Grid, .Dots:
		spacing := ui.ui_frame_metrics(frame).LINE_HEIGHT
		if ui.dot_grid_fits(region, spacing) {
			ui.draw_dot_grid(frame, region, spacing, theme.paper_rule)
		}
	case .Tooth:
		ui.draw_paper_tooth(frame, region, theme.paper_tooth)
	}

	// The margin rule is now independent of the body indent, so a palette can
	// keep the reserved column without the exercise-book line down it.
	if theme.substrate.margin_rule && !narrow {
		page := ui.Rectangle{f32(pane.x), f32(pane.y), f32(pane.w), f32(pane.h)}
		ui.draw_margin_rule(frame, page, MARGIN_INSET, theme.graphite)
	}
}

draw_content :: proc(frame: ^ui.Ui_Frame, sw, top, sh: i32, narrow: bool) {
	// Narrow viewports have no sidebar to sit beside, so the content starts
	// at the left edge and takes the full width. The inner padding shrinks
	// too: 18+52 logical px of margin is a third of a phone's width.
	x := i32(0) if narrow else ui.ui_frame_sc(frame, NAV_W)
	w := sw - x
	pane_rect := ui.Rect_I32{x, top, w, sh - top}
	y := ui.pane_begin(frame, &content_pane, pane_rect, pad = 14, keyboard = section != .Inputs)
	draw_page_substrate(frame, pane_rect, y, narrow)
	inset := ui.ui_frame_sc(frame, 8 if narrow else 18)
	gutter := ui.ui_frame_sc(frame, 20 if narrow else 52)
	cx := x + inset
	cw := w - gutter
	y = draw_section_layer(frame, cx, y, cw)

	end_y: i32
	switch section {
	case .Buttons:
		end_y = draw_buttons(frame, cx, y, cw)
	case .Inputs:
		end_y = draw_inputs(frame, cx, y, cw)
	case .Widgets:
		end_y = draw_widgets(frame, cx, y, cw)
	case .Charts:
		end_y = draw_charts(frame, cx, y, cw)
	case .Markdown:
		md_ctx := ui.markdown_context(frame)
		end_y =
			ui.markdown_draw(
				&md_ctx,
				{cx, y, cw, 0},
				MARKDOWN_SAMPLE,
				ui.ui_frame_theme(frame).fg_primary,
			) +
			y
		// ui reports the click; the application decides what a link means.
		// That split is forced by the API layers - ui imports only core:* and
		// cannot reach sys - and it is also correct: an application may route
		// a relative target internally rather than hand it to a browser.
		if url, activated := ui.markdown_link_activated(&md_ctx); activated {
			// Defaults allow http and https only. A markdown document is
			// untrusted input, so file:// and custom schemes stay blocked
			// rather than becoming a way to launch arbitrary handlers.
			status := sys.open_url(url)
			if status != .Opened do fmt.eprintfln("gallery: open %s failed (%v)", url, status)
		}
	case .Layout:
		end_y = draw_layout_demo(frame, cx, y, cw)
	case .Overlay:
		end_y = draw_overlay_demo(frame, cx, y, cw)
	case .Stress:
		end_y = draw_stress(frame, cx, y, cw)
	case .Theme:
		end_y = draw_theme_section(frame, cx, y, cw)
	}
	ui.pane_end(frame, &content_pane, pane_rect, end_y, pad = 14)
}

draw_section_layer :: proc(frame: ^ui.Ui_Frame, x, y, w: i32) -> i32 {
	assert(frame != nil, "draw_section_layer: nil frame")
	// Exactly two rule-heights tall. Every section below this band inherits
	// its starting y from here, so a band of some other height would push all
	// of them a fraction of a line off the ruled paper. Two lines is also what
	// the previous hardcoded 44 logical px happened to be, so nothing moves on
	// the unruled palettes.
	band := ui.ui_frame_metrics(frame).LINE_HEIGHT * 2
	u := &badge_ui
	ui.begin(u, frame, {x, y, w, band}, gap = .XS)
	ui.row_begin(u, 28, gap = .SM, align = .Center)
	_ = ui.status_pill(u, SECTION_LAYERS[section], ui.Ink.Accent)
	ui.label(u, SECTION_AXES[section], ui.Text_Role.Body, ui.Ink.Secondary)
	ui.row_end(u)
	_ = ui.end(u)
	return y + band
}

draw_buttons :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_buttons: nil frame")
	u := &buttons_ui
	ui.begin(u, frame, {x, y0, w, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	ui.scope_begin(u, "buttons")
	_ = ui.section_header(u, "BUTTON STYLES")
	ui.row_begin(u, 32, gap = .SM)
	if ui.button(u, "primary", "Primary", ui.Btn_Style.Primary) do click_count += 1
	if ui.button(u, "secondary", "Secondary", ui.Btn_Style.Secondary) do click_count += 1
	if ui.button(u, "danger", "Danger", ui.Btn_Style.Danger) do click_count += 1
	if ui.button(u, "ghost", "Ghost", ui.Btn_Style.Ghost) do click_count += 1
	ui.row_end(u)
	ui.row_begin(u, 32, gap = .SM)
	_ = ui.button(u, "disabled", "Disabled", ui.Btn_Style.Primary, false)
	if ui.icon_btn(u, ui.id(u, "close"), "\u2715") do click_count += 1
	if ui.back_btn(u, ui.id(u, "back"), "Back") do click_count += 1
	ui.row_end(u)
	ui.label(u, fmt.tprintf("clicks: %d", click_count), ui.Text_Role.Body, ui.Ink.Secondary)

	_ = ui.section_header(u, "KEYBOARD FOCUS (Tab cycles, Space/Enter activates)")
	ui.row_begin(u, 32, gap = .SM)
	for i in 0 ..< 3 {
		label := fmt.tprintf("Focusable %d", i + 1)
		if ui.button(u, u64(i + 1), label) do click_count += 1
	}
	ui.row_end(u)

	_ = ui.section_header(u, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := fmt.tprintf("Section %d", i + 1)
		_ = ui.collapsible_header(
			u,
			ui.id(u, fmt.tprintf("header:%d", i)),
			label,
			&headers_open[i],
			{icon = 0x25C6, right_label = "Details"},
		)
		if headers_open[i] {
			ui.label(u, "Collapsed state is caller-owned.", ui.Text_Role.Body, ui.Ink.Secondary)
		}
	}
	ui.scope_end(u)
	ui.space(u, .LG)
	return ui.end(u)
}

draw_inputs :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, ui.ui_frame_sc(frame, 420))

	state := &input_state
	ui.begin(&state.ctx, frame, {x, y, iw, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	// One scope per section: identity is composed, never hand-numbered, so
	// adding or reordering a field cannot move focus to a different control.
	ui.scope_begin(&state.ctx, "inputs")
	ui.text_input(
		&state.ctx,
		ui.id(&state.ctx, "name"),
		&state.name,
		"Your name (undo, selection, spellcheck)",
		semantics = ui.Text_Input_Semantics{name = "Name"},
	)
	ui.text_input(
		&state.ctx,
		ui.id(&state.ctx, "password"),
		&state.pass,
		"Password (masked)",
		masked = true,
		semantics = ui.Text_Input_Semantics{name = "Password"},
	)
	ui.text_input(
		&state.ctx,
		ui.id(&state.ctx, "notes"),
		&state.notes,
		"Notes\u2026 (multi-line: Enter for newlines)",
		height = 90,
		semantics = ui.Text_Input_Semantics{name = "Notes"},
	)

	if ui.button(&state.ctx, ui.id(&state.ctx, "reset"), "Reset all") {
		ui.input_box_reset(&state.name)
		ui.input_box_reset(&state.pass)
		ui.input_box_reset(&state.notes)
	}
	ui.space(&state.ctx, .XS)

	summary := fmt.tprintf(
		"name: %q \u00b7 notes: %d bytes",
		ui.input_box_text(&state.name),
		len(ui.input_box_text(&state.notes)),
	)
	ui.label(&state.ctx, summary, ui.Text_Role.Label, ui.Ink.Secondary)

	ui.space(&state.ctx, .SM)
	_ = ui.section_header(&state.ctx, "COMBOBOX (type to filter) + DATE PICKER")
	languages := []ui.Combobox_Item {
		{1, "Odin"},
		{2, "C"},
		{3, "Zig"},
		{4, "Rust"},
		{5, "Go"},
		{6, "Hare"},
	}
	_ = ui.combobox(
		&state.ctx,
		"language",
		&state.combo,
		languages,
		&state.combo_selected,
		"Language\u2026",
		"Language",
	)
	_ = ui.date_picker(
		&state.ctx,
		"release",
		&state.date,
		&state.date_value,
		"Release date\u2026",
		"Release date",
	)
	picked := fmt.tprintf(
		"language id: %d \u00b7 date: %s",
		state.combo_selected,
		ui.calendar_format(state.date_value) if ui.calendar_date_valid(state.date_value) else "unset",
	)
	ui.label(&state.ctx, picked, ui.Text_Role.Label, ui.Ink.Secondary)

	ui.scope_end(&state.ctx)
	ui.space(&state.ctx, .XL)
	return ui.end(&state.ctx)
}

draw_widget_choices :: proc(state: ^Widget_State) {
	assert(state != nil, "draw_widget_choices: nil state")
	ui.row_begin(&state.ctx, 32, gap = .SM)
	ui.checkbox(&state.ctx, ui.id(&state.ctx, "enable"), "Enable widgets", &state.check_a)
	ui.checkbox(&state.ctx, ui.id(&state.ctx, "verbose"), "Verbose logs", &state.check_b)
	ui.row_end(&state.ctx)
	ui.row_begin(&state.ctx, 32, gap = .SM)
	ui.radio(&state.ctx, ui.id(&state.ctx, "small"), "Small", &state.radio_choice, 0)
	ui.radio(&state.ctx, ui.id(&state.ctx, "medium"), "Medium", &state.radio_choice, 1)
	ui.radio(&state.ctx, ui.id(&state.ctx, "large"), "Large", &state.radio_choice, 2)
	ui.row_end(&state.ctx)
}

draw_widget_volume :: proc(frame: ^ui.Ui_Frame, state: ^Widget_State) {
	assert(frame != nil, "draw_widget_volume: nil frame")
	assert(state != nil, "draw_widget_volume: nil state")
	ui.row_begin(&state.ctx, 32, gap = .SM)
	_ = ui.slider_state(
		&state.ctx,
		ui.id(&state.ctx, "volume"),
		&state.slider,
		&state.volume,
		0,
		100,
		5,
		240,
		"Volume",
	)
	ui.label(&state.ctx, fmt.tprintf("%.0f%%", state.volume), ui.Text_Role.Body, ui.Ink.Secondary)
	ui.row_end(&state.ctx)
}

draw_widget_form_controls :: proc(
	frame: ^ui.Ui_Frame,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_form_controls: nil state")
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"FORM CONTROLS (checkbox / radio / slider / dropdown)",
	)
	ui.begin(&state.ctx, frame, {x, y, w, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	ui.scope_begin(&state.ctx, "form")
	draw_widget_choices(state)
	draw_widget_volume(frame, state)
	backends := []string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	ui.dropdown(
		&state.ctx,
		ui.id(&state.ctx, "backend"),
		backends,
		&state.dd_selected,
		&state.dropdown,
		a11y_label = "Graphics backend",
	)
	ui.scope_end(&state.ctx)
	ui.space(&state.ctx, .MD)
	return ui.end(&state.ctx)
}

// The progress / spinner / pill section is pure facade: every widget carves
// its own slot from a Ui, so no call site does arithmetic on x/y/w/h.
draw_widget_progress :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_progress: nil state")
	u := &state.progress_ctx
	ui.begin(u, frame, {x, y0, w, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	ui.scope_begin(u, "progress")
	_ = ui.section_header(u, "PROGRESS / SPINNER / PILLS")

	ui.row_begin(u, 34, gap = .MD, align = .Start)
	ui.spinner(u, 28)
	ui.spinner(u, 20, {style = .Orbit_Dots, dot_radius = 2.5, speed = 6})
	_ = ui.status_pill(u, "active", ui.Ink.Success)
	_ = ui.status_pill(u, "warning", ui.Ink.Tool)
	_ = ui.status_pill(u, "error", ui.Ink.Danger)
	ui.row_end(u)

	ui.progress_bar(u, 0.65)
	ui.progress_bar_animated(u, progress_frac, &progress_anim, ui.Ink.Success)

	ui.row_begin(u, 30, gap = .SM, align = .Start)
	if ui.button(u, ui.id(u, "replay"), "Replay") do progress_anim = 0
	ui.row_end(u)

	ui.scope_end(u)
	ui.space(u, .LG)
	return ui.end(u)
}

// The key/value rows are facade too: kv_row spans the container width, so the
// caller never measures the value to right-align it, and the default inks are
// the muted-key / emphasized-value pairing.
draw_widget_kv_rows :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_kv_rows: nil state")
	u := &state.kv_ctx
	width := min(w, ui.ui_frame_sc(frame, 360))
	ui.begin(u, frame, {x, y0, width, ui.ROOT_EXTENT_OPEN}, gap = .XS)
	_ = ui.section_header(u, "KV ROWS + LIST ROWS")
	ui.kv_row(u, "Renderer", "WebGPU")
	ui.kv_row(u, "State model", "caller-owned")
	ui.space(u, .SM)
	return ui.end(u)
}

draw_widget_backend_list :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_backend_list: nil state")
	y := y0
	labels := [?]string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	width := min(w, ui.ui_frame_sc(frame, 360))
	step := ui.ui_frame_sc(frame, 26)
	config := ui.Listbox_Config {
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
	result := ui.listbox_begin(frame, &state.listbox, config)
	for label, i in labels {
		rect := ui.Rect_I32{x, y, width, ui.ui_frame_sc(frame, 24)}
		row := ui.selectable_row(
			frame,
			&state.listbox,
			config,
			{
				{x, y, width, ui.ui_frame_sc(frame, 24)},
				label,
				fmt.tprintf("gallery:backend:%d", i),
				i,
				false,
				"Rendering backend option",
			},
		)
		ui.list_row_bg_at(frame, rect, row.selected, row.hovered)
		if row.activated do state.list_activated = i
		ui.text(frame, label, x + ui.ui_frame_sc(frame, 8), y + ui.ui_frame_sc(frame, 4), .Label)
		y += step
	}
	ui.listbox_end(frame, &state.listbox)
	if result.activated do state.list_activated = result.activated_index
	if state.list_activated >= 0 {
		assert(state.list_activated < len(labels), "draw_widget_backend_list: invalid index")
		ui.text(
			frame,
			fmt.tprintf("activated: %s", labels[state.list_activated]),
			x,
			y,
			.Label,
			.Secondary,
		)
		y += step
	}
	return y + ui.ui_frame_sc(frame, 8)
}

draw_widget_truncation_card :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(frame, {x, y0, w, 0}, "CARD + SHADOW + TRUNCATION")
	card := ui.Rect_I32{x, y, min(w, ui.ui_frame_sc(frame, 360)), ui.ui_frame_sc(frame, 64)}
	shadow := ui.Rect{f32(card.x), f32(card.y), f32(card.w), f32(card.h)}
	ui.draw_shadow_hard(frame, shadow, .MD, .Lifted)
	ui.card_bg_at(
		frame,
		card,
		ui.ui_frame_theme(frame).bg_secondary,
		accent_w = ui.ui_frame_sc(frame, 3),
	)
	ui.draw_text_truncated_frame(
		frame,
		"A very long label that will be cut with an ellipsis when it overflows the card",
		x + ui.ui_frame_sc(frame, 12),
		y + ui.ui_frame_sc(frame, 12),
		card.w - ui.ui_frame_sc(frame, 24),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_primary,
	)
	path := ui.truncate_path_middle_frame(
		frame,
		"ingot/examples/gallery/very/deep/dir/main.odin",
		card.w - ui.ui_frame_sc(frame, 24),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
	)
	ui.text(
		frame,
		path,
		x + ui.ui_frame_sc(frame, 12),
		y + ui.ui_frame_sc(frame, 34),
		.Label,
		.Secondary,
	)
	return y + card.h + ui.ui_frame_sc(frame, 16)
}

draw_widget_fit_card :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(frame, {x, y0, w, 0}, "FIT-CONTENT CARD")
	fit_w := min(w, ui.ui_frame_sc(frame, 360))
	pad := ui.ui_frame_sc(frame, 12)
	column: ui.Fit_Column
	ui.fit_column_begin(&column, x + pad, y + pad, fit_w - pad * 2, gap = ui.ui_frame_sc(frame, 6))
	title := ui.fit_column_next(&column, ui.ui_frame_sc(frame, 18))
	detail := ui.fit_column_next(&column, ui.ui_frame_sc(frame, 18))
	content := ui.fit_column_end(&column)
	card := ui.Rect_I32{x, y, fit_w, content.h + pad * 2}
	ui.card_bg_at(frame, card, ui.ui_frame_theme(frame).bg_secondary)
	ui.text(frame, "Geometry resolved before drawing", title.x, title.y, .Label)
	ui.text(frame, "No retained tree or trailing gap", detail.x, detail.y, .Label, .Secondary)
	return y + card.h + ui.ui_frame_sc(frame, 16)
}

draw_widgets :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	state := &widget_state
	y := draw_widget_form_controls(frame, x, y0, w, state)
	y = draw_widget_progress(frame, x, y, w, state)
	y = draw_widget_kv_rows(frame, x, y, w, state)
	y = draw_widget_backend_list(frame, x, y, w, state)
	y = draw_widget_tabs_table(frame, x, y, w, state)
	y = draw_widget_truncation_card(frame, x, y, w)
	return draw_widget_fit_card(frame, x, y, w)
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

WIDGET_TABLE_COLUMNS := [3]ui.Table_Column {
	{label = "Widget", track = {kind = .Grow, weight = 1}},
	{label = "Layer", track = {kind = .Fixed, basis = 150}},
	{label = "Procs", track = {kind = .Fixed, basis = 60}, numeric = true},
}

draw_widget_tabs_table :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_tabs_table: nil state")
	u := &state.data_ctx
	width := min(w, ui.ui_frame_sc(frame, 420))
	ui.begin(u, frame, {x, y0, width, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	ui.scope_begin(u, "data")

	_ = ui.section_header(u, "TAB BAR")
	tabs := []string{"Overview", "Details", "Logs"}
	_ = ui.tab_bar(u, "tabs", tabs, &state.tab_active)
	ui.label(
		u,
		fmt.tprintf("active tab: %s \u00b7 state is one caller-owned i32", tabs[state.tab_active]),
		ui.Text_Role.Label,
		ui.Ink.Secondary,
	)

	ui.space(u, .SM)
	_ = ui.section_header(u, "TABLE (click headers to sort)")
	columns := WIDGET_TABLE_COLUMNS[:]
	_ = ui.table_header(u, "table", columns, &state.table_sort)
	rows := slice.clone(WIDGET_TABLE_ROWS[:], context.temp_allocator)
	if state.table_sort.column >= 0 do slice.sort_by(rows, widget_table_less)
	row_h: i32 = 24
	tracks_buffer: [ui.TABLE_COLUMN_COUNT_MAX]ui.Track
	for row in rows {
		ui.flex_row_begin(u, row_h, ui.table_tracks(columns, tracks_buffer[:]), align = .Center)
		draw_widget_table_cell(frame, ui.flex_slot_next(u, row_h), row.widget, false)
		draw_widget_table_cell(frame, ui.flex_slot_next(u, row_h), row.layer, false)
		draw_widget_table_cell(
			frame,
			ui.flex_slot_next(u, row_h),
			fmt.tprintf("%d", row.procs),
			true,
		)
		ui.flex_row_end(u)
	}

	ui.scope_end(u)
	ui.space(u, .LG)
	return ui.end(u)
}

draw_widget_table_cell :: proc(
	frame: ^ui.Ui_Frame,
	rect: ui.Rect_I32,
	label: string,
	numeric: bool,
) {
	if rect.w <= 0 || rect.h <= 0 do return
	pad := ui.ui_frame_sc(frame, 4)
	text_x := rect.x + pad
	if numeric do text_x = rect.x + rect.w - ui.text_width(frame, label, .Label) - pad
	text_y := rect.y + (rect.h - ui.ui_frame_metrics(frame).FONT_SIZE_LABEL) / 2
	ui.text(frame, label, text_x, text_y, .Label)
}

draw_charts :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"LINE + BAR + SPARKLINE (hover for overlay tooltips)",
	)
	cw := min(w, ui.ui_frame_sc(frame, 560))
	series := [2]ui.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	ui.line_chart_at(
		frame,
		{x, y, cw, ui.ui_frame_sc(frame, 240)},
		series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	y += ui.ui_frame_sc(frame, 252)
	ui.bar_chart_at(
		frame,
		{x, y, cw, ui.ui_frame_sc(frame, 220)},
		series[:],
		&bar_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	y += ui.ui_frame_sc(frame, 232)
	ui.text(frame, "sparkline:", x, y + ui.ui_frame_sc(frame, 6), .Label, .Secondary)
	ui.sparkline_at(
		frame,
		{x + ui.ui_frame_sc(frame, 80), y, ui.ui_frame_sc(frame, 140), ui.ui_frame_sc(frame, 28)},
		spark[:],
	)
	return y + ui.ui_frame_sc(frame, 40)
}

draw_layout_demo :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"SINGLE-PASS LAYOUT (weights + flex + justify + flow)",
	)
	l: ui.Layout
	lw := min(w, ui.ui_frame_sc(frame, 520))
	ui.layout_begin(&l, x, y, lw, ui.ui_frame_sc(frame, 296), gap = ui.ui_frame_sc(frame, 8))

	ui.push_row(&l, ui.ui_frame_sc(frame, 40), gap = ui.ui_frame_sc(frame, 8))
	ui.row_weights(&l, {1, 2, 1})
	cell(frame, ui.next_weighted(&l, 1), "1fr")
	cell(frame, ui.next_weighted(&l, 2), "2fr")
	cell(frame, ui.next_weighted(&l, 1), "1fr")
	ui.layout_pop(&l)

	ui.push_row(&l, ui.ui_frame_sc(frame, 40), gap = ui.ui_frame_sc(frame, 8))
	cell(frame, ui.next(&l, ui.ui_frame_sc(frame, 120)), "fixed 120")
	cell(frame, ui.remaining(&l), "remaining")
	ui.layout_pop(&l)

	ui.push_row(
		&l,
		ui.ui_frame_sc(frame, 90),
		gap = ui.ui_frame_sc(frame, 8),
		cross_align = .Center,
	)
	cell(
		frame,
		ui.next_sized(&l, ui.ui_frame_sc(frame, 160), ui.ui_frame_sc(frame, 50)),
		"centered",
	)
	ui.layout_pop(&l)

	ui.push_row(&l, ui.ui_frame_sc(frame, 40), gap = ui.ui_frame_sc(frame, 8))
	ui.flex_begin(
		&l,
		{
			ui.fixed(ui.ui_frame_sc(frame, 72)),
			ui.fit(ui.ui_frame_sc(frame, 96), min_size = ui.ui_frame_sc(frame, 56)),
			ui.percent(0.2),
			ui.grow(),
		},
	)
	cell(frame, ui.flex_next(&l), "fixed")
	cell(frame, ui.flex_next(&l), "fit")
	cell(frame, ui.flex_next(&l), "20%")
	cell(frame, ui.flex_next(&l), "grow")
	ui.layout_pop(&l)

	// justify packs a declared run whose tracks leave free space; here the
	// leftover is distributed between three fixed cells.
	ui.push_row(&l, ui.ui_frame_sc(frame, 40), gap = ui.ui_frame_sc(frame, 8))
	ui.flex_begin(
		&l,
		{
			ui.fixed(ui.ui_frame_sc(frame, 90)),
			ui.fixed(ui.ui_frame_sc(frame, 90)),
			ui.fixed(ui.ui_frame_sc(frame, 90)),
		},
		justify = .Space_Between,
	)
	cell(frame, ui.flex_next(&l), "between")
	cell(frame, ui.flex_next(&l), "between")
	cell(frame, ui.flex_next(&l), "between")
	ui.layout_pop(&l)

	ui.layout_end(&l)
	flow_y := y + ui.ui_frame_sc(frame, 306)
	flow: ui.Flow_Layout
	ui.flow_begin(
		&flow,
		{x, flow_y, lw, max(i32) - flow_y},
		ui.ui_frame_sc(frame, 8),
		ui.ui_frame_sc(frame, 8),
	)
	labels := [?]string{"measured", "single pass", "caller owned", "bounded", "responsive flow"}
	for label in labels {
		width := ui.text_width(frame, label, .Label) + ui.ui_frame_sc(frame, 24)
		cell(frame, ui.flow_next(&flow, width, ui.ui_frame_sc(frame, 32)), label)
	}
	flow_bounds := ui.flow_end(&flow)
	return flow_bounds.y + flow_bounds.h + ui.ui_frame_sc(frame, 10)
}

cell :: proc(frame: ^ui.Ui_Frame, r: ui.Rect_I32, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	ui.draw_rectangle(frame, r.x, r.y, r.w, r.h, ui.ui_frame_theme(frame).bg_active)
	ui.draw_rectangle_lines(frame, r.x, r.y, r.w, r.h, ui.ui_frame_theme(frame).border_color)
	tw := ui.text_width(frame, label, .Label)
	ui.text(
		frame,
		label,
		r.x + (r.w - tw) / 2,
		r.y + (r.h - ui.ui_frame_metrics(frame).FONT_SIZE_LABEL) / 2,
		.Label,
		.Secondary,
	)
}

draw_overlay_controls :: proc(frame: ^ui.Ui_Frame, x, y: i32) -> i32 {
	// A two-column grid places the shielded stack and the action stack; no
	// call site does per-button x/y arithmetic and the columns stay aligned.
	gap := ui.ui_frame_sc(frame, 8)
	grid: ui.Grid
	ui.grid_begin(
		&grid,
		{x, y, ui.ui_frame_sc(frame, 340), 0},
		cols = 2,
		row_h = ui.ui_frame_sc(frame, 30),
		gap_x = gap,
		gap_y = gap,
	)
	if ui.button_at(frame, ui.grid_next(&grid), "Shielded 1") do shielded_clicks += 1
	if ui.button_at(frame, ui.grid_next(&grid), "Toggle popup", ui.Btn_Style.Primary) {
		popup_open = !popup_open
	}
	if ui.button_at(frame, ui.grid_next(&grid), "Shielded 2") do shielded_clicks += 1
	if ui.button_at(frame, ui.grid_next(&grid), "Open modal") {
		about_modal.open = true
	}
	if ui.button_at(frame, ui.grid_next(&grid), "Shielded 3") do shielded_clicks += 1
	if ui.button_at(frame, ui.grid_next(&grid), "Push toast") {
		toast_count += 1
		kind := ui.Toast_Kind(toast_count % 3)
		ui.toast_push(&toasts, kind, fmt.tprintf("Toast %d \u00b7 newest on top", toast_count))
	}
	// The shielded column has only three rows; skip its fourth cell so the
	// danger action stays in the action column.
	_ = ui.grid_next(&grid)
	if ui.button_at(frame, ui.grid_next(&grid), "Delete\u2026", ui.Btn_Style.Danger) {
		ui.confirm_dialog_open(&confirm)
	}
	content := ui.grid_end(&grid)
	info_y := content.y + content.h + gap
	summary := fmt.tprintf(
		"shielded clicks: %d (should not rise while the popup covers them)",
		shielded_clicks,
	)
	ui.text(frame, summary, x, info_y, .Label, .Secondary)
	return info_y
}

draw_overlay_context_menu :: proc(frame: ^ui.Ui_Frame, x, info_y: i32) {
	if ui.is_mouse_button_pressed(frame, .RIGHT) &&
	   !ctx_menu.open &&
	   !about_modal.open &&
	   !confirm.modal.open {
		mouse := ui.get_mouse_position(frame)
		ui.context_menu_open(&ctx_menu, i32(mouse.x), i32(mouse.y))
	}
	if ctx_menu.open {
		items := []ui.Menu_Item {
			{label = "Reset shielded clicks"},
			{label = "Unavailable action", disabled = true},
			{separator = true},
			{label = "Close menu"},
		}
		root := ui_gfx.app_screen_rect(&app)
		when CAPTURE do root = {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT}
		chosen := ui.context_menu(frame, &ctx_menu, items, root)
		if chosen == 0 {
			shielded_clicks = 0
			ctx_note = "shielded clicks reset via context menu"
		}
	}
	ui.draw_text_frame(
		frame,
		strings.clone_to_cstring(ctx_note, context.temp_allocator),
		x,
		info_y + ui.ui_frame_sc(frame, 22),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_label,
	)
}

draw_overlay_modal :: proc(frame: ^ui.Ui_Frame) {
	if !about_modal.open do return
	root := ui_gfx.app_screen_rect(&app)
	when CAPTURE do root = {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT}
	body := ui.modal_begin(
		frame,
		&about_modal,
		"Generic modal",
		{size = {ui.ui_frame_sc(frame, 420), ui.ui_frame_sc(frame, 190)}, screen = root},
	)
	ui.draw_text_wrapped_frame(
		frame,
		body.x + ui.ui_frame_metrics(frame).PADDING,
		body.y + ui.ui_frame_sc(frame, 4),
		body.w - ui.ui_frame_metrics(frame).PADDING * 2,
		"The settings panel is built on this same modal_begin/modal_end pair. " +
		"Escape or a click outside dismisses it.",
		ui.ui_frame_theme(frame).fg_primary,
		ui.ui_frame_metrics(frame).FONT_SIZE_BODY,
		ui.ui_frame_metrics(frame).LINE_HEIGHT,
	)
	if ui.button_at(
		frame,
		{
			body.x + ui.ui_frame_metrics(frame).PADDING,
			body.y + body.h - ui.ui_frame_sc(frame, 44),
			ui.ui_frame_sc(frame, 90),
			ui.ui_frame_sc(frame, 28),
		},
		"Close",
		ui.Btn_Style.Primary,
	) {
		about_modal.open = false
	}
	ui.modal_end(&about_modal)
}

draw_overlay_demo :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"OVERLAY + INPUT ROUTING (popup occludes the buttons under it)",
	)
	info_y := draw_overlay_controls(frame, x, y)
	draw_overlay_context_menu(frame, x, info_y)
	if popup_open {
		draw_demo_popup(frame, x - ui.ui_frame_sc(frame, 8), y - ui.ui_frame_sc(frame, 8))
	}
	draw_overlay_modal(frame)
	draw_overlay_confirm(frame)
	root := ui_gfx.app_screen_rect(&app)
	when CAPTURE do root = {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT}
	ui.toasts_draw(frame, &toasts, root)
	return info_y + ui.ui_frame_sc(frame, 52)
}

// draw_overlay_confirm runs the built-in confirm dialog and reports the
// outcome through a toast, chaining the two lifecycle widgets together.
draw_overlay_confirm :: proc(frame: ^ui.Ui_Frame) {
	if !confirm.modal.open do return
	root := ui_gfx.app_screen_rect(&app)
	when CAPTURE do root = {0, 0, CAPTURE_WIDTH, CAPTURE_HEIGHT}
	choice := ui.confirm_dialog(
		frame,
		&confirm,
		"Delete everything?",
		"confirm_dialog wraps the same modal pair; Escape or a click outside cancels.",
		"Delete",
		root,
	)
	switch choice {
	case .Confirmed:
		ui.toast_push(&toasts, .Error, "Deleted (nothing was actually deleted)")
	case .Canceled:
		ui.toast_push(&toasts, .Info, "Delete canceled")
	case .None:
	}
}

// draw_demo_popup records a popup on the overlay layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(frame: ^ui.Ui_Frame, x, y: i32) {
	w := ui.ui_frame_sc(frame, 220)
	h := ui.ui_frame_sc(frame, 130)
	rect := ui.Rect{f32(x), f32(y), f32(w), f32(h)}
	ui.overlay_begin(frame, rect, claim_input = true)
	ui.overlay_rounded(frame, rect, 0.1, 6, ui.ui_frame_theme(frame).bg_popup)
	ui.overlay_rounded_lines(frame, rect, 0.1, 6, 1.0, ui.ui_frame_theme(frame).border_color)
	ui.overlay_text(
		frame,
		"Overlay popup",
		x + ui.ui_frame_sc(frame, 12),
		y + ui.ui_frame_sc(frame, 10),
		ui.ui_frame_metrics(frame).FONT_SIZE_BODY,
		ui.ui_frame_theme(frame).fg_primary,
	)
	ui.overlay_text(
		frame,
		"Recorded during the frame,",
		x + ui.ui_frame_sc(frame, 12),
		y + ui.ui_frame_sc(frame, 36),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_secondary,
	)
	ui.overlay_text(
		frame,
		"replayed above everything.",
		x + ui.ui_frame_sc(frame, 12),
		y + ui.ui_frame_sc(frame, 54),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_secondary,
	)

	// Close row: the popup is topmost, so it hit-tests raw input.
	row := ui.Rect {
		f32(x + ui.ui_frame_sc(frame, 12)),
		f32(y + h - ui.ui_frame_sc(frame, 30)),
		f32(w - ui.ui_frame_sc(frame, 24)),
		f32(ui.ui_frame_sc(frame, 22)),
	}
	mouse := ui.get_mouse_position(frame)
	hovered := ui.point_in_rect(mouse, row)
	if hovered {
		ui.overlay_rect(frame, ui.Rect(row), ui.ui_frame_theme(frame).bg_active)
		ui.request_cursor(frame, .POINTING_HAND)
	}
	ui.overlay_text(
		frame,
		"Close",
		x + ui.ui_frame_sc(frame, 18),
		y + h - ui.ui_frame_sc(frame, 28),
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_accent,
	)
	if hovered && ui.is_mouse_button_released(frame, .LEFT) {
		popup_open = false
	}
	ui.overlay_end(frame)
}

// STRESS_BUTTONS is the grid size the section advertises. Every one of them is
// laid out and measured for the scroll range; only the on-screen rows are
// built and painted (see draw_stress).
STRESS_BUTTONS :: 1000

draw_stress :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	// The grid owns cell geometry: exact column division, no per-button math.
	cols := max(w / ui.ui_frame_sc(frame, 110), 1)
	gap := ui.ui_frame_sc(frame, 6)
	row_h := ui.ui_frame_sc(frame, 26)
	// The header's height does not depend on its text, so the grid's origin
	// is known before the label is built - which is what lets the label
	// report the drawn count.
	header_h := ui.ui_frame_metrics(frame).FONT_SIZE_LABEL + ui.ui_frame_sc(frame, 11)
	bounds := ui.Rect_I32{x, y0 + header_h, w, 0}
	// Only the rows intersecting the pane's cull band are built. Without this
	// the section constructs 1000 labels, measures and interacts with all of
	// them, and emits ~11 MB of vertex data per frame for the ~25 buttons on
	// screen - enough to exhaust the geometry stream on a phone.
	first, end := ui.grid_visible_range(
		bounds,
		cols,
		row_h,
		gap,
		STRESS_BUTTONS,
		frame.text_cull_top,
		frame.text_cull_bottom,
	)
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		fmt.tprintf(
			"STRESS: %d BUTTONS (batcher, hover-anim bound, culling: %d drawn)",
			STRESS_BUTTONS,
			end - first,
		),
	)
	assert(y == bounds.y, "draw_stress: header height mismatch")
	grid: ui.Grid
	ui.grid_begin(&grid, bounds, cols, row_h, gap, gap)
	ui.grid_skip_to(&grid, first)
	for i in first ..< end {
		label := fmt.tprintf("btn %d", i)
		if ui.button_at(frame, ui.grid_next(&grid), label) {
			stress_clicked = int(i)
		}
	}
	// Advance the cursor past the skipped tail so grid_end still measures the
	// full content height - the pane's scroll range depends on it.
	ui.grid_skip_to(&grid, STRESS_BUTTONS)
	content := ui.grid_end(&grid)
	y = content.y + content.h + ui.ui_frame_sc(frame, 10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		ui.text(frame, msg, x, y, .Label, .Secondary)
		y += ui.ui_frame_sc(frame, 24)
	}
	return y
}
