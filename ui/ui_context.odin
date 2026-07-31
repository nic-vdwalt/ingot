// LIB-CANDIDATE: imports only core:*.
// Ui is a caller-owned context bundling layout, generated identity, and stable
// keyboard focus whose traversal order is rebuilt in bounded frame arrays.
package ui


// MAX_FOCUSABLES bounds focus registrations per frame (Tiger Style: put a
// limit on everything).
MAX_FOCUSABLES :: 256

// Track and its fit / grow / fixed / percent constructors live in layout.odin.

// Ui is caller-owned. Stable arrays retain only bounded traversal identity;
// widgets and their values remain entirely caller-owned.
Ui_Runtime :: struct {
	text:                  Text_System,
	text_backend:          Text_Backend,
	web_form:              Web_Form_Backend,
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
	runtime:                        ^Ui_Runtime,
	input_default:                  Ui_Input,
	input:                          ^Ui_Input,
	output:                         ^Ui_Output,
	scratch:                        Frame_Scratch,
	cursor:                         Cursor_State,
	overlay:                        Overlay_State,
	route:                          Input_Route_State,
	interaction:                    Interaction_State,
	semantics:                      Semantics_State,
	pane_origins:                   [MAX_PANE_SCOPES]Vector2,
	pane_count:                     int,
	font_memo_size:                 i32,
	font_memo_id:                   Font_Id,
	text_cull_top:                  i32,
	text_cull_bottom:               i32,
	open_roots:                     int,
	// Widgets handed a degenerate rect (zero or negative in either dimension)
	// or an empty caller collection draw nothing and return their zero result
	// rather than trapping: layout arithmetic legitimately produces those
	// values when a window is narrowed or a panel collapses, and a trap there
	// takes the whole app down. Counting the drops keeps that from hiding real
	// layout bugs - tests assert the counter is zero on golden-path frames.
	degenerate_drops:               int,
	text_input_full_path_count:     u64,
	text_input_inactive_candidates: u64,
	finalized:                      bool,
	open:                           bool,
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
	assert(frame != nil, "ui_frame_text: nil frame")
	runtime := ui_frame_runtime(frame)
	assert(runtime.text.font_loaded, "ui_frame_text: text system not initialized")
	return &runtime.text
}

ui_frame_spell :: proc(frame: ^Ui_Frame) -> ^Spell_System {
	assert(frame != nil, "ui_frame_spell: nil frame")
	runtime := ui_frame_runtime(frame)
	assert(runtime.initialized, "ui_frame_spell: invalid runtime")
	return &runtime.spell
}

ui_frame_theme :: proc(frame: ^Ui_Frame) -> ^Theme {
	assert(frame != nil, "ui_frame_theme: nil frame")
	runtime := ui_frame_runtime(frame)
	assert(runtime.style.fg_primary.a > 0, "ui_frame_theme: invalid theme")
	return &runtime.style
}

ui_frame_metrics :: proc(frame: ^Ui_Frame) -> ^Ui_Metrics {
	assert(frame != nil, "ui_frame_metrics: nil frame")
	runtime := ui_frame_runtime(frame)
	assert(runtime.scale > 0, "ui_frame_metrics: invalid scale")
	return &runtime.metrics
}

// ui_frame_style returns scaled metrics and the active theme together. Drawing
// code almost always needs both, and resolving them once per view procedure
// avoids re-deriving them at every call site.
ui_frame_style :: proc(frame: ^Ui_Frame) -> (^Ui_Metrics, ^Theme) {
	assert(frame != nil, "ui_frame_style: nil frame")
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
	assert(frame != nil, "ui_frame_scf: nil frame")
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
	frame.font_memo_size = 0
	frame.font_memo_id = 0
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
	parent := frame_pane_origin(frame)
	frame.pane_origins[frame.pane_count] = parent + origin
	frame.pane_count += 1
	assert(frame.pane_count > 0 && frame.pane_count <= MAX_PANE_SCOPES)
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
	frame:       ^Ui_Frame,
	layout:      Layout,
	focus_state: Focus_State,
	focus_prev:  [MAX_FOCUSABLES]Focus_Id,
	focus_cur:   [MAX_FOCUSABLES]Focus_Id,
	focus_count: int,
	focus_seq:   int,
	ids:         Id_Context,
	screen_w:    i32,
	screen_h:    i32,
	open:        bool,
}

