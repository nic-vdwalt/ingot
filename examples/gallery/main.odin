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
import "core:strings"
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
	Api_Relationships,
	Buttons,
	Inputs,
	Widgets,
	Charts,
	Markdown,
	Layout,
	Overlay,
	Stress,
}

SECTION_NAMES := [Section]string {
	.Api_Relationships = "API Relationships",
	.Buttons           = "Buttons",
	.Inputs            = "Inputs",
	.Widgets           = "Widgets",
	.Charts            = "Charts",
	.Markdown          = "Markdown",
	.Layout            = "Layout",
	.Overlay           = "Overlay",
	.Stress            = "Stress",
}

SECTION_LAYERS := [Section]string {
	.Api_Relationships = "RELATIONSHIP MAP",
	.Buttons           = "FACADE LEAVES",
	.Inputs            = "FACADE LEAVES",
	.Widgets           = "FACADE + COMPOSITION",
	.Charts            = "FACADE WRAPPER \u2192 EXPLICIT LEAF",
	.Markdown          = "EXPLICIT COMPOSITION",
	.Layout            = "APPLICATION-OWNED GEOMETRY",
	.Overlay           = "EXPLICIT LIFECYCLE",
	.Stress            = "APPLICATION-OWNED GEOMETRY",
}

SECTION_AXES := [Section]string {
	.Api_Relationships = "ownership \u00b7 delegation \u00b7 output",
	.Buttons           = "framework owns geometry",
	.Inputs            = "framework owns geometry",
	.Widgets           = "geometry and lifecycle owner",
	.Charts            = "delegation",
	.Markdown          = "measurement lifecycle",
	.Layout            = "application owns geometry",
	.Overlay           = "application owns lifecycle",
	.Stress            = "application owns geometry",
}

NAV_W :: 170

// --- caller-owned state (the whole point: no hidden library state) ----------

dark := true
high_contrast := false
reduced_motion := false
section := Section.Api_Relationships
debug_on := false

Api_Tree_Node :: struct {
	rect:   ui.Rect_I32,
	title:  string,
	detail: string,
	accent: ui.Color,
}

Api_Map_State :: struct {
	ui: ui.Ui,
}

nav_ui: ui.Ui
buttons_ui: ui.Ui
badge_ui: ui.Ui
api_map_state: Api_Map_State
content_pane: ui.Pane
click_count := 0
headers_open := [3]bool{true, false, false}

Input_State :: struct {
	ctx:   ui.Ui,
	name:  ui.Input_Box,
	pass:  ui.Input_Box,
	notes: ui.Input_Box,
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
}

widget_state := Widget_State {
	check_a        = true,
	volume         = 40,
	list_activated = -1,
}

// Generic modal + context menu (Overlay section).
about_modal: ui.Modal_State
ctx_menu: ui.Context_Menu_State
ctx_note := "right-click in this section for a context menu"

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
				target_fps = 60,
				event_waiting = !SMOKE,
				clear_color = {24, 26, 32, 255},
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
	draw_nav(frame, header_h, sh)
	draw_content(frame, sw, header_h, sh)

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

draw_nav :: proc(frame: ^ui.Ui_Frame, top, sh: i32) {
	assert(frame != nil, "draw_nav: nil frame")
	w := ui.ui_frame_sc(frame, NAV_W)
	theme := ui.ui_frame_theme(frame)
	ui.draw_rectangle(frame, 0, top, w, sh - top, theme.bg_secondary)
	ui.draw_rectangle(frame, w - 1, top, 1, sh - top, theme.border_subtle)

	u := &nav_ui
	ui.begin(u, frame, {0, top, w, sh - top}, gap = .XS)
	ui.padding(u, .SM)
	ui.scope_begin(u, "navigation")
	ui.label(u, "ingot gallery", ui.ui_frame_metrics(frame).FONT_SIZE_TITLE)
	ui.separator(u)
	for s in Section {
		style := ui.Btn_Style.Primary if s == section else .Ghost
		if ui.button(u, SECTION_NAMES[s], SECTION_NAMES[s], style) {
			section = s
			ui.pane_reset(&content_pane)
		}
	}
	ui.space(u, .SM)
	ui.separator(u)
	if ui.button(u, "theme", "Light theme" if dark else "Dark theme") {
		dark = !dark
		high_contrast = false
		apply_gallery_theme(frame)
	}
	if ui.button(u, "contrast", "Standard contrast" if high_contrast else "High contrast") {
		high_contrast = !high_contrast
		apply_gallery_theme(frame)
	}
	if ui.button(u, "motion", "Motion: reduced" if reduced_motion else "Motion: full") {
		reduced_motion = !reduced_motion
		apply_gallery_theme(frame)
	}
	if ui.button(u, "scale", "UI scale\u2026") {
		settings_open = true
		settings_sel = ui.settings_scale_preset_index(stored_scale)
	}
	ui.scope_end(u)
	ui.end(u)
}

