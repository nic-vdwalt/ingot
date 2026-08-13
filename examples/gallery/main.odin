package main

import "core:fmt"
import fit "ingot:fit"
import "ingot:sys"

SMOKE :: #config(INGOT_SMOKE, false)
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

Input_State :: struct {
	region: fit.Region,
	name:   fit.Input_Box,
	pass:   fit.Input_Box,
	notes:  fit.Input_Box,
}

Widget_State :: struct {
	check_a:      bool,
	check_b:      bool,
	radio_choice: i32,
	volume:       f32,
}

NARROW_WIDTH_MAX :: 640
MARGIN_INSET :: 56

palette := Palette.Dark
reduced_motion := false
section := Section.Buttons
stored_scale: f32
app: fit.App
content_pane: fit.Pane_State
input_state: Input_State
widget_state := Widget_State {
	check_a = true,
	volume  = 40,
}
click_count: int
progress_anim: f32
progress_frac: f32 = 0.35
line_state: fit.Chart_State
bar_state: fit.Chart_State

nav_activated: [Section]bool
palette_activated: bool
motion_activated: bool
scale_activated: bool
primary_activated: bool
secondary_activated: bool
danger_activated: bool
ghost_activated: bool
reset_inputs_activated: bool
open_url_activated: bool
replay_activated: bool
stress_activated: [32]bool
stress_clicked := -1

main :: proc() {
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

palette_theme :: proc(value: Palette) -> fit.Theme {
	switch value {
	case .Dark:
		return fit.Theme_Dark()
	case .Light:
		return fit.Theme_Light()
	case .Sketch_Warm:
		return fit.Theme_Sketch_Warm()
	case .Sketch_Grey:
		return fit.Theme_Sketch_Grey()
	case .High_Contrast:
		return fit.Theme_High_Contrast()
	}
	return fit.Theme_Dark()
}

apply_gallery_theme :: proc() {
	theme := palette_theme(palette)
	fit.Theme_Set_Reduced_Motion(&theme, reduced_motion)
	when CAPTURE {
		fit.Session_Set_Theme(&capture_session, theme)
	} else {
		fit.Set_Theme(&app, theme)
	}
}

apply_scale :: proc(scale: f32) {
	when CAPTURE {
		fit.Session_Set_Scale(&capture_session, scale)
	} else {
		fit.Set_Scale(&app, scale)
	}
}

consume_actions :: proc() {
	for &activated, candidate in nav_activated {
		if activated {
			section = candidate
			fit.Pane_Reset(&content_pane)
			activated = false
		}
	}
	if palette_activated {
		palette = Palette((int(palette) + 1) % len(Palette))
		palette_activated = false
		apply_gallery_theme()
	}
	if motion_activated {
		reduced_motion = !reduced_motion
		motion_activated = false
		apply_gallery_theme()
	}
	if scale_activated {
		stored_scale += 0.5
		if stored_scale > 2 do stored_scale = 0
		scale_activated = false
		apply_scale(stored_scale)
	}
	activations := [?]^bool {
		&primary_activated,
		&secondary_activated,
		&danger_activated,
		&ghost_activated,
	}
	for activation in activations {
		if activation^ {
			click_count += 1
			activation^ = false
		}
	}
	if reset_inputs_activated {
		fit.Input_Box_Reset(&input_state.name)
		fit.Input_Box_Reset(&input_state.pass)
		fit.Input_Box_Reset(&input_state.notes)
		reset_inputs_activated = false
	}
	if open_url_activated {
		_ = sys.open_url("https://example.com")
		open_url_activated = false
	}
	if replay_activated {
		progress_anim = 0
		replay_activated = false
	}
	for &activated, index in stress_activated {
		if activated {
			stress_clicked = index
			activated = false
		}
	}
}

gallery_build :: proc(builder: ^fit.Builder, userdata: rawptr) {
	assert(builder != nil, "gallery_build: nil builder")
	_ = userdata
	consume_actions()
	when SMOKE do smoke_step()
	when CAPTURE do capture_step()

	fit.Row(builder, {gap = .MD, padding = .MD, size = {width = fit.Grow(), height = fit.Grow()}})
	build_navigation(builder)
	fit.Column(builder, {gap = .MD, track = fit.Grow(), size = {height = fit.Grow()}})
	fit.Label(builder, SECTION_NAMES[section], {role = .Title, ink = .Heading})
	fit.Label(
		builder,
		fmt.tprintf("Fit Builder + callback-borrowed Surface · %s", PALETTE_NAMES[palette]),
		{role = .Label, ink = .Secondary},
	)
	build_section(builder)
	fit.End(builder)
	fit.End(builder)
}

build_navigation :: proc(builder: ^fit.Builder) {
	fit.Column(builder, {gap = .XS, size = {width = fit.Fixed(180), height = fit.Grow()}})
	fit.Label(builder, "ingot gallery", {role = .Title})
	for candidate in Section {
		style := fit.Button_Style.Primary if candidate == section else .Ghost
		fit.Button(
			builder,
			SECTION_NAMES[candidate],
			SECTION_NAMES[candidate],
			fit.Button_Options {
				style = style,
				size = {width = fit.Grow()},
				activated = &nav_activated[candidate],
			},
		)
	}
	fit.Button(
		builder,
		"palette",
		fmt.tprintf("Theme: %s", PALETTE_NAMES[palette]),
		&palette_activated,
	)
	fit.Button(
		builder,
		"motion",
		"Motion: reduced" if reduced_motion else "Motion: full",
		&motion_activated,
	)
	fit.Button(builder, "scale", fmt.tprintf("Scale: %.1f", stored_scale), &scale_activated)
	fit.End(builder)
}

build_section :: proc(builder: ^fit.Builder) {
	switch section {
	case .Buttons:
		build_buttons(builder)
	case .Inputs:
		build_inputs(builder)
	case .Widgets:
		build_widgets(builder)
	case .Charts:
		build_charts(builder)
	case .Markdown:
		build_markdown(builder)
	case .Layout:
		build_layout(builder)
	case .Overlay:
		build_overlay(builder)
	case .Stress:
		build_stress(builder)
	case .Theme:
		build_theme(builder)
	}
}

build_buttons :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "BUTTON STYLES", {role = .Label, ink = .Accent})
	fit.Row(builder, {gap = .SM})
	fit.Button(
		builder,
		"primary",
		"Primary",
		fit.Button_Options{style = .Primary, activated = &primary_activated},
	)
	fit.Button(
		builder,
		"secondary",
		"Secondary",
		fit.Button_Options{style = .Secondary, activated = &secondary_activated},
	)
	fit.Button(
		builder,
		"danger",
		"Danger",
		fit.Button_Options{style = .Danger, activated = &danger_activated},
	)
	fit.Button(
		builder,
		"ghost",
		"Ghost",
		fit.Button_Options{style = .Ghost, activated = &ghost_activated},
	)
	fit.End(builder)
	fit.Label(builder, fmt.tprintf("clicks: %d", click_count), {ink = .Secondary})
}

