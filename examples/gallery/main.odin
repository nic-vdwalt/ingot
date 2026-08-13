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
//   - The gallery shell is a bounded fit.Custom surface because this catalogue
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
import "core:strings"
import fit "ingot:fit"
import legacy "ingot:fit"
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
gallery_root: fit.Rect_I32

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
palette_theme :: proc(value: Palette) -> legacy.Theme {
	switch value {
	case .Dark:
		return legacy.theme_dark()
	case .Light:
		return legacy.theme_light()
	case .Sketch_Warm:
		return legacy.theme_sketch_warm()
	case .Sketch_Grey:
		return legacy.theme_sketch_grey()
	case .High_Contrast:
		return legacy.theme_high_contrast()
	}
	return legacy.theme_dark()
}

content_pane: legacy.Pane
click_count := 0
headers_open := [3]bool{true, false, false}

Input_State :: struct {
	name:           legacy.legacy_input_box,
	pass:           legacy.legacy_input_box,
	notes:          legacy.legacy_input_box,
	combo:          legacy.legacy_combobox_state,
	combo_selected: u64,
	date:           legacy.legacy_date_picker_state,
	date_value:     legacy.legacy_calendar_date,
}

input_state: Input_State

progress_anim: f32
progress_frac: f32 = 0.35

line_state: legacy.legacy_chart_state
bar_state: legacy.legacy_chart_state
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
	slider:         legacy.legacy_slider_state,
	dd_selected:    i32,
	dropdown:       legacy.legacy_dropdown_state,
	tooltip:        legacy.legacy_tooltip_state,
	listbox:        legacy.legacy_listbox_state,
	list_selected:  int,
	list_activated: int,
	tab_active:     i32,
	table_sort:     legacy.legacy_table_sort,
}

widget_state := Widget_State {
	check_a = true,
	volume = 40,
	list_activated = -1,
	table_sort = {column = -1},
}

// Generic modal + context menu (Overlay section).
about_modal: legacy.legacy_modal_state
ctx_menu: legacy.legacy_context_menu_state
ctx_note := "right-click in this section for a context menu"

// Toasts + confirm dialog (Overlay section). Zero values are ready to use.
toasts: legacy.legacy_toast_state
confirm: legacy.legacy_confirm_dialog_state
toast_count := 0

popup_open := false
shielded_clicks := 0
leaked_clicks := 0

// Docked-panel-over-canvas journey. The canvas counters must not advance while
// the pointer is over the panel: that is the whole claim of z-ordered input.
dock_canvas_wheel := 0
dock_canvas_clicks := 0
dock_panel_clicks := 0
dock_panel_pane: legacy.Pane

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
	legacy.input_box_destroy(&state.name)
	legacy.input_box_destroy(&state.pass)
	legacy.input_box_destroy(&state.notes)
	legacy.combobox_state_destroy(&state.combo)
}

gallery_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	return {w = max(constraints.max_w, 1), h = max(constraints.max_h, 1)}
}

gallery_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	_ = userdata
	frame := cast(^legacy.Ui_Frame)fit.Surface_Frame(surface)
	gallery_frame(frame, {rect.x, rect.y, rect.w, rect.h})
	return false
}

gallery_build :: proc(builder: ^fit.Builder, userdata: rawptr) {
	_ = userdata
	fit.Column(builder)
	fit.Custom(
		builder,
		{measure = gallery_measure, render = gallery_render},
		{size = {width = fit.Grow(), height = fit.Grow()}},
	)
	fit.End(builder)
}