apply_gallery_theme :: proc(frame: ^ui.Ui_Frame = nil) {
	t :=
		ui.theme_high_contrast() if high_contrast else (ui.theme_dark() if dark else ui.theme_light())
	t.reduced_motion = reduced_motion
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app), t)
	app.config.clear_color = ui_gfx.color_to_gfx(t.bg_app)
	app.config.clear_color.a = 255
	if frame != nil do ui.request_redraw(frame)
}

draw_content :: proc(frame: ^ui.Ui_Frame, sw, top, sh: i32) {
	x := ui.ui_frame_sc(frame, NAV_W)
	w := sw - x
	pane_rect := ui.Rect_I32{x, top, w, sh - top}
	y := ui.pane_begin(frame, &content_pane, pane_rect, pad = 14, keyboard = section != .Inputs)
	cx := x + ui.ui_frame_sc(frame, 18)
	cw := w - ui.ui_frame_sc(frame, 52)
	y = draw_section_layer(frame, cx, y, cw)

	end_y: i32
	switch section {
	case .Api_Relationships:
		end_y = draw_api_relationships(frame, cx, y, cw)
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
	case .Layout:
		end_y = draw_layout_demo(frame, cx, y, cw)
	case .Overlay:
		end_y = draw_overlay_demo(frame, cx, y, cw)
	case .Stress:
		end_y = draw_stress(frame, cx, y, cw)
	}
	ui.pane_end(frame, &content_pane, pane_rect, end_y, pad = 14)
}

draw_section_layer :: proc(frame: ^ui.Ui_Frame, x, y, w: i32) -> i32 {
	assert(frame != nil, "draw_section_layer: nil frame")
	u := &badge_ui
	ui.begin(u, frame, {x, y, w, ui.ui_frame_sc(frame, 44)}, gap = .XS)
	ui.row_begin(u, 28, gap = .SM, align = .Center)
	_ = ui.status_pill(u, SECTION_LAYERS[section], ui.ui_frame_theme(frame).fg_accent)
	ui.label(u, SECTION_AXES[section], color = ui.ui_frame_theme(frame).fg_secondary)
	ui.row_end(u)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 8)
}

draw_entry_paths :: proc(u: ^ui.Ui) {
	assert(u != nil && u.open, "draw_entry_paths: invalid UI")
	theme := ui.ui_frame_theme(u.frame)
	_ = ui.section_header(u, "1. CHOOSE AN ENTRY PATH")
	ui.label(u, "NEW UI APP  \u2192  ui_gfx.App", color = theme.fg_accent)
	ui.label(u, "ui callback: ordinary facade UI; frame callback: mixed UI or graphics")
	ui.label(u, "Need a custom loop? Use Session, not Adapter.", color = theme.fg_secondary)
	ui.space(u, .XS)
	ui.label(u, "RAYLIB APP  \u2192  ingot:gfx RAYLIB-SHAPED LOOP", color = theme.fg_accent)
	ui.label(u, "replace imports first; preserve supported behavior")
	ui.label(
		u,
		"compile errors inventory ports; add App/Session + UI only when needed",
		color = theme.fg_secondary,
	)
	ui.label(u, "rlgl is a bounded migration shim, not OpenGL.", color = theme.fg_tool)
}

api_tree_sc :: proc(frame: ^ui.Ui_Frame, value: i32) -> i32 {
	assert(frame != nil, "api_tree_sc: nil frame")
	return ui.ui_frame_sc(frame, value)
}

