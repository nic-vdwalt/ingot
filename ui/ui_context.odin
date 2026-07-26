// LIB-CANDIDATE: imports only core:*.
// Ui is a caller-owned context bundling layout and keyboard focus. Static
// forms may use sequential registration; conditional and dynamic forms pass
// stable caller IDs whose traversal order is rebuilt in bounded frame arrays.
package ui

import "core:strings"


// MAX_FOCUSABLES bounds focus registrations per frame (Tiger Style: put a
// limit on everything).
MAX_FOCUSABLES :: 256

Ui_Focus_Mode :: enum u8 {
	None,
	Sequential,
	Stable,
}

// Ui is caller-owned. Stable arrays retain only bounded traversal identity;
// widgets and their values remain entirely caller-owned.
Ui_Runtime :: struct {
	text:                  Text_System,
	text_backend:          Text_Backend,
	spell:                 Spell_System,
	style:                 Theme,
	metrics:               Ui_Metrics,
	scale:                 f32,
	dpi_last:              f32,
	generation:            u64,
	frame_generation:      u64,
	pending_a11y:          A11y_Pending_Action,
	semantics_enabled:     bool,
	semantics_snapshot:    Sem_Frame,
	scale_metrics_hook:    proc(scale: f32),
	scale_invalidate_hook: proc(),
	initialized:           bool,
}

MAX_PANE_SCOPES :: 16

Ui_Frame :: struct {
	runtime:          ^Ui_Runtime,
	input_default:    Ui_Input,
	input:            ^Ui_Input,
	output:           ^Ui_Output,
	scratch:          Frame_Scratch,
	cursor:           Cursor_State,
	overlay:          Overlay_State,
	route:            Input_Route_State,
	interaction:      Interaction_State,
	semantics:        Semantics_State,
	pane_origins:     [MAX_PANE_SCOPES]Vector2,
	pane_count:       int,
	text_cull_top:    i32,
	text_cull_bottom: i32,
	open_roots:       int,
	// Widgets handed a degenerate rect (zero or negative in either dimension)
	// or an empty caller collection draw nothing and return their zero result
	// rather than trapping: layout arithmetic legitimately produces those
	// values when a window is narrowed or a panel collapses, and a trap there
	// takes the whole app down. Counting the drops keeps that from hiding real
	// layout bugs — tests assert the counter is zero on golden-path frames.
	degenerate_drops:              int,
	text_input_full_path_count:     u64,
	text_input_inactive_candidates: u64,
	finalized:                     bool,
	open:                          bool,
}

// ui_frame_drop_degenerate records that a widget declined to draw because its
// geometry or inputs were degenerate, and returns true, so call sites read as a
// single guarded early-out:
//
//	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return {}
ui_frame_drop_degenerate :: proc(frame: ^Ui_Frame, degenerate: bool) -> bool {
	if !degenerate do return false
	// A nil frame is a programmer error everywhere else in this package, but
	// this helper sits on the failure path and must never be the thing that
	// crashes.
	if frame != nil do frame.degenerate_drops += 1
	return true
}

ui_runtime_init :: proc(runtime: ^Ui_Runtime) {
	assert(runtime != nil, "ui_runtime_init: nil runtime")
	assert(!runtime.initialized, "ui_runtime_init: already initialized")
	runtime.scale = 1
	runtime.metrics = ui_metrics(runtime.scale)
	runtime.style = THEME_DARK
	text_system_init(&runtime.text)
	runtime.initialized = true
}

ui_runtime_destroy :: proc(runtime: ^Ui_Runtime) {
	assert(runtime != nil, "ui_runtime_destroy: nil runtime")
	text_system_destroy(&runtime.text)
	spell_system_destroy(&runtime.spell)
	runtime^ = {}
}

ui_runtime_set_scale :: proc(runtime: ^Ui_Runtime, value: f32) {
	assert(runtime != nil && runtime.initialized, "ui_runtime_set_scale: invalid runtime")
	scale := clamp(value, 0.5, 3)
	if scale == runtime.scale do return
	runtime.scale = scale
	runtime.metrics = ui_metrics(scale)
	reset_font_atlases_with(&runtime.text)
	ui_runtime_invalidate_scale_caches(runtime)
	if runtime.scale_metrics_hook != nil do runtime.scale_metrics_hook(scale)
	runtime.generation += 1
}