gallery_frame :: proc(frame: ^legacy.Ui_Frame, root: fit.Rect_I32) {
	gallery_root = root
	sw := root.w
	sh := root.h

	when SMOKE do smoke_step()
	when CAPTURE do capture_step()

	if legacy.is_key_pressed(frame, .F12) do debug_on = !debug_on

	header_h := legacy.ui_frame_metrics(frame).TAB_BAR_HEIGHT
	// One decision, taken in the parent and passed down (Tiger Style: push
	// ifs up). Below the breakpoint the sidebar would eat 170 of ~390
	// design units, so the nav becomes a horizontal strip instead.
	narrow := nav_uses_strip(frame, sw, sh - header_h)
	nav_h := draw_nav(frame, header_h, sw, sh, narrow)
	draw_content(frame, sw, header_h + nav_h, sh, narrow)

	if settings_open {
		res := legacy.draw_scale_settings_panel(frame, &settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		legacy.draw_debug_overlay(
			frame,
			sw - legacy.ui_frame_sc(frame, 290),
			header_h + legacy.ui_frame_sc(frame, 10),
		)
	}

	_ = legacy.draw_app_header(frame, "ingot gallery", sw)
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

nav_sidebar_min_height :: proc(frame: ^legacy.Ui_Frame) -> i32 {
	assert(frame != nil, "nav_sidebar_min_height: nil frame")
	return nav_sidebar_min_height_scale(f32(legacy.ui_frame_sc(frame, 1000)) / 1000)
}

nav_uses_strip :: proc(frame: ^legacy.Ui_Frame, width, available_height: i32) -> bool {
	assert(frame != nil, "nav_uses_strip: nil frame")
	scale := f32(legacy.ui_frame_sc(frame, 1000)) / 1000
	return nav_uses_strip_scale(scale, width, available_height)
}

// draw_nav renders the section switcher and returns the vertical space it
// consumed. Wide viewports get the sidebar (0 vertical space, it lives beside
// the content); narrow ones get a horizontal strip whose height the caller
// must subtract from the content area.
// Nav_Control is the set of non-section buttons both nav layouts carry. It
// exists so the sidebar and the narrow strip cannot disagree about which
// controls exist or what they do: an earlier revision duplicated these four
// as inline `if legacy.button(...)` blocks in each layout, and the strip silently
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
nav_control_activate :: proc(control: Nav_Control, frame: ^legacy.Ui_Frame) {
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
		settings_sel = legacy.settings_scale_preset_index(stored_scale)
	}
}

draw_nav :: proc(frame: ^legacy.Ui_Frame, top, sw, sh: i32, narrow: bool) -> i32 {
	assert(frame != nil, "draw_nav: nil frame")
	if narrow do return draw_nav_strip(frame, top, sw)
	w := legacy.ui_frame_sc(frame, NAV_W)
	theme := legacy.ui_frame_theme(frame)
	legacy.draw_rectangle(frame, 0, top, w, sh - top, theme.bg_secondary)
	legacy.draw_rectangle(frame, w - 1, top, 1, sh - top, theme.border_subtle)

	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {0, top, w, sh - top}, gap = .XS)
	legacy.padding(u, .SM)
	legacy.scope_begin(u, "navigation")
	legacy.label(u, "ingot gallery", legacy.legacy_text_role.Title)
	legacy.separator(u)
	for s in Section {
		style := legacy.legacy_btn_style.Primary if s == section else .Ghost
		legacy.flex_row_begin(u, NAV_SIDEBAR_ROW_H, {legacy.grow()})
		if legacy.button(u, SECTION_NAMES[s], SECTION_NAMES[s], style) {
			section = s
			legacy.pane_reset(&content_pane)
		}
		legacy.flex_row_end(u)
	}
	legacy.space(u, .SM)
	legacy.separator(u)
	for control in Nav_Control {
		legacy.flex_row_begin(u, NAV_SIDEBAR_ROW_H, {legacy.grow()})
		if legacy.button(u, NAV_CONTROL_IDS[control], nav_control_label(control, false)) {
			nav_control_activate(control, frame)
		}
		legacy.flex_row_end(u)
	}
	legacy.scope_end(u)
	legacy.end(u)
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
draw_nav_strip :: proc(frame: ^legacy.Ui_Frame, top, sw: i32) -> i32 {
	assert(frame != nil, "draw_nav_strip: nil frame")
	assert(sw > 0, "draw_nav_strip: empty viewport")
	theme := legacy.ui_frame_theme(frame)
	pad := legacy.ui_frame_sc(frame, 8)
	gap := legacy.ui_frame_sc(frame, 6)
	row_h := legacy.ui_frame_sc(frame, NAV_STRIP_ROW_H)
	// Section buttons wrap into as many rows as the width needs; the control
	// row always follows on its own line.
	cols := max((sw - pad * 2 + gap) / (legacy.ui_frame_sc(frame, NAV_STRIP_CELL_W) + gap), 1)
	rows := (i32(len(Section)) + cols - 1) / cols
	height := pad * 2 + rows * row_h + (rows - 1) * gap + gap + row_h

	legacy.draw_rectangle(frame, 0, top, sw, height, theme.bg_secondary)
	legacy.draw_rectangle(frame, 0, top + height - 1, sw, 1, theme.border_subtle)

	grid: legacy.Grid_State
	legacy.grid_begin(&grid, {pad, top + pad, sw - pad * 2, 0}, cols, row_h, gap, gap)
	for s in Section {
		style := legacy.legacy_btn_style.Primary if s == section else .Ghost
		if legacy.button_at(frame, legacy.grid_next(&grid), SECTION_NAMES[s], style) {
			section = s
			legacy.pane_reset(&content_pane)
		}
	}
	content := legacy.grid_end(&grid)

	// One cell per control, using the compact labels: four short words fit
	// where the sidebar's full sentences would not.
	controls: legacy.Grid_State
	legacy.grid_begin(
		&controls,
		{pad, content.y + content.h + gap, sw - pad * 2, 0},
		i32(len(Nav_Control)),
		row_h,
		gap,
		gap,
	)
	for control in Nav_Control {
		if legacy.button_at(frame, legacy.grid_next(&controls), nav_control_label(control, true)) {
			nav_control_activate(control, frame)
		}
	}
	_ = legacy.grid_end(&controls)
	return height
}

apply_gallery_theme :: proc(frame: ^legacy.Ui_Frame = nil) {
	// One lookup. High contrast used to be an override checked ahead of the
	// palette; folding it into the enum removed the branch along with the
	// force-clear that kept the two in step.
	//
	// reduced_motion stays separate because it genuinely is orthogonal: it
	// applies to every palette, including high contrast, and a user who needs
	// both must be able to have both.
	t := palette_theme(palette)
	t.reduced_motion = reduced_motion
	when CAPTURE {
		fit.Session_Set_Theme(&capture_session, t)
	} else {
		fit.Set_Theme(&app, t)
	}
	if frame != nil do legacy.request_redraw(frame)
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
draw_page_substrate :: proc(
	frame: ^legacy.Ui_Frame,
	pane: fit.Rect_I32,
	anchor: i32,
	narrow: bool,
) {
	assert(frame != nil, "draw_page_substrate: nil frame")
	theme := legacy.ui_frame_theme(frame)
	if theme.substrate.kind == .None do return

	// The texture runs from the content anchor to the bottom of the pane, so
	// it scrolls with the content rather than under it.
	height := pane.y + pane.h - anchor
	if height <= 0 do return
	region := fit.Rectangle{f32(pane.x), f32(anchor), f32(pane.w), f32(height)}

	switch theme.substrate.kind {
	case .None:
	// Handled above; listed so a new kind cannot be silently ignored.
	case .Ruled:
		legacy.draw_rule_lines(frame, region, color = theme.paper_rule)
	case .Grid, .Dots:
		spacing := legacy.ui_frame_metrics(frame).LINE_HEIGHT
		if legacy.dot_grid_fits(region, spacing) {
			legacy.draw_dot_grid(frame, region, spacing, theme.paper_rule)
		}
	case .Tooth:
		legacy.draw_paper_tooth(frame, region, theme.paper_tooth)
	}

	// The margin rule is now independent of the body indent, so a palette can
	// keep the reserved column without the exercise-book line down it.
	if theme.substrate.margin_rule && !narrow {
		page := fit.Rectangle{f32(pane.x), f32(pane.y), f32(pane.w), f32(pane.h)}
		legacy.draw_margin_rule(frame, page, MARGIN_INSET, theme.graphite)
	}
}

draw_content :: proc(frame: ^legacy.Ui_Frame, sw, top, sh: i32, narrow: bool) {
	// Narrow viewports have no sidebar to sit beside, so the content starts
	// at the left edge and takes the full width. The inner padding shrinks
	// too: 18+52 logical px of margin is a third of a phone's width.
	x := i32(0) if narrow else legacy.ui_frame_sc(frame, NAV_W)
	w := sw - x
	pane_rect := fit.Rect_I32{x, top, w, sh - top}
	y := legacy.pane_begin(
		frame,
		&content_pane,
		pane_rect,
		pad = 14,
		keyboard = section != .Inputs,
	)
	draw_page_substrate(frame, pane_rect, y, narrow)
	inset := legacy.ui_frame_sc(frame, 8 if narrow else 18)
	gutter := legacy.ui_frame_sc(frame, 20 if narrow else 52)
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
		md_ctx := legacy.markdown_context(frame)
		end_y =
			legacy.markdown_draw(
				&md_ctx,
				{cx, y, cw, 0},
				MARKDOWN_SAMPLE,
				legacy.ui_frame_theme(frame).fg_primary,
			) +
			y
		// ui reports the click; the application decides what a link means.
		// That split is forced by the API layers - ui imports only core:* and
		// cannot reach sys - and it is also correct: an application may route
		// a relative target internally rather than hand it to a browser.
		if url, activated := legacy.markdown_link_activated(&md_ctx); activated {
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
	legacy.pane_end(frame, &content_pane, pane_rect, end_y, pad = 14)
}

draw_section_layer :: proc(frame: ^legacy.Ui_Frame, x, y, w: i32) -> i32 {
	assert(frame != nil, "draw_section_layer: nil frame")
	// Exactly two rule-heights tall. Every section below this band inherits
	// its starting y from here, so a band of some other height would push all
	// of them a fraction of a line off the ruled paper. Two lines is also what
	// the previous hardcoded 44 logical px happened to be, so nothing moves on
	// the unruled palettes.
	band := legacy.ui_frame_metrics(frame).LINE_HEIGHT * 2
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {x, y, w, band}, gap = .XS)
	legacy.row_begin(u, 28, gap = .SM, align = .Center)
	_ = legacy.status_pill(u, SECTION_LAYERS[section], legacy.legacy_ink.Accent)
	legacy.label(
		u,
		SECTION_AXES[section],
		legacy.legacy_text_role.Body,
		legacy.legacy_ink.Secondary,
	)
	legacy.row_end(u)
	_ = legacy.end(u)
	return y + band
}

draw_buttons :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_buttons: nil frame")
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {x, y0, w, legacy.ROOT_EXTENT_OPEN}, gap = .SM)
	legacy.scope_begin(u, "buttons")
	_ = legacy.section_header(u, "BUTTON STYLES")
	legacy.row_begin(u, 32, gap = .SM)
	if legacy.button(u, "primary", "Primary", legacy.legacy_btn_style.Primary) do click_count += 1
	if legacy.button(u, "secondary", "Secondary", legacy.legacy_btn_style.Secondary) {
		click_count += 1
	}
	if legacy.button(u, "danger", "Danger", legacy.legacy_btn_style.Danger) do click_count += 1
	if legacy.button(u, "ghost", "Ghost", legacy.legacy_btn_style.Ghost) do click_count += 1
	legacy.row_end(u)
	legacy.row_begin(u, 32, gap = .SM)
	_ = legacy.button(u, "disabled", "Disabled", legacy.legacy_btn_style.Primary, false)
	if legacy.icon_btn(u, legacy.id(u, "close"), "\u2715") do click_count += 1
	if legacy.back_btn(u, legacy.id(u, "back"), "Back") do click_count += 1
	legacy.row_end(u)
	legacy.label(
		u,
		fmt.tprintf("clicks: %d", click_count),
		legacy.legacy_text_role.Body,
		legacy.legacy_ink.Secondary,
	)

	_ = legacy.section_header(u, "KEYBOARD FOCUS (Tab cycles, Space/Enter activates)")
	legacy.row_begin(u, 32, gap = .SM)
	for i in 0 ..< 3 {
		label := fmt.tprintf("Focusable %d", i + 1)
		if legacy.button(u, u64(i + 1), label) do click_count += 1
	}
	legacy.row_end(u)

	_ = legacy.section_header(u, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := fmt.tprintf("Section %d", i + 1)
		_ = legacy.collapsible_header(
			u,
			legacy.id(u, fmt.tprintf("header:%d", i)),
			label,
			&headers_open[i],
			{icon = 0x25C6, right_label = "Details"},
		)
		if headers_open[i] {
			legacy.label(
				u,
				"Collapsed state is caller-owned.",
				legacy.legacy_text_role.Body,
				legacy.legacy_ink.Secondary,
			)
		}
	}
	legacy.scope_end(u)
	legacy.space(u, .LG)
	return legacy.end(u)
}