api_tree_card :: proc(frame: ^ui.Ui_Frame, node: Api_Tree_Node) {
	assert(frame != nil, "api_tree_card: nil frame")
	assert(node.rect.w > 0 && node.rect.h > 0, "api_tree_card: invalid node")
	theme := ui.ui_frame_theme(frame)
	paint_rect := ui.rect_f32(node.rect)
	ui.draw_rectangle_rounded(frame, paint_rect, 0.10, 6, theme.bg_secondary)
	ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.10, 6, 1, theme.border_color)
	ui.draw_rectangle(
		frame,
		node.rect.x,
		node.rect.y,
		api_tree_sc(frame, 4),
		node.rect.h,
		node.accent,
	)
	ui.text(
		frame,
		node.title,
		node.rect.x + api_tree_sc(frame, 12),
		node.rect.y + api_tree_sc(frame, 7),
		.Label,
		.Primary,
	)
	if len(node.detail) > 0 {
		ui.text(
			frame,
			node.detail,
			node.rect.x + api_tree_sc(frame, 12),
			node.rect.y + api_tree_sc(frame, 25),
			.Label,
			.Secondary,
		)
	}
}

api_tree_segment :: proc(frame: ^ui.Ui_Frame, from, to: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "api_tree_segment: nil frame")
	assert(from.x == to.x || from.y == to.y, "api_tree_segment: diagonal edge")
	ui.draw_line_ex(frame, from, to, f32(api_tree_sc(frame, 2)), color)
}

api_tree_arrow_down :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "api_tree_arrow_down: nil frame")
	size := f32(api_tree_sc(frame, 5))
	ui.draw_triangle(
		frame,
		tip,
		tip + ui.Vector2{-size, -size},
		tip + ui.Vector2{size, -size},
		color,
	)
}

api_tree_arrow_side :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, left: bool, color: ui.Color) {
	assert(frame != nil, "api_tree_arrow_side: nil frame")
	size := f32(api_tree_sc(frame, 5))
	direction: f32 = 1
	if left do direction = -1
	ui.draw_triangle(
		frame,
		tip,
		tip + ui.Vector2{-direction * size, -size},
		tip + ui.Vector2{-direction * size, size},
		color,
	)
}

api_tree_edge_down :: proc(frame: ^ui.Ui_Frame, parent, child: ui.Rect_I32, color: ui.Color) {
	assert(frame != nil && child.y > parent.y + parent.h, "api_tree_edge_down: invalid edge")
	from := ui.Vector2{f32(parent.x + parent.w / 2), f32(parent.y + parent.h)}
	to := ui.Vector2{f32(child.x + child.w / 2), f32(child.y)}
	elbow_y := f32((parent.y + parent.h + child.y) / 2)
	api_tree_segment(frame, from, {from.x, elbow_y}, color)
	api_tree_segment(frame, {from.x, elbow_y}, {to.x, elbow_y}, color)
	api_tree_segment(frame, {to.x, elbow_y}, to, color)
	api_tree_arrow_down(frame, to, color)
}

api_tree_edge_around :: proc(
	frame: ^ui.Ui_Frame,
	parent, child: ui.Rect_I32,
	lane_x: i32,
	color: ui.Color,
) {
	assert(frame != nil && child.y > parent.y + parent.h, "api_tree_edge_around: invalid edge")
	from := ui.Vector2{f32(parent.x + parent.w), f32(parent.y + parent.h / 2)}
	to := ui.Vector2{f32(child.x + child.w / 2), f32(child.y)}
	lane := f32(lane_x)
	elbow_y := f32(child.y - api_tree_sc(frame, 10))
	api_tree_segment(frame, from, {lane, from.y}, color)
	api_tree_segment(frame, {lane, from.y}, {lane, elbow_y}, color)
	api_tree_segment(frame, {lane, elbow_y}, {to.x, elbow_y}, color)
	api_tree_segment(frame, {to.x, elbow_y}, to, color)
	api_tree_arrow_down(frame, to, color)
}

