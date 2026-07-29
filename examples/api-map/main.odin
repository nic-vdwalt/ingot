// ingot api-map - one unified API-architecture diagram. The gallery's three
// stacked panels (where to start, ownership, call paths) are merged into a
// single picture by giving each concept its own visual channel:
//
//   - ownership     -> containment: nested boxes, no edges at all
//   - call path     -> numbered phase badges + short solid arrows
//   - borrows/feeds -> thin dashed arrows between adjacent cards only
//   - where to start-> START pills on the actual nodes
//
// Nothing is duplicated and no lines cross: every arrow is a straight vertical
// drop in its own column channel, except the single right-gutter elbow for the
// direct-gfx escape hatch, which runs through otherwise empty space.
//
// Structural claims are verified against source: ui_gfx/app.odin (App fields),
// ui_gfx/session.odin (Session's five peers), ui_gfx/adapter.odin (text
// backend, paint sink, overlay replay, platform apply, a11y publish),
// ui/ui_context.odin (Ui_Frame borrows), ui/paint.odin (Ui_Output channels).
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

Map_State :: struct {
	form:    ui.Ui,
	tooltip: ui.Tooltip_State,
}

map_state: Map_State

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
		"Dashed gutter: direct gfx capabilities bypass UI paint entirely.")

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
	("Reusable ui.Ui form \u2461 \u00b7 default UI composition" +
		`
` +
		"Backend-free: ingot:ui imports only core:*" +
		`
` +
		"Owns: slot carving, logical scaling, stable identity, focus, semantics" +
		`
` +
		"Persists across frames for Tab order; attaches only between begin/end.")

