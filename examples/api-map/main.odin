// ingot api-map - one unified API-architecture diagram. The gallery's three
// stacked panels (where to start, ownership, call paths) are merged into a
// single picture by giving each concept its own visual channel:
//
//   - ownership     -> containment: nested boxes, no edges at all
//   - call path     -> numbered arrows: a phase is an action, so the badge
//                      rides the edge that performs it, never a node
//   - lifetime      -> one tinted zone for state rebuilt every frame
//   - borrows/feeds -> dashed arrows in their own empty column channels
//   - where to start-> START pills on the actual nodes
//
// Nothing is duplicated and no lines cross: every edge is a vertical run
// inside its own reserved column channel; the diagram has no elbows.
//
// Geometry is derived, never hand-tuned: map_metrics measures the label role
// once and map_layout stacks cards -> rows -> boxes -> total height, so any
// UI scale, font size, or window width stays aligned.
//
// Structural claims are verified against source: ui_gfx/app.odin (App fields),
// ui_gfx/session.odin (Session's five peers), ui_gfx/adapter.odin (text
// backend, paint sink, overlay replay, platform apply, a11y publish),
// ui/ui_context.odin (Ui_Frame borrows and per-frame reset), ui/paint.odin
// (Ui_Output channels).
//
// Build & run:
//
//	odin run examples/api-map -collection:ingot=.
//
// Keys: F12 toggles the metrics/debug overlay.
package main

import "core:fmt"
import "ingot:ui"
import "ingot:ui_gfx"

// --- caller-owned state ------------------------------------------------------

app: ui_gfx.App
dark := true
debug_on := false
content_pane: ui.Pane
// 0 shows the whole cycle; 1-6 isolate one phase of a single frame.
active_phase: i32

Map_State :: struct {
	form:    ui.Ui,
	tooltip: ui.Tooltip_State,
}

map_state: Map_State

// The sweep harness lives in check.odin (native only); the flag is declared
// here because main.odin guards on it and is built for every target.
LAYOUT_CHECK :: #config(INGOT_LAYOUT_CHECK, false)

// MAP_CAPTURE enables the still-capture harness in capture.odin (native only).
// Declared here because main.odin guards on it and is built for every target.
MAP_CAPTURE :: #config(INGOT_MAP_CAPTURE, false)

PHASE_COUNT :: 6

// A phase is an action, so it belongs to an edge, not a node. Each caption
// names the actor first, then the target.
PHASE_CAPTIONS := [PHASE_COUNT + 1]string {
	"Click a phase to walk one frame \u00b7 boxes nest by ownership \u00b7 hover any node",
	"Adapter captures platform events into the Ui_Input snapshot",
	"Facade and explicit UI read that snapshot and declare widgets into the frame",
	"Ui_Frame records paint, semantics, and platform requests into Ui_Output",
	"Main paint streams to the Adapter live, as each command is appended",
	"At frame end the Adapter replays overlay and applies platform output",
	"Adapter calls through to ingot:gfx, which executes on the backend",
}

// Where each claim is verified in the library, shown beside the caption so
// the demo cites the source it is describing.
PHASE_SOURCES := [PHASE_COUNT + 1]string {
	"",
	"ui_gfx/adapter.odin capture_input_context",
	"ui_gfx/app.odin app_frame \u00b7 the ui callback",
	"ui/ui_context.odin ui_frame_begin",
	"ui_gfx/adapter.odin paint_list_set_sink(&output.main)",
	"ui_gfx/adapter.odin replay_list + apply_platform_output_context",
	"ui_gfx/adapter.odin replay_command",
}

// Phases a node participates in, as either actor or target. A node lights up
// when the active phase is one of its own; the Adapter takes part in four.
Phase_Set :: bit_set[1 ..= PHASE_COUNT;u8]

// --- tooltip copy (docs/api-layers.md, verified against source) --------------

TIP_CALLER ::
	("Caller-owned application state" +
		`
` +
		"Owns: ui_gfx.App plus all widget components, textures, and domain state" +
		`
` +
		"May own: additional ui.Ui roots beside the App default" +
		`
` +
		"Dashed drop on the right: direct gfx capabilities (textures, audio," +
		`
` +
		"shaders, GPU 3D) bypass UI paint entirely, caller code straight to gfx.")

TIP_APP ::
	("ui_gfx.App \u00b7 default host \u00b7 START for a new one-window UI app" +
		`
` +
		"Owns: graphics context, Session, reusable ui.Ui form, frame loop, teardown" +
		`
` +
		"Callbacks: ui (facade path) or frame (mixed UI and graphics)" +
		`
` +
		"Move down only for a capability App cannot express.")

TIP_FORM ::
	("Reusable ui.Ui form \u00b7 default UI composition" +
		`
` +
		"Backend-free: ingot:ui imports only core:*" +
		`
` +
		"Owns: slot carving, logical scaling, stable identity, focus, semantics" +
		`
` +
		"Persists across frames so Tab order survives, yet every widget is" +
		`
` +
		"re-declared each frame: the root holds identity, not a retained tree.")

TIP_EXPLICIT ::
	("*_at and explicit composition \u00b7 escape hatch" +
		`
` +
		"The application owns geometry: canvases, virtualized lists, overlays" +
		`
` +
		"Declarations are per-frame like all immediate-mode UI; any state they" +
		`
` +
		"need (scroll offsets, selections) lives in caller-owned components" +
		`
` +
		"Keep islands narrow; return to the facade at the boundary.")

TIP_SESSION ::
	("ui_gfx.Session \u00b7 custom host \u00b7 START when the app must own the loop" +
		`
` +
		"Owns five peers: runtime, frame, input, output, Adapter (session.odin)" +
		`
` +
		"Fits: custom pacing, embedding, multiple contexts, instrumentation" +
		`
` +
		"Do not assemble Adapter and its peers by hand; that is this layer.")

