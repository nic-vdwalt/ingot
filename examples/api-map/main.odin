package main

import fit "ingot:fit"

LAYOUT_CHECK :: #config(INGOT_LAYOUT_CHECK, false)
MAP_CAPTURE :: #config(INGOT_MAP_CAPTURE, false)
NODE_COUNT :: 8
STAGE_COUNT :: 6
EDGE_COUNT :: 7
TIER_COUNT :: 5
NARROW_WIDTH_MAX :: 560
WIDE_WIDTH_MIN :: 980

Tier :: enum u8 {
	Supported,
	Application,
	Callback,
	Internal,
	Presentation,
}

Map_Node :: struct {
	title:    string,
	detail:   string,
	contract: string,
	tier:     Tier,
	stage:    i32,
	ink:      fit.Ink,
}

Map_Edge :: struct {
	from:  i32,
	to:    i32,
	stage: i32,
}

Map_Layout :: struct {
	bounds:     fit.Rect,
	nodes:      [NODE_COUNT]fit.Rect,
	tier_bounds: [TIER_COUNT]fit.Rect,
	wide:       bool,
}

Map_State :: struct {
	selected_stage: i32,
	target_stage:   i32,
	hovered_node:   i32,
	dark:           bool,
	debug_on:       bool,
	reduced_motion: bool,
	playing:        bool,
	progress:       f32,
	hold_seconds:   f32,
}

MAP_NODES := [NODE_COUNT]Map_Node {
	{"ingot:fit", "supported UI entry", "Own lifecycle and describe UI through Builder.", .Supported, 0, .Accent},
	{"ingot:gfx", "supported graphics entry", "Use the raylib-compatible graphics API directly.", .Supported, 0, .Tool},
	{"1  fit.App", "lifecycle + input", "Own the window, theme, scale, pacing, and frame input.", .Application, 1, .Success},
	{"2  fit.Builder", "bounded declaration", "Record responsive containers and stable controls immediately.", .Application, 2, .Accent},
	{"3  measure + place", "responsive layout", "Measure constraints and place the declaration synchronously.", .Internal, 3, .Plan},
	{"4  fit.Surface", "borrowed capability", "Interact and draw explicit geometry only inside the callback.", .Callback, 4, .Tool},
	{"5  UI output", "paint + semantics", "Record bounded paint, accessibility, and platform requests.", .Internal, 5, .Plan},
	{"6  UI/GFX bridge", "WebGPU presentation", "Replay output through native or web platform adapters.", .Presentation, 6, .Success},
}

MAP_EDGES := [EDGE_COUNT]Map_Edge {
	{0, 2, 1},
	{2, 3, 2},
	{3, 4, 3},
	{4, 5, 4},
	{5, 6, 5},
	{6, 7, 6},
	{1, 7, 6},
}

TIER_LABELS := [TIER_COUNT]string {
	"SUPPORTED API",
	"APPLICATION-OWNED STATE",
	"CALLBACK-SCOPED CAPABILITY",
	"INTERNAL UI ENGINE",
	"PRESENTATION",
}

STAGE_LABELS := [STAGE_COUNT]string {
	"1 App",
	"2 Builder",
	"3 Layout",
	"4 Surface",
	"5 Output",
	"6 Present",
}

STAGE_CAPTIONS := [STAGE_COUNT + 1]string {
	"Choose a stage or play the complete path",
	"App owns lifecycle and captures platform input",
	"Builder records one bounded immediate declaration",
	"Fit measures constraints and places responsive layout",
	"Explicit leaves borrow Surface for same-frame work",
	"The UI engine records paint, semantics, and platform requests",
	"The UI/GFX bridge presents through WebGPU on native and web",
}

app: fit.App
map_state := Map_State{dark = true, hovered_node = -1}

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
				width = 1280,
				height = 820,
				title = "ingot API map",
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
	fit.Column(builder, {gap = .SM, padding = .LG})
	defer fit.End(builder)
	fit.Row(builder, {gap = .SM, align = .Center})
	fit.Label(builder, "INGOT API MAP", {role = .Title, track = fit.Grow()})
	theme_clicked := false
	fit.Button(builder, "theme", "Light" if map_state.dark else "Dark", &theme_clicked)
	fit.End(builder)
	if theme_clicked {
		map_state.dark = !map_state.dark
		fit.Set_Theme(&app, fit.Theme_Dark() if map_state.dark else fit.Theme_Light())
	}
	fit.Label(builder, STAGE_CAPTIONS[map_state.target_stage], {ink = .Secondary})
	map_stage_controls(builder)
	fit.Custom(
		builder,
		{measure = map_measure, render = map_render},
		{size = {width = fit.Grow(), height = fit.Grow()}},
	)
}