api_tree_panel :: proc(frame: ^ui.Ui_Frame, rect: ui.Rect_I32, title: string) {
	assert(frame != nil && rect.w > 0 && rect.h > 0, "api_tree_panel: invalid panel")
	theme := ui.ui_frame_theme(frame)
	paint_rect := ui.rect_f32(rect)
	ui.draw_rectangle_rounded(frame, paint_rect, 0.04, 6, theme.bg_code)
	ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.04, 6, 1, theme.border_color)
	ui.text(
		frame,
		title,
		rect.x + api_tree_sc(frame, 12),
		rect.y + api_tree_sc(frame, 10),
		.Label,
		.Primary,
	)
}

api_tree_centered_rect :: proc(panel: ui.Rect_I32, y, w, h: i32) -> ui.Rect_I32 {
	assert(panel.w > 0 && panel.h > 0 && w > 0 && h > 0, "api_tree_centered_rect: invalid rect")
	return {panel.x + (panel.w - w) / 2, y, w, h}
}

api_tree_draw_edges :: proc(
	frame: ^ui.Ui_Frame,
	parent: ui.Rect_I32,
	children: []ui.Rect_I32,
	color: ui.Color,
) {
	assert(frame != nil && len(children) > 0, "api_tree_draw_edges: invalid children")
	for child in children {
		api_tree_edge_down(frame, parent, child, color)
	}
}

api_tree_branch_bus :: proc(
	frame: ^ui.Ui_Frame,
	parent: ui.Rect_I32,
	children: []ui.Rect_I32,
	lane_x: i32,
	color: ui.Color,
) {
	assert(frame != nil && len(children) > 0, "api_tree_branch_bus: invalid children")
	from := ui.Vector2{f32(parent.x + parent.w / 2), f32(parent.y + parent.h)}
	first_y := children[0].y + children[0].h / 2
	last_y := children[len(children) - 1].y + children[len(children) - 1].h / 2
	api_tree_segment(frame, from, {from.x, f32(first_y - api_tree_sc(frame, 8))}, color)
	api_tree_segment(
		frame,
		{from.x, f32(first_y - api_tree_sc(frame, 8))},
		{f32(lane_x), f32(first_y - api_tree_sc(frame, 8))},
		color,
	)
	api_tree_segment(
		frame,
		{f32(lane_x), f32(first_y - api_tree_sc(frame, 8))},
		{f32(lane_x), f32(last_y)},
		color,
	)
	for child in children {
		child_y := f32(child.y + child.h / 2)
		left := child.x < lane_x
		tip_x := f32(child.x + child.w) if left else f32(child.x)
		api_tree_segment(frame, {f32(lane_x), child_y}, {tip_x, child_y}, color)
		api_tree_arrow_side(frame, {tip_x, child_y}, left, color)
	}
}

