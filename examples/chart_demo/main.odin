// Chart widgets demo: line chart with area fill, grouped bar chart, and
// sparkline stat cards, with a dark/light theme toggle. Redraws are
// event-driven while chart animations are settling. Build & run:
//
//	odin run examples/chart_demo -collection:ingot=.
package main

import fit "ingot:fit"

State :: struct {
	dark:       bool,
	line_state: fit.Chart_State,
	bar_state:  fit.Chart_State,
}

state := State {
	dark = true,
}
app: fit.App

toggle_theme :: proc(userdata: rawptr) {
	data := cast(^State)userdata
	assert(data != nil, "toggle_theme: nil state")
	data.dark = !data.dark
	fit.Set_Theme(&app, fit.Theme_Dark() if data.dark else fit.Theme_Light())
}

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
	_ = fit.Run(
		&app,
		{
			width = 960,
			height = 720,
			title = "ingot chart demo",
			frame_pacing = .Monitor_Refresh,
			target_fps = 60,
			event_waiting = true,
			session = {semantics_enabled = true},
		},
		frame,
		&state,
	)
}

frame :: proc(builder: ^fit.Builder, userdata: rawptr) {
	data := cast(^State)userdata
	root_container: {
		fit.Column(builder, {gap = .MD, padding = .LG})
		defer fit.End(builder)
		header_container: {
			fit.Row(builder, {gap = .MD, size = {height = fit.Fixed(36)}})
			defer fit.End(builder)
			fit.Label(builder, "Chart widgets", {role = .Title, track = fit.Grow()})
			fit.Button(
				builder,
				"theme",
				"Light theme" if data.dark else "Dark theme",
				fit.Button_Options{track = fit.Fixed(132), action = fit.On(toggle_theme, data)},
			)
		}
		// The dashboard fills the leftover column height; Grow resolves the
		// same on every layout pass, so the panel tracks window resizes.
		fit.Custom(
			builder,
			{measure = dashboard_measure, render = draw_dashboard, userdata = data},
			{size = {width = fit.Grow(), height = fit.Grow()}},
		)
	}
}

dashboard_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	// The height comes from the Grow sizing in frame; the measured height is
	// only a minimal floor.
	return {max(constraints.max_w, 1), 1, false}
}

draw_dashboard :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	data := cast(^State)userdata
	theme := fit.Surface_Theme_Tokens(surface)
	line_series := [2]fit.Chart_Series {
		{name = "Revenue", values = revenue[:]},
		{name = "Costs", values = costs[:]},
	}
	bar_series := [2]fit.Chart_Series {
		{name = "Total h", values = hours[:]},
		{name = "Billable h", values = billable[:]},
	}
	content_w := max(rect.w - 24, 0)
	chart_w := content_w * 2 / 3
	side_x := rect.x + chart_w + 20
	side_w := max(content_w - chart_w - 20, 0)
	_ = fit.Surface_Line_Chart(
		surface,
		{rect.x, rect.y, chart_w, 288},
		line_series[:],
		&data.line_state,
		{labels = MONTHS[:], show_grid = true, show_axes = true, show_legend = true, fill = true},
	)
	_ = fit.Surface_Bar_Chart(
		surface,
		{rect.x, rect.y + 312, chart_w, 280},
		bar_series[:],
		&data.bar_state,
		{labels = DAYS[:], show_grid = true, show_axes = true, show_legend = true},
	)
	stat_card(
		surface,
		{side_x, rect.y, side_w, 92},
		"ACTIVE PROJECTS",
		"9.3",
		spark_up[:],
		theme.foreground_accent,
	)
	stat_card(
		surface,
		{side_x, rect.y + 104, side_w, 92},
		"OPEN TASKS",
		"4.8",
		spark_down[:],
		theme.foreground_secondary,
	)
	stat_card(
		surface,
		{side_x, rect.y + 208, side_w, 92},
		"AVG HOURS / DAY",
		"5.1",
		spark_flat[:],
		theme.foreground_accent,
	)
	return false
}

stat_card :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	label, value: string,
	values: []f32,
	color: fit.Color,
) {
	theme := fit.Surface_Theme_Tokens(surface)
	metrics := fit.Surface_Metrics(surface)
	fit.Surface_Card_Background(surface, rect, theme.background_secondary)
	fit.Surface_Text(surface, label, rect.x + 14, rect.y + 12, .Label, .Label)
	fit.Surface_Text(
		surface,
		value,
		rect.x + 14,
		rect.y + rect.h - metrics.font_title - 14,
		.Title,
	)
	fit.Surface_Sparkline(
		surface,
		{rect.x + rect.w - 130, rect.y + rect.h / 2 - 16, 110, 32},
		values,
		color,
	)
}