ui_runtime_text :: proc(runtime: ^Ui_Runtime) -> ^Text_System {
	assert(runtime != nil && runtime.initialized, "ui_runtime_text: invalid runtime")
	return &runtime.text
}

ui_runtime_spell :: proc(runtime: ^Ui_Runtime) -> ^Spell_System {
	assert(runtime != nil && runtime.initialized, "ui_runtime_spell: invalid runtime")
	return &runtime.spell
}

ui_runtime_theme :: proc(runtime: ^Ui_Runtime) -> ^Theme {
	assert(runtime != nil && runtime.initialized, "ui_runtime_theme: invalid runtime")
	return &runtime.style
}

ui_frame_runtime :: proc(frame: ^Ui_Frame) -> ^Ui_Runtime {
	assert(frame != nil && frame.open, "ui_frame_runtime: invalid frame")
	assert(frame.runtime != nil && frame.runtime.initialized, "ui_frame_runtime: invalid runtime")
	return frame.runtime
}

ui_frame_text :: proc(frame: ^Ui_Frame) -> ^Text_System {
	runtime := ui_frame_runtime(frame)
	assert(runtime.text.font_loaded, "ui_frame_text: text system not initialized")
	return &runtime.text
}

ui_frame_spell :: proc(frame: ^Ui_Frame) -> ^Spell_System {
	runtime := ui_frame_runtime(frame)
	assert(runtime.initialized, "ui_frame_spell: invalid runtime")
	return &runtime.spell
}

ui_frame_theme :: proc(frame: ^Ui_Frame) -> ^Theme {
	runtime := ui_frame_runtime(frame)
	assert(runtime.style.fg_primary.a > 0, "ui_frame_theme: invalid theme")
	return &runtime.style
}

ui_frame_metrics :: proc(frame: ^Ui_Frame) -> ^Ui_Metrics {
	runtime := ui_frame_runtime(frame)
	assert(runtime.scale > 0, "ui_frame_metrics: invalid scale")
	return &runtime.metrics
}

// ui_frame_style returns scaled metrics and the active theme together. Drawing
// code almost always needs both, and resolving them once per view procedure
// avoids re-deriving them at every call site.
ui_frame_style :: proc(frame: ^Ui_Frame) -> (^Ui_Metrics, ^Theme) {
	runtime := ui_frame_runtime(frame)
	assert(runtime.scale > 0, "ui_frame_style: invalid scale")
	assert(runtime.style.fg_primary.a > 0, "ui_frame_style: invalid theme")
	return &runtime.metrics, &runtime.style
}

ui_frame_sc :: proc(frame: ^Ui_Frame, value: i32) -> i32 {
	runtime := ui_frame_runtime(frame)
	assert(runtime.scale > 0, "ui_frame_sc: invalid scale")
	return i32(f32(value) * runtime.scale + 0.5)
}

ui_frame_scf :: proc(frame: ^Ui_Frame, value: f32) -> f32 {
	runtime := ui_frame_runtime(frame)
	assert(runtime.scale > 0, "ui_frame_scf: invalid scale")
	return value * runtime.scale
}

ui_runtime_set_scale_hooks :: proc(
	runtime: ^Ui_Runtime,
	metrics_hook: proc(scale: f32),
	invalidate_hook: proc(),
) {
	assert(runtime != nil && runtime.initialized, "ui_runtime_set_scale_hooks: invalid runtime")
	runtime.scale_metrics_hook = metrics_hook
	runtime.scale_invalidate_hook = invalidate_hook
}