api_ownership_tree :: proc(frame: ^ui.Ui_Frame, panel: ui.Rect_I32, compact: bool) {
	assert(frame != nil && panel.w > 0 && panel.h > 0, "api_ownership_tree: invalid panel")
	theme := ui.ui_frame_theme(frame)
	margin := api_tree_sc(frame, 14)
	card_w := min(api_tree_sc(frame, 156), (panel.w - margin * 3) / 2)
	card_h := min(api_tree_sc(frame, 42), max((panel.h - api_tree_sc(frame, 104)) / 8, 30))
	top := panel.y + api_tree_sc(frame, 38)
	row_gap := max(api_tree_sc(frame, 8), 6)
	caller := api_tree_centered_rect(panel, top, min(card_w * 2, panel.w - margin * 2), card_h)
	app := api_tree_centered_rect(panel, caller.y + card_h + row_gap, card_w, card_h)
	child_y := app.y + card_h + row_gap
	session_x := panel.x + margin + api_tree_sc(frame, 20)
	session := ui.Rect_I32{session_x, child_y, card_w, card_h}
	ui_card := ui.Rect_I32{panel.x + panel.w - margin - card_w, child_y, card_w, card_h}
	member_y := session.y + card_h + row_gap
	member_x := session.x + api_tree_sc(frame, 20)
	members: [5]ui.Rect_I32
	for index := 0; index < 5; index += 1 {
		members[index] = {member_x, member_y + i32(index) * (card_h + row_gap), card_w, card_h}
	}
	output_w := min(api_tree_sc(frame, 142), panel.x + panel.w - margin - members[3].x - card_w)
	output_x := panel.x + panel.w - margin - output_w
	output_h := min(card_h, api_tree_sc(frame, 36))
	output_y := members[3].y + card_h + row_gap
	output_children := [?]ui.Rect_I32 {
		{output_x, output_y, output_w, output_h},
		{output_x, output_y + output_h + row_gap, output_w, output_h},
		{output_x, output_y + (output_h + row_gap) * 2, output_w, output_h},
	}
	api_tree_edge_down(frame, caller, app, theme.fg_accent)
	app_children := [?]ui.Rect_I32{session, ui_card}
	api_tree_draw_edges(frame, app, app_children[:], theme.fg_accent)
	api_tree_branch_bus(
		frame,
		session,
		members[:],
		members[0].x - api_tree_sc(frame, 7),
		theme.fg_tool,
	)
	api_tree_branch_bus(
		frame,
		members[3],
		output_children[:],
		output_x - api_tree_sc(frame, 7),
		theme.fg_success,
	)
	api_tree_card(
		frame,
		{caller, "Caller-owned application state", "owns App value", theme.fg_accent},
	)
	api_tree_card(frame, {app, "ui_gfx.App", "default host", theme.fg_accent})
	api_tree_card(frame, {session, "ui_gfx.Session", "left sibling field", theme.fg_tool})
	api_tree_card(frame, {ui_card, "reusable ui.Ui", "right sibling field", theme.fg_plan})
	labels := [?]string {
		"Ui_Runtime",
		"Ui_Input",
		"reusable Ui_Frame",
		"Ui_Output",
		"ui_gfx.Adapter",
	}
	accents := [?]ui.Color {
		theme.fg_tool,
		theme.fg_user,
		theme.fg_accent,
		theme.fg_success,
		theme.fg_assistant,
	}
	for member, index in members {
		api_tree_card(frame, {member, labels[index], "Session-owned", accents[index]})
	}
	output_labels := [?]string{"main paint", "overlay paint", "platform output"}
	for child, index in output_children {
		api_tree_card(frame, {child, output_labels[index], "Ui_Output-owned", theme.fg_success})
	}
}

api_call_paths_tree :: proc(frame: ^ui.Ui_Frame, panel: ui.Rect_I32, compact: bool) {
	assert(frame != nil && panel.w > 0 && panel.h > 0, "api_call_paths_tree: invalid panel")
	theme := ui.ui_frame_theme(frame)
	margin := api_tree_sc(frame, 14)
	gap := api_tree_sc(frame, 12)
	card_w := min(api_tree_sc(frame, 168), (panel.w - margin * 2 - gap) / 2)
	card_h := min(api_tree_sc(frame, 48), max((panel.h - api_tree_sc(frame, 104)) / 5, 30))
	top := panel.y + api_tree_sc(frame, 38)
	row_gap := max((panel.h - api_tree_sc(frame, 52) - card_h * 5) / 4, 8)
	entry_w := card_w * 2 + gap
	entry_x := panel.x + (panel.w - entry_w) / 2
	facade := ui.Rect_I32{entry_x, top, card_w, card_h}
	explicit := ui.Rect_I32{entry_x + card_w + gap, top, card_w, card_h}
	frame_rect := api_tree_centered_rect(panel, top + card_h + row_gap, card_w, card_h)
	output := api_tree_centered_rect(panel, frame_rect.y + card_h + row_gap, card_w, card_h)
	adapter := api_tree_centered_rect(panel, output.y + card_h + row_gap, card_w, card_h)
	gfx := api_tree_centered_rect(panel, adapter.y + card_h + row_gap, card_w, card_h)
	raylib_x := panel.x + margin
	if raylib_x + card_w + margin > gfx.x do raylib_x = panel.x + panel.w - margin - card_w
	raylib := ui.Rect_I32{raylib_x, adapter.y, card_w, card_h}
	declarations := [?]ui.Rect_I32{facade, explicit}
	for declaration in declarations {
		api_tree_edge_down(frame, declaration, frame_rect, theme.fg_accent)
	}
	api_tree_edge_down(frame, frame_rect, output, theme.fg_success)
	api_tree_edge_down(frame, output, adapter, theme.fg_assistant)
	api_tree_edge_down(frame, adapter, gfx, theme.fg_assistant)
	lane_x := panel.x + panel.w - api_tree_sc(frame, 8)
	if raylib.x > gfx.x do lane_x = panel.x + api_tree_sc(frame, 8)
	api_tree_edge_around(frame, raylib, gfx, lane_x, theme.fg_user)
	api_tree_card(frame, {facade, "Facade API", "paired *_at when available", theme.fg_plan})
	api_tree_card(frame, {explicit, "Explicit UI", "*_at · canvas · protocols", theme.fg_accent})
	api_tree_card(frame, {frame_rect, "Ui_Frame", "records paint + semantics", theme.fg_accent})
	api_tree_card(frame, {output, "Ui_Output", "main · overlay · platform", theme.fg_success})
	api_tree_card(frame, {adapter, "ui_gfx.Adapter", "replays UI output", theme.fg_assistant})
	api_tree_card(frame, {gfx, "ingot:gfx", "backend-facing API", theme.fg_assistant})
	api_tree_card(
		frame,
		{raylib, "Migrated raylib app", "existing loop · direct gfx", theme.fg_user},
	)
}