// begin opens the root over a logical rectangle: caches screen size, runs Tab
// cycling against last frame's focusable count, and opens the root column.
begin :: proc(u: ^Ui, frame: ^Ui_Frame, rect: Rect_I32, gap: Space = .None) {
	assert(u != nil, "begin: nil Ui")
	assert(frame != nil && frame.open, "begin: frame not open")
	assert(rect.w >= 0 && rect.h >= 0, "begin: negative root rectangle")
	u.frame = frame
	frame.open_roots += 1
	_open(u, rect.x, rect.y, rect.w, rect.h, space_px(u, gap))
}

// ROOT_EXTENT_OPEN is the root height for a Ui laid out inside a scrolling
// pane, where the pane - not the root rectangle - owns the vertical bound.
// It replaces per-call-site "big enough" magic heights while keeping every
// derived coordinate far from i32 overflow; end reports the extent the
// content actually consumed, which is what pane_end needs.
ROOT_EXTENT_OPEN :: i32(1 << 20)

// _open is the physical-pixel root. Only begin may call it, so the facade has
// exactly one entry and the open_roots balance can never be bypassed.
@(private = "file")
_open :: proc(u: ^Ui, x, y, w, h: i32, gap: i32) {
	assert(u != nil, "begin: nil Ui")
	assert(!u.open, "begin: frame already open")
	frame := u.frame
	input: Ui_Input
	if frame != nil && frame.input != nil do input = frame.input^
	u.screen_w = i32(input.screen_size.x)
	u.screen_h = i32(input.screen_size.y)
	if u.focus_count > 0 && input_key_pressed(&input, .TAB) {
		backwards := input_key_down(&input, .LEFT_SHIFT) || input_key_down(&input, .RIGHT_SHIFT)
		ids := u.focus_prev[:u.focus_count]
		u.focus_state.active = focus_order_next(ids, u.focus_state.active, backwards)
	}
	u.focus_seq = 0
	id_context_reset(&u.ids)
	layout_begin(&u.layout, x, y, w, h, gap)
	u.open = true
}

// end closes the root, rebuilds the focus order, and releases the frame root.
// It returns the physical y where the consumed content ends (including any
// trailing space token), so sections chain without re-deriving the cursor:
//
//	ui.space(u, .LG)
//	return ui.end(u)
end :: proc(u: ^Ui) -> i32 {
	assert(u != nil && u.open, "end: frame not open")
	assert(u.ids.depth == 0, "end: unbalanced id scope")
	assert(u.layout.depth == 1, "end: unbalanced layout container")
	content_end := remaining(&u.layout).y
	layout_end(&u.layout)
	if u.focus_state.active != FOCUS_ID_NONE &&
	   focus_order_index(u.focus_cur[:u.focus_seq], u.focus_state.active) < 0 {
		focus_clear(&u.focus_state)
	}
	copy(u.focus_prev[:u.focus_seq], u.focus_cur[:u.focus_seq])
	u.focus_count = u.focus_seq
	u.open = false
	if u.frame != nil {
		assert(u.frame.open_roots > 0, "end: corrupt root count")
		u.frame.open_roots -= 1
		u.frame = nil
	}
	return content_end
}

