// LIB-CANDIDATE: imports only core:*.
// Generic popup widgets: modal panel, context menu, tooltip. All immediate
// mode with caller-owned state. Popups register their rects with the input
// router (input_route.odin) so widgets underneath neither hover nor click
// while one is open. The spell-suggestion menu (spell_menu.odin) and the
// UI-scale settings panel (settings_scale.odin) are consumers.
package ui

import "core:strings"


// --- Modal -------------------------------------------------------------------

// Modal_State is the caller-owned lifecycle of one modal. Set `open` to show
// it; `dismissed` is true only on the frame Escape or a click outside closed
// it (open is cleared at the same time).
Modal_State :: struct {
	open:              bool,
	dismissed:         bool,
	close_reason:      Modal_Close_Reason,
	id:                Modal_Id,
	z:                 Z_Order,
	opened_generation: u64,
	seen_generation:   u64,
	dismiss:           Modal_Dismiss_Policy,
	focus_scope:       Focus_Scope_Id,
	initial_focus:     Focus_Opt,
	restore_focus:     Focus_Opt,
	rect:              Rect_I32,
	frame:             ^Ui_Frame,
	drawing:           bool,
}

// route_claim_backdrop claims pointer input for the region *around* a panel so
// widgets underneath neither hover nor click while it is open.
//
// DEPRECATED: retained for one release. Claims now carry a z-order, so a modal
// claims the whole screen at Z_MODAL and opens a matching z scope around its
// own widgets; equal z does not occlude, which is what the four bands were
// working around. New callers should use route_claim with a z and z_scope_begin.
route_claim_backdrop :: proc(frame: ^Ui_Frame, panel: Rect_I32, screen_w, screen_h: i32) {
	assert(frame != nil, "route_claim_backdrop: nil frame")
	assert(screen_w >= 0 && screen_h >= 0, "route_claim_backdrop: negative screen size")
	route_claim(frame, Rectangle{0, 0, f32(screen_w), f32(panel.y)})
	route_claim(
		frame,
		Rectangle{0, f32(panel.y + panel.h), f32(screen_w), f32(screen_h - panel.y - panel.h)},
	)
	route_claim(frame, Rectangle{0, f32(panel.y), f32(panel.x), f32(panel.h)})
	route_claim(
		frame,
		Rectangle {
			f32(panel.x + panel.w),
			f32(panel.y),
			f32(screen_w - panel.x - panel.w),
			f32(panel.h),
		},
	)
}

Modal_Config :: struct {
	size:          [2]i32,
	screen:        Rect_I32,
	dismiss:       Modal_Dismiss_Policy,
	focus_scope:   Focus_Scope_Id,
	initial_focus: Focus_Opt,
	restore_focus: Focus_Opt,
	host_scoped:   bool,
}

modal_open :: proc(
	frame: ^Ui_Frame,
	state: ^Modal_State,
	id: Modal_Id,
	config: Modal_Config,
) -> bool {
	assert(frame != nil && frame.open, "modal_open: invalid frame")
	assert(state != nil && id != Modal_Id(0), "modal_open: invalid state")
	z := Z_MODAL + Z_Order(frame.runtime.modals.count)
	claim := Rectangle{f32(config.screen.x), f32(config.screen.y), f32(config.screen.w), f32(config.screen.h)}
	if !modal_runtime_register(frame, id, z, claim, !config.host_scoped) do return false
	if !state.open {
		state.opened_generation = frame.runtime.frame_generation
		state.close_reason = .None
	}
	state.open = true
	state.dismissed = false
	state.id = id
	state.z = z
	state.seen_generation = frame.runtime.frame_generation
	state.dismiss = config.dismiss
	state.focus_scope = config.focus_scope
	if state.focus_scope == FOCUS_SCOPE_NONE do state.focus_scope = focus_scope_id(u64(id))
	state.initial_focus = config.initial_focus
	state.restore_focus = config.restore_focus
	return true
}