api_relationship_trees_canvas :: proc(frame: ^ui.Ui_Frame, rect: ui.Rect_I32, userdata: rawptr) {
	assert(
		frame != nil && rect.w > 0 && rect.h > 0,
		"api_relationship_trees_canvas: invalid canvas",
	)
	assert(userdata == nil, "api_relationship_trees_canvas: unexpected userdata")
	wide := rect.w >= api_tree_sc(frame, 700)
	pad := api_tree_sc(frame, 16 if wide else 12)
	gap := api_tree_sc(frame, 20 if wide else 16)
	ownership, depth: ui.Rect_I32
	if wide {
		panel_w := (rect.w - pad * 2 - gap) / 2
		ownership = {rect.x + pad, rect.y + pad, panel_w, rect.h - pad * 2}
		depth = {ownership.x + ownership.w + gap, ownership.y, panel_w, ownership.h}
	} else {
		panel_h := (rect.h - pad * 2 - gap) / 2
		ownership = {rect.x + pad, rect.y + pad, rect.w - pad * 2, panel_h}
		depth = {ownership.x, ownership.y + ownership.h + gap, ownership.w, panel_h}
	}
	api_tree_panel(frame, ownership, "1 · LITERAL OWNERSHIP")
	api_tree_panel(frame, depth, "2 · CALL PATHS · APPLICATION → BACKEND")
	api_ownership_tree(frame, ownership, !wide)
	api_call_paths_tree(frame, depth, !wide)
}

draw_api_text_equivalent :: proc(u: ^ui.Ui) {
	assert(u != nil && u.open, "draw_api_text_equivalent: invalid UI")
	theme := ui.ui_frame_theme(u.frame)
	_ = ui.section_header(u, "TEXTUAL EQUIVALENT")
	ui.label(u, "1. LITERAL OWNERSHIP", color = theme.fg_accent)
	ui.kv_row(u, "Caller", "owns ui_gfx.App", theme.fg_secondary, theme.fg_primary)
	ui.kv_row(
		u,
		"ui_gfx.App",
		"owns reusable ui.Ui and ui_gfx.Session",
		theme.fg_secondary,
		theme.fg_primary,
	)
	ui.kv_row(
		u,
		"ui_gfx.Session",
		"owns Runtime, Ui_Frame, Ui_Input, Ui_Output, and Adapter",
		theme.fg_secondary,
		theme.fg_primary,
	)
	ui.kv_row(
		u,
		"Ui_Output",
		"owns main paint, overlay paint, and platform output",
		theme.fg_secondary,
		theme.fg_primary,
	)
	ui.space(u, .XS)
	ui.label(u, "2. CALL PATHS", color = theme.fg_accent)
	ui.kv_row(
		u,
		"Declaration",
		"facade or explicit UI → Ui_Frame",
		theme.fg_secondary,
		theme.fg_primary,
	)
	ui.kv_row(
		u,
		"Rendering",
		"Ui_Frame → Ui_Output → Adapter → ingot:gfx",
		theme.fg_secondary,
		theme.fg_primary,
	)
	ui.kv_row(
		u,
		"Migration",
		"migrated raylib loop → ingot:gfx; UI optional",
		theme.fg_secondary,
		theme.fg_primary,
	)
}