ui_frame_begin :: proc(frame: ^Ui_Frame, runtime: ^Ui_Runtime, input: ^Ui_Input = nil) {
	assert(frame != nil && runtime != nil, "ui_frame_begin: nil frame or runtime")
	assert(runtime.initialized && !frame.open, "ui_frame_begin: invalid lifetime")
	frame_scratch_begin(&frame.scratch)
	runtime.frame_generation += 1
	frame.input = input if input != nil else &frame.input_default
	if frame.output != nil do ui_output_reset(frame.output)
	a11y_expire_before_frame(runtime)
	frame.runtime = runtime
	frame.cursor.requested = .DEFAULT
	frame.overlay = {}
	frame.pane_count = 0
	frame.text_cull_top = min(i32)
	frame.text_cull_bottom = max(i32)
	frame.open_roots = 0
	frame.degenerate_drops = 0
	when UI_TELEMETRY_ENABLED {
		frame.text_input_full_path_count = 0
		frame.text_input_inactive_candidates = 0
	}
	frame.finalized = false
	frame.open = true
	route_begin_frame(frame)
	interact_frame_begin(frame)
	sem_begin_frame(frame)
}

ui_frame_finalize :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open && !frame.finalized)
	assert(frame.open_roots == 0 && frame.pane_count == 0 && !frame.overlay.open)
	if frame.output != nil {
		// Report the leaking begin_scissor_mode call site: the depth alone
		// says nothing about which view forgot to pop.
		assert(
			frame.output.main.clip_count == 0,
			"ui_frame_finalize: unbalanced main clips",
			paint_clip_leak_origin(&frame.output.main),
		)
		assert(
			frame.output.overlay.clip_count == 0,
			"ui_frame_finalize: unbalanced overlay clips",
			paint_clip_leak_origin(&frame.output.overlay),
		)
	}
	overlay_flush(frame); cursor_apply(frame); focus_scope_frame_end(frame)
	snapshot := &frame.runtime.semantics_snapshot
	snapshot.count = frame.semantics.cur.count
	copy(snapshot.nodes[:snapshot.count], frame.semantics.cur.nodes[:snapshot.count])
	a11y_expire_after_frame(frame.runtime); focus_scope_clear_live(frame)
	frame.finalized = true
}
ui_frame_release :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open && frame.finalized)
	frame.text_cull_top = min(i32); frame.text_cull_bottom = max(i32)
	frame_scratch_end(&frame.scratch)
	frame.runtime = nil; frame.input = nil; frame.open = false; frame.finalized = false
}
ui_frame_end :: proc(frame: ^Ui_Frame) {ui_frame_finalize(frame); ui_frame_release(frame)}
ui_frame_destroy :: proc(frame: ^Ui_Frame) {assert(frame != nil && !frame.open)
	frame_scratch_destroy(&frame.scratch)
	frame^ = {}}

ui_frame_pane_push :: proc(frame: ^Ui_Frame, origin: Vector2) {
	assert(frame != nil && frame.open, "pane_push: invalid frame")
	assert(frame.pane_count < MAX_PANE_SCOPES, "pane_push: scope limit")
	frame.pane_origins[frame.pane_count] = origin
	frame.pane_count += 1
}

ui_frame_pane_pop :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "pane_pop: invalid frame")
	assert(frame.pane_count > 0, "pane_pop: no scope")
	frame.pane_count -= 1
}

frame_pane_origin :: proc(frame: ^Ui_Frame) -> Vector2 {
	assert(frame != nil && frame.open, "pane_origin: invalid frame")
	if frame.pane_count == 0 do return {}
	return frame.pane_origins[frame.pane_count - 1]
}

frame_to_local :: proc(frame: ^Ui_Frame, point: Vector2) -> Vector2 {
	origin := frame_pane_origin(frame)
	return {point.x - origin.x, point.y - origin.y}
}

frame_to_screen :: proc(frame: ^Ui_Frame, point: Vector2) -> Vector2 {
	origin := frame_pane_origin(frame)
	return {point.x + origin.x, point.y + origin.y}
}

Ui :: struct {
	frame:        ^Ui_Frame,
	layout:       Layout,
	focus_slot:   int,
	focus_count:  int,
	focus_seq:    int,
	stable_focus: Focus_State,
	stable_prev:  [MAX_FOCUSABLES]Focus_Id,
	stable_cur:   [MAX_FOCUSABLES]Focus_Id,
	stable_count: int,
	stable_seq:   int,
	focus_mode:   Ui_Focus_Mode,
	ids:          Id_Context,
	screen_w:     i32,
	screen_h:     i32,
	open:         bool,
}