TIP_RUNTIME ::
	("ui.Ui_Runtime \u00b7 persists across frames, yet works during every one" +
		`
` +
		"Owns: fonts, theme, scale, DPI, and semantics infrastructure" +
		`
` +
		"Steps 2 and 3: every widget measures and shapes text through it" +
		`
` +
		"Step 5: finalize copies the frame's semantics into its snapshot," +
		`
` +
		"which the Adapter publishes - the solid 'semantics' arrow" +
		`
` +
		"Receives a text backend from the Adapter for measurement and shaping.")

TIP_FRAME ::
	("ui.Ui_Frame \u00b7 target of step 2, actor of step 3" +
		`
` +
		"Borrows runtime, input, and output as pointers while open" +
		`
` +
		"(ui_context.odin) \u2014 it owns none of them" +
		`
` +
		"The struct is reused, but its recording state resets every frame:" +
		`
` +
		"scratch, cursor, overlay, panes, and semantics all start clean.")

TIP_INPUT ::
	("ui.Ui_Input \u00b7 target of step 1, read during step 2" +
		`
` +
		"Recaptured from platform events at the top of every frame; nothing" +
		`
` +
		"accumulates across frames" +
		`
` +
		"Views should query the frame, never poll gfx again after capture.")

TIP_OUTPUT ::
	("ui.Ui_Output \u00b7 three channels that drain at different times" +
		`
` +
		"main streams live to the Adapter as commands are appended (step 4);" +
		`
` +
		"overlay and platform are replayed at frame end (step 5)" +
		`
` +
		"Reset at frame begin and fully re-emitted every frame: nothing is" +
		`
` +
		"retained-mode, the whole UI repaints from widget declarations.")

TIP_MAIN ::
	("Main paint list" +
		`
` +
		"Streams through adapter_paint_sink as each command is appended" +
		`
` +
		"(adapter.odin) rather than waiting for frame end.")

TIP_OVERLAY ::
	("Overlay paint list" +
		`
` +
		"Buffered during the frame; replayed after a11y publish at frame end" +
		`
` +
		"so tooltips and menus draw above all main content.")

TIP_PLATFORM ::
	("Platform output" +
		`
` +
		"Cursor shape, clipboard, IME, and window requests" +
		`
` +
		"applied through the Adapter/platform bridge at frame end.")

TIP_ADAPTER ::
	("ui_gfx.Adapter \u00b7 actor in four of the six steps" +
		`
` +
		"1 captures events \u00b7 4 streams main paint \u00b7 5 replays overlay and" +
		`
` +
		"applies platform output \u00b7 6 calls through to the backend" +
		`
` +
		"Also lends Ui_Runtime a text backend and publishes the a11y tree" +
		`
` +
		"Not an application shell: direct use means owning every policy above.")

TIP_GFX ::
	("ingot:gfx \u00b7 backend \u00b7 START for a raylib port" +
		`
` +
		"Raylib-shaped API: replace imports first, preserve the existing loop" +
		`
` +
		"Compile errors inventory the port; add Session or App when UI is needed" +
		`
` +
		"Also the home of direct capabilities: textures, audio, shaders, GPU 3D" +
		`
` +
		"rlgl is a bounded migration shim, not a general OpenGL layer.")

// --- spacing scale and derived metrics --------------------------------------

// One spacing scale. Every dimension in the diagram derives from these steps
// and from measured text, so a font or UI-scale change cannot misalign it.
SP_XS :: 6
SP_SM :: 10
SP_MD :: 16
SP_LG :: 24

// Alpha applied to anything outside the active phase. Dimming rather than
// hiding keeps the whole structure readable while the eye follows one step.
DIM_ALPHA :: 60

Map_Metrics :: struct {
	label:   i32, // measured label-role text height
	xs:      i32,
	sm:      i32,
	md:      i32,
	lg:      i32,
	card_h:  i32, // title row + detail row + interior padding
	mini_h:  i32, // single-line card inside the output box
	head_h:  i32, // box title row
	arrow_h: i32, // vertical channel reserved between two rows
	pill_h:  i32,
}

map_metrics :: proc(frame: ^ui.Ui_Frame) -> (m: Map_Metrics) {
	assert(frame != nil, "map_metrics: nil frame")
	m.label = ui.text_role_size(frame, .Label)
	m.xs = msc(frame, SP_XS)
	m.sm = msc(frame, SP_SM)
	m.md = msc(frame, SP_MD)
	m.lg = msc(frame, SP_LG)
	m.card_h = m.label * 2 + m.xs * 3
	m.mini_h = m.label + m.sm * 2
	m.head_h = m.label + m.sm * 2
	// Arrow channels carry a step badge at their midpoint, so they must clear
	// a badge diameter plus breathing room on both sides.
	m.arrow_h = m.label * 2 + m.lg
	m.pill_h = m.label + m.xs * 2
	return
}

msc :: proc(frame: ^ui.Ui_Frame, value: i32) -> i32 {
	assert(frame != nil, "msc: nil frame")
	return ui.ui_frame_sc(frame, value)
}

// map_text_w measures a card's widest line so widths follow content instead
// of a constant.
map_text_w :: proc(frame: ^ui.Ui_Frame, lines: ..string) -> (widest: i32) {
	assert(frame != nil, "map_text_w: nil frame")
	for line in lines {
		if len(line) == 0 do continue
		widest = max(widest, ui.text_width(frame, line, .Label))
	}
	return
}

// --- node model --------------------------------------------------------------

Map_Card :: struct {
	rect:    ui.Rect_I32,
	title:   string,
	detail:  string,
	tooltip: string,
	accent:  ui.Color,
	phases:  Phase_Set, // steps this node takes part in; drives highlighting
}

// map_dim answers whether an element should recede: only participants in the
// active phase stay lit, and elements outside the cycle recede with the rest.
map_dim :: proc(phases: Phase_Set) -> bool {
	if active_phase == 0 do return false
	return int(active_phase) not_in phases
}