draw_inputs :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, legacy.ui_frame_sc(frame, 420))

	state := &input_state
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {x, y, iw, legacy.ROOT_EXTENT_OPEN}, gap = .SM)
	// One scope per section: identity is composed, never hand-numbered, so
	// adding or reordering a field cannot move focus to a different control.
	legacy.scope_begin(u, "inputs")
	legacy.text_input(
		u,
		legacy.id(u, "name"),
		&state.name,
		"Your name (undo, selection, spellcheck)",
		semantics = legacy.legacy_text_input_semantics{name = "Name"},
	)
	legacy.text_input(
		u,
		legacy.id(u, "password"),
		&state.pass,
		"Password (masked)",
		masked = true,
		semantics = legacy.legacy_text_input_semantics{name = "Password"},
	)
	legacy.text_input(
		u,
		legacy.id(u, "notes"),
		&state.notes,
		"Notes\u2026 (multi-line: Enter for newlines)",
		height = 90,
		semantics = legacy.legacy_text_input_semantics{name = "Notes"},
	)

	if legacy.button(u, legacy.id(u, "reset"), "Reset all") {
		legacy.input_box_reset(&state.name)
		legacy.input_box_reset(&state.pass)
		legacy.input_box_reset(&state.notes)
	}
	legacy.space(u, .XS)

	summary := fmt.tprintf(
		"name: %q \u00b7 notes: %d bytes",
		legacy.input_box_text(&state.name),
		len(legacy.input_box_text(&state.notes)),
	)
	legacy.label(u, summary, legacy.legacy_text_role.Label, legacy.legacy_ink.Secondary)

	legacy.space(u, .SM)
	_ = legacy.section_header(u, "COMBOBOX (type to filter) + DATE PICKER")
	languages := []legacy.legacy_combobox_item {
		{1, "Odin"},
		{2, "C"},
		{3, "Zig"},
		{4, "Rust"},
		{5, "Go"},
		{6, "Hare"},
	}
	_ = legacy.combobox(
		u,
		"language",
		&state.combo,
		languages,
		&state.combo_selected,
		"Language\u2026",
		"Language",
	)
	_ = legacy.date_picker(
		u,
		"release",
		&state.date,
		&state.date_value,
		"Release date\u2026",
		"Release date",
	)
	date_text := "unset"
	if legacy.calendar_date_valid(state.date_value) {
		date_text = legacy.calendar_format(state.date_value)
	}
	picked := fmt.tprintf("language id: %d \u00b7 date: %s", state.combo_selected, date_text)
	legacy.label(u, picked, legacy.legacy_text_role.Label, legacy.legacy_ink.Secondary)

	legacy.scope_end(u)
	legacy.space(u, .XL)
	return legacy.end(u)
}