// ui_begin opens the frame over the given area: caches screen size, runs Tab
// cycling against last frame's focusable count, and opens the root column.
ui_begin_frame :: proc(u: ^Ui, frame: ^Ui_Frame, x, y, w, h: i32, gap: i32 = 0) {
	assert(u != nil && frame != nil, "ui_begin_frame: nil Ui or frame")
	assert(frame.open, "ui_begin_frame: frame not open")
	u.frame = frame
	frame.open_roots += 1
	ui_begin(u, x, y, w, h, gap)
}

ui_begin :: proc(u: ^Ui, x, y, w, h: i32, gap: i32 = 0) {
	assert(u != nil, "ui_begin: nil Ui")
	assert(!u.open, "ui_begin: frame already open")
	frame := u.frame
	input: Ui_Input
	if frame != nil && frame.input != nil do input = frame.input^
	u.screen_w = i32(input.screen_size.x)
	u.screen_h = i32(input.screen_size.y)
	if u.focus_count > 0 do form_focus_cycle(frame, &u.focus_slot, u.focus_count)
	if u.stable_count > 0 && input_key_pressed(&input, .TAB) {
		backwards := input_key_down(&input, .LEFT_SHIFT) || input_key_down(&input, .RIGHT_SHIFT)
		ids := u.stable_prev[:u.stable_count]
		u.stable_focus.active = focus_order_next(ids, u.stable_focus.active, backwards)
	}
	u.focus_seq = 0
	u.stable_seq = 0
	u.focus_mode = .None
	id_context_reset(&u.ids)
	layout_begin(&u.layout, x, y, w, h, gap)
	u.open = true
}

ui_end :: proc(u: ^Ui) {
	assert(u.open, "ui_end: frame not open")
	assert(u.ids.depth == 0, "ui_end: unbalanced id scope")
	layout_end(&u.layout)
	if u.focus_mode == .Stable {
		if u.stable_focus.active != FOCUS_ID_NONE &&
		   focus_order_index(u.stable_cur[:u.stable_seq], u.stable_focus.active) < 0 {
			focus_clear(&u.stable_focus)
		}
		copy(u.stable_prev[:u.stable_seq], u.stable_cur[:u.stable_seq])
		u.stable_count = u.stable_seq
		u.focus_count = 0
	} else {
		u.focus_count = u.focus_seq
		u.stable_count = 0
	}
	u.open = false
	if u.frame != nil {
		assert(u.frame.open_roots > 0, "ui_end: corrupt root count")
		u.frame.open_roots -= 1
		u.frame = nil
	}
}

ui_focus_sequential :: proc(u: ^Ui) -> Focus_Opt {
	assert(u.open, "ui_focus: frame not open")
	assert(u.focus_mode != .Stable, "ui_focus: mixed focus registration")
	assert(u.focus_seq < MAX_FOCUSABLES, "ui_focus: too many focusables")
	u.focus_mode = .Sequential
	u.focus_seq += 1
	return Focus_Opt{&u.focus_slot, u.focus_seq}
}

ui_focus_id :: proc(u: ^Ui, id: Widget_Id) -> Focus_Opt {
	assert(u.open, "ui_focus: frame not open")
	assert(id != FOCUS_ID_NONE, "ui_focus: zero stable id")
	assert(u.focus_mode != .Sequential, "ui_focus: mixed focus registration")
	assert(u.stable_seq < MAX_FOCUSABLES, "ui_focus: too many focusables")
	for registered in u.stable_cur[:u.stable_seq] {
		assert(registered != id, "ui_focus: duplicate stable id")
	}
	u.focus_mode = .Stable
	u.stable_cur[u.stable_seq] = id
	u.stable_seq += 1
	return focus_link(&u.stable_focus, id)
}

ui_focus :: proc {
	ui_focus_sequential,
	ui_focus_id,
}

ui_id_u64 :: proc(u: ^Ui, value: u64) -> Widget_Id {
	assert(u != nil && u.open, "ui_id: frame not open")
	return id_context_id(&u.ids, value)
}

