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

// SMOKE enables the self-driving crash harness in smoke.odin (native only;
// see scripts/smoke-gallery.sh).
SMOKE :: #config(INGOT_SMOKE, false)

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
high_contrast := false
reduced_motion := false
section := Section.Buttons
debug_on := false

content_pane: ui.Pane
click_count := 0
focus_slot := 0
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
ui_runtime: ui.Ui_Runtime
ui_frame: ui.Ui_Frame

Widget_State :: struct {
	ctx:          ui.Ui,
	check_a:      bool,
	check_b:      bool,
	radio_choice: i32,
	volume:       f32,
	slider:       ui.Slider_State,
	dd_selected:  i32,
	dropdown:     ui.Dropdown_State,
	tooltip:      ui.Tooltip_State,
}

widget_state := Widget_State {
	check_a = true,
	volume  = 40,
}

// Generic modal + context menu (Overlay section).
about_modal: ui.Modal_State
ctx_menu: ui.Context_Menu_State
ctx_note := "right-click in this section for a context menu"

popup_open := false
shielded_clicks := 0
leaked_clicks := 0

stress_clicked := -1

INPUT_NAME_ID :: ui.Focus_Id(101)
INPUT_PASS_ID :: ui.Focus_Id(102)
INPUT_NOTES_ID :: ui.Focus_Id(103)
INPUT_RESET_ID :: ui.Focus_Id(104)
WIDGET_ENABLE_ID :: ui.Focus_Id(201)
WIDGET_VERBOSE_ID :: ui.Focus_Id(202)
WIDGET_SMALL_ID :: ui.Focus_Id(203)
WIDGET_MEDIUM_ID :: ui.Focus_Id(204)
WIDGET_LARGE_ID :: ui.Focus_Id(205)
WIDGET_VOLUME_ID :: ui.Focus_Id(206)
WIDGET_BACKEND_ID :: ui.Focus_Id(207)

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
	rl.InitWindow(1100, 760, "ingot widget gallery")
	rl.SetTargetFPS(60)
	when !SMOKE do rl.EnableEventWaiting() // smoke needs continuous frames
	ui.ui_runtime_init(&ui_runtime)
	ui.ui_runtime_apply_platform_dpi(&ui_runtime)
	ui.a11y_init(&ui_runtime)
	rl.run(frame)
	input_state_destroy(&input_state)
	ui.ui_runtime_destroy(&ui_runtime)
	rl.CloseWindow()
}

input_state_destroy :: proc(state: ^Input_State) {
	assert(state != nil, "input_state_destroy: nil state")
	ui.input_box_destroy(&state.name)
	ui.input_box_destroy(&state.pass)
	ui.input_box_destroy(&state.notes)
}

frame :: proc() {
	ui.ui_runtime_dpi_refresh(&ui_runtime)
	ui.ui_frame_begin(&ui_frame, &ui_runtime)
	rl.BeginDrawing()
	rl.ClearBackground(ui.ui_frame_theme(&ui_frame).bg_color)

	sw := rl.GetScreenWidth()
	sh := rl.GetScreenHeight()

	when SMOKE do smoke_step()

	if rl.IsKeyPressed(.F12) do debug_on = !debug_on

	draw_nav(sh)
	draw_content(sw, sh)

	if settings_open {
		res := ui.draw_scale_settings_panel(&ui_frame, &settings_sel, stored_scale, sw, sh)
		if res.applied {
			stored_scale = res.ui_scale
			apply_scale(res.ui_scale)
		}
		if res.dismissed do settings_open = false
	}

	if debug_on {
		ui.draw_debug_overlay(
			&ui_frame,
			sw - ui.ui_frame_sc(&ui_frame, 290),
			ui.ui_frame_sc(&ui_frame, 10),
		)
	}

	ui.a11y_frame_end(&ui_frame)
	ui.ui_frame_end(&ui_frame)
	rl.EndDrawing()
}

apply_scale :: proc(scale: f32) {
	resolved := scale if scale > 0 else ui.settings_auto_scale()
	ui.ui_runtime_set_scale(&ui_runtime, resolved)
}