draw_widget_choices :: proc(u: ^legacy.Ui, state: ^Widget_State) {
	assert(u != nil, "draw_widget_choices: nil UI")
	assert(state != nil, "draw_widget_choices: nil state")
	legacy.row_begin(u, 32, gap = .SM)
	legacy.checkbox(u, legacy.id(u, "enable"), "Enable widgets", &state.check_a)
	legacy.checkbox(u, legacy.id(u, "verbose"), "Verbose logs", &state.check_b)
	legacy.row_end(u)
	legacy.row_begin(u, 32, gap = .SM)
	legacy.radio(u, legacy.id(u, "small"), "Small", &state.radio_choice, 0)
	legacy.radio(u, legacy.id(u, "medium"), "Medium", &state.radio_choice, 1)
	legacy.radio(u, legacy.id(u, "large"), "Large", &state.radio_choice, 2)
	legacy.row_end(u)
}

draw_widget_volume :: proc(u: ^legacy.Ui, frame: ^legacy.Ui_Frame, state: ^Widget_State) {
	assert(u != nil, "draw_widget_volume: nil UI")
	assert(frame != nil, "draw_widget_volume: nil frame")
	assert(state != nil, "draw_widget_volume: nil state")
	legacy.row_begin(u, 32, gap = .SM)
	_ = legacy.slider_state(
		u,
		legacy.id(u, "volume"),
		&state.slider,
		&state.volume,
		0,
		100,
		5,
		240,
		"Volume",
	)
	legacy.label(
		u,
		fmt.tprintf("%.0f%%", state.volume),
		legacy.legacy_text_role.Body,
		legacy.legacy_ink.Secondary,
	)
	legacy.row_end(u)
}

draw_widget_form_controls :: proc(
	frame: ^legacy.Ui_Frame,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_form_controls: nil state")
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"FORM CONTROLS (checkbox / radio / slider / dropdown)",
	)
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {x, y, w, legacy.ROOT_EXTENT_OPEN}, gap = .SM)
	legacy.scope_begin(u, "form")
	draw_widget_choices(u, state)
	draw_widget_volume(u, frame, state)
	backends := []string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	legacy.dropdown(
		u,
		legacy.id(u, "backend"),
		backends,
		&state.dd_selected,
		&state.dropdown,
		a11y_label = "Graphics backend",
	)
	legacy.scope_end(u)
	legacy.space(u, .MD)
	return legacy.end(u)
}

// The progress / spinner / pill section is pure facade: every widget carves
// its own slot from a Ui, so no call site does arithmetic on x/y/w/h.
draw_widget_progress :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_progress: nil state")
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(u, frame, {x, y0, w, legacy.ROOT_EXTENT_OPEN}, gap = .SM)
	legacy.scope_begin(u, "progress")
	_ = legacy.section_header(u, "PROGRESS / SPINNER / PILLS")

	legacy.row_begin(u, 34, gap = .MD, align = .Start)
	legacy.spinner(u, 28)
	legacy.spinner(u, 20, {style = .Orbit_Dots, dot_radius = 2.5, speed = 6})
	_ = legacy.status_pill(u, "active", legacy.legacy_ink.Success)
	_ = legacy.status_pill(u, "warning", legacy.legacy_ink.Tool)
	_ = legacy.status_pill(u, "error", legacy.legacy_ink.Danger)
	legacy.row_end(u)

	legacy.progress_bar(u, 0.65)
	legacy.progress_bar_animated(u, progress_frac, &progress_anim, legacy.legacy_ink.Success)

	legacy.row_begin(u, 30, gap = .SM, align = .Start)
	if legacy.button(u, legacy.id(u, "replay"), "Replay") do progress_anim = 0
	legacy.row_end(u)

	legacy.scope_end(u)
	legacy.space(u, .LG)
	return legacy.end(u)
}

// The key/value rows are facade too: kv_row spans the container width, so the
// caller never measures the value to right-align it, and the default inks are
// the muted-key / emphasized-value pairing.
draw_widget_kv_rows :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_kv_rows: nil state")
	u_storage: legacy.Ui
	u := &u_storage
	width := min(w, legacy.ui_frame_sc(frame, 360))
	legacy.begin(u, frame, {x, y0, width, legacy.ROOT_EXTENT_OPEN}, gap = .XS)
	_ = legacy.section_header(u, "KV ROWS + LIST ROWS")
	legacy.kv_row(u, "Renderer", "WebGPU")
	legacy.kv_row(u, "State model", "caller-owned")
	legacy.space(u, .SM)
	return legacy.end(u)
}

draw_widget_backend_list :: proc(
	frame: ^legacy.Ui_Frame,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_backend_list: nil state")
	y := y0
	labels := [?]string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	width := min(w, legacy.ui_frame_sc(frame, 360))
	step := legacy.ui_frame_sc(frame, 26)
	config := legacy.legacy_listbox_config {
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
	result := legacy.listbox_begin(frame, &state.listbox, config)
	for label, i in labels {
		rect := fit.Rect_I32{x, y, width, legacy.ui_frame_sc(frame, 24)}
		row := legacy.selectable_row(
			frame,
			&state.listbox,
			config,
			{
				{x, y, width, legacy.ui_frame_sc(frame, 24)},
				label,
				fmt.tprintf("gallery:backend:%d", i),
				i,
				false,
				"Rendering backend option",
			},
		)
		legacy.list_row_bg_at(frame, rect, row.selected, row.hovered)
		if row.activated do state.list_activated = i
		legacy.text(
			frame,
			label,
			x + legacy.ui_frame_sc(frame, 8),
			y + legacy.ui_frame_sc(frame, 4),
			.Label,
		)
		y += step
	}
	legacy.listbox_end(frame, &state.listbox)
	if result.activated do state.list_activated = result.activated_index
	if state.list_activated >= 0 {
		assert(state.list_activated < len(labels), "draw_widget_backend_list: invalid index")
		legacy.text(
			frame,
			fmt.tprintf("activated: %s", labels[state.list_activated]),
			x,
			y,
			.Label,
			.Secondary,
		)
		y += step
	}
	return y + legacy.ui_frame_sc(frame, 8)
}

draw_widget_truncation_card :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(frame, {x, y0, w, 0}, "CARD + SHADOW + TRUNCATION")
	card := fit.Rect_I32 {
		x,
		y,
		min(w, legacy.ui_frame_sc(frame, 360)),
		legacy.ui_frame_sc(frame, 64),
	}
	shadow := legacy.legacy_rect{f32(card.x), f32(card.y), f32(card.w), f32(card.h)}
	legacy.draw_shadow_hard(frame, shadow, .MD, .Lifted)
	legacy.card_bg_at(
		frame,
		card,
		legacy.ui_frame_theme(frame).bg_secondary,
		accent_w = legacy.ui_frame_sc(frame, 3),
	)
	legacy.draw_text_truncated_frame(
		frame,
		"A very long label that will be cut with an ellipsis when it overflows the card",
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 12),
		card.w - legacy.ui_frame_sc(frame, 24),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		legacy.ui_frame_theme(frame).fg_primary,
	)
	path := legacy.truncate_path_middle_frame(
		frame,
		"ingot/examples/gallery/very/deep/dir/main.odin",
		card.w - legacy.ui_frame_sc(frame, 24),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
	)
	legacy.text(
		frame,
		path,
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 34),
		.Label,
		.Secondary,
	)
	return y + card.h + legacy.ui_frame_sc(frame, 16)
}

