// Ingot public API map. The diagram intentionally describes only consumer
// boundaries: App owns lifecycle, Builder declares the frame, and Surface is a
// callback-scoped explicit drawing capability.
package main

import fit "ingot:fit"

LAYOUT_CHECK :: #config(INGOT_LAYOUT_CHECK, false)
MAP_CAPTURE :: #config(INGOT_MAP_CAPTURE, false)

app: fit.App
dark := true
debug_on := false
active_phase: i32

PHASE_COUNT :: 4
PHASE_CAPTIONS := [PHASE_COUNT + 1]string {
	"The complete public path",
	"App captures input and starts one bounded frame",
	"Builder declares responsive layout and stable controls",
	"Custom callbacks borrow Surface for explicit same-frame drawing",
	"Fit records paint, semantics, and platform requests for presentation",
}

Map_Node :: struct {
	title:  string,
	detail: string,
	phase:  i32,
	accent: fit.Ink,
}

MAP_NODES := [4]Map_Node {
	{"fit.App", "lifecycle, theme, scale, pacing", 1, .Success},
	{"fit.Builder", "bounded immediate description", 2, .Accent},
	{"fit.Surface / fit.Region", "callback-scoped explicit geometry", 3, .Tool},
	{"paint + semantics output", "internal recording and presentation", 4, .Plan},
}

main :: proc() {
	when LAYOUT_CHECK {
		layout_check()
	}
	when MAP_CAPTURE {
		map_capture_main()
	} else {
		flags: fit.Window_Flags = {.Resizable, .Vsync}
		when ODIN_OS == .Darwin do flags += {.High_Dpi}
		_ = fit.Run(
			&app,
			{
				width = 1180,
				height = 760,
				title = "ingot api map",
				flags = flags,
				frame_pacing = .Monitor_Refresh,
				target_fps = 60,
				event_waiting = true,
				session = {semantics_enabled = true},
			},
			map_build,
		)
	}
}

map_build :: proc(builder: ^fit.Builder, userdata: rawptr) {
	_ = userdata
	fit.Column(builder, {gap = .MD, padding = .LG})
	fit.Row(builder, {gap = .SM, align = .Center})
	fit.Label(builder, "INGOT API MAP", {role = .Title, track = fit.Grow()})
	theme_clicked := false
	fit.Button(builder, "theme", "Light theme" if dark else "Dark theme", &theme_clicked)
	fit.End(builder)
	if theme_clicked {
		dark = !dark
		fit.Set_Theme(&app, fit.Theme_Dark() if dark else fit.Theme_Light())
	}
	fit.Label(builder, PHASE_CAPTIONS[active_phase], {ink = .Secondary})
	fit.Row(builder, {gap = .XS})
	for phase in i32(0) ..= PHASE_COUNT {
		clicked := false
		fit.Button(
			builder,
			u64(phase + 1),
			"All" if phase == 0 else phase_label(phase),
			fit.Button_Options {
				style = .Primary if active_phase == phase else .Ghost,
				activated = &clicked,
			},
		)
		if clicked do active_phase = phase
	}
	fit.End(builder)
	fit.Custom(
		builder,
		{measure = map_measure, render = map_render},
		{size = {width = fit.Grow(), height = fit.Grow()}},
	)
	fit.End(builder)
}

phase_label :: proc(phase: i32) -> string {
	switch phase {
	case 1:
		return "1 App"
	case 2:
		return "2 Builder"
	case 3:
		return "3 Surface"
	case 4:
		return "4 Output"
	}
	return "?"
}

map_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	return {max(constraints.max_w, 1), max(constraints.max_h, 420), false}
}

map_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	_ = userdata
	if fit.Surface_Key_Pressed(surface, .F12) do debug_on = !debug_on
	theme := fit.Surface_Theme_Tokens(surface)
	gap := fit.Surface_Scale(surface, 18)
	card_h := fit.Surface_Scale(surface, 92)
	x := rect.x + gap
	y := rect.y + gap
	width := max(rect.w - gap * 2, 1)
	for node, index in MAP_NODES {
		selected := active_phase == 0 || active_phase == node.phase
		background := theme.background_secondary if selected else theme.background_app
		card := fit.Rect{x, y, width, card_h}
		fit.Surface_Card_Background(surface, card, background, theme.foreground_accent, 4)
		fit.Surface_Text(surface, node.title, x + gap, y + gap, .Title)
		fit.Surface_Text(
			surface,
			node.detail,
			x + gap,
			y + gap + fit.Surface_Metrics(surface).line_height,
			.Body,
			.Secondary,
		)
		if index < len(MAP_NODES) - 1 {
			center := x + width / 2
			fit.Surface_Line(
				surface,
				{f32(center), f32(y + card_h)},
				{f32(center), f32(y + card_h + gap)},
				2,
				theme.foreground_accent,
			)
		}
		y += card_h + gap
	}
	if debug_on do _ = fit.Surface_Debug_Overlay(surface, rect.x + rect.w - 290, rect.y + 10)
	return false
}