map_dim_phase :: proc(phase: i32) -> bool {
	if phase == 0 do return active_phase != 0
	return active_phase != 0 && active_phase != phase
}

map_fade :: proc(color: ui.Color, dim: bool) -> ui.Color {
	if !dim do return color
	faded := color
	faded.a = u8(min(i32(color.a), DIM_ALPHA))
	return faded
}

map_ink :: proc(ink: ui.Ink, dim: bool) -> ui.Ink {
	return .Muted if dim else ink
}

// --- primitives --------------------------------------------------------------

map_card :: proc(frame: ^ui.Ui_Frame, state: ^Map_State, node: Map_Card) {
	assert(frame != nil && state != nil, "map_card: invalid arguments")
	assert(node.rect.w > 0 && node.rect.h > 0, "map_card: invalid node")
	assert(len(node.title) > 0 && len(node.tooltip) > 0, "map_card: missing text")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	dim := map_dim(node.phases)
	active := active_phase != 0 && !dim
	origin := ui.frame_pane_origin(frame)
	screen_rect := ui.Rect_I32 {
		node.rect.x + i32(origin.x),
		node.rect.y + i32(origin.y),
		node.rect.w,
		node.rect.h,
	}
	hovered := ui.point_in_rect(ui.get_mouse_position(frame), ui.rect_f32(screen_rect))
	paint_rect := ui.rect_f32(node.rect)
	ui.draw_rectangle_rounded(frame, paint_rect, 0.10, 6, theme.bg_secondary)
	border := map_fade(theme.border_color, dim)
	if active do border = node.accent
	thickness: f32 = 2 if (active || hovered) else 1
	if hovered do border = node.accent
	ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.10, 6, thickness, border)
	ui.draw_rectangle(
		frame,
		node.rect.x,
		node.rect.y,
		msc(frame, 4),
		node.rect.h,
		map_fade(node.accent, dim),
	)
	text_x := node.rect.x + m.sm + msc(frame, 4)
	ui.text(frame, node.title, text_x, node.rect.y + m.xs, .Label, map_ink(.Primary, dim))
	if len(node.detail) > 0 {
		ui.text(
			frame,
			node.detail,
			text_x,
			node.rect.y + m.xs * 2 + m.label,
			.Label,
			map_ink(.Secondary, dim),
		)
	}
	viewport := ui.frame_viewport(frame)
	ui.tooltip_wrapped_at(
		frame,
		&state.tooltip,
		screen_rect,
		node.tooltip,
		viewport.w,
		viewport.h,
		{max_width = msc(frame, 340)},
	)
}

// map_phase_badge stamps a step number at a point on its edge. A phase is an
// action, so the badge rides the arrow that performs it rather than a node,
// which is a thing. This also lets one node (the Adapter) take part in four
// steps without competing for a single corner.
map_phase_badge :: proc(frame: ^ui.Ui_Frame, center: ui.Vector2, phase: i32) {
	assert(frame != nil, "map_phase_badge: nil frame")
	assert(phase >= 1 && phase <= PHASE_COUNT, "map_phase_badge: invalid phase")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	dim := map_dim_phase(phase)
	radius := f32(m.label * 3 / 4)
	// Knock the edge out behind the badge so the line does not read through it.
	ui.draw_circle_v(frame, center, radius + 2, theme.bg_code)
	ui.draw_circle_v(frame, center, radius, map_fade(theme.fg_accent, dim))
	digit := fmt.tprintf("%d", phase)
	width := ui.text_width(frame, digit, .Label)
	ui.text(
		frame,
		digit,
		i32(center.x) - width / 2,
		i32(center.y) - m.label / 2,
		.Label,
		map_ink(.Inverse, dim),
	)
}

// map_box draws a containment box: ownership is expressed by nesting alone,
// so boxes carry no edges. Containers never dim; only cycle nodes do. The
// title row is the hover target for the box's tooltip.
map_box :: proc(
	frame: ^ui.Ui_Frame,
	state: ^Map_State,
	rect: ui.Rect_I32,
	title: string,
	tooltip: string,
	fill: ui.Color,
	pill: string = "",
	phases: Phase_Set = {},
) {
	assert(frame != nil && state != nil, "map_box: invalid arguments")
	assert(rect.w > 0 && rect.h > 0, "map_box: invalid rect")
	assert(len(title) > 0 && len(tooltip) > 0, "map_box: missing text")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	dim := phases != {} && map_dim(phases)
	paint_rect := ui.rect_f32(rect)
	ui.draw_rectangle_rounded(frame, paint_rect, 0.03, 6, fill)
	ui.draw_rectangle_rounded_lines_ex(
		frame,
		paint_rect,
		0.03,
		6,
		1,
		map_fade(theme.border_color, dim),
	)
	title_x := rect.x + m.sm
	title_y := rect.y + m.sm
	ui.text(frame, title, title_x, title_y, .Label, map_ink(.Primary, dim))
	if len(pill) > 0 {
		pill_w := map_pill_width(frame, pill)
		map_pill(frame, rect.x + rect.w - m.sm - pill_w, rect.y + m.sm - m.xs / 2, pill)
	}
	origin := ui.frame_pane_origin(frame)
	title_rect := ui.Rect_I32 {
		rect.x + i32(origin.x),
		rect.y + i32(origin.y),
		rect.w,
		m.head_h,
	}
	viewport := ui.frame_viewport(frame)
	ui.tooltip_wrapped_at(
		frame,
		&state.tooltip,
		title_rect,
		tooltip,
		viewport.w,
		viewport.h,
		{max_width = msc(frame, 340)},
	)
}

map_pill_width :: proc(frame: ^ui.Ui_Frame, label: string) -> i32 {
	assert(frame != nil && len(label) > 0, "map_pill_width: invalid label")
	return ui.text_width(frame, label, .Label) + msc(frame, SP_SM) * 2
}