inputs_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	return {w = max(constraints.max_w, 320), h = 360}
}

inputs_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	_ = userdata
	state := &input_state
	fit.Surface_Region_Begin(surface, &state.region, rect, .SM)
	fit.Region_Section_Header(&state.region, "TEXT INPUTS")
	fit.Region_Text_Input(
		&state.region,
		"name",
		&state.name,
		"Your name",
		{semantics = {name = "Name"}},
	)
	fit.Region_Text_Input(
		&state.region,
		"password",
		&state.pass,
		"Password",
		{masked = true, semantics = {name = "Password"}},
	)
	fit.Region_Text_Input(
		&state.region,
		"notes",
		&state.notes,
		"Notes…",
		{height = 90, semantics = {name = "Notes"}},
	)
	fit.Region_Label(
		&state.region,
		fmt.tprintf(
			"name: %q · notes: %d bytes",
			fit.Input_Box_Text(&state.name),
			len(fit.Input_Box_Text(&state.notes)),
		),
		.Label,
		.Secondary,
	)
	_ = fit.Surface_Region_End(&state.region)
	return false
}

build_inputs :: proc(builder: ^fit.Builder) {
	fit.Custom(
		builder,
		{measure = inputs_measure, render = inputs_render},
		{size = {width = fit.Grow(), height = fit.Fixed(360)}},
	)
	fit.Button(builder, "reset-inputs", "Reset all", &reset_inputs_activated)
}

