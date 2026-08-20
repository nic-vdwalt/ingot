package main

import "core:math"
import fit "ingot:fit"

LAYOUT_CHECK :: #config(INGOT_LAYOUT_CHECK, false)
MAP_CAPTURE :: #config(INGOT_MAP_CAPTURE, false)
NODE_COUNT :: 9
STAGE_COUNT :: 6
EDGE_COUNT :: 8
PKG_COUNT :: 5
LANE_COUNT :: 5
MAX_EDGE_POINTS :: 4
PROGRESS_SEGMENTS :: STAGE_COUNT
NARROW_WIDTH_MAX :: 560
WIDE_WIDTH_MIN :: 980

// Pkg is the ingot package (or the caller) that owns a card. Each swimlane is
// one package, so the entry level of every card reads directly from its row.
Pkg :: enum u8 {
	App,
	Fit,
	Ui_Gfx,
	Ui_Lib,
	Gfx,
}

Node_Phase :: enum u8 {
	Entry,
	Upcoming,
	Done,
	Active,
}

Map_Node :: struct {
	title:    string,
	detail:   string,
	contract: string,
	pkg:      Pkg,
	stage:    i32,
	ink:      fit.Ink,
	// library marks cards that are never an entry point, so the detail line can
	// keep a distinct ink even while the card is in the muted Upcoming phase.
	library:  bool,
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
	gutter_w:   i32,
	strip_h:    i32,
	card_h:     i32,
	narrow_max: i32,
	wide_min:   i32,
}