// map_pill labels a node as a starting tier directly on the node, so the
// decision layer needs no separate cards.
map_pill :: proc(frame: ^ui.Ui_Frame, x, y: i32, label: string) {
	assert(frame != nil && len(label) > 0, "map_pill: invalid label")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	rect := ui.rect_f32({x, y, map_pill_width(frame, label), m.pill_h})
	ui.draw_rectangle_rounded(frame, rect, 0.9, 8, theme.bg_code)
	ui.draw_rectangle_rounded_lines_ex(frame, rect, 0.9, 8, 1, theme.fg_accent)
	ui.text(frame, label, x + m.sm, y + m.xs, .Label, .Primary)
}

map_segment :: proc(frame: ^ui.Ui_Frame, from, to: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "map_segment: nil frame")
	assert(from.x == to.x || from.y == to.y, "map_segment: diagonal edge")
	ui.draw_line_ex(frame, from, to, f32(msc(frame, 2)), color)
}

map_dashed_segment :: proc(frame: ^ui.Ui_Frame, from, to: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "map_dashed_segment: nil frame")
	assert(from.x == to.x || from.y == to.y, "map_dashed_segment: diagonal edge")
	dash := f32(msc(frame, 5))
	gap := f32(msc(frame, 4))
	thickness := f32(msc(frame, 2))
	delta := to - from
	length := abs(delta.x) + abs(delta.y)
	if length <= 0 do return
	direction := delta / length
	traveled: f32 = 0
	for traveled < length {
		segment := min(dash, length - traveled)
		ui.draw_line_ex(
			frame,
			from + direction * traveled,
			from + direction * (traveled + segment),
			thickness,
			color,
		)
		traveled += segment + gap
	}
}

Map_Arrow :: enum {
	Down,
	Up,
	Left,
}

map_arrow :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, direction: Map_Arrow, color: ui.Color) {
	assert(frame != nil, "map_arrow: nil frame")
	size := f32(msc(frame, 5))
	switch direction {
	case .Down:
		ui.draw_triangle(frame, tip, tip + {-size, -size}, tip + {size, -size}, color)
	case .Up:
		ui.draw_triangle(frame, tip, tip + {size, size}, tip + {-size, size}, color)
	case .Left:
		ui.draw_triangle(frame, tip, tip + {size, -size}, tip + {size, size}, color)
	}
}

// Map_Edge is one directed run inside a reserved column channel. Every edge in
// the diagram is vertical, so two edges can only meet if they share a channel,
// which the layout prevents by construction. An edge with a phase carries that
// step's badge at its midpoint: the action lives on the arrow, not the node.
Map_Edge :: struct {
	x:      i32,
	from_y: i32,
	to_y:   i32,
	color:  ui.Color,
	dashed: bool,
	head:   bool, // false for a bus leg that continues elsewhere
	phase:  i32,
	quiet:  bool, // dims with its phase but carries no badge
	label:  string,
	right:  bool, // label sits right of the channel
	space:  i32, // horizontal room for the label; 0 means unconstrained
}

map_edge_mid :: proc(edge: Map_Edge) -> ui.Vector2 {
	return {f32(edge.x), f32((edge.from_y + edge.to_y) / 2)}
}

map_edge :: proc(frame: ^ui.Ui_Frame, edge: Map_Edge) {
	assert(frame != nil && edge.from_y != edge.to_y, "map_edge: degenerate edge")
	m := map_metrics(frame)
	dim := map_dim_phase(edge.phase)
	color := map_fade(edge.color, dim)
	from := ui.Vector2{f32(edge.x), f32(edge.from_y)}
	to := ui.Vector2{f32(edge.x), f32(edge.to_y)}
	if edge.dashed {
		map_dashed_segment(frame, from, to, color)
	} else {
		map_segment(frame, from, to, color)
	}
	if edge.head {
		map_arrow(frame, to, .Down if edge.to_y > edge.from_y else .Up, color)
	}
	if edge.phase > 0 && !edge.quiet do map_phase_badge(frame, map_edge_mid(edge), edge.phase)
	if len(edge.label) == 0 do return
	width := ui.text_width(frame, edge.label, .Label)
	// A label that cannot fit its corridor is dropped rather than allowed to
	// collide with a neighbouring card.
	if edge.space > 0 && width + m.sm > edge.space do return
	label_x := edge.x + m.sm if edge.right else edge.x - m.sm - width
	// A badged edge centres its label below the badge instead of beside it.
	label_y := (edge.from_y + edge.to_y) / 2 - m.label / 2
	if edge.phase > 0 && !edge.quiet do label_y += m.label + m.xs
	ui.text(frame, edge.label, label_x, label_y, .Label, map_ink(.Secondary, dim))
}

// --- layout ------------------------------------------------------------------

Map_Layout :: struct {
	caller:      ui.Rect_I32,
	app_box:     ui.Rect_I32,
	form:        ui.Rect_I32,
	explicit:    ui.Rect_I32,
	session:     ui.Rect_I32,
	runtime:     ui.Rect_I32,
	frame_card:  ui.Rect_I32,
	input:       ui.Rect_I32,
	output:      ui.Rect_I32,
	channels:    [3]ui.Rect_I32,
	adapter:     ui.Rect_I32,
	gfx:         ui.Rect_I32,
	zone:        ui.Rect_I32, // rebuilt-every-frame tint
	col_left:    i32, // runtime column centre
	col_text:    i32, // Adapter -> Runtime text-backend service (dashed, up)
	col_sem:     i32, // Runtime -> Adapter semantics hand-off (solid, down)
	col_mid:     i32, // record and execute flow
	col_main:    i32, // main paint streaming live to the Adapter
	col_replay:  i32, // overlay and platform replayed at frame end
	col_capture: i32, // input capture channel, clear of the output box
	zone_foot:   i32, // reserved strip for the zone caption
	gutter:      i32, // direct-gfx escape hatch
	bus_y:       i32, // where the two declare paths merge
	text_space:  i32, // corridor width for the text-backend label
	sem_space:   i32, // corridor width for the semantics label
	drain_space: i32, // corridor width for the live / frame-end labels
}