draw_nav :: proc(sh: i32) {
	w := ui.ui_frame_sc(&ui_frame, NAV_W)
	rl.DrawRectangle(0, 0, w, sh, ui.ui_frame_theme(&ui_frame).bg_secondary)
	rl.DrawRectangle(w - 1, 0, 1, sh, ui.ui_frame_theme(&ui_frame).border_subtle)

	y := ui.ui_frame_sc(&ui_frame, 14)
	ui.draw_text_frame(
		&ui_frame,
		"ingot gallery",
		ui.ui_frame_sc(&ui_frame, 14),
		y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_LARGE,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	y += ui.ui_frame_sc(&ui_frame, 40)

	for s in Section {
		style := ui.Btn_Style.Primary if s == section else .Ghost
		if ui.btn(
			&ui_frame,
			ui.ui_frame_sc(&ui_frame, 10),
			y,
			w - ui.ui_frame_sc(&ui_frame, 20),
			ui.ui_frame_sc(&ui_frame, 28),
			SECTION_NAMES[s],
			style,
		) {
			section = s
			ui.pane_reset(&content_pane)
		}
		y += ui.ui_frame_sc(&ui_frame, 32)
	}

	y = sh - ui.ui_frame_sc(&ui_frame, 140)
	if ui.btn(
		&ui_frame,
		ui.ui_frame_sc(&ui_frame, 10),
		y,
		w - ui.ui_frame_sc(&ui_frame, 20),
		ui.ui_frame_sc(&ui_frame, 26),
		"Light theme" if dark else "Dark theme",
	) {
		dark = !dark
		high_contrast = false
		apply_gallery_theme()
	}
	y += ui.ui_frame_sc(&ui_frame, 32)
	if ui.btn(
		&ui_frame,
		ui.ui_frame_sc(&ui_frame, 10),
		y,
		w - ui.ui_frame_sc(&ui_frame, 20),
		ui.ui_frame_sc(&ui_frame, 26),
		"Standard contrast" if high_contrast else "High contrast",
	) {
		high_contrast = !high_contrast
		apply_gallery_theme()
	}
	y += ui.ui_frame_sc(&ui_frame, 32)
	if ui.btn(
		&ui_frame,
		ui.ui_frame_sc(&ui_frame, 10),
		y,
		w - ui.ui_frame_sc(&ui_frame, 20),
		ui.ui_frame_sc(&ui_frame, 26),
		"Motion: reduced" if reduced_motion else "Motion: full",
	) {
		reduced_motion = !reduced_motion
		apply_gallery_theme()
	}
	y += ui.ui_frame_sc(&ui_frame, 32)
	if ui.btn(
		&ui_frame,
		ui.ui_frame_sc(&ui_frame, 10),
		y,
		w - ui.ui_frame_sc(&ui_frame, 20),
		ui.ui_frame_sc(&ui_frame, 26),
		"UI scale\u2026",
	) {
		settings_open = true
		settings_sel = ui.settings_scale_preset_index(stored_scale)
	}
}

apply_gallery_theme :: proc() {
	t :=
		ui.theme_high_contrast() if high_contrast else (ui.theme_dark() if dark else ui.theme_light())
	t.reduced_motion = reduced_motion
	ui.ui_runtime_set_theme(&ui_runtime, t)
}

draw_content :: proc(sw, sh: i32) {
	x := ui.ui_frame_sc(&ui_frame, NAV_W)
	w := sw - x
	y := ui.pane_begin(
		&ui_frame,
		&content_pane,
		x,
		0,
		w,
		sh,
		pad = 14,
		keyboard = section != .Inputs,
	)
	cx := x + ui.ui_frame_sc(&ui_frame, 18)
	cw := w - ui.ui_frame_sc(&ui_frame, 52)

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
		md_ctx := ui.markdown_context(&ui_frame)
		end_y =
			ui.draw_markdown(
				&md_ctx,
				cx,
				y,
				cw,
				MARKDOWN_SAMPLE,
				ui.ui_frame_theme(&ui_frame).fg_primary,
			) +
			y
	case .Layout:
		end_y = draw_layout_demo(cx, y, cw)
	case .Overlay:
		end_y = draw_overlay_demo(cx, y, cw)
	case .Stress:
		end_y = draw_stress(cx, y, cw)
	}
	ui.pane_end(&ui_frame, &content_pane, x, 0, w, sh, end_y, pad = 14)
}