map_stage_controls :: proc(builder: ^fit.Builder) {
	assert(builder != nil, "api map controls: nil builder")
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	fit.Flow(builder, {gap_x = .XS, gap_y = .XS})
	defer fit.End(builder)
	for stage in 0 ..< STAGE_COUNT {
		clicked := false
		value := i32(stage + 1)
		fit.Button(
			builder,
			u64(value),
			STAGE_LABELS[stage],
			fit.Button_Options {
				style = .Primary if map_state.target_stage == value else .Ghost,
				activated = &clicked,
			},
		)
		if clicked do map_select_stage(value)
	}
}

map_select_stage :: proc(stage: i32) {
	assert(stage >= 0 && stage <= STAGE_COUNT, "api map: invalid stage")
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	map_state.target_stage = stage
	map_state.selected_stage = stage
	map_state.progress = 1
	map_state.hold_seconds = 0
}

map_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "api map: invalid constraints")
	height := map_content_height(max(constraints.max_w, 1))
	return {max(constraints.max_w, 1), max(constraints.max_h, height), false}
}

map_content_height :: proc(width: i32) -> i32 {
	assert(width > 0, "api map: non-positive width")
	if width <= NARROW_WIDTH_MAX do return 960
	if width < WIDE_WIDTH_MIN do return 650
	return 460
}

map_layout :: proc(rect: fit.Rect, gap, entry_h, card_h: i32) -> Map_Layout {
	assert(rect.w > 0 && rect.h > 0, "api map layout: invalid bounds")
	assert(gap > 0 && entry_h > 0 && card_h > 0, "api map layout: invalid metrics")
	result := Map_Layout{bounds = rect, wide = rect.w >= WIDE_WIDTH_MIN}
	inner := fit.Rect{rect.x + gap, rect.y + gap, max(rect.w - gap * 2, 1), rect.h - gap * 2}
	if rect.w <= NARROW_WIDTH_MAX {
		map_layout_narrow(&result, inner, gap, entry_h, card_h)
	} else if rect.w < WIDE_WIDTH_MIN {
		map_layout_medium(&result, inner, gap, entry_h, card_h)
	} else {
		map_layout_wide(&result, inner, gap, entry_h, card_h)
	}
	map_layout_tiers(&result, gap)
	return result
}

map_layout_narrow :: proc(layout: ^Map_Layout, inner: fit.Rect, gap, entry_h, card_h: i32) {
	assert(layout != nil && inner.w > 0, "api map narrow layout: invalid argument")
	assert(gap > 0 && entry_h > 0 && card_h > 0)
	layout.nodes[0] = {inner.x, inner.y, inner.w, entry_h}
	layout.nodes[1] = {inner.x, inner.y + entry_h + gap, inner.w, entry_h}
	y := inner.y + (entry_h + gap) * 2 + gap
	for index in 0 ..< STAGE_COUNT {
		layout.nodes[index + 2] = {inner.x, y, inner.w, card_h}
		y += card_h + gap
	}
}

map_layout_medium :: proc(layout: ^Map_Layout, inner: fit.Rect, gap, entry_h, card_h: i32) {
	assert(layout != nil && inner.w > gap, "api map medium layout: invalid argument")
	assert(gap > 0 && entry_h > 0 && card_h > 0)
	column_w := (inner.w - gap) / 2
	layout.nodes[0] = {inner.x, inner.y, column_w, entry_h}
	layout.nodes[1] = {inner.x + column_w + gap, inner.y, column_w, entry_h}
	y := inner.y + entry_h + gap * 2
	for index in 0 ..< STAGE_COUNT {
		column := i32(index % 2)
		row := i32(index / 2)
		x := inner.x + column * (column_w + gap)
		layout.nodes[index + 2] = {x, y + row * (card_h + gap), column_w, card_h}
	}
}

map_layout_wide :: proc(layout: ^Map_Layout, inner: fit.Rect, gap, entry_h, card_h: i32) {
	assert(layout != nil && inner.w > gap * 2, "api map wide layout: invalid argument")
	assert(gap > 0 && entry_h > 0 && card_h > 0)
	entry_w := (inner.w - gap) / 2
	layout.nodes[0] = {inner.x, inner.y, entry_w, entry_h}
	layout.nodes[1] = {inner.x + entry_w + gap, inner.y, entry_w, entry_h}
	column_w := (inner.w - gap * 2) / 3
	y := inner.y + entry_h + gap * 2
	for index in 0 ..< STAGE_COUNT {
		column := i32(index % 3)
		row := i32(index / 3)
		x := inner.x + column * (column_w + gap)
		layout.nodes[index + 2] = {x, y + row * (card_h + gap), column_w, card_h}
	}
}

