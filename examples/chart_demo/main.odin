// Chart widgets demo: line chart with area fill, grouped bar chart, and
// sparkline stat cards, with a dark/light theme toggle. Redraws are
// event-driven (EnableEventWaiting): frames only run on input or while a
// chart's enter animation is settling. Build & run:
//
//	odin run examples/chart_demo -collection:ingot=.
package main

import rl "ingot:gfx"
import "ingot:ui"
import "ingot:ui_gfx"

dark := true
line_state: ui.Chart_State
bar_state: ui.Chart_State
app: ui_gfx.App

revenue := [12]f32{12.4, 14.1, 13.2, 16.8, 18.9, 17.4, 21.0, 22.6, 20.1, 24.3, 26.8, 25.2}
costs := [12]f32{8.1, 8.4, 9.0, 9.7, 10.2, 11.5, 11.1, 12.4, 12.0, 13.6, 13.1, 14.0}
hours := [7]f32{32, 41, 38, 45, 29, 12, 6}
billable := [7]f32{28, 36, 30, 41, 24, 8, 2}
spark_up := [10]f32{3, 4, 3.6, 5, 6.2, 5.8, 7, 8.4, 8.1, 9.3}
spark_down := [10]f32{9, 8.2, 8.6, 7.4, 7.9, 6.8, 6.1, 6.4, 5.2, 4.8}
spark_flat := [10]f32{5, 5.4, 4.8, 5.1, 5.3, 4.9, 5.2, 5.0, 5.3, 5.1}

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
DAYS := [7]string{"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"}

main :: proc() {
	_ = ui_gfx.app_run(
		&app,
		{
			width = 960,
			height = 720,
			title = "ingot chart demo",
			target_fps = 60,
			event_waiting = true,
			clear_color = {24, 26, 32, 255},
			session = {semantics_enabled = true},
		},
		{frame = frame},
	)
}

frame :: proc(app: ^ui_gfx.App, ui_frame: ^ui.Ui_Frame, userdata: rawptr) {
	_ = userdata
	style := ui.ui_frame_theme(ui_frame)
	metrics := ui.ui_frame_metrics(ui_frame)
	root := ui_gfx.app_screen_rect(app)
	sw := root.w

	ui.draw_text_frame(
		ui_frame,
		"Chart widgets",
		24,
		20,
		metrics.FONT_SIZE_TITLE,
		style.fg_primary,
	)
	if ui.button_at(ui_frame, {sw - 140, 16, 120, 30}, "Light theme" if dark else "Dark theme") {
		dark = !dark
		ui.ui_runtime_set_theme(
			ui_gfx.app_ui_runtime(app),
			ui.theme_dark() if dark else ui.theme_light(),
		)
	}

	line_series := [2]ui.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	ui.line_chart_at(
		ui_frame,
		{24, 64, 580, 300},
		line_series[:],
		&line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)

	bar_series := [2]ui.Chart_Series {
		{name = "Total h", values = hours[:]},
		{name = "Billable h", values = billable[:]},
	}
	ui.bar_chart_at(
		ui_frame,
		{24, 396, 580, 280},
		bar_series[:],
		&bar_state,
		{labels = DAYS[:], show_grid = true, show_axes = true, show_legend = true},
	)

	stat_card(ui_frame, 628, 64, 308, 92, "ACTIVE PROJECTS", "9.3", spark_up[:], style.fg_success)
	stat_card(ui_frame, 628, 168, 308, 92, "OPEN TASKS", "4.8", spark_down[:], style.fg_error)
	stat_card(
		ui_frame,
		628,
		272,
		308,
		92,
		"AVG HOURS / DAY",
		"5.1",
		spark_flat[:],
		style.fg_accent,
	)
}

stat_card :: proc(
	frame: ^ui.Ui_Frame,
	x, y, w, h: i32,
	label, value: cstring,
	values: []f32,
	col: ui.Color,
) {
	style := ui.ui_frame_theme(frame)
	metrics := ui.ui_frame_metrics(frame)
	ui.card_bg_at(frame, {x, y, w, h}, style.bg_secondary)
	ui.draw_text_frame(frame, label, x + 14, y + 12, metrics.FONT_SIZE_LABEL, style.fg_label)
	ui.draw_text_frame(
		frame,
		value,
		x + 14,
		y + h - metrics.FONT_SIZE_TITLE - 14,
		metrics.FONT_SIZE_TITLE,
		style.fg_primary,
	)
	ui.sparkline_at(frame, {x + w - 130, y + h / 2 - 16, 110, 32}, values, col)
}