draw_api_relationships :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil && w > 0, "draw_api_relationships: invalid geometry")
	u := &api_map_state.ui
	wide := w >= ui.ui_frame_sc(frame, 700)
	canvas_h: i32 = 520 if wide else 900
	total_h: i32 = canvas_h + 420
	ui.begin(u, frame, {x, y0, w, ui.ui_frame_sc(frame, total_h)}, gap = .SM)
	ui.scope_begin(u, "api-relationships")
	_ = ui.section_header(u, "API OWNERSHIP AND CALL PATHS")
	ui.label(u, "Ownership is literal; application-facing routes flow toward ingot:gfx.")
	_ = ui.canvas(u, {height = canvas_h}, api_relationship_trees_canvas)
	draw_api_text_equivalent(u)
	draw_entry_paths(u)
	ui.scope_end(u)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 16)
}

draw_buttons :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_buttons: nil frame")
	u := &buttons_ui
	ui.begin(u, frame, {x, y0, w, ui.ui_frame_sc(frame, 620)}, gap = .SM)
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
	if ui.icon_btn(u, ui.id(u, "close"), "Close") do click_count += 1
	if ui.back_btn(u, ui.id(u, "back"), "Back") do click_count += 1
	ui.row_end(u)
	ui.label(
		u,
		fmt.tprintf("clicks: %d", click_count),
		color = ui.ui_frame_theme(frame).fg_secondary,
	)

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
			ui.label(
				u,
				"Collapsed state is caller-owned.",
				color = ui.ui_frame_theme(frame).fg_secondary,
			)
		}
	}
	ui.scope_end(u)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 16)
}

draw_inputs :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, ui.ui_frame_sc(frame, 420))

	state := &input_state
	ui.begin(&state.ctx, frame, {x, y, iw, ui.ui_frame_sc(frame, 600)}, gap = .SM)
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
		"Notes\u2026 (Shift+Enter for newlines)",
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
	ui.label(
		&state.ctx,
		summary,
		ui.ui_frame_metrics(frame).FONT_SIZE_LABEL,
		ui.ui_frame_theme(frame).fg_secondary,
	)

	ui.scope_end(&state.ctx)
	end_y := ui.remaining_rect(&state.ctx).y
	ui.end(&state.ctx)
	return end_y + ui.ui_frame_sc(frame, 24)
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
	ui.label(
		&state.ctx,
		fmt.tprintf("%.0f%%", state.volume),
		color = ui.ui_frame_theme(frame).fg_secondary,
	)
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
	ui.begin(&state.ctx, frame, {x, y, w, ui.ui_frame_sc(frame, 400)}, gap = .SM)
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
	y = ui.remaining_rect(&state.ctx).y + ui.ui_frame_sc(frame, 14)
	ui.end(&state.ctx)
	return y
}

// The progress / spinner / pill section is pure facade: every widget carves
// its own slot from a Ui, so no call site does arithmetic on x/y/w/h.
draw_widget_progress :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_progress: nil state")
	u := &state.progress_ctx
	theme := ui.ui_frame_theme(frame)
	ui.begin(u, frame, {x, y0, w, ui.ui_frame_sc(frame, 200)}, gap = .SM)
	ui.scope_begin(u, "progress")
	_ = ui.section_header(u, "PROGRESS / SPINNER / PILLS")

	ui.row_begin(u, 34, gap = .MD, align = .Start)
	ui.spinner(u, 28)
	ui.spinner(u, 20, {style = .Orbit_Dots, dot_radius = 2.5, speed = 6})
	_ = ui.status_pill(u, "active", theme.fg_success)
	_ = ui.status_pill(u, "warning", theme.fg_tool)
	_ = ui.status_pill(u, "error", theme.fg_error)
	ui.row_end(u)

	ui.progress_bar(u, 0.65, theme.fg_accent)
	ui.progress_bar_animated(u, progress_frac, &progress_anim, theme.fg_success)

	ui.row_begin(u, 30, gap = .SM, align = .Start)
	if ui.button(u, ui.id(u, "replay"), "Replay") do progress_anim = 0
	ui.row_end(u)

	ui.scope_end(u)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 16)
}