TIP_EXPLICIT ::
	("*_at and explicit composition \u2461 \u00b7 escape hatch" +
		`
` +
		"The application owns geometry: canvases, virtualized lists, overlays" +
		`
` +
		"Takes physical pixels; scaling and focus wiring move to the caller" +
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
	("ui.Ui_Runtime \u00b7 borrowed session state" +
		`
` +
		"Owns: fonts, theme, scale, DPI, semantics infrastructure" +
		`
` +
		"Borrowed by Ui_Frame while a frame is open" +
		`
` +
		"Receives a text backend from the Adapter for measurement and shaping.")

TIP_FRAME ::
	("ui.Ui_Frame \u2462 \u00b7 records paint and semantics" +
		`
` +
		"Borrows runtime, input, and output as pointers while open" +
		`
` +
		"(ui_context.odin) \u2014 it owns none of them" +
		`
` +
		"Widgets read the input snapshot and emit to the UI paint lists.")

TIP_INPUT ::
	("ui.Ui_Input \u2460 \u00b7 one snapshot per frame" +
		`
` +
		"Filled by the Adapter from platform events before widgets run" +
		`
` +
		"Views should query the frame, never poll gfx again after capture.")

TIP_OUTPUT ::
	("ui.Ui_Output \u2463 \u00b7 three channels (paint.odin)" +
		`
` +
		"main: streamed through the Adapter sink as commands are emitted" +
		`
` +
		"overlay: replayed at frame end, above main paint" +
		`
` +
		"platform: cursor, clipboard, and window requests applied via the bridge.")

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
	("ui_gfx.Adapter \u2464 \u00b7 two-way renderer/platform bridge" +
		`
` +
		"Down: streams main paint, replays overlay, applies platform output" +
		`
` +
		"Up: captures events into Ui_Input, lends Ui_Runtime a text backend," +
		`
` +
		"publishes the accessibility tree after finalization" +
		`
` +
		"Not an application shell: direct use means owning every policy above.")

TIP_GFX ::
	("ingot:gfx \u2465 \u00b7 backend \u00b7 START for a raylib port" +
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

// --- small drawing helpers (physical pixels; canvas is an explicit island) ---

msc :: proc(frame: ^ui.Ui_Frame, value: i32) -> i32 {
	assert(frame != nil, "msc: nil frame")
	return ui.ui_frame_sc(frame, value)
}

Map_Card :: struct {
	rect:    ui.Rect_I32,
	title:   string,
	detail:  string,
	tooltip: string,
	accent:  ui.Color,
	phase:   i32,
}

map_card :: proc(frame: ^ui.Ui_Frame, state: ^Map_State, node: Map_Card) {
	assert(frame != nil && state != nil, "map_card: invalid arguments")
	assert(node.rect.w > 0 && node.rect.h > 0, "map_card: invalid node")
	assert(len(node.title) > 0 && len(node.tooltip) > 0, "map_card: missing text")
	theme := ui.ui_frame_theme(frame)
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
	ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.10, 6, 1, theme.border_color)
	if hovered {
		ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.10, 6, 2, node.accent)
	}
	ui.draw_rectangle(frame, node.rect.x, node.rect.y, msc(frame, 4), node.rect.h, node.accent)
	ui.text(
		frame,
		node.title,
		node.rect.x + msc(frame, 12),
		node.rect.y + msc(frame, 7),
		.Label,
		.Primary,
	)
	if len(node.detail) > 0 {
		ui.text(
			frame,
			node.detail,
			node.rect.x + msc(frame, 12),
			node.rect.y + msc(frame, 25),
			.Label,
			.Secondary,
		)
	}
	if node.phase > 0 do map_phase_badge(frame, node.rect, node.phase)
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

// map_phase_badge marks a node's position in the per-frame cycle with a
// numbered circle on its top-right corner.
map_phase_badge :: proc(frame: ^ui.Ui_Frame, card: ui.Rect_I32, phase: i32) {
	assert(frame != nil && phase >= 1 && phase <= 6, "map_phase_badge: invalid phase")
	theme := ui.ui_frame_theme(frame)
	radius := f32(msc(frame, 9))
	center := ui.Vector2{f32(card.x + card.w), f32(card.y)}
	ui.draw_circle_v(frame, center, radius, theme.fg_accent)
	digit := fmt.tprintf("%d", phase)
	width := ui.text_width(frame, digit, .Label)
	size := ui.text_role_size(frame, .Label)
	ui.text(frame, digit, i32(center.x) - width / 2, i32(center.y) - size / 2, .Label, .Inverse)
}

// map_box draws a containment box: ownership is expressed by nesting alone,
// so boxes carry no edges. The title row is hoverable for the box's tooltip.
map_box :: proc(
	frame: ^ui.Ui_Frame,
	state: ^Map_State,
	rect: ui.Rect_I32,
	title: string,
	tooltip: string,
	fill: ui.Color,
	pill: string = "",
	phase: i32 = 0,
) {
	assert(frame != nil && state != nil, "map_box: invalid arguments")
	assert(rect.w > 0 && rect.h > 0, "map_box: invalid rect")
	assert(len(title) > 0 && len(tooltip) > 0, "map_box: missing text")
	theme := ui.ui_frame_theme(frame)
	paint_rect := ui.rect_f32(rect)
	ui.draw_rectangle_rounded(frame, paint_rect, 0.03, 6, fill)
	ui.draw_rectangle_rounded_lines_ex(frame, paint_rect, 0.03, 6, 1, theme.border_color)
	title_x := rect.x + msc(frame, 12)
	title_y := rect.y + msc(frame, 8)
	ui.text(frame, title, title_x, title_y, .Label, .Primary)
	pill_x := title_x + ui.text_width(frame, title, .Label) + msc(frame, 10)
	if len(pill) > 0 do map_start_pill(frame, pill_x, title_y - msc(frame, 2), pill)
	if phase > 0 do map_phase_badge(frame, rect, phase)
	origin := ui.frame_pane_origin(frame)
	title_rect := ui.Rect_I32 {
		rect.x + i32(origin.x),
		rect.y + i32(origin.y),
		rect.w,
		msc(frame, 26),
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

// map_start_pill labels a node as a starting tier directly on the node, so the
// decision layer needs no separate cards.
map_start_pill :: proc(frame: ^ui.Ui_Frame, x, y: i32, label: string) {
	assert(frame != nil && len(label) > 0, "map_start_pill: invalid label")
	theme := ui.ui_frame_theme(frame)
	width := ui.text_width(frame, label, .Label)
	pad := msc(frame, 8)
	rect := ui.rect_f32({x, y, width + pad * 2, msc(frame, 20)})
	ui.draw_rectangle_rounded(frame, rect, 0.9, 8, theme.bg_code)
	ui.draw_rectangle_rounded_lines_ex(frame, rect, 0.9, 8, 1, theme.fg_accent)
	size := ui.text_role_size(frame, .Label)
	ui.text(
		frame,
		label,
		x + pad,
		y + (msc(frame, 20) - size) / 2,
		.Label,
		.Primary,
	)
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

map_arrow_down :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "map_arrow_down: nil frame")
	size := f32(msc(frame, 5))
	ui.draw_triangle(frame, tip, tip + ui.Vector2{-size, -size}, tip + ui.Vector2{size, -size}, color)
}

map_arrow_up :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "map_arrow_up: nil frame")
	size := f32(msc(frame, 5))
	ui.draw_triangle(frame, tip, tip + ui.Vector2{size, size}, tip + ui.Vector2{-size, size}, color)
}