modal_close :: proc(state: ^Modal_State, reason: Modal_Close_Reason = .Programmatic) {
	assert(state != nil, "modal_close: nil state")
	if !state.open do return
	state.open = false
	state.dismissed = reason == .Escape || reason == .Outside_Click
	state.close_reason = reason
	if state.frame != nil && state.frame.runtime != nil {
		modal_runtime_remove(&state.frame.runtime.modals, state.id)
	}
}

modal_take_close :: proc(state: ^Modal_State) -> Modal_Close_Reason {
	assert(state != nil, "modal_take_close: nil state")
	reason := state.close_reason
	state.close_reason = .None
	return reason
}

modal_is_open :: proc(state: ^Modal_State) -> bool {
	assert(state != nil, "modal_is_open: nil state")
	return state.open
}

// modal_begin dims the screen, claims backdrop input (nothing under the dim
// layer hovers or clicks), draws a centered titled panel clamped to the screen,
// begins a scissor over it, and returns the body rect below the title band.
modal_begin :: proc(
	frame: ^Ui_Frame,
	st: ^Modal_State,
	title: string,
	config: Modal_Config,
) -> Rect_I32 {
	assert(st != nil && st.open, "modal_begin: modal not open")
	assert(!st.drawing, "modal_begin: unbalanced begin (missing modal_end)")
	if st.id == Modal_Id(0) {
		_ = modal_open(frame, st, Modal_Id(uintptr(st)), config)
	} else {
		claim := Rectangle {
			f32(config.screen.x),
			f32(config.screen.y),
			f32(config.screen.w),
			f32(config.screen.h),
		}
		_ = modal_runtime_register(frame, st.id, st.z, claim, !config.host_scoped)
		index := modal_runtime_find(&frame.runtime.modals, st.id)
		assert(index >= 0, "modal_begin: state not registered")
		st.z = frame.runtime.modals.entries[index].z
	}
	w, h := config.size.x, config.size.y
	screen_w, screen_h := config.screen.w, config.screen.h
	assert(w > 0 && h > 0, "modal_begin: empty modal size")
	st.drawing = true
	st.frame = frame
	st.dismissed = false
	modal_owner_begin(frame, st)
	focus_scope_begin(frame, st.focus_scope, 1000 + i32(st.z - Z_MODAL))
	style := ui_frame_theme(frame)
	metrics := ui_frame_metrics(frame)

	mw := min(w, screen_w - metrics.PADDING * 4)
	mh := min(h, screen_h - metrics.PADDING * 2)
	mx := config.screen.x + (screen_w - mw) / 2
	my := config.screen.y + (screen_h - mh) / 2
	st.rect = Rect_I32{mx, my, mw, mh}
	claim := Rectangle {
		f32(config.screen.x),
		f32(config.screen.y),
		f32(screen_w),
		f32(screen_h),
	}
	layer_begin(frame, st.z, claim = claim)

	// Dimmed inside the modal's z scope so it paints at the modal tier and
	// covers every lower tier, including content submitted after modal_end.
	draw_rectangle(frame, config.screen.x, config.screen.y, screen_w, screen_h, style.modal_dim)
	draw_rectangle(frame, mx, my, mw, mh, style.bg_secondary)
	draw_rectangle_lines(frame, mx, my, mw, mh, style.border_color)
	begin_scissor_mode(frame, mx, my, mw, mh)
	semantic_push(frame, .Modal, st.rect, title)

	title_h := ui_frame_sc(frame, 40)
	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text_frame(
		frame,
		title_c,
		mx + metrics.PADDING,
		my + metrics.PADDING,
		metrics.FONT_SIZE_TITLE,
		style.fg_primary,
	)
	return Rect_I32{mx, my + title_h, mw, mh - title_h}
}