draw_widget_fit_card :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(frame, {x, y0, w, 0}, "FIT-CONTENT CARD")
	fit_w := min(w, legacy.ui_frame_sc(frame, 360))
	pad := legacy.ui_frame_sc(frame, 12)
	column: legacy.Fit_Column
	legacy.fit_column_begin(
		&column,
		x + pad,
		y + pad,
		fit_w - pad * 2,
		gap = legacy.ui_frame_sc(frame, 6),
	)
	title := legacy.fit_column_next(&column, legacy.ui_frame_sc(frame, 18))
	detail := legacy.fit_column_next(&column, legacy.ui_frame_sc(frame, 18))
	content := legacy.fit_column_end(&column)
	card := fit.Rect_I32{x, y, fit_w, content.h + pad * 2}
	legacy.card_bg_at(frame, card, legacy.ui_frame_theme(frame).bg_secondary)
	legacy.text(frame, "Geometry resolved before drawing", title.x, title.y, .Label)
	legacy.text(frame, "No retained tree or trailing gap", detail.x, detail.y, .Label, .Secondary)
	return y + card.h + legacy.ui_frame_sc(frame, 16)
}

draw_widgets :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
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

WIDGET_TABLE_COLUMNS := [3]legacy.legacy_table_column {
	{label = "Widget", track = {kind = .Grow, weight = 1}},
	{label = "Layer", track = {kind = .Fixed, basis = 150}},
	{label = "Procs", track = {kind = .Fixed, basis = 60}, numeric = true},
}

draw_widget_tabs_table :: proc(
	frame: ^legacy.Ui_Frame,
	x, y0, w: i32,
	state: ^Widget_State,
) -> i32 {
	assert(state != nil, "draw_widget_tabs_table: nil state")
	u_storage: legacy.Ui
	u := &u_storage
	width := min(w, legacy.ui_frame_sc(frame, 420))
	legacy.begin(u, frame, {x, y0, width, legacy.ROOT_EXTENT_OPEN}, gap = .SM)
	legacy.scope_begin(u, "data")

	_ = legacy.section_header(u, "TAB BAR")
	tabs := []string{"Overview", "Details", "Logs"}
	_ = legacy.tab_bar(u, "tabs", tabs, &state.tab_active)
	legacy.label(
		u,
		fmt.tprintf("active tab: %s \u00b7 state is one caller-owned i32", tabs[state.tab_active]),
		legacy.legacy_text_role.Label,
		legacy.legacy_ink.Secondary,
	)

	legacy.space(u, .SM)
	_ = legacy.section_header(u, "TABLE (click headers to sort)")
	columns := WIDGET_TABLE_COLUMNS[:]
	_ = legacy.table_header(u, "table", columns, &state.table_sort)
	rows := slice.clone(WIDGET_TABLE_ROWS[:], context.temp_allocator)
	if state.table_sort.column >= 0 do slice.sort_by(rows, widget_table_less)
	row_h: i32 = 24
	tracks_buffer: [legacy.TABLE_COLUMN_COUNT_MAX]legacy.legacy_track
	for row in rows {
		legacy.flex_row_begin(
			u,
			row_h,
			legacy.table_tracks(columns, tracks_buffer[:]),
			align = .Center,
		)
		draw_widget_table_cell(frame, legacy.flex_slot_next(u, row_h), row.widget, false)
		draw_widget_table_cell(frame, legacy.flex_slot_next(u, row_h), row.layer, false)
		draw_widget_table_cell(
			frame,
			legacy.flex_slot_next(u, row_h),
			fmt.tprintf("%d", row.procs),
			true,
		)
		legacy.flex_row_end(u)
	}

	legacy.scope_end(u)
	legacy.space(u, .LG)
	return legacy.end(u)
}

draw_widget_table_cell :: proc(
	frame: ^legacy.Ui_Frame,
	rect: fit.Rect_I32,
	label: string,
	numeric: bool,
) {
	if rect.w <= 0 || rect.h <= 0 do return
	pad := legacy.ui_frame_sc(frame, 4)
	text_x := rect.x + pad
	if numeric do text_x = rect.x + rect.w - legacy.text_width(frame, label, .Label) - pad
	text_y := rect.y + (rect.h - legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL) / 2
	legacy.text(frame, label, text_x, text_y, .Label)
}