// focus registers one stable control in this frame's traversal order.
focus :: proc(u: ^Ui, widget: Widget_Id) -> Focus_Opt {
	assert(u != nil, "focus: nil u")
	assert(u.open, "focus: frame not open")
	assert(widget != WIDGET_ID_NONE, "focus: zero stable id")
	assert(u.focus_seq < MAX_FOCUSABLES, "focus: too many focusables")
	widget_focus := focus_widget_id(widget)
	for registered in u.focus_cur[:u.focus_seq] {
		assert(registered != widget_focus, "focus: duplicate stable id")
	}
	u.focus_cur[u.focus_seq] = widget_focus
	u.focus_seq += 1
	return focus_link(&u.focus_state, widget_focus)
}

@(private = "package")
id_u64 :: proc(u: ^Ui, value: u64) -> Widget_Id {
	assert(u != nil && u.open, "id: frame not open")
	return id_context_id(&u.ids, value)
}

@(private = "package")
id_string :: proc(u: ^Ui, value: string) -> Widget_Id {
	assert(u != nil && u.open, "id: frame not open")
	return id_context_id(&u.ids, value)
}

// id derives a Widget_Id from the active scope stack plus a caller key.
id :: proc {
	id_u64,
	id_string,
}

@(private = "package")
scope_begin_u64 :: proc(u: ^Ui, value: u64, loc := #caller_location) {
	assert(u != nil && u.open, "scope_begin: frame not open")
	id_context_push(&u.ids, value, loc)
}

@(private = "package")
scope_begin_string :: proc(u: ^Ui, value: string, loc := #caller_location) {
	assert(u != nil && u.open, "scope_begin: frame not open")
	id_context_push(&u.ids, value, loc)
}

// scope_begin pushes a component or domain scope onto the identity stack.
scope_begin :: proc {
	scope_begin_u64,
	scope_begin_string,
}

scope_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "scope_end: frame not open")
	id_context_pop(&u.ids)
}

Scope_Proc :: #type proc(u: ^Ui, userdata: rawptr)

@(private = "package")
scope_string :: proc(u: ^Ui, key: string, body: Scope_Proc, userdata: rawptr = nil) {
	assert(u != nil && u.open, "scope: frame not open")
	assert(body != nil, "scope: nil body")
	scope_begin(u, key)
	defer scope_end(u)
	body(u, userdata)
}

@(private = "package")
scope_u64 :: proc(u: ^Ui, key: u64, body: Scope_Proc, userdata: rawptr = nil) {
	assert(u != nil && u.open, "scope: frame not open")
	assert(body != nil, "scope: nil body")
	scope_begin(u, key)
	defer scope_end(u)
	body(u, userdata)
}

scope :: proc {
	scope_string,
	scope_u64,
}

// focus_reset drops retained focus between frames. The root must be closed so
// this can never race the traversal order being rebuilt in end.
focus_reset :: proc(u: ^Ui) {
	assert(u != nil, "focus_reset: nil Ui")
	assert(!u.open, "focus_reset: frame open")
	focus_clear(&u.focus_state)
}