// The key/value rows are facade too: kv_row spans the container width, so the
// caller never measures the value to right-align it.
draw_widget_kv_rows :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32, state: ^Widget_State) -> i32 {
	assert(state != nil, "draw_widget_kv_rows: nil state")
	u := &state.kv_ctx
	theme := ui.ui_frame_theme(frame)
	width := min(w, ui.ui_frame_sc(frame, 360))
	ui.begin(u, frame, {x, y0, width, ui.ui_frame_sc(frame, 120)}, gap = .XS)
	_ = ui.section_header(u, "KV ROWS + LIST ROWS")
	ui.kv_row(u, "Renderer", "WebGPU", theme.fg_secondary, theme.fg_primary)
	ui.kv_row(u, "State model", "caller-owned", theme.fg_secondary, theme.fg_primary)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 10)
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
	ui.draw_shadow_rounded(frame, shadow, 0.15)
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
	y = draw_widget_truncation_card(frame, x, y, w)
	return draw_widget_fit_card(frame, x, y, w)
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
	y := ui.section_header_at(frame, {x, y0, w, 0}, "SINGLE-PASS LAYOUT (weights + flex + flow)")
	l: ui.Layout
	lw := min(w, ui.ui_frame_sc(frame, 520))
	ui.layout_begin(&l, x, y, lw, ui.ui_frame_sc(frame, 248), gap = ui.ui_frame_sc(frame, 8))

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

	ui.layout_end(&l)
	flow_y := y + ui.ui_frame_sc(frame, 258)
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
	button_w := ui.ui_frame_sc(frame, 150)
	button_h := ui.ui_frame_sc(frame, 30)
	for index in 0 ..< 3 {
		label := fmt.tprintf("Shielded %d", index + 1)
		button_y := y + i32(index) * (button_h + ui.ui_frame_sc(frame, 8))
		if ui.button_at(frame, {x, button_y, button_w, button_h}, label) do shielded_clicks += 1
	}
	info_y := y + 3 * (button_h + ui.ui_frame_sc(frame, 8))
	summary := fmt.tprintf(
		"shielded clicks: %d (should not rise while the popup covers them)",
		shielded_clicks,
	)
	ui.text(frame, summary, x, info_y, .Label, .Secondary)
	action_x := x + button_w + ui.ui_frame_sc(frame, 100)
	if ui.button_at(
		frame,
		{action_x, y, ui.ui_frame_sc(frame, 150), button_h},
		"Toggle popup",
		ui.Btn_Style.Primary,
	) {
		popup_open = !popup_open
	}
	if ui.button_at(
		frame,
		{action_x, y + button_h + ui.ui_frame_sc(frame, 8), ui.ui_frame_sc(frame, 150), button_h},
		"Open modal",
	) {
		about_modal.open = true
	}
	return info_y
}

draw_overlay_context_menu :: proc(frame: ^ui.Ui_Frame, x, info_y: i32) {
	if ui.is_mouse_button_pressed(frame, .RIGHT) && !ctx_menu.open && !about_modal.open {
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
	return info_y + ui.ui_frame_sc(frame, 52)
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

draw_stress :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	y := ui.section_header_at(
		frame,
		{x, y0, w, 0},
		"STRESS: 1000 BUTTONS (batcher, hover-anim bound, culling)",
	)
	cols := max(int(w / ui.ui_frame_sc(frame, 110)), 1)
	bw := ui.ui_frame_sc(frame, 100)
	bh := ui.ui_frame_sc(frame, 26)
	for i in 0 ..< 1000 {
		col := i % cols
		row := i / cols
		bx := x + i32(col) * (bw + ui.ui_frame_sc(frame, 6))
		by := y + i32(row) * (bh + ui.ui_frame_sc(frame, 6))
		label := fmt.tprintf("btn %d", i)
		if ui.button_at(frame, {bx, by, bw, bh}, label) {
			stress_clicked = i
		}
	}
	rows := (1000 + cols - 1) / cols
	y += i32(rows) * (bh + ui.ui_frame_sc(frame, 6)) + ui.ui_frame_sc(frame, 10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		ui.text(frame, msg, x, y, .Label, .Secondary)
		y += ui.ui_frame_sc(frame, 24)
	}
	return y
}