map_arrow_left :: proc(frame: ^ui.Ui_Frame, tip: ui.Vector2, color: ui.Color) {
	assert(frame != nil, "map_arrow_left: nil frame")
	size := f32(msc(frame, 5))
	ui.draw_triangle(frame, tip, tip + ui.Vector2{size, -size}, tip + ui.Vector2{size, size}, color)
}

// map_drop draws a straight solid arrow from x between two y coordinates:
// the only solid edge shape in the diagram, so no two edges can cross.
map_drop :: proc(frame: ^ui.Ui_Frame, x: i32, from_y, to_y: i32, color: ui.Color) {
	assert(frame != nil && to_y > from_y, "map_drop: invalid drop")
	map_segment(frame, {f32(x), f32(from_y)}, {f32(x), f32(to_y)}, color)
	map_arrow_down(frame, {f32(x), f32(to_y)}, color)
}

map_rise :: proc(frame: ^ui.Ui_Frame, x: i32, from_y, to_y: i32, dashed: bool, color: ui.Color) {
	assert(frame != nil && from_y > to_y, "map_rise: invalid rise")
	if dashed {
		map_dashed_segment(frame, {f32(x), f32(from_y)}, {f32(x), f32(to_y)}, color)
	} else {
		map_segment(frame, {f32(x), f32(from_y)}, {f32(x), f32(to_y)}, color)
	}
	map_arrow_up(frame, {f32(x), f32(to_y)}, color)
}

// --- the unified diagram -----------------------------------------------------

Map_Rects :: struct {
	caller:   ui.Rect_I32,
	app_box:  ui.Rect_I32,
	form:     ui.Rect_I32,
	explicit: ui.Rect_I32,
	session:  ui.Rect_I32,
	runtime:  ui.Rect_I32,
	frame:    ui.Rect_I32,
	input:    ui.Rect_I32,
	output:   ui.Rect_I32,
	minis:    [3]ui.Rect_I32,
	adapter:  ui.Rect_I32,
	gfx:      ui.Rect_I32,
	columns:  [3]i32, // channel x for left (runtime), mid (frame), right (input)
	gutter_x: i32, // right-gutter channel for the direct-gfx escape hatch
}

map_rects :: proc(frame: ^ui.Ui_Frame, rect: ui.Rect_I32) -> (r: Map_Rects) {
	assert(frame != nil && rect.w > 0 && rect.h > 0, "map_rects: invalid rect")
	pad := msc(frame, 16)
	gutter := msc(frame, 56)
	r.caller = {rect.x + pad, rect.y + pad, rect.w - pad * 2, msc(frame, 434)}
	r.app_box = {
		r.caller.x + msc(frame, 14),
		r.caller.y + msc(frame, 28),
		r.caller.w - msc(frame, 28) - gutter,
		msc(frame, 392),
	}
	r.gutter_x = r.app_box.x + r.app_box.w + gutter / 2
	r.session = {
		r.app_box.x + msc(frame, 14),
		r.app_box.y + msc(frame, 102),
		r.app_box.w - msc(frame, 28),
		msc(frame, 276),
	}
	inner_x := r.session.x + msc(frame, 14)
	inner_w := r.session.w - msc(frame, 28)
	for index in 0 ..< 3 {
		r.columns[index] = inner_x + inner_w * (2 * i32(index) + 1) / 6
	}
	card_w := min(msc(frame, 170), inner_w / 3 - msc(frame, 10))
	card_h := msc(frame, 44)
	row1_y := r.session.y + msc(frame, 30)
	r.runtime = {r.columns[0] - card_w / 2, row1_y, card_w, card_h}
	r.frame = {r.columns[1] - card_w / 2, row1_y, card_w, card_h}
	r.input = {r.columns[2] - card_w / 2, row1_y, card_w, card_h}
	strip_w := msc(frame, 130)
	strip_y := r.app_box.y + msc(frame, 28)
	r.form = {r.columns[1] - msc(frame, 70) - strip_w / 2, strip_y, strip_w, card_h}
	r.explicit = {r.columns[1] + msc(frame, 70) - strip_w / 2, strip_y, strip_w, card_h}
	output_w := inner_w / 3
	r.output = {inner_x + inner_w / 3, row1_y + card_h + msc(frame, 34), output_w, msc(frame, 76)}
	mini_gap := msc(frame, 6)
	mini_w := (r.output.w - msc(frame, 20) - mini_gap * 2) / 3
	mini_y := r.output.y + msc(frame, 28)
	for index in 0 ..< 3 {
		r.minis[index] = {
			r.output.x + msc(frame, 10) + i32(index) * (mini_w + mini_gap),
			mini_y,
			mini_w,
			msc(frame, 38),
		}
	}
	r.adapter = {inner_x, r.output.y + r.output.h + msc(frame, 34), inner_w, card_h}
	gfx_w := card_w + msc(frame, 40)
	r.gfx = {
		r.columns[1] - gfx_w / 2,
		r.caller.y + r.caller.h + msc(frame, 40),
		gfx_w,
		card_h,
	}
	return
}

