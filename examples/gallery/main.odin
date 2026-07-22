// ingot widget gallery — the imgui_demo.cpp equivalent: living documentation,
// copy-paste cookbook, and regression/stress surface for every ui widget.
// Frames are event-driven (EnableEventWaiting). Build & run:
//
//	odin run examples/gallery -collection:ingot=.
//
// Keys: F12 toggles the metrics/debug overlay (renderer counters need
// -define:INGOT_RENDER_STATS=true). Tab cycles keyboard focus in the
// Buttons section.
package main

import "core:fmt"
import "core:strings"
import rl "ingot:gfx"
import "ingot:ui"

Section :: enum {
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
	.Buttons  = "Buttons",
	.Inputs   = "Inputs",
	.Widgets  = "Widgets",
	.Charts   = "Charts",
	.Markdown = "Markdown",
	.Layout   = "Layout",
	.Overlay  = "Overlay",
	.Stress   = "Stress",
}

NAV_W :: 170

// --- caller-owned state (the whole point: no hidden library state) ----------

dark := true
section := Section.Buttons
debug_on := false

content_pane: ui.Pane
click_count := 0
focus_slot := 0
headers_open := [3]bool{true, false, false}

name_box: ui.Input_Box
pass_box: ui.Input_Box
notes_box: ui.Input_Box
active_input := 0 // 1-based focus id; 0 = none

progress_anim: f32
progress_frac: f32 = 0.35

line_state: ui.Chart_State
bar_state: ui.Chart_State
revenue := [12]f32{12.4, 14.1, 13.2, 16.8, 18.9, 17.4, 21.0, 22.6, 20.1, 24.3, 26.8, 25.2}
costs := [12]f32{8.1, 8.4, 9.0, 9.7, 10.2, 11.5, 11.1, 12.4, 12.0, 13.6, 13.1, 14.0}
MONTHS := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
spark := [10]f32{3, 4, 3.6, 5, 6.2, 5.8, 7, 8.4, 8.1, 9.3}

settings_open := false
settings_sel := 0
stored_scale: f32 = 0 // 0 = auto

popup_open := false
shielded_clicks := 0
leaked_clicks := 0

stress_clicked := -1

