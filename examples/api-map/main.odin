package main

import "core:math"
import fit "ingot:fit"

LAYOUT_CHECK :: #config(INGOT_LAYOUT_CHECK, false)
MAP_CAPTURE :: #config(INGOT_MAP_CAPTURE, false)
NODE_COUNT :: 8
STAGE_COUNT :: 6
EDGE_COUNT :: 7
TIER_COUNT :: 5
MAX_EDGE_POINTS :: 4
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

// All metric fields are in already-scaled pixels because custom-leaf rects and
// Surface helpers share that space; unscaled constants here would break at 2x.
Map_Metrics :: struct {
	gap:        i32,
	margin:     i32,
	header_h:   i32,
	entry_h:    i32,
	card_h:     i32,
	narrow_max: i32,
	wide_min:   i32,
}

Map_Layout :: struct {
	bounds:      fit.Rect,
	metrics:     Map_Metrics,
	nodes:       [NODE_COUNT]fit.Rect,
	tier_bounds: [TIER_COUNT]fit.Rect,
	columns:     i32,
}

Edge_Path :: struct {
	points: [MAX_EDGE_POINTS]fit.Point,
	count:  i32,
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
	{
		"ingot:fit",
		"supported UI entry",
		"Own lifecycle and describe UI through Builder.",
		.Supported,
		0,
		.Accent,
	},
	{
		"ingot:gfx",
		"supported graphics entry",
		"Use the raylib-compatible graphics API directly.",
		.Supported,
		0,
		.Tool,
	},
	{
		"1  fit.App",
		"lifecycle + input",
		"Own the window, theme, scale, pacing, and frame input.",
		.Application,
		1,
		.Success,
	},
	{
		"2  fit.Builder",
		"bounded declaration",
		"Record responsive containers and stable controls immediately.",
		.Application,
		2,
		.Accent,
	},
	{
		"3  measure + place",
		"responsive layout",
		"Measure constraints and place the declaration synchronously.",
		.Internal,
		3,
		.Plan,
	},
	{
		"4  fit.Surface",
		"borrowed capability",
		"Interact and draw explicit geometry only inside the callback.",
		.Callback,
		4,
		.Tool,
	},
	{
		"5  UI output",
		"paint + semantics",
		"Record bounded paint, accessibility, and platform requests.",
		.Internal,
		5,
		.Plan,
	},
	{
		"6  UI/GFX bridge",
		"WebGPU presentation",
		"Replay output through native or web platform adapters.",
		.Presentation,
		6,
		.Success,
	},
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

// Bands are stacked in stage order (Internal before Callback) so the animated
// path only ever hops one band at a time except for the two bridge edges.
BAND_ORDER := [TIER_COUNT]Tier{.Supported, .Application, .Internal, .Callback, .Presentation}

// Column assignments per column count keep every straight edge clear of
// unrelated cards; the router falls back to a margin elbow when blocked.
NODE_COLUMNS := [3][NODE_COUNT]i32 {
	{0, 0, 0, 0, 0, 0, 0, 0},
	{0, 1, 0, 1, 0, 0, 1, 1},
	{0, 2, 0, 1, 0, 0, 1, 2},
}

NODE_ROWS_NARROW := [NODE_COUNT]i32{0, 1, 0, 1, 0, 0, 1, 0}

// Elbow edges sharing a margin get distinct lanes so overlapping verticals do
// not repaint each other in conflicting colors while the path animates.
EDGE_LANES := [EDGE_COUNT]i32{0, 0, 0, 1, 0, 2, 0}

EDGE_SIDE_RIGHT := [EDGE_COUNT]bool{false, false, false, false, false, false, true}

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
map_state := Map_State {
	dark         = true,
	hovered_node = -1,
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
	map_playback_controls(builder)
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

map_playback_controls :: proc(builder: ^fit.Builder) {
	assert(builder != nil, "api map playback: nil builder")
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	fit.Flow(builder, {gap_x = .XS, gap_y = .XS})
	defer fit.End(builder)
	play_clicked := false
	reset_clicked := false
	fit.Button(builder, "play", "Pause" if map_state.playing else "Play path", &play_clicked)
	fit.Button(builder, "reset", "Reset", &reset_clicked)
	fit.Checkbox(builder, "motion", "Reduced motion", &map_state.reduced_motion)
	if play_clicked {
		map_state.playing = !map_state.playing
		if map_state.playing && map_state.target_stage == 0 do map_select_stage(1)
	}
	if reset_clicked {
		map_state.playing = false
		map_state.selected_stage = 0
		map_state.target_stage = 0
		map_state.progress = 1
		map_state.hold_seconds = 0
	}
}

map_select_stage :: proc(stage: i32) {
	assert(stage >= 0 && stage <= STAGE_COUNT, "api map: invalid stage")
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	if stage == map_state.target_stage && map_state.progress >= 1 do return
	map_state.target_stage = stage
	map_state.progress = 1 if map_state.reduced_motion else 0
	map_state.hold_seconds = 0
	if map_state.progress >= 1 do map_state.selected_stage = stage
}

map_measure :: proc(constraints: fit.Constraints, userdata: rawptr) -> fit.Size {
	_ = userdata
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "api map: invalid constraints")
	// Fill the granted space; the layout clamps card heights to fit, so the
	// leaf never needs an unscaled intrinsic height that would break at 2x.
	return {max(constraints.max_w, 1), max(constraints.max_h, 1), false}
}

map_metrics :: proc(surface: ^fit.Surface) -> Map_Metrics {
	assert(surface != nil, "api map metrics: nil surface")
	label_h := fit.Surface_Text_Line_Height(surface, .Note)
	metrics := Map_Metrics {
		gap        = fit.Surface_Space(surface, .MD),
		margin     = fit.Px(surface, 36),
		header_h   = label_h + fit.Surface_Space(surface, .XS) * 2,
		entry_h    = fit.Px(surface, 56),
		card_h     = fit.Px(surface, 92),
		narrow_max = fit.Px(surface, NARROW_WIDTH_MAX),
		wide_min   = fit.Px(surface, WIDE_WIDTH_MIN),
	}
	assert(metrics.gap > 0 && metrics.margin > 0 && metrics.header_h > 0)
	assert(metrics.entry_h > 0 && metrics.card_h > 0)
	return metrics
}

map_columns :: proc(width: i32, metrics: Map_Metrics) -> i32 {
	assert(width > 0, "api map columns: non-positive width")
	assert(metrics.wide_min > metrics.narrow_max, "api map columns: invalid breakpoints")
	if width <= metrics.narrow_max do return 1
	if width < metrics.wide_min do return 2
	return 3
}

map_band_rows :: proc(tier: Tier, columns: i32) -> i32 {
	assert(columns >= 1 && columns <= 3, "api map rows: invalid column count")
	count: i32
	for node in MAP_NODES {
		if node.tier == tier do count += 1
	}
	assert(count > 0, "api map rows: empty tier")
	return count if columns == 1 else 1
}

map_content_height :: proc(width: i32, metrics: Map_Metrics) -> i32 {
	assert(width > 0, "api map height: non-positive width")
	assert(metrics.gap > 0 && metrics.header_h > 0, "api map height: invalid metrics")
	columns := map_columns(width, metrics)
	total := metrics.gap
	for tier in Tier {
		rows := map_band_rows(tier, columns)
		row_h := metrics.entry_h if tier == .Supported else metrics.card_h
		total += metrics.header_h + rows * row_h + (rows - 1) * metrics.gap + metrics.gap
	}
	return total
}

map_layout :: proc(rect: fit.Rect, metrics: Map_Metrics) -> Map_Layout {
	assert(rect.w > 0 && rect.h > 0, "api map layout: invalid bounds")
	assert(metrics.gap > 0 && metrics.margin > 0 && metrics.header_h > 0)
	assert(metrics.entry_h > 0 && metrics.card_h > 0, "api map layout: invalid heights")
	columns := map_columns(rect.w, metrics)
	entry_rows, card_rows, intra_gaps: i32
	for tier in Tier {
		rows := map_band_rows(tier, columns)
		if tier == .Supported {
			entry_rows += rows
		} else {
			card_rows += rows
		}
		intra_gaps += rows - 1
	}
	fixed := metrics.gap * 2 + TIER_COUNT * metrics.header_h
	fixed += (TIER_COUNT - 1) * metrics.gap + intra_gaps * metrics.gap
	// Entry rows weigh 2 and card rows weigh 3 so short windows shrink both
	// kinds of card proportionally instead of overflowing the leaf.
	weight := entry_rows * 2 + card_rows * 3
	available := max(rect.h - fixed, weight)
	unit := available / weight
	entry_h := clamp(unit * 2, 2, metrics.entry_h)
	card_h := clamp(unit * 3, 3, metrics.card_h)
	result := Map_Layout {
		bounds  = rect,
		metrics = metrics,
		columns = columns,
	}
	side := metrics.gap + metrics.margin
	content_x := rect.x + side
	content_w := max(rect.w - side * 2, columns)
	cell_w := (content_w - (columns - 1) * metrics.gap) / columns
	y := rect.y + metrics.gap
	for tier in BAND_ORDER {
		rows := map_band_rows(tier, columns)
		row_h := entry_h if tier == .Supported else card_h
		band_h := metrics.header_h + rows * row_h + (rows - 1) * metrics.gap
		result.tier_bounds[tier] = {rect.x + metrics.gap, y, rect.w - metrics.gap * 2, band_h}
		for node, index in MAP_NODES {
			if node.tier != tier do continue
			column := NODE_COLUMNS[columns - 1][index]
			row := NODE_ROWS_NARROW[index] if columns == 1 else 0
			result.nodes[index] = fit.Rect {
				content_x + column * (cell_w + metrics.gap),
				y + metrics.header_h + row * (row_h + metrics.gap),
				cell_w,
				row_h,
			}
		}
		y += band_h + metrics.gap
	}
	return result
}

map_edge_path :: proc(layout: ^Map_Layout, edge_index: i32) -> Edge_Path {
	assert(layout != nil, "api map edge path: nil layout")
	assert(edge_index >= 0 && edge_index < EDGE_COUNT, "api map edge path: invalid index")
	edge := MAP_EDGES[edge_index]
	from := layout.nodes[edge.from]
	to := layout.nodes[edge.to]
	start, finish: fit.Point
	if rows_overlap(from, to) {
		left, right := from, to
		if to.x < from.x do left, right = to, from
		start = {f32(left.x + left.w), f32(left.y + left.h / 2)}
		finish = {f32(right.x), f32(right.y + right.h / 2)}
	} else if to.y > from.y {
		start = {f32(from.x + from.w / 2), f32(from.y + from.h)}
		finish = {f32(to.x + to.w / 2), f32(to.y)}
	} else {
		start = {f32(from.x + from.w / 2), f32(from.y)}
		finish = {f32(to.x + to.w / 2), f32(to.y + to.h)}
	}
	if map_segment_clear(layout, start, finish, edge.from, edge.to) {
		return {{start, finish, {}, {}}, 2}
	}
	return map_edge_elbow(layout, edge_index)
}

// Blocked edges route through the reserved side margins, which are card-free
// at every width by construction, instead of drawing lines under cards.
map_edge_elbow :: proc(layout: ^Map_Layout, edge_index: i32) -> Edge_Path {
	assert(layout != nil, "api map elbow: nil layout")
	assert(edge_index >= 0 && edge_index < EDGE_COUNT, "api map elbow: invalid index")
	edge := MAP_EDGES[edge_index]
	from := layout.nodes[edge.from]
	to := layout.nodes[edge.to]
	lane_w := max(layout.metrics.margin / 3, 1)
	offset := lane_w / 2 + EDGE_LANES[edge_index] * lane_w
	start, finish: fit.Point
	channel_x: f32
	if EDGE_SIDE_RIGHT[edge_index] {
		channel_x = f32(layout.bounds.x + layout.bounds.w - layout.metrics.gap - offset)
		start = {f32(from.x + from.w), f32(from.y + from.h / 2)}
		finish = {f32(to.x + to.w), f32(to.y + to.h / 2)}
	} else {
		channel_x = f32(layout.bounds.x + layout.metrics.gap + offset)
		start = {f32(from.x), f32(from.y + from.h / 2)}
		finish = {f32(to.x), f32(to.y + to.h / 2)}
	}
	return {{start, {channel_x, start.y}, {channel_x, finish.y}, finish}, 4}
}

map_segment_clear :: proc(
	layout: ^Map_Layout,
	start, finish: fit.Point,
	skip_from, skip_to: i32,
) -> bool {
	assert(layout != nil, "api map clear: nil layout")
	assert(skip_from >= 0 && skip_from < NODE_COUNT, "api map clear: invalid from")
	assert(skip_to >= 0 && skip_to < NODE_COUNT, "api map clear: invalid to")
	for rect, index in layout.nodes {
		if i32(index) == skip_from || i32(index) == skip_to do continue
		if segment_hits_rect(start, finish, rect) do return false
	}
	return true
}

segment_hits_rect :: proc(start, finish: fit.Point, rect: fit.Rect) -> bool {
	assert(rect.w > 0 && rect.h > 0, "api map hit: invalid rectangle")
	// Shrink by half a pixel so a segment touching a border does not count.
	enter: f32 = 0
	exit: f32 = 1
	if !segment_clip_axis(
		start.x,
		finish.x - start.x,
		f32(rect.x) + 0.5,
		f32(rect.x + rect.w) - 0.5,
		&enter,
		&exit,
	) {
		return false
	}
	if !segment_clip_axis(
		start.y,
		finish.y - start.y,
		f32(rect.y) + 0.5,
		f32(rect.y + rect.h) - 0.5,
		&enter,
		&exit,
	) {
		return false
	}
	return enter < exit
}

segment_clip_axis :: proc(origin, delta, lo, hi: f32, enter, exit: ^f32) -> bool {
	assert(enter != nil && exit != nil, "api map clip: nil range")
	assert(lo < hi, "api map clip: empty slab")
	if delta == 0 do return origin > lo && origin < hi
	first := (lo - origin) / delta
	second := (hi - origin) / delta
	if first > second do first, second = second, first
	enter^ = max(enter^, first)
	exit^ = min(exit^, second)
	return enter^ < exit^
}

path_length :: proc(path: ^Edge_Path) -> f32 {
	assert(path != nil, "api map path: nil path")
	assert(path.count >= 2 && path.count <= MAX_EDGE_POINTS, "api map path: invalid count")
	total: f32
	for index in 0 ..< path.count - 1 {
		total += point_distance(path.points[index], path.points[index + 1])
	}
	return total
}

path_point :: proc(path: ^Edge_Path, amount: f32) -> fit.Point {
	assert(path != nil && path.count >= 2, "api map path point: invalid path")
	assert(amount >= 0 && amount <= 1, "api map path point: invalid amount")
	target := path_length(path) * amount
	walked: f32
	for index in 0 ..< path.count - 1 {
		segment := point_distance(path.points[index], path.points[index + 1])
		if segment <= 0 do continue
		if walked + segment >= target {
			fraction := clamp((target - walked) / segment, 0, 1)
			return point_lerp(path.points[index], path.points[index + 1], fraction)
		}
		walked += segment
	}
	return path.points[path.count - 1]
}

point_distance :: proc(from, to: fit.Point) -> f32 {
	delta_x := to.x - from.x
	delta_y := to.y - from.y
	return math.sqrt(delta_x * delta_x + delta_y * delta_y)
}

map_render :: proc(surface: ^fit.Surface, rect: fit.Rect, userdata: rawptr) -> bool {
	_ = userdata
	assert(surface != nil && rect.w > 0 && rect.h > 0, "api map render: invalid argument")
	if fit.Surface_Key_Pressed(surface, .F12) do map_state.debug_on = !map_state.debug_on
	map_animate(surface)
	metrics := map_metrics(surface)
	layout := map_layout(rect, metrics)
	theme := fit.Surface_Theme_Tokens(surface)
	fit.Surface_Fill_Rect(surface, rect, theme.background_app)
	// Submission order already paints back-to-front; opening claimed layers
	// here would occlude Surface_Interact for everything below the top claim.
	map_render_tiers(surface, &layout)
	map_render_edges(surface, &layout)
	map_render_nodes(surface, &layout)
	map_render_active(surface, &layout)
	if map_state.debug_on {
		_ = fit.Surface_Debug_Overlay(surface, rect.x + rect.w - 290, rect.y + 10)
	}
	return false
}

map_animate :: proc(surface: ^fit.Surface) {
	assert(surface != nil, "api map animation: nil surface")
	assert(map_state.progress >= 0 && map_state.progress <= 1)
	delta := clamp(fit.Surface_Frame_Time(surface), 0, 0.1)
	if map_state.reduced_motion && map_state.progress < 1 do map_state.progress = 1
	if map_state.progress < 1 {
		map_state.progress = map_advance_progress(map_state.progress, delta)
		if map_state.progress >= 1 do map_state.selected_stage = map_state.target_stage
	} else if map_state.playing {
		map_state.hold_seconds += delta
		if map_state.hold_seconds >= 0.7 {
			next := map_state.target_stage + 1
			if next > STAGE_COUNT do next = 1
			map_select_stage(next)
		}
	}
	if map_state.progress < 1 || map_state.playing do fit.Request_Redraw(surface)
}

map_render_tiers :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map tiers: invalid argument")
	inset := fit.Surface_Space(surface, .XS)
	for bounds, tier in layout.tier_bounds {
		fit.Surface_Draw_Surface(surface, rect_float(bounds), .Panel, .Rest, .LG)
		fit.Surface_Text(
			surface,
			TIER_LABELS[tier],
			bounds.x + layout.metrics.margin,
			bounds.y + inset,
			.Note,
			.Muted,
		)
	}
}