map_edges :: proc(frame: ^ui.Ui_Frame, r: Map_Rects) {
	assert(frame != nil, "map_edges: nil frame")
	theme := ui.ui_frame_theme(frame)
	// Facade and explicit UI both declare into the frame (phase 2 -> 3). Drop
	// points sit inside the frame card's top edge, one per strip card.
	map_drop(
		frame,
		r.form.x + r.form.w / 2,
		r.form.y + r.form.h,
		r.frame.y,
		theme.fg_success,
	)
	map_drop(
		frame,
		r.explicit.x + r.explicit.w / 2,
		r.explicit.y + r.explicit.h,
		r.frame.y,
		theme.fg_accent,
	)
	// Frame records into output, output feeds the adapter (3 -> 4 -> 5): the
	// middle channel.
	map_drop(frame, r.columns[1], r.frame.y + r.frame.h, r.output.y, theme.fg_success)
	map_drop(frame, r.columns[1], r.output.y + r.output.h, r.adapter.y, theme.fg_success)
	// Left channel: adapter lends the runtime a text backend (upstream feed).
	map_rise(frame, r.columns[0], r.adapter.y, r.runtime.y + r.runtime.h, true, theme.fg_secondary)
	ui.text(
		frame,
		"text backend",
		r.columns[0] + msc(frame, 8),
		(r.adapter.y + r.output.y + r.output.h) / 2,
		.Label,
		.Secondary,
	)
	// Right channel: adapter captures platform events into the snapshot (1).
	map_rise(frame, r.columns[2], r.adapter.y, r.input.y + r.input.h, false, theme.fg_tool)
	capture_label := "\u2460 capture"
	label_w := ui.text_width(frame, capture_label, .Label)
	ui.text(
		frame,
		capture_label,
		r.columns[2] - msc(frame, 8) - label_w,
		(r.adapter.y + r.output.y + r.output.h) / 2,
		.Label,
		.Tool,
	)
	// Adapter executes on the backend (5 -> 6): the drop passes through box
	// borders, which are containment, not edges.
	map_drop(frame, r.columns[1], r.adapter.y + r.adapter.h, r.gfx.y, theme.fg_success)
	// Escape hatch: caller-owned direct gfx capabilities bypass UI paint via
	// the right gutter, the only elbow in the diagram, through empty space.
	gutter_top := r.caller.y + msc(frame, 34)
	elbow_y := r.gfx.y + r.gfx.h / 2
	map_dashed_segment(
		frame,
		{f32(r.gutter_x), f32(gutter_top)},
		{f32(r.gutter_x), f32(elbow_y)},
		theme.fg_secondary,
	)
	map_dashed_segment(
		frame,
		{f32(r.gutter_x), f32(elbow_y)},
		{f32(r.gfx.x + r.gfx.w), f32(elbow_y)},
		theme.fg_secondary,
	)
	map_arrow_left(frame, {f32(r.gfx.x + r.gfx.w), f32(elbow_y)}, theme.fg_secondary)
	ui.text(
		frame,
		"direct gfx",
		r.gutter_x + msc(frame, 8),
		r.caller.y + r.caller.h + msc(frame, 8),
		.Label,
		.Secondary,
	)
}

map_legend :: proc(frame: ^ui.Ui_Frame, r: Map_Rects) {
	assert(frame != nil, "map_legend: nil frame")
	legend := "boxes \u2192 ownership \u00b7 solid \u2192 per-frame call path \u00b7 dashed \u2192 borrow / escape hatch"
	width := ui.text_width(frame, legend, .Label)
	x := r.caller.x + r.caller.w - msc(frame, 12) - width
	if x <= r.caller.x + msc(frame, 320) do return
	ui.text(frame, legend, x, r.caller.y + msc(frame, 8), .Label, .Secondary)
}