// slot_px carves a w×h device-pixel rect from the active layout frame. In a
// column the main axis is h; in a row it is w. Cross-axis placement honors
// alignment. Widgets use this after resolving their own scaled metrics.
@(private = "package")
slot_px :: proc(u: ^Ui, w, h: i32) -> Rect_I32 {
	assert(u != nil && u.open, "slot_px: frame not open")
	assert(w >= 0 && h >= 0, "slot_px: negative size")
	l := &u.layout
	if layout_cross_align(l) != .Stretch {
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

slot_visible :: proc(rect: Rect_I32) -> bool {
	return rect.w > 0 && rect.h > 0
}

@(private = "package")
slot_next_px :: proc(u: ^Ui, intrinsic_w, intrinsic_h: i32) -> Rect_I32 {
	assert(u != nil && u.open, "slot_next_px: frame not open")
	assert(intrinsic_w >= 0 && intrinsic_h >= 0, "slot_next_px: negative size")
	if layout_flex_active(&u.layout) {
		cross_size := intrinsic_w if layout_kind(&u.layout) == .Column else intrinsic_h
		return flex_next_sized(&u.layout, cross_size)
	}
	return slot_px(u, intrinsic_w, intrinsic_h)
}

slot_next :: proc(u: ^Ui, width, height: i32) -> Rect_I32 {
	assert(u != nil && u.open, "slot_next: frame not open")
	assert(!layout_flex_active(&u.layout), "slot_next: flex tracks active")
	assert(width >= 0 && height >= 0, "slot_next: negative size")
	return slot_px(u, ui_frame_sc(u.frame, width), ui_frame_sc(u.frame, height))
}

flex_slot_next :: proc(u: ^Ui, cross_size: i32) -> Rect_I32 {
	assert(u != nil && u.open, "flex_slot_next: frame not open")
	assert(layout_flex_active(&u.layout), "flex_slot_next: no active tracks")
	assert(cross_size >= 0, "flex_slot_next: negative cross size")
	return flex_next_sized(&u.layout, ui_frame_sc(u.frame, cross_size))
}

// flex_begin_px resolves sibling main-axis sizes already in device pixels.
@(private = "package")
flex_begin_px :: proc(u: ^Ui, sizes: []Track, justify: Main_Align = .Start) {
	assert(u != nil, "flex_begin_px: nil Ui")
	assert(u.open, "flex_begin_px: frame not open")
	flex_begin(&u.layout, sizes, justify)
}

// flex_slot_px consumes one flex size and honors active cross-axis alignment.
@(private = "package")
flex_slot_px :: proc(u: ^Ui, cross_size: i32) -> Rect_I32 {
	assert(u != nil, "flex_slot_px: nil Ui")
	assert(u.open && cross_size >= 0, "flex_slot_px: invalid call")
	return flex_next_sized(&u.layout, cross_size)
}

// track_px scales one logical Track into device pixels. This is the single
// boundary where facade units become Layout units.
@(private = "file")
track_px :: proc(u: ^Ui, track: Track) -> Track {
	assert(u != nil && u.frame != nil, "track_px: invalid Ui")
	basis := ui_frame_sc(u.frame, track.basis)
	minimum := ui_frame_sc(u.frame, track.min_size)
	maximum := ui_frame_sc(u.frame, track.max_size) if track.max_size > 0 else 0
	switch track.kind {
	case .Fit:
		return fit(basis, minimum, maximum)
	case .Grow:
		return grow(track.weight, minimum, maximum)
	case .Fixed:
		return fixed(basis)
	case .Percent:
		return percent(track.percent, minimum, maximum)
	}
	unreachable()
}

// Package-visible: the facade row widgets (facade_rows.odin) open flex runs
// inside a row strip they carve themselves.
@(private = "package")
flex_begin_tracks :: proc(u: ^Ui, tracks: []Track, justify: Main_Align = .Start) {
	assert(u != nil && u.open, "flex_begin_tracks: frame not open")
	assert(len(tracks) > 0, "flex_begin_tracks: empty tracks")
	assert(len(tracks) <= MAX_LAYOUT_FLEX, "flex_begin_tracks: too many tracks")
	sizes: [MAX_LAYOUT_FLEX]Track
	for track, index in tracks {
		sizes[index] = track_px(u, track)
	}
	flex_begin(&u.layout, sizes[:len(tracks)], justify)
}

// Package-visible: facade_rows.odin carves row strips with the same
// container semantics row_begin uses.
@(private = "package")
container_rect_px :: proc(u: ^Ui, width, height: i32) -> Rect_I32 {
	assert(u != nil && u.open, "container_rect_px: frame not open")
	assert(width >= 0 && height >= 0, "container_rect_px: negative size")
	if layout_flex_active(&u.layout) {
		cross_size := width if layout_kind(&u.layout) == .Column else height
		return flex_next_sized(&u.layout, cross_size)
	}
	return slot_px(u, width, height)
}

// padding insets the active container by one spacing token on every side.
padding :: proc(u: ^Ui, value: Space) {
	assert(u != nil && u.open, "padding: frame not open")
	layout_inset(&u.layout, insets_of(u, value))
}

// padding_insets takes logical per-side insets and scales them once.
padding_insets :: proc(u: ^Ui, value: Insets_I32) {
	assert(u != nil && u.open, "padding_insets: frame not open")
	assert(u.frame != nil, "padding_insets: nil frame")
	scaled := Insets_I32 {
		ui_frame_sc(u.frame, value.left),
		ui_frame_sc(u.frame, value.top),
		ui_frame_sc(u.frame, value.right),
		ui_frame_sc(u.frame, value.bottom),
	}
	layout_inset(&u.layout, scaled)
}

// space_px resolves a spacing token to device pixels at the active scale.
space_px :: proc(u: ^Ui, value: Space) -> i32 {
	assert(u != nil && u.frame != nil, "space_px: frame required")
	return space_pixels(u.frame, value)
}

// space_pixels is the frame-level spacing resolver.
//
// The explicit tier owns its own geometry and has no Ui to ask, but it still
// has to agree with the facade about what "MD" means. Without this, a caller
// laying out an application-owned region has no choice but to re-declare the
// scale locally - and a second copy of a shared scale drifts the moment either
// side is tuned. space_px delegates here so there is exactly one table.
space_pixels :: proc(frame: ^Ui_Frame, value: Space) -> i32 {
	assert(frame != nil, "space_pixels: nil frame")
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
	return ui_frame_sc(frame, logical)
}

// insets_of resolves a spacing token to equal insets on every side.
insets_of :: proc(u: ^Ui, value: Space) -> Insets_I32 {
	assert(u != nil && u.frame != nil, "insets_of: frame required")
	return insets(space_px(u, value))
}

// space advances the cursor by one spacing token without carving a slot.
space :: proc(u: ^Ui, value: Space) {
	assert(u != nil && u.open, "space: frame not open")
	spacer(&u.layout, space_px(u, value))
}

// compact reports whether the active container is narrower than a logical
// breakpoint, so callers can switch layout without querying the window.
compact :: proc(u: ^Ui, breakpoint: i32 = 640) -> bool {
	assert(u != nil && u.open, "compact: frame not open")
	assert(breakpoint > 0, "compact: non-positive breakpoint")
	return remaining(&u.layout).w < ui_frame_sc(u.frame, breakpoint)
}

// remaining_rect reports the unconsumed area without advancing the cursor.
remaining_rect :: proc(u: ^Ui) -> Rect_I32 {
	assert(u != nil && u.open, "remaining_rect: frame not open")
	return remaining(&u.layout)
}

// fill consumes and returns everything left in the active container.
fill :: proc(u: ^Ui) -> Rect_I32 {
	assert(u != nil && u.open, "fill: frame not open")
	return take_remaining(&u.layout)
}

// Containers default to .Stretch: a child that declares no cross size should
// span its parent, which is what every ordinary row and column wants.
row_begin :: proc(u: ^Ui, height: i32, gap: Space = .None, align: Cross_Align = .Stretch) {
	assert(u != nil && u.open, "row_begin: frame not open")
	assert(height >= 0, "row_begin: negative height")
	height_px := ui_frame_sc(u.frame, height)
	parent := remaining(&u.layout)
	rect := container_rect_px(u, parent.w, height_px)
	layout_push_rect(&u.layout, .Row, rect, space_px(u, gap), align)
}

row_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "row_end: frame not open")
	assert(layout_kind(&u.layout) == .Row, "row_end: active container is not a row")
	layout_pop(&u.layout)
}