map_render_edges :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map edges: invalid argument")
	for edge, index in MAP_EDGES {
		path := map_edge_path(layout, i32(index))
		map_draw_edge(surface, &path, map_edge_amount(edge.stage))
	}
}

map_draw_edge :: proc(surface: ^fit.Surface, path: ^Edge_Path, amount: f32) {
	assert(surface != nil && path != nil, "api map draw edge: invalid argument")
	assert(amount >= 0 && amount <= 1, "api map draw edge: invalid amount")
	theme := fit.Surface_Theme_Tokens(surface)
	for index in 0 ..< path.count - 1 {
		fit.Surface_Line(
			surface,
			path.points[index],
			path.points[index + 1],
			fit.Px(surface, 2.0),
			theme.border,
		)
	}
	if amount <= 0 do return
	target := path_length(path) * amount
	walked: f32
	for index in 0 ..< path.count - 1 {
		segment := point_distance(path.points[index], path.points[index + 1])
		if segment <= 0 do continue
		finish := path.points[index + 1]
		partial := walked + segment > target
		if partial {
			fraction := clamp((target - walked) / segment, 0, 1)
			finish = point_lerp(path.points[index], path.points[index + 1], fraction)
		}
		fit.Surface_Line(
			surface,
			path.points[index],
			finish,
			fit.Px(surface, 3.0),
			theme.foreground_accent,
		)
		if partial do break
		walked += segment
	}
}