// modal_end closes the scissor and applies dismissal: Escape or a click
// pressed outside the panel clears `open` and sets `dismissed` for this
// frame. Press (not release) is used so the release of the click that
// opened the modal cannot dismiss it on the same frame.
modal_end :: proc(st: ^Modal_State) {
	assert(st != nil, "modal_end: nil state")
	assert(st.drawing, "modal_end: modal_begin not called")
	st.drawing = false
	frame := st.frame
	assert(frame != nil, "modal_end: missing frame")
	end_scissor_mode(frame)
	focus_scope_end(frame, st.focus_scope)
	layer_end(frame)
	if modal_is_top(frame, st) && .Escape in st.dismiss && is_key_pressed(frame, .ESCAPE) {
		key_pressed_consume(frame, .ESCAPE)
		modal_close(st, .Escape)
	}
	mrect := Rectangle{f32(st.rect.x), f32(st.rect.y), f32(st.rect.w), f32(st.rect.h)}
	if st.open &&
	   modal_is_top(frame, st) &&
	   frame.runtime.frame_generation > st.opened_generation &&
	   .Outside_Click in st.dismiss &&
	   is_mouse_button_pressed(frame, .LEFT) &&
	   !point_in_rect(get_mouse_position(frame), mrect) {
		modal_close(st, .Outside_Click)
	}
	modal_owner_end(frame, st)
	st.frame = nil
}

// --- Custom popup ------------------------------------------------------------

Popup_Id :: distinct u64

Popup_Close_Reason :: enum u8 {
	None,
	Accepted,
	Escape,
	Outside_Click,
	Programmatic,
}

Popup_Placement :: enum u8 {
	Auto,
	Above,
	Below,
	Point,
}

Popup_Config :: struct {
	anchor:          Rect_I32,
	viewport:        Rect_I32,
	preferred_size: [2]i32,
	placement:       Popup_Placement,
	dismiss_escape: bool,
	dismiss_outside: bool,
	focus_scope:     Focus_Scope_Id,
	initial_focus:   Focus_Opt,
	restore_focus:   Focus_Opt,
}

Popup_State :: struct {
	open:              bool,
	close_reason:      Popup_Close_Reason,
	id:                Popup_Id,
	opened_generation: u64,
	rect:              Rect_I32,
	config:            Popup_Config,
	frame:             ^Ui_Frame,
	drawing:           bool,
}

popup_open :: proc(frame: ^Ui_Frame, state: ^Popup_State, id: Popup_Id, config: Popup_Config) {
	assert(frame != nil && frame.open, "popup_open: invalid frame")
	assert(state != nil && id != Popup_Id(0), "popup_open: invalid state")
	assert(config.viewport.w > 0 && config.viewport.h > 0, "popup_open: empty viewport")
	assert(config.preferred_size.x > 0 && config.preferred_size.y > 0, "popup_open: empty size")
	state^ = {open = true, id = id, opened_generation = frame.runtime.frame_generation, config = config}
}

popup_is_open :: proc(state: ^Popup_State) -> bool {
	assert(state != nil, "popup_is_open: nil state")
	return state.open
}

popup_close :: proc(state: ^Popup_State, reason: Popup_Close_Reason = .Programmatic) {
	assert(state != nil, "popup_close: nil state")
	if !state.open do return
	state.open = false
	state.close_reason = reason
}

popup_take_close :: proc(state: ^Popup_State) -> Popup_Close_Reason {
	assert(state != nil, "popup_take_close: nil state")
	reason := state.close_reason
	state.close_reason = .None
	return reason
}

popup_placed_layout :: proc(config: Popup_Config) -> Popup_Layout {
	assert(config.viewport.w > 0 && config.viewport.h > 0, "popup layout: empty viewport")
	width, height := config.preferred_size.x, config.preferred_size.y
	anchor := Vector2{f32(config.anchor.x), f32(config.anchor.y)}
	placement := config.placement
	if placement == .Auto {
		below := config.viewport.y + config.viewport.h - (config.anchor.y + config.anchor.h)
		above := config.anchor.y - config.viewport.y
		placement = .Below if below >= height || below >= above else .Above
	}
	switch placement {
	case .Above:
		anchor.y = f32(config.anchor.y - height)
	case .Below:
		anchor.y = f32(config.anchor.y + config.anchor.h)
	case .Point:
	case .Auto:
		unreachable()
	}
	return popup_layout(anchor, width, height, config.viewport)
}