// map_layout derives every rectangle from measured text and the spacing scale.
// Heights stack bottom-up (cards -> rows -> session -> app -> caller -> gfx),
// and the total is returned so the canvas can size itself instead of carrying
// a magic constant.
map_layout :: proc(frame: ^ui.Ui_Frame, x, y, w: i32) -> (l: Map_Layout, total_h: i32) {
	assert(frame != nil && w > 0, "map_layout: invalid width")
	m := map_metrics(frame)

	// Widths first: the session interior splits into a three-column flow area
	// and a dedicated capture corridor on the right. Reserving the corridor
	// here is what keeps the upward capture arrow outside the tinted zone.
	caller_w := w - m.md * 2
	gutter_w := m.lg * 2
	app_w := caller_w - m.sm * 2 - gutter_w
	session_w := app_w - m.sm * 2
	inner_w := session_w - m.sm * 2
	capture_w := m.lg * 3
	flow_w := inner_w - capture_w
	col_w := flow_w / 3
	// Cards are as wide as their widest line, but never so wide that the
	// runtime column reaches the tinted zone's left padding: adjacent column
	// centres are col_w apart, and the zone starts m.sm before the frame card.
	card_w := min(
		map_text_w(
			frame,
			"Ui_Runtime",
			"measure \u00b7 semantics",
			"Ui_Frame",
			"records paint",
			"Ui_Input",
			"one snapshot",
		) +
		m.md * 2,
		col_w - m.sm * 3,
	)
	strip_w := min(
		map_text_w(frame, "ui.Ui form", "facade widgets", "*_at islands", "explicit UI") + m.md * 2,
		(flow_w - m.lg) / 2,
	)

	// Heights, innermost first. The zone reserves a caption strip below the
	// output box, and every box leaves a gap under its title row so a START
	// pill can never touch the content beneath it.
	zone_foot := m.label + m.xs * 2
	output_h := m.head_h + m.mini_h + m.sm
	session_h :=
		m.head_h +
		m.xs +
		m.card_h +
		m.arrow_h +
		output_h +
		zone_foot +
		m.arrow_h +
		m.card_h +
		m.sm
	app_h := m.head_h + m.xs + m.card_h + m.arrow_h + session_h + m.sm
	caller_h := m.head_h + app_h + m.sm
	total_h = caller_h + m.arrow_h + m.card_h + m.xs + m.pill_h + m.md * 2

	// Boxes.
	l.caller = {x + m.md, y + m.md, caller_w, caller_h}
	l.app_box = {l.caller.x + m.sm, l.caller.y + m.head_h, app_w, app_h}
	l.session = {
		l.app_box.x + m.sm,
		l.app_box.y + m.head_h + m.xs + m.card_h + m.arrow_h,
		session_w,
		session_h,
	}
	inner_x := l.session.x + m.sm
	l.col_left = inner_x + col_w / 2
	l.col_mid = inner_x + flow_w / 2
	col_right := inner_x + flow_w - col_w / 2

	// Row 1: runtime (persists) | frame | input, one card per column centre.
	// The row starts a gap below the title row so the START pill clears it.
	row1_y := l.session.y + m.head_h + m.xs
	l.runtime = {l.col_left - card_w / 2, row1_y, card_w, m.card_h}
	l.frame_card = {l.col_mid - card_w / 2, row1_y, card_w, m.card_h}
	l.input = {col_right - card_w / 2, row1_y, card_w, m.card_h}

	// Declare strip, symmetric about the middle channel so both paths merge
	// onto one bus instead of crossing.
	strip_y := l.app_box.y + m.head_h + m.xs
	l.form = {l.col_mid - m.sm / 2 - strip_w, strip_y, strip_w, m.card_h}
	l.explicit = {l.col_mid + m.sm / 2, strip_y, strip_w, m.card_h}
	l.bus_y = strip_y + m.card_h + m.arrow_h / 2

	// Output spans from the frame card to the input card's right edge, so the
	// zone is a clean rectangle and the capture corridor stays outside it.
	output_y := row1_y + m.card_h + m.arrow_h
	l.output = {l.frame_card.x, output_y, l.input.x + l.input.w - l.frame_card.x, output_h}
	l.col_capture = inner_x + inner_w - capture_w / 2
	mini_w := (l.output.w - m.sm * 4) / 3
	mini_y := l.output.y + m.head_h
	for index in 0 ..< 3 {
		l.channels[index] = {
			l.output.x + m.sm + i32(index) * (mini_w + m.sm),
			mini_y,
			mini_w,
			m.mini_h,
		}
	}
	// The channels do not drain together: main streams live from its own card
	// while overlay and platform replay at frame end, so each gets a channel
	// centred under the cards it carries.
	l.col_main = l.channels[0].x + l.channels[0].w / 2
	l.col_replay = (l.channels[1].x + l.channels[2].x + l.channels[2].w) / 2
	assert(l.col_main < l.col_replay, "map_layout: drain channels collide")

	l.adapter = {inner_x, l.output.y + l.output.h + zone_foot + m.arrow_h, inner_w, m.card_h}

	// The rebuilt-every-frame zone is exactly the union of frame, input, and
	// output, plus the caption strip. The runtime column sits clear on the
	// left and the capture corridor clear on the right.
	l.zone_foot = zone_foot
	l.zone = {
		l.frame_card.x - m.sm,
		row1_y - m.xs,
		l.input.x + l.input.w + m.sm - (l.frame_card.x - m.sm),
		l.output.y + l.output.h + zone_foot - (row1_y - m.xs),
	}
	assert(l.zone.x > l.runtime.x + l.runtime.w, "map_layout: zone covers retained state")
	assert(l.zone.y >= l.session.y + m.head_h, "map_layout: zone reaches the title row")
	assert(
		l.col_capture > l.zone.x + l.zone.w,
		"map_layout: capture corridor crosses the zone",
	)
	assert(l.col_capture < inner_x + inner_w, "map_layout: capture corridor escapes session")

	// ingot:gfx is the backend under everything the caller owns, so it spans
	// the caller's full width. That turns the direct-gfx escape hatch into a
	// straight vertical drop from the caller's gutter onto the bar - the
	// diagram has no elbows at all - and separates the bar's two roles
	// horizontally: execute (6) lands at col_mid, direct gfx at the gutter,
	// and the raylib-port pill sits on the bar's left, clear of both.
	l.gfx = {l.caller.x, l.caller.y + caller_h + m.arrow_h, caller_w, m.card_h}
	l.gutter = l.app_box.x + app_w + gutter_w / 2
	assert(l.gutter < l.gfx.x + l.gfx.w - m.sm, "map_layout: gutter misses the gfx bar")
	// The runtime column carries a symmetric pair inside the card's footprint:
	// the text-backend service rises on the left half, the step-5 semantics
	// hand-off drops on the right half. Both stay clear of the tinted zone.
	l.col_text = l.col_left - m.lg
	l.col_sem = l.col_left + m.lg
	assert(l.col_text > l.runtime.x, "map_layout: text channel escapes runtime card")
	assert(
		l.col_sem < l.runtime.x + l.runtime.w,
		"map_layout: semantics channel escapes runtime card",
	)
	assert(l.col_sem < l.zone.x, "map_layout: semantics channel enters the zone")
	// Label corridors: from each channel to the nearest occupied edge.
	l.text_space = l.col_text - inner_x
	l.sem_space = l.zone.x - l.col_sem
	l.drain_space = l.col_replay - l.col_main
	assert(l.drain_space > 0, "map_layout: drain corridors inverted")
	return
}