draw_charts :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"LINE + BAR + SPARKLINE (hover for overlay tooltips)",
	)
	cw := min(w, legacy.ui_frame_sc(frame, 560))
	series := [2]legacy.legacy_chart_series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	legacy.line_chart_at(
		frame,
		{x, y, cw, legacy.ui_frame_sc(frame, 240)},
		series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	y += legacy.ui_frame_sc(frame, 252)
	legacy.bar_chart_at(
		frame,
		{x, y, cw, legacy.ui_frame_sc(frame, 220)},
		series[:],
		&bar_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	y += legacy.ui_frame_sc(frame, 232)
	legacy.text(frame, "sparkline:", x, y + legacy.ui_frame_sc(frame, 6), .Label, .Secondary)
	legacy.sparkline_at(
		frame,
		{
			x + legacy.ui_frame_sc(frame, 80),
			y,
			legacy.ui_frame_sc(frame, 140),
			legacy.ui_frame_sc(frame, 28),
		},
		spark[:],
	)
	return y + legacy.ui_frame_sc(frame, 40)
}

draw_layout_demo :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"SINGLE-PASS LAYOUT (weights + flex + justify + flow)",
	)
	l: legacy.Layout
	lw := min(w, legacy.ui_frame_sc(frame, 520))
	legacy.layout_begin(
		&l,
		x,
		y,
		lw,
		legacy.ui_frame_sc(frame, 296),
		gap = legacy.ui_frame_sc(frame, 8),
	)

	legacy.push_row(&l, legacy.ui_frame_sc(frame, 40), gap = legacy.ui_frame_sc(frame, 8))
	legacy.row_weights(&l, {1, 2, 1})
	cell(frame, legacy.next_weighted(&l, 1), "1fr")
	cell(frame, legacy.next_weighted(&l, 2), "2fr")
	cell(frame, legacy.next_weighted(&l, 1), "1fr")
	legacy.layout_pop(&l)

	legacy.push_row(&l, legacy.ui_frame_sc(frame, 40), gap = legacy.ui_frame_sc(frame, 8))
	cell(frame, legacy.next(&l, legacy.ui_frame_sc(frame, 120)), "fixed 120")
	cell(frame, legacy.remaining(&l), "remaining")
	legacy.layout_pop(&l)

	legacy.push_row(
		&l,
		legacy.ui_frame_sc(frame, 90),
		gap = legacy.ui_frame_sc(frame, 8),
		cross_align = .Center,
	)
	cell(
		frame,
		legacy.next_sized(&l, legacy.ui_frame_sc(frame, 160), legacy.ui_frame_sc(frame, 50)),
		"centered",
	)
	legacy.layout_pop(&l)

	legacy.push_row(&l, legacy.ui_frame_sc(frame, 40), gap = legacy.ui_frame_sc(frame, 8))
	legacy.flex_begin(
		&l,
		{
			legacy.fixed(legacy.ui_frame_sc(frame, 72)),
			legacy.fit(legacy.ui_frame_sc(frame, 96), min_size = legacy.ui_frame_sc(frame, 56)),
			legacy.percent(0.2),
			legacy.grow(),
		},
	)
	cell(frame, legacy.flex_next(&l), "fixed")
	cell(frame, legacy.flex_next(&l), "fit")
	cell(frame, legacy.flex_next(&l), "20%")
	cell(frame, legacy.flex_next(&l), "grow")
	legacy.layout_pop(&l)

	// justify packs a declared run whose tracks leave free space; here the
	// leftover is distributed between three fixed cells.
	legacy.push_row(&l, legacy.ui_frame_sc(frame, 40), gap = legacy.ui_frame_sc(frame, 8))
	legacy.flex_begin(
		&l,
		{
			legacy.fixed(legacy.ui_frame_sc(frame, 90)),
			legacy.fixed(legacy.ui_frame_sc(frame, 90)),
			legacy.fixed(legacy.ui_frame_sc(frame, 90)),
		},
		justify = .Space_Between,
	)
	cell(frame, legacy.flex_next(&l), "between")
	cell(frame, legacy.flex_next(&l), "between")
	cell(frame, legacy.flex_next(&l), "between")
	legacy.layout_pop(&l)

	legacy.layout_end(&l)
	flow_y := y + legacy.ui_frame_sc(frame, 306)
	flow: legacy.Flow_Layout
	legacy.flow_begin(
		&flow,
		{x, flow_y, lw, max(i32) - flow_y},
		legacy.ui_frame_sc(frame, 8),
		legacy.ui_frame_sc(frame, 8),
	)
	labels := [?]string{"measured", "single pass", "caller owned", "bounded", "responsive flow"}
	for label in labels {
		width := legacy.text_width(frame, label, .Label) + legacy.ui_frame_sc(frame, 24)
		cell(frame, legacy.flow_next(&flow, width, legacy.ui_frame_sc(frame, 32)), label)
	}
	flow_bounds := legacy.flow_end(&flow)
	return flow_bounds.y + flow_bounds.h + legacy.ui_frame_sc(frame, 10)
}

cell :: proc(frame: ^legacy.Ui_Frame, r: fit.Rect_I32, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	legacy.draw_rectangle(frame, r.x, r.y, r.w, r.h, legacy.ui_frame_theme(frame).bg_active)
	legacy.draw_rectangle_lines(
		frame,
		r.x,
		r.y,
		r.w,
		r.h,
		legacy.ui_frame_theme(frame).border_color,
	)
	tw := legacy.text_width(frame, label, .Label)
	legacy.text(
		frame,
		label,
		r.x + (r.w - tw) / 2,
		r.y + (r.h - legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL) / 2,
		.Label,
		.Secondary,
	)
}

draw_overlay_controls :: proc(frame: ^legacy.Ui_Frame, x, y: i32) -> i32 {
	// A two-column grid places the shielded stack and the action stack; no
	// call site does per-button x/y arithmetic and the columns stay aligned.
	gap := legacy.ui_frame_sc(frame, 8)
	grid: legacy.Grid_State
	legacy.grid_begin(
		&grid,
		{x, y, legacy.ui_frame_sc(frame, 340), 0},
		cols = 2,
		row_h = legacy.ui_frame_sc(frame, 30),
		gap_x = gap,
		gap_y = gap,
	)
	if legacy.button_at(frame, legacy.grid_next(&grid), "Shielded 1") do shielded_clicks += 1
	if legacy.button_at(
		frame,
		legacy.grid_next(&grid),
		"Toggle popup",
		legacy.legacy_btn_style.Primary,
	) {
		popup_open = !popup_open
	}
	if legacy.button_at(frame, legacy.grid_next(&grid), "Shielded 2") do shielded_clicks += 1
	if legacy.button_at(frame, legacy.grid_next(&grid), "Open modal") {
		about_modal.open = true
	}
	if legacy.button_at(frame, legacy.grid_next(&grid), "Shielded 3") do shielded_clicks += 1
	if legacy.button_at(frame, legacy.grid_next(&grid), "Push toast") {
		toast_count += 1
		kind := legacy.legacy_toast_kind(toast_count % 3)
		legacy.toast_push(&toasts, kind, fmt.tprintf("Toast %d \u00b7 newest on top", toast_count))
	}
	// The shielded column has only three rows; skip its fourth cell so the
	// danger action stays in the action column.
	_ = legacy.grid_next(&grid)
	if legacy.button_at(
		frame,
		legacy.grid_next(&grid),
		"Delete\u2026",
		legacy.legacy_btn_style.Danger,
	) {
		legacy.confirm_dialog_open(&confirm)
	}
	content := legacy.grid_end(&grid)
	info_y := content.y + content.h + gap
	summary := fmt.tprintf(
		"shielded clicks: %d (should not rise while the popup covers them)",
		shielded_clicks,
	)
	legacy.text(frame, summary, x, info_y, .Label, .Secondary)
	return info_y
}