popup_begin :: proc(frame: ^Ui_Frame, state: ^Popup_State, config: Popup_Config) -> Rect_I32 {
	assert(frame != nil && frame.open, "popup_begin: invalid frame")
	assert(state != nil && state.open && !state.drawing, "popup_begin: invalid state")
	state.config = config
	layout := popup_placed_layout(config)
	state.rect = {
		i32(layout.rect.x),
		i32(layout.rect.y),
		i32(layout.rect.width),
		i32(layout.rect.height),
	}
	state.frame = frame
	state.drawing = true
	if config.focus_scope != FOCUS_SCOPE_NONE do focus_scope_begin(frame, config.focus_scope, 900)
	layer_begin(frame, Z_POPUP, claim = layout.rect)
	style := ui_frame_theme(frame)
	draw_rectangle_rec(frame, layout.rect, style.bg_popup)
	draw_rectangle_lines_ex(frame, layout.rect, ui_frame_scf(frame, 1), style.border_color)
	semantic_push(frame, .List, state.rect, "Popup")
	return state.rect
}

popup_end :: proc(state: ^Popup_State) {
	assert(state != nil && state.drawing, "popup_end: invalid state")
	frame := state.frame
	assert(frame != nil, "popup_end: missing frame")
	layer_end(frame)
	if state.config.focus_scope != FOCUS_SCOPE_NONE do focus_scope_end(frame, state.config.focus_scope)
	if state.open && state.config.dismiss_escape && is_key_pressed(frame, .ESCAPE) {
		key_pressed_consume(frame, .ESCAPE)
		popup_close(state, .Escape)
	}
	mouse := get_mouse_position(frame)
	rect := Rectangle{f32(state.rect.x), f32(state.rect.y), f32(state.rect.w), f32(state.rect.h)}
	if state.open &&
	   state.config.dismiss_outside &&
	   frame.runtime.frame_generation > state.opened_generation &&
	   (is_mouse_button_pressed(frame, .LEFT) || is_mouse_button_pressed(frame, .RIGHT)) &&
	   !point_in_rect(mouse, rect) {
		popup_close(state, .Outside_Click)
	}
	state.frame = nil
	state.drawing = false
}

// --- Context menu ------------------------------------------------------------

// Menu_Item is one context-menu row. Zero value is an enabled, selectable
// item; set `separator` for a divider row or `disabled` to gray it out.
Menu_Item :: struct {
	label:     string,
	disabled:  bool,
	separator: bool,
}

// Context_Menu_State is the caller-owned lifecycle of one popup menu.
Context_Menu_State :: struct {
	open:        bool,
	just_opened: bool, // swallow the opening click for one frame
	selected:    int,
	anchor_x:    i32, // pane-local anchor (menu's top-left, clamped on draw)
	anchor_y:    i32,
}

// context_menu_open opens the menu at a pane-local anchor point.
context_menu_open :: proc(st: ^Context_Menu_State, x, y: i32) {
	assert(st != nil, "context_menu_open: nil state")
	st^ = {}
	st.open = true
	st.just_opened = true
	st.anchor_x = x
	st.anchor_y = y
	assert(st.selected == 0, "context_menu_open: selection not reset")
}

// menu_nav_next returns the next selectable index from `current` moving by
// `delta` (+1/-1) with wraparound, skipping separators and disabled items.
// Pure; used by the menu and its tests. Returns current when nothing else is
// selectable (bounded by one full wrap).
menu_nav_next :: proc(items: []Menu_Item, current, delta: int) -> int {
	assert(len(items) > 0, "menu_nav_next: empty items")
	assert(delta == 1 || delta == -1, "menu_nav_next: delta must be +/-1")
	idx := current
	for _ in 0 ..< len(items) {
		idx = (idx + delta + len(items)) % len(items)
		if !items[idx].separator && !items[idx].disabled do return idx
	}
	return current
}

Popup_Layout :: struct {
	rect:        Rectangle,
	content_w:   i32,
	content_h:   i32,
	constrained: bool,
}