ui_id_string :: proc(u: ^Ui, value: string) -> Widget_Id {
	assert(u != nil && u.open, "ui_id: frame not open")
	return id_context_id(&u.ids, value)
}

ui_id :: proc {
	ui_id_u64,
	ui_id_string,
}

ui_id_push_u64 :: proc(u: ^Ui, value: u64, loc := #caller_location) {
	assert(u != nil && u.open, "ui_id_push: frame not open")
	id_context_push(&u.ids, value, loc)
}

ui_id_push_string :: proc(u: ^Ui, value: string, loc := #caller_location) {
	assert(u != nil && u.open, "ui_id_push: frame not open")
	id_context_push(&u.ids, value, loc)
}

ui_id_push :: proc {
	ui_id_push_u64,
	ui_id_push_string,
}

ui_id_root :: proc {
	ui_id_push_u64,
	ui_id_push_string,
}

ui_id_pop :: proc(u: ^Ui) {
	assert(u != nil && u.open, "ui_id_pop: frame not open")
	id_context_pop(&u.ids)
}

ui_focus_clear :: proc(u: ^Ui) {
	assert(u != nil, "ui_focus_clear: nil Ui")
	assert(!u.open, "ui_focus_clear: frame open")
	u.focus_slot = 0
	focus_clear(&u.stable_focus)
}

// ui_slot carves a w×h rect from the active layout frame. In a column the
// main axis is h; in a row it is w. Cross-axis placement honors alignment.
ui_slot :: proc(u: ^Ui, w, h: i32) -> Rect_I32 {
	assert(u != nil && u.open, "ui_slot: frame not open")
	assert(w >= 0 && h >= 0, "ui_slot: negative size")
	l := &u.layout
	f := &l.stack[l.depth - 1]
	if f.cross_align != .Stretch {
		if layout_kind(l) == .Column do return next_sized(l, h, w)
		return next_sized(l, w, h)
	}
	if layout_kind(l) == .Column {
		r := next(l, h)
		r.w = min(r.w, w)
		return r
	}
	r := next(l, w)
	r.h = min(r.h, h)
	return r
}

ui_slot_visible :: proc(rect: Rect_I32) -> bool {
	return rect.w > 0 && rect.h > 0
}

// ui_flex_begin resolves sibling main-axis sizes on the active Ui frame.
ui_flex_begin :: proc(u: ^Ui, sizes: []Flex_Size) {
	assert(u != nil, "ui_flex_begin: nil Ui")
	assert(u.open, "ui_flex_begin: frame not open")
	flex_begin(&u.layout, sizes)
}

// ui_flex_slot consumes one flex size and honors active cross-axis alignment.
ui_flex_slot :: proc(u: ^Ui, cross_size: i32) -> Rect_I32 {
	assert(u != nil, "ui_flex_slot: nil Ui")
	assert(u.open && cross_size >= 0, "ui_flex_slot: invalid call")
	return flex_next_sized(&u.layout, cross_size)
}

ui_padding :: proc(u: ^Ui, value: Insets_I32) {
	assert(u != nil && u.open, "ui_padding: frame not open")
	layout_inset(&u.layout, value)
}

ui_fill :: proc(u: ^Ui) -> Rect_I32 {
	assert(u != nil && u.open, "ui_fill: frame not open")
	return take_remaining(&u.layout)
}

ui_space_px :: proc(u: ^Ui, value: Space) -> i32 {
	assert(u != nil && u.frame != nil, "ui_space_px: frame required")
	logical: i32
	switch value {
	case .None:
		logical = 0
	case .XS:
		logical = 4
	case .SM:
		logical = 8
	case .MD:
		logical = 12
	case .LG:
		logical = 16
	case .XL:
		logical = 24
	}
	return ui_frame_sc(u.frame, logical)
}

ui_insets :: proc(u: ^Ui, value: Space) -> Insets_I32 {
	return insets(ui_space_px(u, value))
}

ui_compact :: proc(u: ^Ui, breakpoint: i32 = 640) -> bool {
	assert(u != nil && u.open && breakpoint > 0, "ui_compact: invalid call")
	return remaining(&u.layout).w < ui_frame_sc(u.frame, breakpoint)
}