draw_overlay_context_menu :: proc(frame: ^legacy.Ui_Frame, x, info_y: i32) {
	if legacy.is_mouse_button_pressed(frame, .RIGHT) &&
	   !ctx_menu.open &&
	   !about_modal.open &&
	   !confirm.modal.open {
		mouse := legacy.get_mouse_position(frame)
		legacy.context_menu_open(&ctx_menu, i32(mouse.x), i32(mouse.y))
	}
	if ctx_menu.open {
		items := []legacy.legacy_menu_item {
			{label = "Reset shielded clicks"},
			{label = "Unavailable action", disabled = true},
			{separator = true},
			{label = "Close menu"},
		}
		root := gallery_root
		chosen := legacy.context_menu(frame, &ctx_menu, items, root)
		if chosen == 0 {
			shielded_clicks = 0
			ctx_note = "shielded clicks reset via context menu"
		}
	}
	legacy.draw_text_frame(
		frame,
		strings.clone_to_cstring(ctx_note, context.temp_allocator),
		x,
		info_y + legacy.ui_frame_sc(frame, 22),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		legacy.ui_frame_theme(frame).fg_label,
	)
}

draw_overlay_modal :: proc(frame: ^legacy.Ui_Frame) {
	if !about_modal.open do return
	root := gallery_root
	body := legacy.modal_begin(
		frame,
		&about_modal,
		"Generic modal",
		{size = {legacy.ui_frame_sc(frame, 420), legacy.ui_frame_sc(frame, 190)}, screen = root},
	)
	legacy.draw_text_wrapped_frame(
		frame,
		body.x + legacy.ui_frame_metrics(frame).PADDING,
		body.y + legacy.ui_frame_sc(frame, 4),
		body.w - legacy.ui_frame_metrics(frame).PADDING * 2,
		"The settings panel is built on this same modal_begin/modal_end pair. " +
		"Escape or a click outside dismisses it.",
		legacy.ui_frame_theme(frame).fg_primary,
		legacy.ui_frame_metrics(frame).FONT_SIZE_BODY,
		legacy.ui_frame_metrics(frame).LINE_HEIGHT,
	)
	if legacy.button_at(
		frame,
		{
			body.x + legacy.ui_frame_metrics(frame).PADDING,
			body.y + body.h - legacy.ui_frame_sc(frame, 44),
			legacy.ui_frame_sc(frame, 90),
			legacy.ui_frame_sc(frame, 28),
		},
		"Close",
		legacy.legacy_btn_style.Primary,
	) {
		about_modal.open = false
	}
	legacy.modal_end(&about_modal)
}

draw_overlay_demo :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"OVERLAY + INPUT ROUTING (popup occludes the buttons under it)",
	)
	info_y := draw_overlay_controls(frame, x, y)
	info_y = draw_docked_panel_over_canvas(frame, x, info_y, w)
	draw_overlay_context_menu(frame, x, info_y)
	if popup_open {
		draw_demo_popup(frame, x - legacy.ui_frame_sc(frame, 8), y - legacy.ui_frame_sc(frame, 8))
	}
	draw_overlay_modal(frame)
	draw_overlay_confirm(frame)
	root := gallery_root
	legacy.toasts_draw(frame, &toasts, root)
	return info_y + legacy.ui_frame_sc(frame, 52)
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
draw_docked_panel_over_canvas :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_docked_panel_over_canvas: nil frame")
	assert(w >= 0, "draw_docked_panel_over_canvas: negative width")
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		"Z-ORDERED INPUT (canvas counters stay put under the docked panel)",
	)
	canvas_h := legacy.ui_frame_sc(frame, 150)
	panel_w := min(legacy.ui_frame_sc(frame, 190), w)
	canvas := fit.Rect_I32{x, y, w, canvas_h}
	panel := fit.Rect_I32{x + w - panel_w, y, panel_w, canvas_h}
	if w <= 0 || canvas_h <= 0 do return y

	theme := legacy.ui_frame_theme(frame)
	legacy.draw_surface(frame, legacy.rect_f32(canvas), .Panel, radius = .SM, border = .Hairline)

	// The canvas spans the full width and is drawn first, so the panel floats
	// over its right edge rather than sitting beside it.
	canvas_hit := legacy.interact(frame, legacy.rect_f32(canvas))
	if canvas_hit.hovered {
		wheel := legacy.get_wheel_move(frame)
		if wheel != 0 do dock_canvas_wheel += 1
	}
	if canvas_hit.clicked do dock_canvas_clicks += 1
	metrics := legacy.ui_frame_metrics(frame)
	legacy.draw_text_frame(
		frame,
		fmt.ctprintf("canvas wheel: %d", dock_canvas_wheel),
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 12),
		metrics.FONT_SIZE_BODY,
		theme.fg_primary,
	)
	legacy.draw_text_frame(
		frame,
		fmt.ctprintf("canvas clicks: %d", dock_canvas_clicks),
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 12) + metrics.LINE_HEIGHT,
		metrics.FONT_SIZE_BODY,
		theme.fg_primary,
	)
	legacy.draw_text_frame(
		frame,
		"wheel and click here, then over the panel",
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 12) + metrics.LINE_HEIGHT * 2,
		metrics.FONT_SIZE_NOTE,
		theme.fg_secondary,
	)

	draw_dock_panel(frame, panel)
	return y + canvas_h + legacy.ui_frame_sc(frame, 12)
}

// draw_dock_panel is the docked surface: one layer couples the claim, the
// paint tier, and screen-space drawing. Nothing here hit-tests raw input.
draw_dock_panel :: proc(frame: ^legacy.Ui_Frame, panel: fit.Rect_I32) {
	assert(frame != nil, "draw_dock_panel: nil frame")
	assert(panel.w > 0 && panel.h > 0, "draw_dock_panel: empty panel")
	legacy.draw_surface(frame, legacy.rect_f32(panel), .Panel, radius = .SM, border = .Hairline)
	legacy.layer_begin(frame, legacy.Z_PANEL, claim = legacy.rect_f32(panel))
	defer legacy.layer_end(frame)

	// A scroll pane inside the claim: pane_begin consults the router, so this
	// is the exact case that went dead when a panel claimed its own rect.
	content_y := legacy.pane_begin(frame, &dock_panel_pane, panel, pad = 10)
	u_storage: legacy.Ui
	u := &u_storage
	legacy.begin(
		u,
		frame,
		{
			panel.x + legacy.ui_frame_sc(frame, 10),
			content_y,
			panel.w - legacy.ui_frame_sc(frame, 24),
			legacy.ROOT_EXTENT_OPEN,
		},
		gap = .XS,
	)
	legacy.scope_begin(u, "dock-panel")
	legacy.label(u, "DOCKED PANEL", legacy.legacy_text_role.Label, legacy.legacy_ink.Heading)
	legacy.label(
		u,
		"Claims Z_PANEL over the canvas.",
		legacy.legacy_text_role.Note,
		legacy.legacy_ink.Secondary,
	)
	if legacy.button(u, "dock-a", "Panel button A") do dock_panel_clicks += 1
	if legacy.button(u, "dock-b", "Panel button B") do dock_panel_clicks += 1
	legacy.label(
		u,
		fmt.tprintf("panel clicks: %d", dock_panel_clicks),
		legacy.legacy_text_role.Body,
		legacy.legacy_ink.Primary,
	)
	for row in 0 ..< 8 {
		legacy.label(
			u,
			fmt.tprintf("scroll row %d", row),
			legacy.legacy_text_role.Note,
			legacy.legacy_ink.Secondary,
		)
	}
	legacy.scope_end(u)
	end_y := legacy.end(u)
	legacy.pane_end(frame, &dock_panel_pane, panel, end_y, pad = 10)
}