popup_layout :: proc(
	anchor: Vector2,
	preferred_w, preferred_h: i32,
	viewport: Rect_I32,
) -> Popup_Layout {
	assert(preferred_w >= 0 && preferred_h >= 0, "popup_layout: negative size")
	assert(viewport.w >= 0 && viewport.h >= 0, "popup_layout: negative viewport")
	width := min(preferred_w, viewport.w)
	height := min(preferred_h, viewport.h)
	x := clamp(i32(anchor.x), viewport.x, max(viewport.x + viewport.w - width, viewport.x))
	y := clamp(i32(anchor.y), viewport.y, max(viewport.y + viewport.h - height, viewport.y))
	return {
		rect = {f32(x), f32(y), f32(width), f32(height)},
		content_w = width,
		content_h = height,
		constrained = width < preferred_w || height < preferred_h,
	}
}

// context_menu_height returns the popup's pixel height for an item list, so
// callers can pre-position the anchor (e.g. open upward above an input box).
context_menu_height_frame :: proc(frame: ^Ui_Frame, items: []Menu_Item) -> i32 {
	assert(frame != nil, "context_menu_height_frame: nil frame")
	assert(len(items) > 0, "context_menu_height_frame: empty items")
	metrics := ui_frame_metrics(frame)
	h := metrics.MENU_PAD * 2
	for it in items {
		h += ui_frame_sc(frame, 5) if it.separator else metrics.MENU_ITEM_H
	}
	assert(h > 0, "context_menu_height_frame: non-positive height")
	return h
}

// context_menu_width returns the popup width for an item list (widest label
// plus padding, at least MENU_MIN_W, capped to the given width).
context_menu_width_frame :: proc(frame: ^Ui_Frame, items: []Menu_Item, max_w: i32) -> i32 {
	assert(frame != nil, "context_menu_width_frame: nil frame")
	assert(len(items) > 0, "context_menu_width_frame: empty items")
	assert(max_w > 0, "context_menu_width_frame: non-positive cap")
	metrics := ui_frame_metrics(frame)
	w := metrics.MENU_MIN_W
	for it in items {
		if it.separator do continue
		c := strings.clone_to_cstring(it.label, context.temp_allocator)
		lw := measure_text_frame(frame, c, metrics.FONT_SIZE_BODY) + ui_frame_sc(frame, 32)
		if lw > w do w = lw
	}
	return min(w, max_w)
}

// context_menu draws and drives the open popup. Returns the chosen item
// index, or -1 while no choice was made. Escape, click-away, and choosing
// all close the menu. Up/Down navigate (skipping separators/disabled), Enter
// applies; hover follows the mouse only while it moves so keyboard selection
// is not overridden by a stationary cursor. The menu claims its rect with
// the input router so widgets underneath stay inert.
context_menu :: proc(
	frame: ^Ui_Frame,
	st: ^Context_Menu_State,
	items: []Menu_Item,
	screen: Rect_I32,
) -> int {
	assert(frame != nil, "context_menu: nil frame")
	assert(st != nil, "context_menu: nil state")
	if !st.open do return -1
	assert(len(items) > 0, "context_menu: empty items")
	assert(screen.w > 0 && screen.h >= 0, "context_menu: invalid screen bounds")
	screen_right := i64(screen.x) + i64(screen.w)
	screen_bottom := i64(screen.y) + i64(screen.h)
	assert(screen_right <= i64(max(i32)), "context_menu: screen right overflow")
	assert(screen_bottom <= i64(max(i32)), "context_menu: screen bottom overflow")

	menu_w := context_menu_width_frame(frame, items, screen.w)
	menu_h := context_menu_height_frame(frame, items)
	anchor := frame_to_screen(frame, {f32(st.anchor_x), f32(st.anchor_y)})
	layout := popup_layout(anchor, menu_w, menu_h, screen)
	screen_rect := layout.rect
	menu_rect := frame_rect_to_local(frame, screen_rect)

	// Caller-owned state may outlive or be reused with a different item slice.
	if st.selected < 0 || st.selected >= len(items) do st.selected = 0
	if items[st.selected].separator || items[st.selected].disabled {
		st.selected = menu_nav_next(items, st.selected, 1)
	}
	if is_key_pressed(frame, .ESCAPE) {
		key_pressed_consume(frame, .ESCAPE)
		st.open = false
		return -1
	}
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) {
		st.selected = menu_nav_next(items, st.selected, -1)
	}
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) {
		st.selected = menu_nav_next(items, st.selected, 1)
	}
	if is_key_pressed(frame, .ENTER) {
		key_pressed_consume(frame, .ENTER)
		st.open = false
		return st.selected
	}

	mouse := get_mouse_position(frame)
	mouse = frame_to_local(frame, mouse)
	if !st.just_opened &&
	   (is_mouse_button_pressed(frame, .LEFT) || is_mouse_button_pressed(frame, .RIGHT)) &&
	   !point_in_rect(mouse, menu_rect) {
		st.open = false
		return -1
	}
	st.just_opened = false

	// Record all panel draws on a popup layer in screen space so the menu
	// replays above content painted later in the frame (and outside any pane
	// scissor); the claim rect keeps the covered widgets inert.
	style := ui_frame_theme(frame)
	mouse_screen := get_mouse_position(frame)
	layer_begin(frame, Z_POPUP, claim = screen_rect)
	draw_rectangle_rec(frame, screen_rect, style.bg_popup)
	draw_rectangle_lines_ex(frame, screen_rect, ui_frame_scf(frame, 1), style.border_color)
	chosen := context_menu_rows(frame, st, items, screen_rect, mouse_screen)
	layer_end(frame)
	return chosen
}