draw_buttons :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(&ui_frame, x, y0, w, "BUTTON STYLES")
	bw := ui.ui_frame_sc(&ui_frame, 120)
	bh := ui.ui_frame_sc(&ui_frame, 30)
	gap := ui.ui_frame_sc(&ui_frame, 10)
	if ui.btn(&ui_frame, x, y, bw, bh, "Primary", ui.Btn_Style.Primary) do click_count += 1
	if ui.btn(&ui_frame, x + (bw + gap), y, bw, bh, "Secondary", ui.Btn_Style.Secondary) do click_count += 1
	if ui.btn(&ui_frame, x + (bw + gap) * 2, y, bw, bh, "Danger", ui.Btn_Style.Danger) do click_count += 1
	if ui.btn(&ui_frame, x + (bw + gap) * 3, y, bw, bh, "Ghost", ui.Btn_Style.Ghost) do click_count += 1
	y += bh + gap
	ui.btn(&ui_frame, x, y, bw, bh, "Disabled", ui.Btn_Style.Primary, enabled = false)
	if ui.icon_btn(&ui_frame, x + bw + gap, y, bh, "\u2715") do click_count += 1
	if ui.back_btn(&ui_frame, x + bw + gap + bh + gap, y + ui.ui_frame_sc(&ui_frame, 4), "Back") do click_count += 1
	y += bh + gap

	count := fmt.tprintf("clicks: %d", click_count)
	ui.draw_text_frame(
		&ui_frame,
		strings.clone_to_cstring(count, context.temp_allocator),
		x,
		y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	y += ui.ui_frame_sc(&ui_frame, 30)

	y = ui.section_header(&ui_frame, x, y, w, "KEYBOARD FOCUS (Tab cycles, Space/Enter activates)")
	ui.form_focus_cycle(&focus_slot, 3)
	for i in 0 ..< 3 {
		label := fmt.tprintf("Focusable %d", i + 1)
		if ui.btn(
			&ui_frame,
			x + i32(i) * (bw + gap),
			y,
			bw,
			bh,
			label,
			focus = ui.Focus_Opt{&focus_slot, i + 1},
		) {
			click_count += 1
		}
	}
	y += bh + ui.ui_frame_sc(&ui_frame, 16)

	y = ui.section_header(&ui_frame, x, y, w, "COLLAPSIBLE HEADERS")
	for i in 0 ..< 3 {
		label := fmt.tprintf("Section %d", i + 1)
		ui.collapsible_header(&ui_frame, x, y, w, label, &headers_open[i])
		y += ui.ui_frame_sc(&ui_frame, 28)
		if headers_open[i] {
			ui.draw_text_frame(
				&ui_frame,
				"Collapsed state is a caller-owned bool.",
				x + ui.ui_frame_sc(&ui_frame, 12),
				y,
				ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
				ui.ui_frame_theme(&ui_frame).fg_secondary,
			)
			y += ui.ui_frame_sc(&ui_frame, 24)
		}
	}
	return y
}

draw_inputs :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(
		&ui_frame,
		x,
		y0,
		w,
		"TEXT INPUTS (Input_Box bundle: builder + caret + undo + pills)",
	)
	iw := min(w, ui.ui_frame_sc(&ui_frame, 420))

	state := &input_state
	ui.ui_begin_frame(
		&state.ctx,
		&ui_frame,
		x,
		y,
		iw,
		ui.ui_frame_sc(&ui_frame, 600),
		gap = ui.ui_frame_sc(&ui_frame, 10),
	)
	ui.input(&state.ctx, INPUT_NAME_ID, &state.name, "Your name (undo, selection, spellcheck)")
	ui.input(&state.ctx, INPUT_PASS_ID, &state.pass, "Password (masked)", masked = true)
	ui.input(
		&state.ctx,
		INPUT_NOTES_ID,
		&state.notes,
		"Notes\u2026 (Shift+Enter for newlines)",
		h = ui.ui_frame_sc(&ui_frame, 90),
	)

	if ui.btn(&state.ctx, INPUT_RESET_ID, "Reset all") {
		ui.input_box_reset(&state.name)
		ui.input_box_reset(&state.pass)
		ui.input_box_reset(&state.notes)
	}
	ui.ui_space(&state.ctx, ui.ui_frame_sc(&ui_frame, 6))

	summary := fmt.tprintf(
		"name: %q \u00b7 notes: %d bytes",
		ui.input_box_text(&state.name),
		len(ui.input_box_text(&state.notes)),
	)
	ui.label(
		&state.ctx,
		summary,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)

	end_y := ui.remaining(&state.ctx.layout).y
	ui.ui_end(&state.ctx)
	return end_y + ui.ui_frame_sc(&ui_frame, 24)
}