api_map_canvas :: proc(frame: ^ui.Ui_Frame, rect: ui.Rect_I32, userdata: rawptr) {
	assert(frame != nil && rect.w > 0 && rect.h > 0, "api_map_canvas: invalid canvas")
	assert(userdata != nil, "api_map_canvas: nil state")
	state := cast(^Map_State)userdata
	theme := ui.ui_frame_theme(frame)
	r := map_rects(frame, rect)
	// Containment boxes, outermost first.
	map_box(frame, state, r.caller, "CALLER-OWNED APPLICATION STATE", TIP_CALLER, theme.bg_code)
	map_box(
		frame,
		state,
		r.app_box,
		"ui_gfx.App",
		TIP_APP,
		theme.bg_secondary,
		pill = "START \u00b7 new UI app",
	)
	map_box(
		frame,
		state,
		r.session,
		"ui_gfx.Session",
		TIP_SESSION,
		theme.bg_code,
		pill = "START \u00b7 custom loop",
	)
	map_box(
		frame,
		state,
		r.output,
		"ui.Ui_Output",
		TIP_OUTPUT,
		theme.bg_secondary,
		phase = 4,
	)
	// Edges under the cards so arrowheads meet card borders cleanly.
	map_edges(frame, r)
	map_legend(frame, r)
	// Nodes.
	map_card(
		frame,
		state,
		{r.form, "ui.Ui form", "facade widgets", TIP_FORM, theme.fg_success, 2},
	)
	map_card(
		frame,
		state,
		{r.explicit, "*_at islands", "explicit UI", TIP_EXPLICIT, theme.fg_accent, 2},
	)
	map_card(
		frame,
		state,
		{r.runtime, "Ui_Runtime", "fonts \u00b7 theme \u00b7 scale", TIP_RUNTIME, theme.fg_tool, 0},
	)
	map_card(
		frame,
		state,
		{r.frame, "Ui_Frame", "records paint", TIP_FRAME, theme.fg_success, 3},
	)
	map_card(
		frame,
		state,
		{r.input, "Ui_Input", "one snapshot", TIP_INPUT, theme.fg_tool, 1},
	)
	mini_titles := [3]string{"main", "overlay", "platform"}
	mini_tips := [3]string{TIP_MAIN, TIP_OVERLAY, TIP_PLATFORM}
	for index in 0 ..< 3 {
		map_card(
			frame,
			state,
			{r.minis[index], mini_titles[index], "", mini_tips[index], theme.fg_user, 0},
		)
	}
	map_card(
		frame,
		state,
		{r.adapter, "Adapter", "two-way bridge: replay down, feed up", TIP_ADAPTER, theme.fg_assistant, 5},
	)
	map_card(
		frame,
		state,
		{r.gfx, "ingot:gfx", "backend calls", TIP_GFX, theme.fg_user, 6},
	)
	pill_w := ui.text_width(frame, "START \u00b7 raylib port", .Label) + msc(frame, 16)
	map_start_pill(
		frame,
		r.gfx.x + (r.gfx.w - pill_w) / 2,
		r.gfx.y + r.gfx.h + msc(frame, 8),
		"START \u00b7 raylib port",
	)
}

// --- app shell ---------------------------------------------------------------

draw_map :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil && w > 0, "draw_map: invalid geometry")
	state := &map_state
	u := &state.form
	canvas_h: i32 = 604
	ui.begin(u, frame, {x, y0, w, ui.ui_frame_sc(frame, canvas_h + 120)}, gap = .SM)
	ui.scope_begin(u, "api-map")
	_ = ui.section_header(u, "INGOT API MAP: START TIERS, OWNERSHIP, PER-FRAME CALL PATH")
	ui.row_begin(u, 32, gap = .SM, align = .Center)
	ui.label(
		u,
		"Boxes nest by ownership; badges \u2460-\u2465 order one frame; hover any node.",
	)
	if ui.button(u, "theme", "Light theme" if dark else "Dark theme") {
		dark = !dark
		apply_theme(frame)
	}
	ui.row_end(u)
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
	_ = ui_gfx.app_run(
		&app,
		{
			width = 1100,
			height = 820,
			title = "ingot api map",
			target_fps = 60,
			event_waiting = true,
			clear_color = {24, 26, 32, 255},
			session = {semantics_enabled = true},
		},
		{frame = map_frame},
	)
}