// --- diagram -----------------------------------------------------------------

// map_zone tints the contiguous region rebuilt from scratch every frame:
// Ui_Frame's recording state (ui_context.odin ui_frame_begin), the Ui_Input
// snapshot, and all three Ui_Output channels. Everything outside it persists.
map_zone :: proc(frame: ^ui.Ui_Frame, l: Map_Layout) {
	assert(frame != nil, "map_zone: nil frame")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	tint := theme.fg_tool
	tint.a = 26
	ui.draw_rectangle_rounded(frame, ui.rect_f32(l.zone), 0.05, 6, tint)
	edge := theme.fg_tool
	edge.a = 90
	ui.draw_rectangle_rounded_lines_ex(frame, ui.rect_f32(l.zone), 0.05, 6, 1, edge)
	label := "REBUILT EVERY FRAME"
	width := ui.text_width(frame, label, .Label)
	label_x := l.zone.x + l.zone.w - m.sm - width
	// The caption sits in the strip between row 1 and the output box, right
	// of the record channel; the foot strip below now belongs to the two
	// drain arrows. It yields rather than reach the channel or its badge.
	if label_x <= l.col_mid + m.lg do return
	ui.text(
		frame,
		label,
		label_x,
		(l.input.y + l.input.h + l.output.y - m.label) / 2,
		.Label,
		.Tool,
	)
}

// map_edges draws the six numbered actions of one frame plus the two
// phaseless services. Each badge rides its own arrow, so the numbers name
// what happens rather than labelling whichever node had a free corner.
map_edges :: proc(frame: ^ui.Ui_Frame, l: Map_Layout) {
	assert(frame != nil, "map_edges: nil frame")
	m := map_metrics(frame)
	theme := ui.ui_frame_theme(frame)
	declare := theme.fg_success
	dim_declare := map_dim_phase(2)

	// (2) declare: one step, two performers, so each path carries its own
	// badge - mirroring how step 5 lights two arrows. The bus that merges
	// them into the frame is quiet: it dims with the phase but repeats no
	// number.
	map_edge(
		frame,
		{
			x = l.form.x + l.form.w / 2,
			from_y = l.form.y + l.form.h,
			to_y = l.bus_y,
			color = declare,
			phase = 2,
		},
	)
	map_edge(
		frame,
		{
			x = l.explicit.x + l.explicit.w / 2,
			from_y = l.explicit.y + l.explicit.h,
			to_y = l.bus_y,
			color = theme.fg_accent,
			phase = 2,
		},
	)
	map_segment(
		frame,
		{f32(l.form.x + l.form.w / 2), f32(l.bus_y)},
		{f32(l.explicit.x + l.explicit.w / 2), f32(l.bus_y)},
		map_fade(declare, dim_declare),
	)
	map_edge(
		frame,
		{
			x = l.col_mid,
			from_y = l.bus_y,
			to_y = l.frame_card.y,
			color = declare,
			head = true,
			phase = 2,
			quiet = true,
		},
	)

	// (3) record: the frame writes paint and semantics into output.
	map_edge(
		frame,
		{
			x = l.col_mid,
			from_y = l.frame_card.y + l.frame_card.h,
			to_y = l.output.y,
			color = declare,
			head = true,
			phase = 3,
		},
	)

	// (4) stream and (5) finalize drain the same box at different times, so
	// they are separate arrows whose labels state the timing: main streams
	// live through the adapter sink, overlay and platform replay at frame end.
	map_edge(
		frame,
		{
			x = l.col_main,
			from_y = l.output.y + l.output.h,
			to_y = l.adapter.y,
			color = theme.fg_user,
			head = true,
			phase = 4,
			label = "live",
			right = false,
			// The corridor ends at the semantics run, which passes through
			// the same strip on its way down to the adapter.
			space = l.col_main - l.col_sem - m.lg,
		},
	)
	map_edge(
		frame,
		{
			x = l.col_replay,
			from_y = l.output.y + l.output.h,
			to_y = l.adapter.y,
			color = theme.fg_assistant,
			head = true,
			phase = 5,
			label = "frame end",
			right = true,
			space = l.col_capture - l.col_replay - m.lg,
		},
	)

	// The runtime column carries a symmetric pair. Up, dashed: the adapter
	// lends a text backend (service, no step). Down, solid: at finalize the
	// runtime's semantics snapshot is handed to the adapter for publication -
	// part of step 5, so it lights with it; the badge stays on the replay
	// arrow.
	map_edge(
		frame,
		{
			x = l.col_text,
			from_y = l.adapter.y,
			to_y = l.runtime.y + l.runtime.h,
			color = theme.fg_secondary,
			dashed = true,
			head = true,
			label = "text backend",
			right = false,
			space = l.text_space,
		},
	)
	map_edge(
		frame,
		{
			x = l.col_sem,
			from_y = l.runtime.y + l.runtime.h,
			to_y = l.adapter.y,
			color = theme.fg_assistant,
			head = true,
			phase = 5,
			quiet = true,
			label = "semantics",
			right = true,
			space = l.sem_space,
		},
	)

	// (1) capture: platform events sampled into the snapshot, in a corridor
	// reserved clear of the tinted zone.
	map_edge(
		frame,
		{
			x = l.col_capture,
			from_y = l.adapter.y,
			to_y = l.input.y + l.input.h,
			color = theme.fg_tool,
			head = true,
			phase = 1,
		},
	)

	// (6) execute: the run passes through box borders, which are containment,
	// not edges.
	map_edge(
		frame,
		{
			x = l.col_mid,
			from_y = l.adapter.y + l.adapter.h,
			to_y = l.gfx.y,
			color = theme.fg_user,
			head = true,
			phase = 6,
		},
	)

	// Escape hatch: caller-owned direct gfx bypasses UI paint entirely. The
	// run starts at the caller's own title row - it is the caller's code that
	// makes these calls, not any UI layer - and drops straight down the
	// reserved gutter onto the gfx bar. Labelled at its origin so it reads as
	// a port on the caller, not an annotation floating at the bottom.
	dim_direct := active_phase != 0
	hatch := map_fade(theme.fg_secondary, dim_direct)
	direct := "direct gfx"
	direct_w := ui.text_width(frame, direct, .Label)
	ui.text(
		frame,
		direct,
		min(l.gutter - direct_w / 2, l.caller.x + l.caller.w - m.sm - direct_w),
		l.caller.y + m.sm,
		.Label,
		map_ink(.Secondary, dim_direct),
	)
	map_dashed_segment(
		frame,
		{f32(l.gutter), f32(l.caller.y + m.head_h)},
		{f32(l.gutter), f32(l.gfx.y)},
		hatch,
	)
	map_arrow(frame, {f32(l.gutter), f32(l.gfx.y)}, .Down, hatch)
}