// draw_overlay_confirm runs the built-in confirm dialog and reports the
// outcome through a toast, chaining the two lifecycle widgets together.
draw_overlay_confirm :: proc(frame: ^legacy.Ui_Frame) {
	if !confirm.modal.open do return
	root := gallery_root
	choice := legacy.confirm_dialog(
		frame,
		&confirm,
		"Delete everything?",
		"confirm_dialog wraps the same modal pair; Escape or a click outside cancels.",
		"Delete",
		root,
	)
	switch choice {
	case .Confirmed:
		legacy.toast_push(&toasts, .Error, "Deleted (nothing was actually deleted)")
	case .Canceled:
		legacy.toast_push(&toasts, .Info, "Delete canceled")
	case .None:
	}
}

// draw_demo_popup records a popup on its own layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(frame: ^legacy.Ui_Frame, x, y: i32) {
	w := legacy.ui_frame_sc(frame, 220)
	h := legacy.ui_frame_sc(frame, 130)
	rect := legacy.legacy_rect{f32(x), f32(y), f32(w), f32(h)}
	legacy.layer_begin(frame, legacy.Z_POPUP, claim = rect)
	legacy.draw_rectangle_rounded(frame, rect, 0.1, 6, legacy.ui_frame_theme(frame).bg_popup)
	legacy.draw_rectangle_rounded_lines_ex(
		frame,
		rect,
		0.1,
		6,
		1.0,
		legacy.ui_frame_theme(frame).border_color,
	)
	legacy.draw_text_string(
		frame,
		"Overlay popup",
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 10),
		legacy.ui_frame_metrics(frame).FONT_SIZE_BODY,
		legacy.ui_frame_theme(frame).fg_primary,
	)
	legacy.draw_text_string(
		frame,
		"Recorded during the frame,",
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 36),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		legacy.ui_frame_theme(frame).fg_secondary,
	)
	legacy.draw_text_string(
		frame,
		"replayed above everything.",
		x + legacy.ui_frame_sc(frame, 12),
		y + legacy.ui_frame_sc(frame, 54),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		legacy.ui_frame_theme(frame).fg_secondary,
	)

	// Close row: the popup sits in its own Z_POPUP scope, so its own claim
	// does not occlude it and the ordinary interaction path applies.
	row := legacy.legacy_rect {
		f32(x + legacy.ui_frame_sc(frame, 12)),
		f32(y + h - legacy.ui_frame_sc(frame, 30)),
		f32(w - legacy.ui_frame_sc(frame, 24)),
		f32(legacy.ui_frame_sc(frame, 22)),
	}
	close := legacy.interact(frame, row)
	if close.hovered {
		legacy.draw_rectangle_rec(frame, row, legacy.ui_frame_theme(frame).bg_active)
		legacy.request_cursor(frame, .POINTING_HAND)
	}
	legacy.draw_text_string(
		frame,
		"Close",
		x + legacy.ui_frame_sc(frame, 18),
		y + h - legacy.ui_frame_sc(frame, 28),
		legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		legacy.ui_frame_theme(frame).fg_accent,
	)
	if close.clicked {
		popup_open = false
	}
	legacy.layer_end(frame)
}

// STRESS_BUTTONS is the grid size the section advertises. Every one of them is
// laid out and measured for the scroll range; only the on-screen rows are
// built and painted (see draw_stress).
STRESS_BUTTONS :: 1000

draw_stress :: proc(frame: ^legacy.Ui_Frame, x, y0, w: i32) -> i32 {
	// The grid owns cell geometry: exact column division, no per-button math.
	cols := max(w / legacy.ui_frame_sc(frame, 110), 1)
	gap := legacy.ui_frame_sc(frame, 6)
	row_h := legacy.ui_frame_sc(frame, 26)
	// The header's height does not depend on its text, so the grid's origin
	// is known before the label is built - which is what lets the label
	// report the drawn count.
	header_h := legacy.ui_frame_metrics(frame).FONT_SIZE_LABEL + legacy.ui_frame_sc(frame, 11)
	bounds := fit.Rect_I32{x, y0 + header_h, w, 0}
	// Only the rows intersecting the pane's cull band are built. Without this
	// the section constructs 1000 labels, measures and interacts with all of
	// them, and emits ~11 MB of vertex data per frame for the ~25 buttons on
	// screen - enough to exhaust the geometry stream on a phone.
	first, end := legacy.grid_visible_range(
		bounds,
		cols,
		row_h,
		gap,
		STRESS_BUTTONS,
		frame.text_cull_top,
		frame.text_cull_bottom,
	)
	y := legacy.section_header_at(
		frame,
		{x, y0, w, 0},
		fmt.tprintf(
			"STRESS: %d BUTTONS (batcher, hover-anim bound, culling: %d drawn)",
			STRESS_BUTTONS,
			end - first,
		),
	)
	assert(y == bounds.y, "draw_stress: header height mismatch")
	grid: legacy.Grid_State
	legacy.grid_begin(&grid, bounds, cols, row_h, gap, gap)
	legacy.grid_skip_to(&grid, first)
	for i in first ..< end {
		label := fmt.tprintf("btn %d", i)
		if legacy.button_at(frame, legacy.grid_next(&grid), label) {
			stress_clicked = int(i)
		}
	}
	// Advance the cursor past the skipped tail so grid_end still measures the
	// full content height - the pane's scroll range depends on it.
	legacy.grid_skip_to(&grid, STRESS_BUTTONS)
	content := legacy.grid_end(&grid)
	y = content.y + content.h + legacy.ui_frame_sc(frame, 10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		legacy.text(frame, msg, x, y, .Label, .Secondary)
		y += legacy.ui_frame_sc(frame, 24)
	}
	return y
}