Map_Layout :: struct {
	bounds:      fit.Rect,
	metrics:     Map_Metrics,
	strip:       fit.Rect,
	nodes:       [NODE_COUNT]fit.Rect,
	lane_bounds: [LANE_COUNT]fit.Rect,
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

// The entry rail (stage 0) states the three supported ways in: fit (the
// supported facade), ui_gfx (the pro loop), and gfx (raw graphics, no UI
// stack). ui appears only mid-path because it is a library, never an entry.
MAP_NODES := [NODE_COUNT]Map_Node {
	{
		"your app",
		"owns main + state",
		"Pick an entry: fit (supported), ui_gfx (pro), gfx (raw).",
		.App,
		0,
		.Accent,
		false,
	},
	{
		"ingot:ui_gfx",
		"pro entry",
		"Own the loop with app_init and app_tick; skip fit's sugar.",
		.Ui_Gfx,
		0,
		.Tool,
		false,
	},
	{
		"ingot:gfx",
		"raw graphics entry",
		"Draw raylib-style immediately; no UI stack at all.",
		.Gfx,
		0,
		.Tool,
		false,
	},
	{
		"1  fit.App",
		"supported entry",
		"Run, or Init/Start/Tick; a thin facade over ui_gfx.app_*.",
		.Fit,
		1,
		.Success,
		false,
	},
	{
		"2  ui_gfx loop",
		"window + input + pacing",
		"The real runtime; fit delegates every call here.",
		.Ui_Gfx,
		2,
		.Accent,
		false,
	},
	{
		"3  ui layout",
		"library - not an entry",
		"Immediate mode: per-frame arena, describe and place, no I/O.",
		.Ui_Lib,
		3,
		.Plan,
		true,
	},
	{
		"4  fit.Surface",
		"your callback",
		"Your leaves borrow Surface for same-frame explicit work.",
		.App,
		4,
		.Tool,
		false,
	},
	{
		"5  ui output",
		"paint + semantics",
		"Draw list and Platform_Output describe work for the host.",
		.Ui_Lib,
		5,
		.Plan,
		false,
	},
	{
		"6  gfx present",
		"WebGPU presentation",
		"ui_gfx replays ui output through gfx, native or web.",
		.Gfx,
		6,
		.Success,
		false,
	},
}

// The two stage-0 alternates (ui_gfx pro entry, raw gfx) merge into the main
// path: three entries, one presentation. Edge 0 must stay the app-to-fit
// entry edge because the elbow router gives index 0 the left rail.
MAP_EDGES := [EDGE_COUNT]Map_Edge {
	{0, 3, 1},
	{3, 4, 2},
	{1, 4, 2},
	{4, 5, 3},
	{5, 6, 4},
	{6, 7, 5},
	{7, 8, 6},
	{2, 8, 6},
}

// Swimlane rows ordered so the animated stage path only ever hops one or two
// adjacent lanes, keeping connectors short and readable. APP sits between FIT
// and UI-GFX so the return-to-callback hop stays short.
LANE_OF_PKG := [Pkg]i32 {
	.Fit    = 0,
	.App    = 1,
	.Ui_Gfx = 2,
	.Ui_Lib = 3,
	.Gfx    = 4,
}

// Single-word lane labels fit the left gutter without wrapping at any scale.
LANE_LABELS := [LANE_COUNT]string{"FIT", "APP", "UI-GFX", "UI", "GFX"}

// Grid columns per breakpoint. Wide places the three entries in a column-0
// rail and the six stages left to right; medium pairs stages into columns so
// the path snakes. Cells are chosen so no two cards share a cell and every
// straight card-to-card connector clears all unrelated cards; the elbow
// router covers any crossing that remains (check.odin verifies clearance at
// every width).
NODE_COLS_MEDIUM := [NODE_COUNT]i32{0, 0, 0, 1, 1, 2, 2, 3, 3}
NODE_COLS_WIDE := [NODE_COUNT]i32{0, 0, 0, 1, 2, 3, 4, 5, 6}
GRID_COLS_MEDIUM :: 4
GRID_COLS_WIDE :: 7

STAGE_LABELS := [STAGE_COUNT]string{"1 fit", "2 ui_gfx", "3 ui", "4 callback", "5 output", "6 gfx"}

// Static strip titles avoid core:fmt, which would drag core:os into any
// future js build of this package.
STAGE_TITLES := [STAGE_COUNT + 1]string {
	"OVERVIEW",
	"STAGE 1 / 6",
	"STAGE 2 / 6",
	"STAGE 3 / 6",
	"STAGE 4 / 6",
	"STAGE 5 / 6",
	"STAGE 6 / 6",
}

STAGE_CAPTIONS := [STAGE_COUNT + 1]string {
	"Three entries: fit (supported), ui_gfx (pro), gfx (raw); ui is a library, no window, no loop",
	"fit.App is the supported entry: Run or Init/Start/Tick, a thin facade over ui_gfx",
	"ui_gfx is the pro entry: it owns the window, input pump, and frame pacing",
	"ui is immediate-mode and I/O-free - a library that never runs the app",
	"Your callback borrows fit.Surface for same-frame explicit work",
	"ui records the draw list, semantics, and Platform_Output requests",
	"ui_gfx replays ui output through gfx WebGPU; raw gfx apps skip the UI stack",
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

toggle_theme_action :: proc(ctx: rawptr) {
	_ = ctx
	map_state.dark = !map_state.dark
	fit.Set_Theme(&app, fit.Theme_Dark() if map_state.dark else fit.Theme_Light())
}

select_stage_action :: proc(ctx: rawptr, tag: u64) {
	_ = ctx
	assert(tag > 0 && tag <= STAGE_COUNT, "select_stage_action: invalid stage")
	map_select_stage(i32(tag))
}

play_action :: proc(ctx: rawptr) {
	_ = ctx
	map_state.playing = !map_state.playing
	if map_state.playing && map_state.target_stage == 0 do map_select_stage(1)
}

reset_action :: proc(ctx: rawptr) {
	_ = ctx
	map_state.playing = false
	map_state.selected_stage = 0
	map_state.target_stage = 0
	map_state.progress = 1
	map_state.hold_seconds = 0
}

map_build :: proc(builder: ^fit.Builder, ctx: rawptr) {
	_ = ctx
	root := fit.Column(builder, {gap = .SM, padding = .LG})
	header := fit.Row(root, {gap = .SM, align = .Center})
	fit.Label(header, "INGOT API MAP", {role = .Title, track = fit.Grow()})
	fit.Button(
		header,
		"theme",
		"Light" if map_state.dark else "Dark",
		fit.action(toggle_theme_action),
	)
	map_stage_controls(root)
	map_playback_controls(root)
	fit.Custom(
		root,
		{measure = map_measure, render = map_render},
		{size = {width = fit.Grow(), height = fit.Grow()}},
	)
}

map_stage_controls :: proc(parent: fit.Parent) {
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	controls := fit.Flow(parent, {gap_x = .XS, gap_y = .XS})
	for stage in 0 ..< STAGE_COUNT {
		value := i32(stage + 1)
		fit.Button(
			controls,
			u64(value),
			STAGE_LABELS[stage],
			fit.Button_Options {
				style = .Primary if map_state.target_stage == value else .Ghost,
				action = fit.action(select_stage_action, nil, u64(value)),
			},
		)
	}
}

map_playback_controls :: proc(parent: fit.Parent) {
	assert(map_state.target_stage >= 0 && map_state.target_stage <= STAGE_COUNT)
	controls := fit.Flow(parent, {gap_x = .XS, gap_y = .XS})
	fit.Button(
		controls,
		"play",
		"Pause" if map_state.playing else "Play path",
		fit.action(play_action),
	)
	fit.Button(controls, "reset", "Reset", fit.action(reset_action))
	fit.Checkbox(controls, "motion", "Reduced motion", &map_state.reduced_motion)
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

map_measure :: proc(constraints: fit.Constraints, ctx: rawptr) -> fit.Size {
	_ = ctx
	assert(constraints.max_w >= 0 && constraints.max_h >= 0, "api map: invalid constraints")
	// The body height comes from the Grow sizing in map_build; the measured
	// height is only a minimal floor.
	return {max(constraints.max_w, 1), 1, false}
}

map_metrics :: proc(surface: ^fit.Surface) -> Map_Metrics {
	assert(surface != nil, "api map metrics: nil surface")
	title_h := fit.Surface_Text_Line_Height(surface, .Title)
	metrics := Map_Metrics {
		gap        = fit.Surface_Space(surface, .SM),
		margin     = fit.Px(surface, 26),
		gutter_w   = fit.Px(surface, 104),
		strip_h    = title_h + fit.Surface_Space(surface, .XS) * 2 + fit.Px(surface, 6),
		card_h     = fit.Px(surface, 80),
		narrow_max = fit.Px(surface, NARROW_WIDTH_MAX),
		wide_min   = fit.Px(surface, WIDE_WIDTH_MIN),
	}
	assert(metrics.gap > 0 && metrics.margin > 0 && metrics.gutter_w > 0)
	assert(metrics.strip_h > 0 && metrics.card_h > 0)
	return metrics
}

map_columns :: proc(width: i32, metrics: Map_Metrics) -> i32 {
	assert(width > 0, "api map columns: non-positive width")
	assert(metrics.wide_min > metrics.narrow_max, "api map columns: invalid breakpoints")
	if width <= metrics.narrow_max do return 1
	if width < metrics.wide_min do return GRID_COLS_MEDIUM
	return GRID_COLS_WIDE
}

map_content_height :: proc(width: i32, metrics: Map_Metrics) -> i32 {
	assert(width > 0, "api map height: non-positive width")
	assert(metrics.gap > 0 && metrics.card_h > 0, "api map height: invalid metrics")
	columns := map_columns(width, metrics)
	total := metrics.gap * 2 + metrics.strip_h + metrics.gap
	if columns == 1 {
		total += NODE_COUNT * (metrics.card_h + metrics.gap)
	} else {
		lane_h := metrics.card_h + metrics.gap
		total += LANE_COUNT * lane_h + (LANE_COUNT - 1) * max(metrics.gap / 2, 2)
	}
	return total
}

map_layout :: proc(rect: fit.Rect, metrics: Map_Metrics) -> Map_Layout {
	assert(rect.w > 0 && rect.h > 0, "api map layout: invalid bounds")
	assert(metrics.gap > 0 && metrics.strip_h > 0, "api map layout: invalid metrics")
	result := Map_Layout {
		bounds  = rect,
		metrics = metrics,
		columns = map_columns(rect.w, metrics),
	}
	inner := fit.Rect{rect.x + metrics.gap, rect.y + metrics.gap, rect.w - metrics.gap * 2, 0}
	inner.h = max(rect.h - metrics.gap * 2, metrics.strip_h + metrics.gap + NODE_COUNT * 3)
	result.strip = {inner.x, inner.y, max(inner.w, 1), metrics.strip_h}
	body := fit.Rect {
		inner.x,
		inner.y + metrics.strip_h + metrics.gap,
		max(inner.w, 1),
		max(inner.h - metrics.strip_h - metrics.gap, NODE_COUNT * 3),
	}
	if result.columns == 1 {
		map_layout_stack(&result, body)
	} else {
		map_layout_grid(&result, body)
	}
	return result
}

map_layout_grid :: proc(layout: ^Map_Layout, body: fit.Rect) {
	assert(layout != nil && layout.columns > 1, "api map grid: invalid layout")
	assert(body.w > 0 && body.h > 0, "api map grid: invalid body")
	metrics := layout.metrics
	lane_gap := max(metrics.gap / 2, 2)
	lane_h := max((body.h - (LANE_COUNT - 1) * lane_gap) / LANE_COUNT, 3)
	cols := layout.columns
	region_x := body.x + metrics.gutter_w
	region_w := max(body.w - metrics.gutter_w - metrics.margin, cols)
	cell_w := max((region_w - (cols - 1) * metrics.gap) / cols, 1)
	card_h := clamp(lane_h - metrics.gap, 2, metrics.card_h)
	cols_table := NODE_COLS_WIDE if cols == GRID_COLS_WIDE else NODE_COLS_MEDIUM
	for lane in 0 ..< i32(LANE_COUNT) {
		layout.lane_bounds[lane] = {body.x, body.y + lane * (lane_h + lane_gap), body.w, lane_h}
	}
	for node, index in MAP_NODES {
		lane := layout.lane_bounds[LANE_OF_PKG[node.pkg]]
		column := cols_table[index]
		layout.nodes[index] = fit.Rect {
			region_x + column * (cell_w + metrics.gap),
			lane.y + (lane.h - card_h) / 2,
			cell_w,
			card_h,
		}
	}
}

map_layout_stack :: proc(layout: ^Map_Layout, body: fit.Rect) {
	assert(layout != nil && layout.columns == 1, "api map stack: invalid layout")
	assert(body.w > 0 && body.h > 0, "api map stack: invalid body")
	metrics := layout.metrics
	card_w := max(body.w - metrics.margin * 2, 1)
	card_h := clamp((body.h - (NODE_COUNT - 1) * metrics.gap) / NODE_COUNT, 2, metrics.card_h)
	y := body.y
	// Declaration order already reads entry, entry, entry, stage 1..6 top to
	// bottom.
	for index in 0 ..< NODE_COUNT {
		layout.nodes[index] = {body.x + metrics.margin, y, card_w, card_h}
		y += card_h + metrics.gap
	}
}

map_edge_path :: proc(layout: ^Map_Layout, edge_index: i32) -> Edge_Path {
	assert(layout != nil, "api map edge path: nil layout")
	assert(edge_index >= 0 && edge_index < EDGE_COUNT, "api map edge path: invalid index")
	edge := MAP_EDGES[edge_index]
	from := layout.nodes[edge.from]
	to := layout.nodes[edge.to]
	start, finish: fit.Point
	if rows_overlap(from, to) {
		if to.x >= from.x {
			start = {f32(from.x + from.w), f32(from.y + from.h / 2)}
			finish = {f32(to.x), f32(to.y + to.h / 2)}
		} else {
			start = {f32(from.x), f32(from.y + from.h / 2)}
			finish = {f32(to.x + to.w), f32(to.y + to.h / 2)}
		}
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
	start, finish: fit.Point
	channel_x: f32
	// The app-to-fit entry edge keeps the left rail beside its cards; everything
	// else that needs an elbow (the long same-lane hops in the narrow stack)
	// uses the right rail.
	if edge_index == 0 {
		channel_x = f32(min(from.x, to.x)) - f32(layout.metrics.margin) / 2
		start = {f32(from.x), f32(from.y + from.h / 2)}
		finish = {f32(to.x), f32(to.y + to.h / 2)}
	} else {
		channel_x = f32(layout.bounds.x + layout.bounds.w) - f32(layout.metrics.margin) / 2
		start = {f32(from.x + from.w), f32(from.y + from.h / 2)}
		finish = {f32(to.x + to.w), f32(to.y + to.h / 2)}
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

map_render :: proc(surface: ^fit.Surface, rect: fit.Rect, ctx: rawptr) -> bool {
	_ = ctx
	assert(surface != nil && rect.w > 0 && rect.h > 0, "api map render: invalid argument")
	if fit.Surface_Key_Pressed(surface, .F12) do map_state.debug_on = !map_state.debug_on
	map_animate(surface)
	metrics := map_metrics(surface)
	layout := map_layout(rect, metrics)
	theme := fit.Surface_Theme_Tokens(surface)
	fit.Surface_Fill_Rect(surface, rect, theme.background_app)
	// Submission order paints back-to-front: lanes, connectors, cards, then
	// the active overlay. Claimed layers would occlude Surface_Interact.
	map_render_strip(surface, &layout)
	if layout.columns > 1 do map_render_lanes(surface, &layout)
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

// map_render_strip is the in-map status readout: stage title, caption, and a
// six-segment progress bar. It exists so Play and Reset change the map itself
// rather than only the small controls above it.
map_render_strip :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map strip: invalid argument")
	assert(layout.strip.w > 0 && layout.strip.h > 0, "api map strip: invalid rect")
	theme := fit.Surface_Theme_Tokens(surface)
	strip := layout.strip
	stage := map_state.target_stage
	title_ink := fit.Ink.Accent if stage > 0 else fit.Ink.Secondary
	fit.Surface_Text(surface, STAGE_TITLES[stage], strip.x, strip.y, .Title, title_ink)
	title_h := fit.Surface_Text_Line_Height(surface, .Title)
	caption_x := strip.x + fit.Px(surface, 130)
	caption_y := strip.y + (title_h - fit.Surface_Text_Line_Height(surface, .Body)) / 2
	caption_w := max(strip.w - fit.Px(surface, 130), 1)
	fit.Surface_Text_Truncated(
		surface,
		STAGE_CAPTIONS[stage],
		caption_x,
		caption_y,
		caption_w,
		.Body,
		.Secondary,
	)
	bar_h := fit.Px(surface, 6)
	bar_y := strip.y + strip.h - bar_h
	seg_gap := fit.Surface_Space(surface, .XS)
	seg_w := max((strip.w - (PROGRESS_SEGMENTS - 1) * seg_gap) / PROGRESS_SEGMENTS, 1)
	for segment in 0 ..< i32(PROGRESS_SEGMENTS) {
		seg_x := strip.x + segment * (seg_w + seg_gap)
		fit.Surface_Fill_Rect(surface, {seg_x, bar_y, seg_w, bar_h}, theme.border)
		amount := map_edge_amount(segment + 1)
		if amount <= 0 do continue
		fill_w := i32(f32(seg_w) * amount)
		if fill_w <= 0 do continue
		fit.Surface_Fill_Rect(surface, {seg_x, bar_y, fill_w, bar_h}, theme.foreground_accent)
	}
}

map_render_lanes :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map lanes: invalid argument")
	assert(layout.columns > 1, "api map lanes: narrow layout has no lanes")
	note_h := fit.Surface_Text_Line_Height(surface, .Note)
	inset := fit.Surface_Space(surface, .SM)
	for lane in 0 ..< i32(LANE_COUNT) {
		bounds := layout.lane_bounds[lane]
		fit.Surface_Draw_Surface(surface, rect_float(bounds), .Panel, .Rest, .MD)
		fit.Surface_Text(
			surface,
			LANE_LABELS[lane],
			bounds.x + inset,
			bounds.y + (bounds.h - note_h) / 2,
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
	map_draw_arrowhead(surface, path, theme.border)
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
	if amount >= 1 do map_draw_arrowhead(surface, path, theme.foreground_accent)
}

map_draw_arrowhead :: proc(surface: ^fit.Surface, path: ^Edge_Path, color: fit.Color) {
	assert(surface != nil && path != nil, "api map arrowhead: invalid argument")
	assert(path.count >= 2, "api map arrowhead: degenerate path")
	tip := path.points[path.count - 1]
	tail := path.points[path.count - 2]
	length := point_distance(tail, tip)
	if length <= 0 do return
	direction := fit.Point{(tip.x - tail.x) / length, (tip.y - tail.y) / length}
	size := fit.Px(surface, 7.0)
	spread: f32 = 0.45
	sin_s := math.sin(spread)
	cos_s := math.cos(spread)
	back := fit.Point{-direction.x, -direction.y}
	left := fit.Point{back.x * cos_s - back.y * sin_s, back.x * sin_s + back.y * cos_s}
	right := fit.Point{back.x * cos_s + back.y * sin_s, -back.x * sin_s + back.y * cos_s}
	thickness := fit.Px(surface, 2.0)
	fit.Surface_Line(
		surface,
		tip,
		{tip.x + left.x * size, tip.y + left.y * size},
		thickness,
		color,
	)
	fit.Surface_Line(
		surface,
		tip,
		{tip.x + right.x * size, tip.y + right.y * size},
		thickness,
		color,
	)
}

map_node_phase :: proc(stage: i32) -> Node_Phase {
	assert(stage >= 0 && stage <= STAGE_COUNT, "api map phase: invalid stage")
	assert(map_state.selected_stage <= STAGE_COUNT, "api map phase: invalid selection")
	if stage == 0 do return .Entry
	if stage == map_state.target_stage do return .Active
	if stage <= map_state.selected_stage do return .Done
	return .Upcoming
}

map_render_nodes :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map nodes: invalid argument")
	map_state.hovered_node = -1
	inset := fit.Surface_Space(surface, .SM)
	theme := fit.Surface_Theme_Tokens(surface)
	for node, index in MAP_NODES {
		rect := layout.nodes[index]
		interaction := fit.Surface_Interact(surface, rect_float(rect))
		phase := map_node_phase(node.stage)
		state := fit.Visual_State.Rest
		border := fit.Border.Hairline
		title_ink := node.ink
		detail_ink := fit.Ink.Secondary
		switch phase {
		case .Entry:
		case .Upcoming:
			title_ink = .Muted
			detail_ink = .Muted
		case .Done:
			state = .Selected
		case .Active:
			state = .Selected
			border = .Emphasis
		}
		if interaction.hovered {
			map_state.hovered_node = i32(index)
			state = .Hover
			fit.Surface_Request_Cursor(surface, .Pointing_Hand)
		}
		// Library cards keep a distinct detail ink in every phase so "not an
		// entry" stays readable at rest, not only in the hover contract.
		if node.library do detail_ink = .Plan
		fit.Surface_Draw_Surface(surface, rect_float(rect), .Card, state, .MD, border, .Lifted)
		if phase == .Done || phase == .Active {
			bar := fit.Rect{rect.x + 1, rect.y + 2, fit.Px(surface, 3), rect.h - 4}
			fit.Surface_Fill_Rect(surface, bar, theme.foreground_accent)
		}
		fit.Surface_Text_Truncated(
			surface,
			node.title,
			rect.x + inset,
			rect.y + inset,
			max(rect.w - inset * 2, 1),
			.Title,
			title_ink,
		)
		fit.Surface_Text_Truncated(
			surface,
			node.contract if interaction.hovered else node.detail,
			rect.x + inset,
			rect.y + inset + fit.Surface_Text_Line_Height(surface, .Title),
			max(rect.w - inset * 2, 1),
			.Note,
			detail_ink,
		)
		if layout.columns == 1 do map_render_pkg_chip(surface, layout, i32(index))
		if interaction.clicked && node.stage > 0 do map_select_stage(node.stage)
	}
}

// map_render_pkg_chip stands in for lane backgrounds at narrow widths, where
// full swimlanes would waste most of the column.
map_render_pkg_chip :: proc(surface: ^fit.Surface, layout: ^Map_Layout, index: i32) {
	assert(surface != nil && layout != nil, "api map chip: invalid argument")
	assert(index >= 0 && index < NODE_COUNT, "api map chip: invalid index")
	node := MAP_NODES[index]
	rect := layout.nodes[index]
	label := LANE_LABELS[LANE_OF_PKG[node.pkg]]
	inset := fit.Surface_Space(surface, .SM)
	chip_w := fit.Px(surface, 92)
	fit.Surface_Text(surface, label, rect.x + rect.w - chip_w, rect.y + inset, .Note, .Muted)
}

map_render_active :: proc(surface: ^fit.Surface, layout: ^Map_Layout) {
	assert(surface != nil && layout != nil, "api map active: invalid argument")
	stage := map_state.target_stage
	if stage <= 0 do return
	assert(stage <= STAGE_COUNT, "api map active: invalid stage")
	// Stage N's card sits after the three entry cards.
	node_index := stage + 2
	ring := rect_expand(layout.nodes[node_index], fit.Surface_Space(surface, .XS) / 2)
	fit.Surface_Stroke_Rounded_Rect(
		surface,
		rect_float(ring),
		0.12,
		8,
		fit.Px(surface, 3.0),
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
			fit.Px(surface, 6.0),
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