api_map_canvas :: proc(frame: ^ui.Ui_Frame, rect: ui.Rect_I32, userdata: rawptr) {
	assert(frame != nil && rect.w > 0 && rect.h > 0, "api_map_canvas: invalid canvas")
	assert(userdata != nil, "api_map_canvas: nil state")
	state := cast(^Map_State)userdata
	theme := ui.ui_frame_theme(frame)
	l, _ := map_layout(frame, rect.x, rect.y, rect.w)

	map_box(frame, state, l.caller, "CALLER-OWNED APPLICATION STATE", TIP_CALLER, theme.bg_code)
	map_box(
		frame,
		state,
		l.app_box,
		"ui_gfx.App",
		TIP_APP,
		theme.bg_secondary,
		pill = "START HERE \u00b7 default host",
	)
	map_box(
		frame,
		state,
		l.session,
		"ui_gfx.Session",
		TIP_SESSION,
		theme.bg_code,
		pill = "custom loop only",
	)
	map_zone(frame, l)
	map_box(frame, state, l.output, "ui.Ui_Output", TIP_OUTPUT, theme.bg_secondary, phases = {3, 4, 5})
	map_edges(frame, l)

	// Nodes carry the set of steps they take part in, as actor or target, so
	// the Adapter can light up for all four of its actions.
	map_card(
		frame,
		state,
		{l.form, "ui.Ui form", "facade widgets", TIP_FORM, theme.fg_success, {2}},
	)
	map_card(
		frame,
		state,
		{l.explicit, "*_at islands", "explicit UI", TIP_EXPLICIT, theme.fg_accent, {2}},
	)
	// The runtime persists, but it is not idle during a frame: widgets measure
	// and shape text through it while declaring and recording, and finalize
	// copies the frame's semantics into runtime.semantics_snapshot for the
	// Adapter to publish. It is consulted in place rather than handed along a
	// channel, so it participates without owning an arrow.
	map_card(
		frame,
		state,
		{
			l.runtime,
			"Ui_Runtime",
			"measure \u00b7 semantics",
			TIP_RUNTIME,
			theme.fg_tool,
			{2, 3, 5},
		},
	)
	map_card(
		frame,
		state,
		{l.frame_card, "Ui_Frame", "records paint", TIP_FRAME, theme.fg_success, {2, 3}},
	)
	map_card(frame, state, {l.input, "Ui_Input", "one snapshot", TIP_INPUT, theme.fg_tool, {1, 2}})
	channel_titles := [3]string{"main", "overlay", "platform"}
	channel_tips := [3]string{TIP_MAIN, TIP_OVERLAY, TIP_PLATFORM}
	// main drains live (4); overlay and platform are replayed at frame end (5).
	channel_phases := [3]Phase_Set{{3, 4}, {3, 5}, {3, 5}}
	for index in 0 ..< 3 {
		map_card(
			frame,
			state,
			{
				l.channels[index],
				channel_titles[index],
				"",
				channel_tips[index],
				theme.fg_user,
				channel_phases[index],
			},
		)
	}
	map_card(
		frame,
		state,
		{
			l.adapter,
			"Adapter",
			"streams down \u00b7 feeds up",
			TIP_ADAPTER,
			theme.fg_assistant,
			{1, 4, 5, 6},
		},
	)
	map_card(frame, state, {l.gfx, "ingot:gfx", "backend calls", TIP_GFX, theme.fg_user, {6}})
	// The raylib-port pill rides the bar itself, on the stretch left of the
	// execute channel; the direct-gfx drop owns the gutter stretch on the
	// right. Two entry points, two separate places on one backend.
	pill := "raylib port entry"
	m := map_metrics(frame)
	pill_w := map_pill_width(frame, pill)
	title_end := l.gfx.x + m.md + map_text_w(frame, "ingot:gfx", "backend calls")
	pill_x := max((l.gfx.x + l.col_left) - pill_w / 2, title_end + m.lg)
	if pill_x + pill_w < l.col_mid - m.lg {
		map_pill(frame, pill_x, l.gfx.y + (l.gfx.h - m.pill_h) / 2, pill)
	}
}