flex_row_begin :: proc(
	u: ^Ui,
	height: i32,
	tracks: []Track,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
	justify: Main_Align = .Start,
) {
	row_begin(u, height, gap, align)
	flex_begin_tracks(u, tracks, justify)
}

flex_row_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "flex_row_end: frame not open")
	row_end(u)
}

column_begin :: proc(u: ^Ui, width: i32, gap: Space = .None, align: Cross_Align = .Stretch) {
	assert(u != nil && u.open, "column_begin: frame not open")
	assert(width >= 0, "column_begin: negative width")
	width_px := ui_frame_sc(u.frame, width)
	parent := remaining(&u.layout)
	rect := container_rect_px(u, width_px, parent.h)
	layout_push_rect(&u.layout, .Column, rect, space_px(u, gap), align)
}

column_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "column_end: frame not open")
	assert(layout_kind(&u.layout) == .Column, "column_end: active container is not a column")
	layout_pop(&u.layout)
}

flex_column_begin :: proc(
	u: ^Ui,
	width: i32,
	tracks: []Track,
	gap: Space = .None,
	align: Cross_Align = .Stretch,
	justify: Main_Align = .Start,
) {
	column_begin(u, width, gap, align)
	flex_begin_tracks(u, tracks, justify)
}

flex_column_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "flex_column_end: frame not open")
	column_end(u)
}