ui_remaining :: proc(u: ^Ui) -> Rect_I32 {
	assert(u != nil && u.open, "ui_remaining: frame not open")
	return remaining(&u.layout)
}

// ui_row / ui_row_end / ui_space: thin conveniences over the Layout the Ui
// already owns; callers may equally use push_row(&u.layout, …) directly.
ui_row :: proc(u: ^Ui, h: i32, gap: i32 = 0, cross_align: Cross_Align = .Start) {
	assert(u.open, "ui_row: frame not open")
	push_row(&u.layout, h, gap, cross_align)
}

ui_row_end :: proc(u: ^Ui) {
	assert(u.open, "ui_row_end: frame not open")
	layout_pop(&u.layout)
}

ui_row_begin :: proc(u: ^Ui, height: i32, sizes: []Layout_Size, style: Layout_Style = {}) {
	assert(u != nil && len(sizes) > 0, "ui_row_begin: invalid call")
	ui_row(u, ui_frame_sc(u.frame, height), ui_space_px(u, style.gap), style.align)
	ui_flex_begin(u, sizes)
}

ui_column :: proc(u: ^Ui, w: i32, gap: i32 = 0, cross_align: Cross_Align = .Stretch) {
	assert(u != nil && u.open, "ui_column: frame not open")
	push_column_sized(&u.layout, w, gap, cross_align)
}

ui_column_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "ui_column_end: frame not open")
	layout_pop(&u.layout)
}

ui_column_begin :: proc(u: ^Ui, width: i32, sizes: []Layout_Size, style: Layout_Style = {}) {
	assert(u != nil && len(sizes) > 0, "ui_column_begin: invalid call")
	ui_column(u, ui_frame_sc(u.frame, width), ui_space_px(u, style.gap), style.align)
	ui_flex_begin(u, sizes)
}

ui_panel_begin :: proc(u: ^Ui, style: Layout_Style = {}) {
	assert(u != nil && u.open, "ui_panel_begin: frame not open")
	push_column(&u.layout, ui_space_px(u, style.gap), style.align)
	ui_padding(u, ui_insets(u, style.padding))
}

ui_panel_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "ui_panel_end: frame not open")
	layout_pop(&u.layout)
}

ui_weights :: proc(u: ^Ui, weights: []i32) {
	assert(u != nil && u.open, "ui_weights: frame not open")
	row_weights(&u.layout, weights)
}

ui_weighted_slot :: proc(u: ^Ui, weight: i32) -> Rect_I32 {
	assert(u != nil && u.open, "ui_weighted_slot: frame not open")
	return next_weighted(&u.layout, weight)
}

ui_space :: proc(u: ^Ui, px: i32) {
	assert(u.open, "ui_space: frame not open")
	spacer(&u.layout, px)
}

ui_spacer :: proc(u: ^Ui, value: Space) {
	ui_space(u, ui_space_px(u, value))
}

ui_separator :: proc(u: ^Ui) {
	assert(u != nil && u.open && u.frame != nil, "ui_separator: invalid UI")
	rect := ui_slot(u, remaining(&u.layout).w, 1)
	if ui_slot_visible(rect) {
		draw_rectangle_rec(
			u.frame,
			{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)},
			ui_frame_theme(u.frame).border_subtle,
		)
	}
}

// label draws a plain text line, carving its own slot and semantic node.
label :: proc(u: ^Ui, text: string, font_size: i32 = 0, color: Color = {}) {
	assert(u.open && u.frame != nil, "label: frame not open")
	metrics := ui_frame_metrics(u.frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_BODY
	col := color if color.a > 0 else ui_frame_theme(u.frame).fg_primary
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	r := ui_slot(u, measure_text_frame(u.frame, text_c, fs), metrics.LINE_HEIGHT)
	if !ui_slot_visible(r) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	begin_scissor_mode(u.frame, r.x, r.y, r.w, r.h)
	draw_text_frame(u.frame, text_c, r.x, r.y + (r.h - fs) / 2, fs, col)
	end_scissor_mode(u.frame)
	semantic_push(u.frame, .Label, r, text, {})
}