build_widgets :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "CALLER-OWNED CONTROLS", {role = .Label, ink = .Accent})
	fit.Checkbox(builder, "enable", "Enable widgets", &widget_state.check_a)
	fit.Checkbox(builder, "verbose", "Verbose logs", &widget_state.check_b)
	fit.Row(builder, {gap = .SM})
	fit.Radio(builder, "small", "Small", &widget_state.radio_choice, 0)
	fit.Radio(builder, "medium", "Medium", &widget_state.radio_choice, 1)
	fit.Radio(builder, "large", "Large", &widget_state.radio_choice, 2)
	fit.End(builder)
	fit.Slider(builder, "volume", &widget_state.volume, 0, 100, 5, "Volume")
	fit.Label(builder, fmt.tprintf("volume: %.0f%%", widget_state.volume), {ink = .Secondary})
	fit.Button(builder, "replay", "Replay animation", &replay_activated)
}

build_charts :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "CHARTS", {role = .Label, ink = .Accent})
	fit.Label(builder, "Chart data and animation remain caller-owned.", {wrap = true})
	for month in 0 ..< 12 {
		fit.Label(
			builder,
			fmt.tprintf(
				"month %02d  revenue %.1f  cost %.1f",
				month + 1,
				12.4 + f32(month),
				8.1 + f32(month) * 0.5,
			),
			{role = .Note},
		)
	}
}

build_markdown :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "MARKDOWN", {role = .Label, ink = .Accent})
	fit.Label(
		builder,
		"# Immediate mode\n\nCaller-owned state, bounded frame storage, and explicit links.",
		{wrap = true},
	)
	fit.Button(builder, "open-link", "Open https://example.com", &open_url_activated)
}

build_layout :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "RESPONSIVE LAYOUT", {role = .Label, ink = .Accent})
	fit.Grid(builder, {columns = 3, row_height = 48, gap_x = .SM, gap_y = .SM})
	for index in 0 ..< 9 {
		fit.Label(builder, fmt.tprintf("cell %d", index + 1), {ink = .Secondary})
	}
	fit.End(builder)
}

build_overlay :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "ATTACHMENTS", {role = .Label, ink = .Accent})
	fit.Label(builder, "Overlays use Fit attachments and caller-owned open state.", {wrap = true})
	fit.Attachment(
		builder,
		{
			target_kind = .Viewport,
			target_point = .Top_Right,
			self_point = .Top_Right,
			offset_x = -16,
			offset_y = 16,
			z = fit.Z_Order(30),
			claim = true,
		},
	)
	fit.Label(builder, "Fit overlay", {ink = .Accent})
	fit.End(builder)
}

build_stress :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "STRESS: 32 VISIBLE BUTTONS", {role = .Label, ink = .Accent})
	fit.Grid(builder, {columns = 4, row_height = 30, gap_x = .XS, gap_y = .XS})
	for index in 0 ..< len(stress_activated) {
		fit.Button(builder, u64(index + 1), fmt.tprintf("btn %d", index), &stress_activated[index])
	}
	fit.End(builder)
	if stress_clicked >= 0 do fit.Label(builder, fmt.tprintf("last clicked: btn %d", stress_clicked))
}

build_theme :: proc(builder: ^fit.Builder) {
	fit.Label(builder, "DESIGN TOKENS", {role = .Label, ink = .Accent})
	fit.Row(builder, {gap = .SM})
	for ink in fit.Ink {
		fit.Label(builder, fmt.tprint(ink), {role = .Note, ink = ink})
	}
	fit.End(builder)
	fit.Label(builder, "Every value resolves from the active Fit theme.", {wrap = true})
}

gallery_scaled :: proc(value: i32, scale: f32) -> i32 {
	return i32(f32(value) * scale + 0.5)
}

nav_sidebar_min_height_scale :: proc(scale: f32) -> i32 {
	padding := gallery_scaled(8, scale)
	gap := gallery_scaled(4, scale)
	row_height := gallery_scaled(28, scale)
	line_height := gallery_scaled(22, scale)
	row_count := i32(len(Section) + 3)
	item_count := row_count + 3
	return padding * 3 + line_height + 2 + row_count * row_height + (item_count - 1) * gap
}

nav_uses_strip_scale :: proc(scale: f32, width, available_height: i32) -> bool {
	return(
		width <= gallery_scaled(NARROW_WIDTH_MAX, scale) ||
		available_height < nav_sidebar_min_height_scale(scale) \
	)
}

shutdown :: proc() {
	fit.Input_Box_Destroy(&input_state.name)
	fit.Input_Box_Destroy(&input_state.pass)
	fit.Input_Box_Destroy(&input_state.notes)
}