map_layout_tiers :: proc(layout: ^Map_Layout, gap: i32) {
	assert(layout != nil && gap > 0, "api map tiers: invalid argument")
	for tier in Tier {
		bounds: fit.Rect
		found := false
		for node, index in MAP_NODES {
			if node.tier != tier do continue
			bounds = rect_union(bounds, layout.nodes[index], found)
			found = true
		}
		assert(found, "api map tiers: empty tier")
		layout.tier_bounds[tier] = rect_expand(bounds, gap / 2)
	}
}

rect_union :: proc(a, b: fit.Rect, has_a: bool) -> fit.Rect {
	assert(b.w > 0 && b.h > 0, "api map union: invalid rectangle")
	if !has_a do return b
	x := min(a.x, b.x)
	y := min(a.y, b.y)
	right := max(a.x + a.w, b.x + b.w)
	bottom := max(a.y + a.h, b.y + b.h)
	return {x, y, right - x, bottom - y}
}

rect_expand :: proc(rect: fit.Rect, amount: i32) -> fit.Rect {
	assert(rect.w > 0 && rect.h > 0, "api map expand: invalid rectangle")
	assert(amount >= 0, "api map expand: negative amount")
	return {rect.x - amount, rect.y - amount, rect.w + amount * 2, rect.h + amount * 2}
}

map_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	_ = userdata
	assert(surface != nil && rect.w > 0 && rect.h > 0, "api map render: invalid argument")
	if fit.Surface_Key_Pressed(surface, .F12) do map_state.debug_on = !map_state.debug_on
	gap := fit.Surface_Space(surface, .MD)
	layout := map_layout(rect, gap, fit.Px(surface, 62), fit.Px(surface, 88))
	theme := fit.Surface_Theme_Tokens(surface)
	fit.Surface_Fill_Rect(surface, rect, theme.background_app)
	map_render_edges(surface, &layout)
	map_render_nodes(surface, &layout)
	if map_state.debug_on do _ = fit.Surface_Debug_Overlay(surface, rect.x + rect.w - 290, rect.y + 10)
	return false
}

map_render_edges :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map edges: invalid argument")
	color := fit.Surface_Theme_Tokens(surface).border
	for edge in MAP_EDGES {
		from := rect_center(layout.nodes[edge.from])
		to := rect_center(layout.nodes[edge.to])
		fit.Surface_Line(surface, from, to, fit.Px(surface, 2.0), color)
	}
}

map_render_nodes :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map nodes: invalid argument")
	map_state.hovered_node = -1
	for node, index in MAP_NODES {
		rect := layout.nodes[index]
		interaction := fit.Surface_Interact(surface, rect_float(rect))
		selected := node.stage > 0 && node.stage == map_state.target_stage
		state := fit.Visual_State.Selected if selected else fit.Visual_State.Rest
		if interaction.hovered {
			map_state.hovered_node = i32(index)
			state = .Hover
			fit.Surface_Request_Cursor(surface, .Pointing_Hand)
		}
		fit.Surface_Draw_Surface(surface, rect_float(rect), .Card, state, .MD, .Hairline, .Lifted)
		inset := fit.Surface_Space(surface, .SM)
		fit.Surface_Text(surface, node.title, rect.x + inset, rect.y + inset, .Title, node.ink)
		fit.Surface_Text_Truncated(
			surface,
			node.contract if interaction.hovered else node.detail,
			rect.x + inset,
			rect.y + inset + fit.Surface_Text_Line_Height(surface, .Title),
			max(rect.w - inset * 2, 1),
			.Note,
			.Secondary,
		)
		if interaction.clicked && node.stage > 0 do map_select_stage(node.stage)
	}
}

rect_center :: proc(rect: fit.Rect) -> fit.Point {
	assert(rect.w > 0 && rect.h > 0, "api map center: invalid rectangle")
	return {f32(rect.x + rect.w / 2), f32(rect.y + rect.h / 2)}
}

rect_float :: proc(rect: fit.Rect) -> fit.Float_Rect {
	assert(rect.w > 0 && rect.h > 0, "api map float rect: invalid rectangle")
	return {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
}