map_render_nodes :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map nodes: invalid argument")
	map_state.hovered_node = -1
	inset := fit.Surface_Space(surface, .SM)
	for node, index in MAP_NODES {
		rect := layout.nodes[index]
		interaction := fit.Surface_Interact(surface, rect_float(rect))
		selected := node.stage > 0 && node.stage <= map_state.selected_stage
		state := fit.Visual_State.Selected if selected else fit.Visual_State.Rest
		if interaction.hovered {
			map_state.hovered_node = i32(index)
			state = .Hover
			fit.Surface_Request_Cursor(surface, .Pointing_Hand)
		}
		fit.Surface_Draw_Surface(surface, rect_float(rect), .Card, state, .MD, .Hairline, .Lifted)
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

map_render_active :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map active: invalid argument")
	stage := map_state.target_stage
	if stage <= 0 do return
	assert(stage <= STAGE_COUNT, "api map active: invalid stage")
	node_index := stage + 1
	ring := rect_expand(layout.nodes[node_index], fit.Surface_Space(surface, .XS) / 2)
	fit.Surface_Stroke_Rounded_Rect(
		surface,
		rect_float(ring),
		0.12,
		8,
		fit.Px(surface, 2.0),
		fit.Surface_Theme_Tokens(surface).foreground_accent,
	)
	// The pulse only exists while the path is moving; a resting dot after the
	// transition finished reads as a stray artifact.
	if map_state.reduced_motion do return
	if map_state.progress >= 1 && !map_state.playing do return
	for edge, index in MAP_EDGES {
		if edge.stage != stage do continue
		path := map_edge_path(layout, i32(index))
		pulse := path_point(&path, map_ease(map_state.progress))
		fit.Surface_Fill_Circle(
			surface,
			pulse,
			fit.Px(surface, 5.0),
			fit.Surface_Theme_Tokens(surface).foreground_accent,
		)
		break
	}
}