// panel_begin opens a padded column that fills the parent's width. It is the
// one container whose inset is part of the container itself.
panel_begin :: proc(u: ^Ui, style: Layout_Style = {}) {
	assert(u != nil && u.open, "panel_begin: frame not open")
	push_column(&u.layout, space_px(u, style.gap), style.align)
	layout_inset(&u.layout, insets_of(u, style.padding))
}

panel_end :: proc(u: ^Ui) {
	assert(u != nil && u.open, "panel_end: frame not open")
	assert(layout_kind(&u.layout) == .Column, "panel_end: active container is not a column")
	layout_pop(&u.layout)
}

// Weighted division is a strict subset of grow() tracks, so flex_row_begin /
// flex_column_begin is the single declared-sibling path on the facade.

// separator draws a one-pixel rule spanning the active container.
separator :: proc(u: ^Ui) {
	assert(u != nil && u.open && u.frame != nil, "separator: invalid UI")
	rect := slot_px(u, remaining(&u.layout).w, 1)
	if slot_visible(rect) {
		draw_rectangle_rec(u.frame, rect_f32(rect), ui_frame_theme(u.frame).border_subtle)
	}
}

// label draws a plain text line, carving its own slot and semantic node.
// label_sized takes an explicit physical size and raw color for callers that
// need values the semantic enums do not name.
label_sized :: proc(u: ^Ui, text: string, font_size: i32 = 0, color: Color = {}) {
	assert(u.open && u.frame != nil, "label: frame not open")
	metrics := ui_frame_metrics(u.frame)
	fs := font_size if font_size > 0 else metrics.FONT_SIZE_BODY
	col := color if color.a > 0 else ui_frame_theme(u.frame).fg_primary
	_label_px(u, text, fs, col)
}

// label_role resolves a typographic role and semantic ink against the active
// metrics and theme, so call sites stop re-deriving FONT_SIZE_* + fg_* pairs.
label_role :: proc(u: ^Ui, text: string, role: Text_Role, ink: Ink = .Primary) {
	assert(u != nil && u.open, "label: frame not open")
	assert(u.frame != nil, "label: nil frame")
	_label_px(u, text, text_role_size(u.frame, role), text_ink(u.frame, ink))
}

label :: proc {
	label_sized,
	label_role,
}

@(private = "file")
_label_px :: proc(u: ^Ui, text: string, font_size: i32, color: Color) {
	assert(u != nil && u.open, "_label_px: frame not open")
	assert(font_size > 0 && color.a > 0, "_label_px: unresolved style")
	metrics := ui_frame_metrics(u.frame)
	r := slot_next_px(u, measure_text_string_frame(u.frame, text, font_size), metrics.LINE_HEIGHT)
	if !slot_visible(r) {
		_ = ui_frame_drop_degenerate(u.frame, true)
		return
	}
	begin_scissor_mode(u.frame, r.x, r.y, r.w, r.h)
	draw_text_string_frame(u.frame, text, r.x, r.y + (r.h - font_size) / 2, font_size, color)
	end_scissor_mode(u.frame)
	semantic_push(u.frame, .Label, r, text, {})
}