draw_widgets :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(
		&ui_frame,
		x,
		y0,
		w,
		"FORM CONTROLS (checkbox / radio / slider / dropdown)",
	)
	state := &widget_state
	ui.ui_begin_frame(
		&state.ctx,
		&ui_frame,
		x,
		y,
		w,
		ui.ui_frame_sc(&ui_frame, 400),
		gap = ui.ui_frame_sc(&ui_frame, 8),
	)
	ui.ui_row(
		&state.ctx,
		ui.ui_frame_metrics(&ui_frame).ROW_H_SM,
		gap = ui.ui_frame_sc(&ui_frame, 10),
	)
	ui.checkbox(&state.ctx, WIDGET_ENABLE_ID, "Enable widgets", &state.check_a)
	ui.checkbox(&state.ctx, WIDGET_VERBOSE_ID, "Verbose logs", &state.check_b)
	ui.ui_row_end(&state.ctx)
	ui.ui_row(
		&state.ctx,
		ui.ui_frame_metrics(&ui_frame).ROW_H_SM,
		gap = ui.ui_frame_sc(&ui_frame, 10),
	)
	ui.radio(&state.ctx, WIDGET_SMALL_ID, "Small", &state.radio_choice, 0)
	ui.radio(&state.ctx, WIDGET_MEDIUM_ID, "Medium", &state.radio_choice, 1)
	ui.radio(&state.ctx, WIDGET_LARGE_ID, "Large", &state.radio_choice, 2)
	ui.ui_row_end(&state.ctx)
	ui.ui_row(
		&state.ctx,
		ui.ui_frame_metrics(&ui_frame).ROW_H_SM,
		gap = ui.ui_frame_sc(&ui_frame, 10),
	)
	slider_rect := ui.ui_slot(
		&state.ctx,
		ui.ui_frame_sc(&ui_frame, 240),
		ui.ui_frame_metrics(&ui_frame).ROW_H_SM,
	)
	ui.slider_at_state(
		&ui_frame,
		&state.slider,
		slider_rect,
		&state.volume,
		0,
		100,
		5,
		ui.ui_focus(&state.ctx, WIDGET_VOLUME_ID),
	)
	ui.tooltip(
		&ui_frame,
		&state.tooltip,
		slider_rect,
		"drag, or use \u2190/\u2192 when focused",
		state.ctx.screen_w,
		state.ctx.screen_h,
	)
	ui.label(
		&state.ctx,
		fmt.tprintf("%.0f%%", state.volume),
		color = ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	ui.ui_row_end(&state.ctx)
	backends := []string{"Metal", "Vulkan", "D3D12", "WebGPU"}
	ui.dropdown(&state.ctx, WIDGET_BACKEND_ID, backends, &state.dd_selected, &state.dropdown)
	y = ui.remaining(&state.ctx.layout).y + ui.ui_frame_sc(&ui_frame, 14)
	ui.ui_end(&state.ctx)

	y = ui.section_header(&ui_frame, x, y, w, "PROGRESS / SPINNER / PILLS")
	ui.spinner(
		&ui_frame,
		x + ui.ui_frame_sc(&ui_frame, 16),
		y + ui.ui_frame_sc(&ui_frame, 16),
		ui.ui_frame_scf(&ui_frame, 14),
	)
	ui.progress_bar(
		&ui_frame,
		x + ui.ui_frame_sc(&ui_frame, 48),
		y + ui.ui_frame_sc(&ui_frame, 4),
		ui.ui_frame_sc(&ui_frame, 200),
		ui.ui_frame_sc(&ui_frame, 8),
		0.65,
		ui.ui_frame_theme(&ui_frame).fg_accent,
	)
	ui.progress_bar_animated(
		&ui_frame,
		x + ui.ui_frame_sc(&ui_frame, 48),
		y + ui.ui_frame_sc(&ui_frame, 20),
		ui.ui_frame_sc(&ui_frame, 200),
		ui.ui_frame_sc(&ui_frame, 8),
		progress_frac,
		&progress_anim,
		ui.ui_frame_theme(&ui_frame).fg_success,
	)
	if ui.btn(
		&ui_frame,
		x + ui.ui_frame_sc(&ui_frame, 260),
		y,
		ui.ui_frame_sc(&ui_frame, 90),
		ui.ui_frame_sc(&ui_frame, 24),
		"Replay",
	) {
		progress_anim = 0
	}
	y += ui.ui_frame_sc(&ui_frame, 44)
	px := x
	px +=
		ui.status_pill(
			&ui_frame,
			"active",
			px,
			y,
			ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
			ui.ui_frame_theme(&ui_frame).fg_success,
		) +
		ui.ui_frame_sc(&ui_frame, 8)
	px +=
		ui.status_pill(
			&ui_frame,
			"warning",
			px,
			y,
			ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
			ui.ui_frame_theme(&ui_frame).fg_tool,
		) +
		ui.ui_frame_sc(&ui_frame, 8)
	ui.status_pill(
		&ui_frame,
		"error",
		px,
		y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_error,
	)
	y += ui.ui_frame_sc(&ui_frame, 34)

	y = ui.section_header(&ui_frame, x, y, w, "KV ROWS + LIST ROWS")
	ui.kv_row_frame(
		&ui_frame,
		x,
		y,
		min(w, ui.ui_frame_sc(&ui_frame, 360)),
		"Renderer",
		"WebGPU",
		ui.ui_frame_theme(&ui_frame).fg_secondary,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	y += ui.ui_frame_sc(&ui_frame, 20)
	ui.kv_row_frame(
		&ui_frame,
		x,
		y,
		min(w, ui.ui_frame_sc(&ui_frame, 360)),
		"State model",
		"caller-owned",
		ui.ui_frame_theme(&ui_frame).fg_secondary,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	y += ui.ui_frame_sc(&ui_frame, 26)
	for i in 0 ..< 3 {
		rect := rl.Rectangle {
			f32(x),
			f32(y),
			f32(min(w, ui.ui_frame_sc(&ui_frame, 360))),
			f32(ui.ui_frame_sc(&ui_frame, 24)),
		}
		hovered := rl.CheckCollisionPointRec(rl.GetMousePosition(), rect)
		ui.list_row_bg(&ui_frame, rect, i == 1, hovered)
		label := fmt.tprintf("list row %d%s", i + 1, " (selected)" if i == 1 else "")
		ui.draw_text_frame(
			&ui_frame,
			strings.clone_to_cstring(label, context.temp_allocator),
			x + ui.ui_frame_sc(&ui_frame, 8),
			y + ui.ui_frame_sc(&ui_frame, 4),
			ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
			ui.ui_frame_theme(&ui_frame).fg_primary,
		)
		y += ui.ui_frame_sc(&ui_frame, 26)
	}
	y += ui.ui_frame_sc(&ui_frame, 8)

	y = ui.section_header(&ui_frame, x, y, w, "CARD + SHADOW + TRUNCATION")
	card := rl.Rectangle {
		f32(x),
		f32(y),
		f32(min(w, ui.ui_frame_sc(&ui_frame, 360))),
		f32(ui.ui_frame_sc(&ui_frame, 64)),
	}
	ui.draw_shadow_rounded(&ui_frame, card, 0.15)
	ui.draw_card_bg_frame(
		&ui_frame,
		card,
		ui.ui_frame_theme(&ui_frame).bg_secondary,
		accent_w = ui.ui_frame_sc(&ui_frame, 3),
	)
	ui.draw_text_truncated_frame(
		&ui_frame,
		"A very long label that will be cut with an ellipsis when it overflows the card",
		x + ui.ui_frame_sc(&ui_frame, 12),
		y + ui.ui_frame_sc(&ui_frame, 12),
		i32(card.width) - ui.ui_frame_sc(&ui_frame, 24),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	path := ui.truncate_path_middle_frame(
		&ui_frame,
		"ingot/examples/gallery/very/deep/dir/main.odin",
		i32(card.width) - ui.ui_frame_sc(&ui_frame, 24),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
	)
	ui.draw_text_frame(
		&ui_frame,
		strings.clone_to_cstring(path, context.temp_allocator),
		x + ui.ui_frame_sc(&ui_frame, 12),
		y + ui.ui_frame_sc(&ui_frame, 34),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	y += i32(card.height) + ui.ui_frame_sc(&ui_frame, 16)

	y = ui.section_header(&ui_frame, x, y, w, "FIT-CONTENT CARD")
	fit_w := min(w, ui.ui_frame_sc(&ui_frame, 360))
	pad := ui.ui_frame_sc(&ui_frame, 12)
	column: ui.Fit_Column
	ui.fit_column_begin(
		&column,
		x + pad,
		y + pad,
		fit_w - pad * 2,
		gap = ui.ui_frame_sc(&ui_frame, 6),
	)
	title := ui.fit_column_next(&column, ui.ui_frame_sc(&ui_frame, 18))
	detail := ui.fit_column_next(&column, ui.ui_frame_sc(&ui_frame, 18))
	content := ui.fit_column_end(&column)
	fit_card := rl.Rectangle{f32(x), f32(y), f32(fit_w), f32(content.h + pad * 2)}
	ui.draw_card_bg_frame(&ui_frame, fit_card, ui.ui_frame_theme(&ui_frame).bg_secondary)
	ui.draw_text_frame(
		&ui_frame,
		"Geometry resolved before drawing",
		title.x,
		title.y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	ui.draw_text_frame(
		&ui_frame,
		"No retained tree or trailing gap",
		detail.x,
		detail.y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	return y + i32(fit_card.height) + ui.ui_frame_sc(&ui_frame, 16)
}

draw_charts :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(
		&ui_frame,
		x,
		y0,
		w,
		"LINE + BAR + SPARKLINE (hover for overlay tooltips)",
	)
	cw := min(w, ui.ui_frame_sc(&ui_frame, 560))
	series := [2]ui.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	ui.line_chart(
		&ui_frame,
		x,
		y,
		cw,
		ui.ui_frame_sc(&ui_frame, 240),
		series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	y += ui.ui_frame_sc(&ui_frame, 252)
	ui.bar_chart(
		&ui_frame,
		x,
		y,
		cw,
		ui.ui_frame_sc(&ui_frame, 220),
		series[:],
		&bar_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	y += ui.ui_frame_sc(&ui_frame, 232)
	ui.draw_text_frame(
		&ui_frame,
		"sparkline:",
		x,
		y + ui.ui_frame_sc(&ui_frame, 6),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	ui.sparkline(
		&ui_frame,
		x + ui.ui_frame_sc(&ui_frame, 80),
		y,
		ui.ui_frame_sc(&ui_frame, 140),
		ui.ui_frame_sc(&ui_frame, 28),
		spark[:],
	)
	return y + ui.ui_frame_sc(&ui_frame, 40)
}

draw_layout_demo :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(&ui_frame, x, y0, w, "SINGLE-PASS LAYOUT (weights + flex sizing)")
	l: ui.Layout
	lw := min(w, ui.ui_frame_sc(&ui_frame, 520))
	ui.layout_begin(
		&l,
		x,
		y,
		lw,
		ui.ui_frame_sc(&ui_frame, 248),
		gap = ui.ui_frame_sc(&ui_frame, 8),
	)

	ui.push_row(&l, ui.ui_frame_sc(&ui_frame, 40), gap = ui.ui_frame_sc(&ui_frame, 8))
	ui.row_weights(&l, {1, 2, 1})
	cell(ui.next_weighted(&l, 1), "1fr")
	cell(ui.next_weighted(&l, 2), "2fr")
	cell(ui.next_weighted(&l, 1), "1fr")
	ui.layout_pop(&l)

	ui.push_row(&l, ui.ui_frame_sc(&ui_frame, 40), gap = ui.ui_frame_sc(&ui_frame, 8))
	cell(ui.next(&l, ui.ui_frame_sc(&ui_frame, 120)), "fixed 120")
	cell(ui.remaining(&l), "remaining")
	ui.layout_pop(&l)

	ui.push_row(
		&l,
		ui.ui_frame_sc(&ui_frame, 90),
		gap = ui.ui_frame_sc(&ui_frame, 8),
		cross_align = .Center,
	)
	cell(
		ui.next_sized(&l, ui.ui_frame_sc(&ui_frame, 160), ui.ui_frame_sc(&ui_frame, 50)),
		"centered",
	)
	ui.layout_pop(&l)

	ui.push_row(&l, ui.ui_frame_sc(&ui_frame, 40), gap = ui.ui_frame_sc(&ui_frame, 8))
	ui.flex_begin(
		&l,
		{
			ui.flex_fixed(ui.ui_frame_sc(&ui_frame, 72)),
			ui.flex_fit(ui.ui_frame_sc(&ui_frame, 96), min_size = ui.ui_frame_sc(&ui_frame, 56)),
			ui.flex_percent(0.2),
			ui.flex_grow(),
		},
	)
	cell(ui.flex_next(&l), "fixed")
	cell(ui.flex_next(&l), "fit")
	cell(ui.flex_next(&l), "20%")
	cell(ui.flex_next(&l), "grow")
	ui.layout_pop(&l)

	ui.layout_end(&l)
	return y + ui.ui_frame_sc(&ui_frame, 258)
}

cell :: proc(r: ui.Rect_I32, label: string) {
	if r.w <= 0 || r.h <= 0 do return
	rl.DrawRectangle(r.x, r.y, r.w, r.h, ui.ui_frame_theme(&ui_frame).bg_active)
	rl.DrawRectangleLines(r.x, r.y, r.w, r.h, ui.ui_frame_theme(&ui_frame).border_color)
	c := strings.clone_to_cstring(label, context.temp_allocator)
	tw := ui.measure_text_frame(&ui_frame, c, ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL)
	ui.draw_text_frame(
		&ui_frame,
		c,
		r.x + (r.w - tw) / 2,
		r.y + (r.h - ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL) / 2,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
}

draw_overlay_demo :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(
		&ui_frame,
		x,
		y0,
		w,
		"OVERLAY + INPUT ROUTING (popup occludes the buttons under it)",
	)
	bw := ui.ui_frame_sc(&ui_frame, 150)
	bh := ui.ui_frame_sc(&ui_frame, 30)
	// These buttons sit UNDER the popup. With routing, clicks on the popup
	// must not reach them.
	for i in 0 ..< 3 {
		label := fmt.tprintf("Shielded %d", i + 1)
		if ui.btn(&ui_frame, x, y + i32(i) * (bh + ui.ui_frame_sc(&ui_frame, 8)), bw, bh, label) {
			shielded_clicks += 1
		}
	}
	info_y := y + 3 * (bh + ui.ui_frame_sc(&ui_frame, 8))
	summary := fmt.tprintf(
		"shielded clicks: %d (should not rise while the popup covers them)",
		shielded_clicks,
	)
	ui.draw_text_frame(
		&ui_frame,
		strings.clone_to_cstring(summary, context.temp_allocator),
		x,
		info_y,
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)

	if ui.btn(
		&ui_frame,
		x + bw + ui.ui_frame_sc(&ui_frame, 100),
		y,
		ui.ui_frame_sc(&ui_frame, 150),
		bh,
		"Toggle popup",
		ui.Btn_Style.Primary,
	) {
		popup_open = !popup_open
	}
	if ui.btn(
		&ui_frame,
		x + bw + ui.ui_frame_sc(&ui_frame, 100),
		y + bh + ui.ui_frame_sc(&ui_frame, 8),
		ui.ui_frame_sc(&ui_frame, 150),
		bh,
		"Open modal",
	) {
		about_modal.open = true
	}

	// Generic context menu: right-click anywhere in this section opens it.
	if rl.IsMouseButtonPressed(.RIGHT) && !ctx_menu.open && !about_modal.open {
		m := rl.GetMousePosition()
		ui.context_menu_open(&ctx_menu, i32(m.x), i32(m.y))
	}
	if ctx_menu.open {
		items := []ui.Menu_Item {
			{label = "Reset shielded clicks"},
			{label = "Unavailable action", disabled = true},
			{separator = true},
			{label = "Close menu"},
		}
		chosen := ui.context_menu(
			&ui_frame,
			&ctx_menu,
			items,
			rl.GetScreenWidth(),
			rl.GetScreenHeight(),
		)
		if chosen == 0 {
			shielded_clicks = 0
			ctx_note = "shielded clicks reset via context menu"
		}
	}
	ui.draw_text_frame(
		&ui_frame,
		strings.clone_to_cstring(ctx_note, context.temp_allocator),
		x,
		info_y + ui.ui_frame_sc(&ui_frame, 22),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_label,
	)

	if popup_open {
		// Fully covers all three shielded buttons (and nothing else), so any
		// click on them while the popup is open would be a routing leak.
		draw_demo_popup(x - ui.ui_frame_sc(&ui_frame, 8), y - ui.ui_frame_sc(&ui_frame, 8))
	}

	// Generic modal: dims, claims all input, Escape / click-outside dismisses.
	if about_modal.open {
		body := ui.modal_begin(
			&ui_frame,
			&about_modal,
			"Generic modal",
			ui.ui_frame_sc(&ui_frame, 420),
			ui.ui_frame_sc(&ui_frame, 190),
			rl.GetScreenWidth(),
			rl.GetScreenHeight(),
		)
		ui.draw_text_wrapped_frame(
			&ui_frame,
			body.x + ui.ui_frame_metrics(&ui_frame).PADDING,
			body.y + ui.ui_frame_sc(&ui_frame, 4),
			body.w - ui.ui_frame_metrics(&ui_frame).PADDING * 2,
			"The settings panel is built on this same modal_begin/modal_end pair. " +
			"Escape or a click outside dismisses it.",
			ui.ui_frame_theme(&ui_frame).fg_primary,
			ui.ui_frame_metrics(&ui_frame).FONT_SIZE,
			ui.ui_frame_metrics(&ui_frame).LINE_HEIGHT,
		)
		if ui.btn(
			&ui_frame,
			body.x + ui.ui_frame_metrics(&ui_frame).PADDING,
			body.y + body.h - ui.ui_frame_sc(&ui_frame, 44),
			ui.ui_frame_sc(&ui_frame, 90),
			ui.ui_frame_sc(&ui_frame, 28),
			"Close",
			ui.Btn_Style.Primary,
		) {
			about_modal.open = false
		}
		ui.modal_end(&about_modal)
	}
	return info_y + ui.ui_frame_sc(&ui_frame, 52)
}

// draw_demo_popup records a popup on the overlay layer (drawn above content
// painted later) and claims its rect so widgets underneath are inert.
draw_demo_popup :: proc(x, y: i32) {
	w := ui.ui_frame_sc(&ui_frame, 220)
	h := ui.ui_frame_sc(&ui_frame, 130)
	rect := rl.Rectangle{f32(x), f32(y), f32(w), f32(h)}
	ui.overlay_begin(&ui_frame, rect, claim_input = true)
	ui.overlay_rounded(&ui_frame, rect, 0.1, 6, ui.ui_frame_theme(&ui_frame).bg_popup)
	ui.overlay_rounded_lines(
		&ui_frame,
		rect,
		0.1,
		6,
		1.0,
		ui.ui_frame_theme(&ui_frame).border_color,
	)
	ui.overlay_text(
		&ui_frame,
		"Overlay popup",
		x + ui.ui_frame_sc(&ui_frame, 12),
		y + ui.ui_frame_sc(&ui_frame, 10),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE,
		ui.ui_frame_theme(&ui_frame).fg_primary,
	)
	ui.overlay_text(
		&ui_frame,
		"Recorded during the frame,",
		x + ui.ui_frame_sc(&ui_frame, 12),
		y + ui.ui_frame_sc(&ui_frame, 36),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)
	ui.overlay_text(
		&ui_frame,
		"replayed above everything.",
		x + ui.ui_frame_sc(&ui_frame, 12),
		y + ui.ui_frame_sc(&ui_frame, 54),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_secondary,
	)

	// Close row: the popup is topmost, so it hit-tests raw input.
	row := rl.Rectangle {
		f32(x + ui.ui_frame_sc(&ui_frame, 12)),
		f32(y + h - ui.ui_frame_sc(&ui_frame, 30)),
		f32(w - ui.ui_frame_sc(&ui_frame, 24)),
		f32(ui.ui_frame_sc(&ui_frame, 22)),
	}
	mouse := rl.GetMousePosition()
	hovered := rl.CheckCollisionPointRec(mouse, row)
	if hovered {
		ui.overlay_rect(&ui_frame, row, ui.ui_frame_theme(&ui_frame).bg_active)
		ui.request_cursor(&ui_frame, .POINTING_HAND)
	}
	ui.overlay_text(
		&ui_frame,
		"Close",
		x + ui.ui_frame_sc(&ui_frame, 18),
		y + h - ui.ui_frame_sc(&ui_frame, 28),
		ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
		ui.ui_frame_theme(&ui_frame).fg_accent,
	)
	if hovered && rl.IsMouseButtonReleased(.LEFT) {
		popup_open = false
	}
	ui.overlay_end(&ui_frame)
}

draw_stress :: proc(x, y0, w: i32) -> i32 {
	y := ui.section_header(
		&ui_frame,
		x,
		y0,
		w,
		"STRESS: 1000 BUTTONS (batcher, hover-anim bound, culling)",
	)
	cols := max(int(w / ui.ui_frame_sc(&ui_frame, 110)), 1)
	bw := ui.ui_frame_sc(&ui_frame, 100)
	bh := ui.ui_frame_sc(&ui_frame, 26)
	for i in 0 ..< 1000 {
		col := i % cols
		row := i / cols
		bx := x + i32(col) * (bw + ui.ui_frame_sc(&ui_frame, 6))
		by := y + i32(row) * (bh + ui.ui_frame_sc(&ui_frame, 6))
		label := fmt.tprintf("btn %d", i)
		if ui.btn(&ui_frame, bx, by, bw, bh, label) {
			stress_clicked = i
		}
	}
	rows := (1000 + cols - 1) / cols
	y += i32(rows) * (bh + ui.ui_frame_sc(&ui_frame, 6)) + ui.ui_frame_sc(&ui_frame, 10)
	if stress_clicked >= 0 {
		msg := fmt.tprintf("last clicked: btn %d", stress_clicked)
		ui.draw_text_frame(
			&ui_frame,
			strings.clone_to_cstring(msg, context.temp_allocator),
			x,
			y,
			ui.ui_frame_metrics(&ui_frame).FONT_SIZE_SMALL,
			ui.ui_frame_theme(&ui_frame).fg_secondary,
		)
		y += ui.ui_frame_sc(&ui_frame, 24)
	}
	return y
}