MARKDOWN_SAMPLE :: `# Markdown widget

Inline **bold**, *italic*, ` + "`code`" + `, and [links](https://example.com).

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
	rl.InitWindow(1100, 760, "ingot widget gallery")
	rl.SetTargetFPS(60)
	rl.EnableEventWaiting()
	ui.apply_platform_dpi()
	ui.init_font()
	rl.run(frame)
}

frame :: proc() {
	ui.dpi_refresh()
	ui.begin_cursor_frame()
	rl.BeginDrawing()
	rl.ClearBackground(ui.theme.bg_color)

	sw := rl.GetScreenWidth()
	sh := rl.GetScreenHeight()

	if rl.IsKeyPressed(.F12) do debug_on = !debug_on

	draw_nav(sh)
	draw_content(sw, sh)

	if settings_open {
		res := ui.draw_scale_settings_panel(&settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		ui.draw_debug_overlay(sw - ui.sc(290), ui.sc(10))
	}

	ui.apply_cursor()
	rl.EndDrawing()
}

apply_scale :: proc(scale: f32) {
	resolved := scale if scale > 0 else ui.settings_auto_scale()
	ui.set_ui_scale(resolved)
	ui.reset_font_atlases()
	ui.invalidate_scale_caches()
}

draw_nav :: proc(sh: i32) {
	w := ui.sc(NAV_W)
	rl.DrawRectangle(0, 0, w, sh, ui.theme.bg_secondary)
	rl.DrawRectangle(w - 1, 0, 1, sh, ui.theme.border_subtle)

	y := ui.sc(14)
	ui.draw_text("ingot gallery", ui.sc(14), y, ui.FONT_SIZE_LARGE, ui.theme.fg_primary)
	y += ui.sc(40)

	for s in Section {
		style := ui.Btn_Style.Primary if s == section else .Ghost
		if ui.btn(ui.sc(10), y, w - ui.sc(20), ui.sc(28), SECTION_NAMES[s], style) {
			section = s
			ui.pane_reset(&content_pane)
		}
		y += ui.sc(32)
	}

	y = sh - ui.sc(76)
	if ui.btn(ui.sc(10), y, w - ui.sc(20), ui.sc(26), "Light theme" if dark else "Dark theme") {
		dark = !dark
		ui.set_theme(ui.theme_dark() if dark else ui.theme_light())
	}
	y += ui.sc(32)
	if ui.btn(ui.sc(10), y, w - ui.sc(20), ui.sc(26), "UI scale\u2026") {
		settings_open = true
		settings_sel = ui.settings_scale_preset_index(stored_scale)
	}
}

draw_content :: proc(sw, sh: i32) {
	x := ui.sc(NAV_W)
	w := sw - x
	y := ui.pane_begin(&content_pane, x, 0, w, sh, pad = 14, keyboard = section != .Inputs)
	cx := x + ui.sc(18)
	cw := w - ui.sc(52)

	end_y: i32
	switch section {
	case .Buttons:
		end_y = draw_buttons(cx, y, cw)
	case .Inputs:
		end_y = draw_inputs(cx, y, cw)
	case .Widgets:
		end_y = draw_widgets(cx, y, cw)
	case .Charts:
		end_y = draw_charts(cx, y, cw)
	case .Markdown:
		end_y = ui.draw_markdown(cx, y, cw, MARKDOWN_SAMPLE, ui.theme.fg_primary) + y
	case .Layout:
		end_y = draw_layout_demo(cx, y, cw)
	case .Overlay:
		end_y = draw_overlay_demo(cx, y, cw)
	case .Stress:
		end_y = draw_stress(cx, y, cw)
	}
	ui.pane_end(&content_pane, x, 0, w, sh, end_y, pad = 14)
}

draw_buttons :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "BUTTON STYLES")
	bw := ui.sc(120)
	bh := ui.sc(30)
	gap := ui.sc(10)
	if ui.btn(x, y, bw, bh, "Primary", .Primary) do click_count += 1
	if ui.btn(x + (bw + gap), y, bw, bh, "Secondary", .Secondary) do click_count += 1
	if ui.btn(x + (bw + gap) * 2, y, bw, bh, "Danger", .Danger) do click_count += 1
	if ui.btn(x + (bw + gap) * 3, y, bw, bh, "Ghost", .Ghost) do click_count += 1
	y += bh + gap
	ui.btn(x, y, bw, bh, "Disabled", .Primary, enabled = false)
	if ui.icon_btn(x + bw + gap, y, bh, "\u2715") do click_count += 1
	if ui.back_btn(x + bw + gap + bh + gap, y + ui.sc(4), "Back") do click_count += 1
	y += bh + gap

	count := fmt.tprintf("clicks: %d", click_count)
	ui.draw_text(strings.clone_to_cstring(count, context.temp_allocator),
		x, y, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	y += ui.sc(30)

	y = ui.section_header(x, y, w, "KEYBOARD FOCUS (Tab cycles, Space/Enter activates)")
	ui.form_focus_cycle(&focus_slot, 3)
	for i in 0 ..< 3 {
		label := fmt.tprintf("Focusable %d", i + 1)
		if ui.btn(x + i32(i) * (bw + gap), y, bw, bh, label,
			focus = ui.Focus_Opt{&focus_slot, i + 1}) {
			click_count += 1
		}
	}
	y += bh + ui.sc(16)

	y = ui.section_header(x, y, w, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := fmt.tprintf("Section %d", i + 1)
		ui.collapsible_header(x, y, w, label, &headers_open[i])
		y += ui.sc(28)
		if headers_open[i] {
			ui.draw_text("Collapsed state is a caller-owned bool.",
				x + ui.sc(12), y, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
			y += ui.sc(24)
		}
	}
	return y
}

draw_inputs :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)")
	iw := min(w, ui.sc(420))
	ih := ui.sc(34)

	activate :: proc(x, y, w, h, id: i32) {
		mouse := rl.GetMousePosition()
		if rl.IsMouseButtonPressed(.LEFT) &&
		   rl.CheckCollisionPointRec(mouse, {f32(x), f32(y), f32(w), f32(h)}) {
			active_input = int(id)
		}
	}

	activate(x, y, iw, ih, 1)
	ui.input(x, y, iw, ih, &name_box, "Your name (undo, selection, spellcheck)", active_input == 1)
	y += ih + ui.sc(10)

	activate(x, y, iw, ih, 2)
	ui.input(x, y, iw, ih, &pass_box, "Password (masked)", active_input == 2, masked = true)
	y += ih + ui.sc(10)

	mh := ui.sc(90)
	activate(x, y, iw, mh, 3)
	ui.input(x, y, iw, mh, &notes_box, "Notes\u2026 (Shift+Enter for newlines)", active_input == 3)
	y += mh + ui.sc(10)

	if ui.btn(x, y, ui.sc(120), ui.sc(26), "Reset all") {
		ui.input_box_reset(&name_box)
		ui.input_box_reset(&pass_box)
		ui.input_box_reset(&notes_box)
	}
	y += ui.sc(40)

	summary := fmt.tprintf("name: %q \u00b7 notes: %d bytes",
		ui.input_box_text(&name_box), len(ui.input_box_text(&notes_box)))
	ui.draw_text(strings.clone_to_cstring(summary, context.temp_allocator),
		x, y, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	return y + ui.sc(24)
}

draw_widgets :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "PROGRESS / SPINNER / PILLS")
	ui.spinner(x + ui.sc(16), y + ui.sc(16), ui.scf(14))
	ui.progress_bar(x + ui.sc(48), y + ui.sc(4), ui.sc(200), ui.sc(8), 0.65, ui.theme.fg_accent)
	ui.progress_bar_animated(x + ui.sc(48), y + ui.sc(20), ui.sc(200), ui.sc(8),
		progress_frac, &progress_anim, ui.theme.fg_success)
	if ui.btn(x + ui.sc(260), y, ui.sc(90), ui.sc(24), "Replay") {
		progress_anim = 0
	}
	y += ui.sc(44)
	px := x
	px += ui.status_pill("active", px, y, ui.FONT_SIZE_SMALL, ui.theme.fg_success) + ui.sc(8)
	px += ui.status_pill("warning", px, y, ui.FONT_SIZE_SMALL, ui.theme.fg_tool) + ui.sc(8)
	ui.status_pill("error", px, y, ui.FONT_SIZE_SMALL, ui.theme.fg_error)
	y += ui.sc(34)

	y = ui.section_header(x, y, w, "KV ROWS + LIST ROWS")
	ui.kv_row(x, y, min(w, ui.sc(360)), "Renderer", "WebGPU", ui.theme.fg_secondary, ui.theme.fg_primary)
	y += ui.sc(20)
	ui.kv_row(x, y, min(w, ui.sc(360)), "State model", "caller-owned", ui.theme.fg_secondary, ui.theme.fg_primary)
	y += ui.sc(26)
	for i in 0 ..< 3 {
		rect := rl.Rectangle{f32(x), f32(y), f32(min(w, ui.sc(360))), f32(ui.sc(24))}
		hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
		ui.list_row_bg(rect, i == 1, hovered)
		label := fmt.tprintf("list row %d%s", i + 1, " (selected)" if i == 1 else "")
		ui.draw_text(strings.clone_to_cstring(label, context.temp_allocator),
			x + ui.sc(8), y + ui.sc(4), ui.FONT_SIZE_SMALL, ui.theme.fg_primary)
		y += ui.sc(26)
	}
	y += ui.sc(8)

	y = ui.section_header(x, y, w, "CARD + SHADOW + TRUNCATION")
	card := rl.Rectangle{f32(x), f32(y), f32(min(w, ui.sc(360))), f32(ui.sc(64))}
	ui.draw_shadow_rounded(card, 0.15)
	ui.draw_card_bg(card, ui.theme.bg_secondary, accent_w = ui.sc(3))
	ui.draw_text_truncated("A very long label that will be cut with an ellipsis when it overflows the card",
		x + ui.sc(12), y + ui.sc(12), i32(card.width) - ui.sc(24), ui.FONT_SIZE_SMALL, ui.theme.fg_primary)
	path := ui.truncate_path_middle("ingot/examples/gallery/very/deep/dir/main.odin",
		i32(card.width) - ui.sc(24), ui.FONT_SIZE_SMALL)
	ui.draw_text(strings.clone_to_cstring(path, context.temp_allocator),
		x + ui.sc(12), y + ui.sc(34), ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	return y + i32(card.height) + ui.sc(16)
}

draw_charts :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "LINE + BAR + SPARKLINE (hover for overlay tooltips)")
	cw := min(w, ui.sc(560))
	series := [2]ui.Chart_Series{
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	ui.line_chart(x, y, cw, ui.sc(240), series[:], &line_state, {
		labels      = MONTHS[:],
		show_grid   = true,
		show_axes   = true,
		show_legend = true,
		fill        = true,
	})
	y += ui.sc(252)
	ui.bar_chart(x, y, cw, ui.sc(220), series[:], &bar_state, {
		labels      = MONTHS[:],
		show_grid   = true,
		show_axes   = true,
		show_legend = true,
	})
	y += ui.sc(232)
	ui.draw_text("sparkline:", x, y + ui.sc(6), ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	ui.sparkline(x + ui.sc(80), y, ui.sc(140), ui.sc(28), spark[:])
	return y + ui.sc(40)
}

draw_layout_demo :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "SINGLE-PASS LAYOUT (row_weights declared up front)")
	l: ui.Layout
	lw := min(w, ui.sc(520))
	ui.layout_begin(&l, x, y, lw, ui.sc(200), gap = ui.sc(8))

	ui.push_row(&l, ui.sc(40), gap = ui.sc(8))
	ui.row_weights(&l, {1, 2, 1})
	cell(ui.next_weighted(&l, 1), "1fr")
	cell(ui.next_weighted(&l, 2), "2fr")
	cell(ui.next_weighted(&l, 1), "1fr")
	ui.layout_pop(&l)

	ui.push_row(&l, ui.sc(40), gap = ui.sc(8))
	cell(ui.next(&l, ui.sc(120)), "fixed 120")
	cell(ui.remaining(&l), "remaining")
	ui.layout_pop(&l)

	ui.push_row(&l, ui.sc(90), gap = ui.sc(8), cross_align = .Center)
	cell(ui.next_sized(&l, ui.sc(160), ui.sc(50)), "centered")
	ui.layout_pop(&l)

	ui.layout_end(&l)
	return y + ui.sc(210)
}

cell :: proc(r: ui.Rect_I32, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	rl.DrawRectangle(r.x, r.y, r.w, r.h, ui.theme.bg_active)
	rl.DrawRectangleLines(r.x, r.y, r.w, r.h, ui.theme.border_color)
	c := strings.clone_to_cstring(label, context.temp_allocator)
	tw := ui.measure_text(c, ui.FONT_SIZE_SMALL)
	ui.draw_text(c, r.x + (r.w - tw) / 2, r.y + (r.h - ui.FONT_SIZE_SMALL) / 2,
		ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
}

draw_overlay_demo :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "OVERLAY + INPUT ROUTING (popup occludes the buttons under it)")
	bw := ui.sc(150)
	bh := ui.sc(30)
	// These buttons sit UNDER the popup. With routing, clicks on the popup
	// must not reach them.
	for i in 0 ..< 3 {
		label := fmt.tprintf("Shielded %d", i + 1)
		if ui.btn(x, y + i32(i) * (bh + ui.sc(8)), bw, bh, label) {
			shielded_clicks += 1
		}
	}
	info_y := y + 3 * (bh + ui.sc(8))
	summary := fmt.tprintf("shielded clicks: %d (should not rise while the popup covers them)", shielded_clicks)
	ui.draw_text(strings.clone_to_cstring(summary, context.temp_allocator),
		x, info_y, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)

	if ui.btn(x + bw + ui.sc(30), y, ui.sc(150), bh, "Toggle popup", .Primary) {
		popup_open = !popup_open
	}

	if popup_open {
		draw_demo_popup(x + ui.sc(60), y + ui.sc(12))
	}
	return info_y + ui.sc(30)
}

// draw_demo_popup records a popup on the overlay layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(x, y: i32) {
	w := ui.sc(220)
	h := ui.sc(110)
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	ui.overlay_begin(rect, claim_input = true)
	ui.overlay_rounded(rect, 0.1, 6, ui.theme.bg_popup)
	ui.overlay_rounded_lines(rect, 0.1, 6, 1.0, ui.theme.border_color)
	ui.overlay_text("Overlay popup", x + ui.sc(12), y + ui.sc(10), ui.FONT_SIZE, ui.theme.fg_primary)
	ui.overlay_text("Recorded during the frame,", x + ui.sc(12), y + ui.sc(36), ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
	ui.overlay_text("replayed above everything.", x + ui.sc(12), y + ui.sc(54), ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)

	// Close row: the popup is topmost, so it hit-tests raw input.
	row := rl.Rectangle{f32(x + ui.sc(12)), f32(y + h - ui.sc(30)), f32(w - ui.sc(24)), f32(ui.sc(22))}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, row)
	if hovered {
		ui.overlay_rect(row, ui.theme.bg_active)
		ui.request_cursor(.POINTING_HAND)
	}
	ui.overlay_text("Close", x + ui.sc(18), y + h - ui.sc(28), ui.FONT_SIZE_SMALL, ui.theme.fg_accent)
	if hovered && rl.IsMouseButtonReleased(.LEFT) {
		popup_open = false
	}
	ui.overlay_end()
}

draw_stress :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(x, y0, w, "STRESS: 1000 BUTTONS (batcher, hover-anim bound, culling)")
	cols := max(int(w / ui.sc(110)), 1)
	bw := ui.sc(100)
	bh := ui.sc(26)
	for i in 0 ..< 1000 {
		col := i % cols
		row := i / cols
		bx := x + i32(col) * (bw + ui.sc(6))
		by := y + i32(row) * (bh + ui.sc(6))
		label := fmt.tprintf("btn %d", i)
		if ui.btn(bx, by, bw, bh, label) {
			stress_clicked = i
		}
	}
	rows := (1000 + cols - 1) / cols
	y += i32(rows) * (bh + ui.sc(6)) + ui.sc(10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		ui.draw_text(strings.clone_to_cstring(msg, context.temp_allocator),
			x, y, ui.FONT_SIZE_SMALL, ui.theme.fg_secondary)
		y += ui.sc(24)
	}
	return y
}