// context_menu_rows records the rows inside the menu layer. Layout, drawing,
// and hit-testing all happen in screen space: the layer zeroed the pane
// origin, and `mouse` arrives untranslated. Returns the clicked index or -1.
@(private = "file")
context_menu_rows :: proc(
	frame: ^Ui_Frame,
	st: ^Context_Menu_State,
	items: []Menu_Item,
	menu_screen: Rectangle,
	mouse: Vector2,
) -> int {
	assert(frame != nil, "context_menu_rows: nil frame")
	assert(st != nil, "context_menu_rows: nil st")
	assert(st.open, "context_menu_rows: menu not open")
	assert(len(items) > 0, "context_menu_rows: empty items")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	inset := ui_frame_sc(frame, 2)
	item_x := menu_screen.x + f32(inset)
	item_w := i32(menu_screen.width) - inset * 2
	item_y := menu_screen.y + f32(metrics.MENU_PAD)
	chosen := -1
	for it, i in items {
		if it.separator {
			sep_h := ui_frame_sc(frame, 5)
			separator := Rectangle {
				menu_screen.x + f32(ui_frame_sc(frame, 6)),
				item_y + f32(sep_h / 2),
				menu_screen.width - f32(ui_frame_sc(frame, 12)),
				ui_frame_scf(frame, 1),
			}
			draw_rectangle_rec(frame, separator, style.border_color)
			item_y += f32(sep_h)
			continue
		}
		row_screen := Rectangle{item_x, item_y, f32(item_w), f32(metrics.MENU_ITEM_H)}
		hovered := point_in_rect(mouse, row_screen)
		sem: Sem_State
		if it.disabled do sem += {.Disabled}
		semantic_push(
			frame,
			.Menu_Item,
			{i32(row_screen.x), i32(row_screen.y), item_w, metrics.MENU_ITEM_H},
			it.label,
			sem,
		)
		if hovered && !it.disabled && mouse_moved(frame) do st.selected = i
		if st.selected == i do draw_rectangle_rec(frame, row_screen, style.bg_active)
		if hovered && !it.disabled do request_cursor(frame, .POINTING_HAND)
		col := style.fg_disabled if it.disabled else style.fg_primary
		txt := truncate_to_width_frame(
			frame,
			it.label,
			item_w - ui_frame_sc(frame, 16),
			metrics.FONT_SIZE_BODY,
		)
		draw_text_string(
			frame,
			txt,
			i32(row_screen.x) + ui_frame_sc(frame, 8),
			i32(row_screen.y) + (metrics.MENU_ITEM_H - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			col,
		)
		if hovered && !it.disabled && is_mouse_button_released(frame, .LEFT) {
			st.open = false
			chosen = i
		}
		item_y += f32(metrics.MENU_ITEM_H)
	}
	return chosen
}

// --- Tooltip -----------------------------------------------------------------

// Tooltip_State tracks hover dwell for one shared tooltip (only one tooltip
// shows at a time, so a single state serves any number of hover targets).
Tooltip_State :: struct {
	key:         u64, // geometry key of the rect currently dwelled on
	hover_start: f64,
}

Tooltip_Options :: struct {
	max_width: i32,
}

// tooltip_at shows `text` near the mouse after the cursor has dwelled over
// `rect` for TOOLTIP_DELAY seconds. Call it after drawing the target; the tip
// itself is replayed through the overlay layer so it always paints on top.
// Keeps frames coming while the dwell timer runs (event-driven hosts).
tooltip_at :: proc(
	frame: ^Ui_Frame,
	st: ^Tooltip_State,
	rect: Rect_I32,
	text: string,
	screen_w, screen_h: i32,
) {
	tooltip_wrapped_at(frame, st, rect, text, screen_w, screen_h, {})
}

tooltip_wrapped_at :: proc(
	frame: ^Ui_Frame,
	st: ^Tooltip_State,
	rect: Rect_I32,
	text: string,
	screen_w, screen_h: i32,
	options: Tooltip_Options,
) {
	assert(st != nil, "tooltip: nil state")
	assert(rect.w > 0 && rect.h > 0, "tooltip: empty target rect")
	assert(screen_w > 0 && screen_h > 0, "tooltip: invalid viewport")
	mouse := get_mouse_position(frame)
	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	key :=
		(u64(u32(rect.x)) | u64(u32(rect.y)) << 32) ~
		((u64(u32(rect.w)) | u64(u32(rect.h)) << 32) * 0x100000001b3)
	if !point_in_rect(mouse, rrect) || route_occluded(frame, mouse) {
		if st.key == key do st^ = {}
		return
	}
	now := frame_input(frame).time
	if st.key != key {
		st.key = key
		st.hover_start = now
	}
	elapsed := now - st.hover_start
	if elapsed < TOOLTIP_DELAY {
		request_redraw_in(frame, TOOLTIP_DELAY - elapsed)
		return
	}
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	viewport_limit := max(screen_w - metrics.TOOLTIP_PAD * 4, metrics.FONT_SIZE_LABEL)
	requested_width := options.max_width if options.max_width > 0 else viewport_limit
	text_limit := min(requested_width, viewport_limit)
	lines := wrap_text_frame(frame, text, text_limit, metrics.FONT_SIZE_LABEL)
	tw := wrapped_max_line_width_frame(frame, text, text_limit, metrics.FONT_SIZE_LABEL)
	line_height := metrics.LINE_HEIGHT
	bw := tw + metrics.TOOLTIP_PAD * 2
	bh := i32(len(lines)) * line_height + metrics.TOOLTIP_PAD * 2
	anchor := Vector2{mouse.x + ui_frame_scf(frame, 12), mouse.y + ui_frame_scf(frame, 18)}
	layout := popup_layout(anchor, bw, bh, {0, 0, screen_w, screen_h})
	tip := layout.rect
	visible_lines := int(max((layout.content_h - metrics.TOOLTIP_PAD * 2) / line_height, 0))
	layer_begin(frame, Z_TOOLTIP, claim = tip)
	draw_rectangle_rec(frame, tip, style.bg_popup)
	draw_rectangle_lines_ex(frame, tip, ui_frame_scf(frame, 1), style.border_color)
	for line, index in lines {
		if index >= visible_lines do break
		draw_text_string(
			frame,
			text[line.start:line.end],
			i32(tip.x) + metrics.TOOLTIP_PAD,
			i32(tip.y) + metrics.TOOLTIP_PAD + i32(index) * line_height,
			metrics.FONT_SIZE_LABEL,
			style.fg_primary,
		)
	}
	layer_end(frame)
}