map_edge_amount :: proc(stage: i32) -> f32 {
	assert(stage >= 1 && stage <= STAGE_COUNT, "api map edge: invalid stage")
	if stage <= map_state.selected_stage do return 1
	if stage == map_state.target_stage do return map_ease(map_state.progress)
	return 0
}

point_lerp :: proc(from, to: fit.Point, amount: f32) -> fit.Point {
	assert(amount >= 0 && amount <= 1, "api map lerp: invalid amount")
	return {from.x + (to.x - from.x) * amount, from.y + (to.y - from.y) * amount}
}

rows_overlap :: proc(a, b: fit.Rect) -> bool {
	assert(a.h > 0 && b.h > 0, "api map rows: invalid rectangle")
	return a.y < b.y + b.h && b.y < a.y + a.h
}

rect_expand :: proc(rect: fit.Rect, amount: i32) -> fit.Rect {
	assert(rect.w > 0 && rect.h > 0, "api map expand: invalid rectangle")
	assert(amount >= 0, "api map expand: negative amount")
	return {rect.x - amount, rect.y - amount, rect.w + amount * 2, rect.h + amount * 2}
}

rect_float :: proc(rect: fit.Rect) -> fit.Float_Rect {
	assert(rect.w > 0 && rect.h > 0, "api map float rect: invalid rectangle")
	return {f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
}

map_ease :: proc(value: f32) -> f32 {
	clamped := clamp(value, 0, 1)
	return clamped * clamped * (3 - 2 * clamped)
}

map_advance_progress :: proc(progress, delta: f32) -> f32 {
	assert(progress >= 0 && progress <= 1, "api map progress: invalid value")
	return clamp(progress + max(delta, 0) * 3.5, 0, 1)
}
