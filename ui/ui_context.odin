// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Ui is a caller-owned context bundling layout and keyboard focus. Static
// forms may use sequential registration; conditional and dynamic forms pass
// stable caller IDs whose traversal order is rebuilt in bounded frame arrays.
package ui

import "core:strings"
import rl "ingot:gfx"

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
	spell:                 Spell_System,
	style:                 Theme,
	metrics:               Ui_Metrics,
	scale:                 f32,
	dpi_last:              f32,
	generation:            u64,
	pending_click:         u64,
	semantics_enabled:     bool,
	semantics_snapshot:    Sem_Frame,
	scale_metrics_hook:    proc(scale: f32),
	scale_invalidate_hook: proc(),
	initialized:           bool,
}

MAX_PANE_SCOPES :: 16

Ui_Frame :: struct {
	runtime:      ^Ui_Runtime,
	cursor:       Cursor_State,
	overlay:      Overlay_State,
	route:        Input_Route_State,
	interaction:  Interaction_State,
	semantics:    Semantics_State,
	pane_origins: [MAX_PANE_SCOPES]rl.Vector2,
	pane_count:   int,
	open_roots:   int,
	open:         bool,
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

ui_runtime_set_scale_hooks :: proc(
	runtime: ^Ui_Runtime,
	metrics_hook: proc(scale: f32),
	invalidate_hook: proc(),
) {
	assert(runtime != nil && runtime.initialized, "ui_runtime_set_scale_hooks: invalid runtime")
	runtime.scale_metrics_hook = metrics_hook
	runtime.scale_invalidate_hook = invalidate_hook
}

ui_frame_begin :: proc(frame: ^Ui_Frame, runtime: ^Ui_Runtime) {
	assert(frame != nil && runtime != nil, "ui_frame_begin: nil frame or runtime")
	assert(runtime.initialized && !frame.open, "ui_frame_begin: invalid lifetime")
	frame.runtime = runtime
	frame.cursor.requested = .DEFAULT
	frame.overlay.count = 0
	frame.overlay.text_len = 0
	frame.overlay.dropped = 0
	frame.overlay.open = false
	frame.pane_count = 0
	frame.open_roots = 0
	frame.open = true
	route_begin_frame(frame)
	interact_frame_begin(frame)
	sem_begin_frame(frame)
}

ui_frame_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "ui_frame_end: frame not open")
	assert(frame.open_roots == 0, "ui_frame_end: UI root still open")
	assert(frame.pane_count == 0, "ui_frame_end: pane scope still open")
	assert(!frame.overlay.open, "ui_frame_end: overlay still open")
	overlay_flush(frame)
	cursor_apply(frame)
	frame.runtime.semantics_snapshot = frame.semantics.cur
	frame.runtime = nil
	frame.open = false
}

ui_frame_pane_push :: proc(frame: ^Ui_Frame, origin: rl.Vector2) {
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

frame_pane_origin :: proc(frame: ^Ui_Frame) -> rl.Vector2 {
	assert(frame != nil && frame.open, "pane_origin: invalid frame")
	if frame.pane_count == 0 do return {}
	return frame.pane_origins[frame.pane_count - 1]
}

frame_to_local :: proc(frame: ^Ui_Frame, point: rl.Vector2) -> rl.Vector2 {
	origin := frame_pane_origin(frame)
	return {point.x - origin.x, point.y - origin.y}
}

frame_to_screen :: proc(frame: ^Ui_Frame, point: rl.Vector2) -> rl.Vector2 {
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
	u.screen_w = rl.GetScreenWidth()
	u.screen_h = rl.GetScreenHeight()
	if u.focus_count > 0 do form_focus_cycle(&u.focus_slot, u.focus_count)
	if u.stable_count > 0 && rl.IsKeyPressed(.TAB) {
		backwards := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
		ids := u.stable_prev[:u.stable_count]
		u.stable_focus.active = focus_order_next(ids, u.stable_focus.active, backwards)
	}
	u.focus_seq = 0
	u.stable_seq = 0
	u.focus_mode = .None
	layout_begin(&u.layout, x, y, w, h, gap)
	u.open = true
}

ui_end :: proc(u: ^Ui) {
	assert(u.open, "ui_end: frame not open")
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

ui_focus_id :: proc(u: ^Ui, id: Focus_Id) -> Focus_Opt {
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

ui_focus_clear :: proc(u: ^Ui) {
	assert(u != nil, "ui_focus_clear: nil Ui")
	assert(!u.open, "ui_focus_clear: frame open")
	u.focus_slot = 0
	focus_clear(&u.stable_focus)
}

// ui_slot carves a w×h rect from the active layout frame. In a column the
// main axis is h (cross trimmed to w); in a row it is w (cross trimmed to h).
ui_slot :: proc(u: ^Ui, w, h: i32) -> Rect_I32 {
	assert(u.open, "ui_slot: frame not open")
	assert(w >= 0 && h >= 0, "ui_slot: negative size")
	l := &u.layout
	if layout_kind(l) == .Column {
		r := next(l, h)
		r.w = min(r.w, w)
		return r
	}
	r := next(l, w)
	r.h = min(r.h, h)
	return r
}

// ui_flex_begin resolves sibling main-axis sizes on the active Ui frame.
ui_flex_begin :: proc(u: ^Ui, sizes: []Flex_Size) {
	assert(u != nil, "ui_flex_begin: nil Ui")
	assert(u.open, "ui_flex_begin: frame not open")
	flex_begin(&u.layout, sizes)
}

// ui_flex_slot consumes one flex size and trims only the cross axis.
ui_flex_slot :: proc(u: ^Ui, cross_size: i32) -> Rect_I32 {
	assert(u != nil, "ui_flex_slot: nil Ui")
	assert(u.open && cross_size >= 0, "ui_flex_slot: invalid call")
	r := flex_next(&u.layout)
	if layout_kind(&u.layout) == .Column {
		r.w = min(r.w, cross_size)
	} else {
		r.h = min(r.h, cross_size)
	}
	return r
}

// ui_row / ui_row_end / ui_space: thin conveniences over the Layout the Ui
// already owns; callers may equally use push_row(&u.layout, …) directly.
ui_row :: proc(u: ^Ui, h: i32, gap: i32 = 0) {
	assert(u.open, "ui_row: frame not open")
	push_row(&u.layout, h, gap)
}

ui_row_end :: proc(u: ^Ui) {
	assert(u.open, "ui_row_end: frame not open")
	layout_pop(&u.layout)
}

ui_space :: proc(u: ^Ui, px: i32) {
	assert(u.open, "ui_space: frame not open")
	spacer(&u.layout, px)
}

// label draws a plain text line, carving its own slot.
label :: proc(u: ^Ui, text: string, font_size: i32 = 0, color: rl.Color = {}) {
	assert(u.open, "label: frame not open")
	fs := font_size if font_size > 0 else FONT_SIZE_BODY
	col := color if color.a > 0 else theme.fg_primary
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	r := ui_slot(u, measure_text(text_c, fs), LINE_HEIGHT)
	draw_text(text_c, r.x, r.y + (r.h - fs) / 2, fs, col)
}