// --- layout smoke check ------------------------------------------------------

// --- app shell ---------------------------------------------------------------

map_legend :: proc(u: ^ui.Ui) {
	assert(u != nil && u.open, "map_legend: invalid UI")
	theme := ui.ui_frame_theme(u.frame)
	if active_phase > 0 {
		ui.label(u, PHASE_SOURCES[active_phase], color = theme.fg_tool)
		return
	}
	ui.label(
		u,
		"boxes \u2192 ownership \u00b7 numbered arrows \u2192 the six steps of one frame \u00b7 dashed \u2192 service or escape hatch \u00b7 tint \u2192 rebuilt each frame",
		color = theme.fg_secondary,
	)
	ui.label(
		u,
		"Start at the highest tier that fits: App before Session before gfx \u00b7 facade widgets by default, *_at islands only where the app owns geometry",
		color = theme.fg_secondary,
	)
}

draw_map :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil && w > 0, "draw_map: invalid geometry")
	state := &map_state
	u := &state.form
	// The canvas carves the form's full width, so the layout can be measured
	// before the root opens and the canvas sized from it. ui.canvas takes a
	// logical height, hence the divide by the current scale.
	_, canvas_px := map_layout(frame, 0, 0, w)
	scale := ui.ui_frame_scf(frame, 1)
	assert(scale > 0, "draw_map: invalid scale")
	canvas_h := i32(f32(canvas_px) / scale + 1)
	// Toolbar block: header, stepper row, caption, legend, and the gaps
	// between them - measured, not guessed.
	m := map_metrics(frame)
	rows_h := m.label * 5 + m.card_h + m.lg * 2
	ui.begin(u, frame, {x, y0, w, canvas_px + rows_h}, gap = .SM)
	ui.scope_begin(u, "api-map")
	_ = ui.section_header(u, "INGOT API MAP: START TIERS, OWNERSHIP, ONE FRAME")
	ui.row_begin(u, 32, gap = .XS, align = .Center)
	if ui.button(u, "all", "All", ui.Btn_Style.Primary if active_phase == 0 else .Ghost) {
		active_phase = 0
	}
	for phase in i32(1) ..= PHASE_COUNT {
		style := ui.Btn_Style.Primary if active_phase == phase else .Ghost
		if ui.button(u, u64(phase), fmt.tprintf("%d", phase), style) {
			active_phase = 0 if active_phase == phase else phase
		}
	}
	if ui.button(u, "theme", "Light theme" if dark else "Dark theme") {
		dark = !dark
		apply_theme(frame)
	}
	ui.row_end(u)
	ui.label(u, PHASE_CAPTIONS[active_phase])
	map_legend(u)
	_ = ui.canvas(u, {height = canvas_h}, api_map_canvas, state)
	ui.scope_end(u)
	end_y := ui.remaining_rect(u).y
	ui.end(u)
	return end_y + ui.ui_frame_sc(frame, 16)
}

apply_theme :: proc(frame: ^ui.Ui_Frame = nil) {
	t := ui.theme_dark() if dark else ui.theme_light()
	ui.ui_runtime_set_theme(ui_gfx.app_ui_runtime(&app), t)
	app.config.clear_color = ui_gfx.color_to_gfx(t.bg_app)
	app.config.clear_color.a = 255
	if frame != nil do ui.request_redraw(frame)
}

map_frame :: proc(a: ^ui_gfx.App, frame: ^ui.Ui_Frame, userdata: rawptr) {
	_ = userdata
	root := ui_gfx.app_screen_rect(a)
	when MAP_CAPTURE do root = {0, 0, MAP_CAPTURE_WIDTH, MAP_CAPTURE_HEIGHT}
	// Native-only sweep harness (check.odin); exits the process when enabled.
	when LAYOUT_CHECK do layout_check(frame)
	if ui.is_key_pressed(frame, .F12) do debug_on = !debug_on
	header_h := ui.ui_frame_metrics(frame).TAB_BAR_HEIGHT
	pane_rect := ui.Rect_I32{0, header_h, root.w, root.h - header_h}
	y := ui.pane_begin(frame, &content_pane, pane_rect, pad = 14)
	cx := ui.ui_frame_sc(frame, 18)
	cw := root.w - ui.ui_frame_sc(frame, 52)
	end_y := draw_map(frame, cx, y, cw)
	ui.pane_end(frame, &content_pane, pane_rect, end_y, pad = 14)
	if debug_on {
		ui.draw_debug_overlay(
			frame,
			root.w - ui.ui_frame_sc(frame, 290),
			header_h + ui.ui_frame_sc(frame, 10),
		)
	}
	_ = ui.draw_app_header(frame, "ingot api map", root.w)
}

main :: proc() {
	// Capture mode owns its own loop: paint replays after the frame callback
	// returns, so the render target must bracket the whole session frame.
	when MAP_CAPTURE {
		map_capture_main()
	} else {
		_ = ui_gfx.app_run(
			&app,
			{
				width = 1180,
				height = 860,
				title = "ingot api map",
				target_fps = 60,
				event_waiting = true,
				clear_color = {24, 26, 32, 255},
				session = {semantics_enabled = true},
			},
			{frame = map_frame},
		)
	}
}
