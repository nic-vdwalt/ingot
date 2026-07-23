// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Generic popup widgets: modal panel, context menu, tooltip. All immediate
// mode with caller-owned state. Popups register their rects with the input
// router (input_route.odin) so widgets underneath neither hover nor click
// while one is open. The spell-suggestion menu (spell_menu.odin) and the
// UI-scale settings panel (settings_scale.odin) are consumers.
package ui

import "core:strings"
import rl "ingot:gfx"

// --- Modal -------------------------------------------------------------------

// Modal_State is the caller-owned lifecycle of one modal. Set `open` to show
// it; `dismissed` is true only on the frame Escape or a click outside closed
// it (open is cleared at the same time).
Modal_State :: struct {
	open:      bool,
	dismissed: bool,
	rect:      Rect_I32, // panel rect computed by modal_begin
	drawing:   bool,     // begin/end balance check
}

// modal_begin dims the screen, claims all input (nothing under the dim layer
// hovers or clicks), draws a centered titled panel clamped to the screen,
// begins a scissor over it, and returns the body rect below the title band.
// Pair with modal_end, which handles dismissal. Focus trap: while a modal is
// open the caller must route Tab cycling only across the widgets it draws
// inside the body.
modal_begin :: proc(st: ^Modal_State, title: string, w, h, screen_w, screen_h: i32) -> Rect_I32 {
	assert(st != nil && st.open, "modal_begin: modal not open")
	assert(!st.drawing, "modal_begin: unbalanced begin (missing modal_end)")
	assert(w > 0 && h > 0, "modal_begin: empty modal size")
	st.drawing = true
	st.dismissed = false
	route_claim_all()
	rl.DrawRectangle(0, 0, screen_w, screen_h, theme.modal_dim)

	mw := min(w, screen_w - PADDING * 4)
	mh := min(h, screen_h - PADDING * 2)
	mx := (screen_w - mw) / 2
	my := (screen_h - mh) / 2
	st.rect = Rect_I32{mx, my, mw, mh}

	rl.DrawRectangle(mx, my, mw, mh, theme.bg_secondary)
	rl.DrawRectangleLines(mx, my, mw, mh, theme.border_color)
	rl.BeginScissorMode(mx, my, mw, mh)
	semantic_push(.Modal, st.rect, title)

	title_h := sc(40)
	title_c := strings.clone_to_cstring(title, context.temp_allocator)
	draw_text(title_c, mx + PADDING, my + PADDING, FONT_SIZE_LARGE, theme.fg_primary)
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
	rl.EndScissorMode()
	if rl.IsKeyPressed(.ESCAPE) {
		st.open = false
		st.dismissed = true
		return
	}
	mrect := rl.Rectangle{f32(st.rect.x), f32(st.rect.y), f32(st.rect.w), f32(st.rect.h)}
	if rl.IsMouseButtonPressed(.LEFT) &&
	   !rl.CheckCollisionPointRec(rl.GetMousePosition(), mrect) {
		st.open = false
		st.dismissed = true
	}
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

// context_menu_height returns the popup's pixel height for an item list, so
// callers can pre-position the anchor (e.g. open upward above an input box).
context_menu_height :: proc(items: []Menu_Item) -> i32 {
	assert(len(items) > 0, "context_menu_height: empty items")
	h := MENU_PAD * 2
	for it in items {
		h += sc(5) if it.separator else MENU_ITEM_H
	}
	assert(h > 0, "context_menu_height: non-positive height")
	return h
}

// context_menu_width returns the popup width for an item list (widest label
// plus padding, at least MENU_MIN_W, capped to the given width).
context_menu_width :: proc(items: []Menu_Item, max_w: i32) -> i32 {
	assert(len(items) > 0, "context_menu_width: empty items")
	assert(max_w > 0, "context_menu_width: non-positive cap")
	w := MENU_MIN_W
	for it in items {
		if it.separator do continue
		c := strings.clone_to_cstring(it.label, context.temp_allocator)
		lw := measure_text(c, FONT_SIZE) + sc(32)
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
context_menu :: proc(st: ^Context_Menu_State, items: []Menu_Item, screen_w, screen_h: i32) -> int {
	assert(st != nil, "context_menu: nil state")
	if !st.open do return -1
	assert(len(items) > 0, "context_menu: empty items")

	menu_w := context_menu_width(items, screen_w)
	menu_h := context_menu_height(items)
	mx := clamp(st.anchor_x, 0, max(screen_w - menu_w, 0))
	my := clamp(st.anchor_y, 0, max(screen_h - menu_h, 0))
	menu_rect := rl.Rectangle{f32(mx), f32(my), f32(menu_w), f32(menu_h)}

	// Ensure the selection starts on a selectable row.
	if items[st.selected].separator || items[st.selected].disabled {
		st.selected = menu_nav_next(items, st.selected, 1)
	}
	if rl.IsKeyPressed(.ESCAPE) {
		st.open = false
		return -1
	}
	if rl.IsKeyPressed(.UP) || rl.IsKeyPressedRepeat(.UP) {
		st.selected = menu_nav_next(items, st.selected, -1)
	}
	if rl.IsKeyPressed(.DOWN) || rl.IsKeyPressedRepeat(.DOWN) {
		st.selected = menu_nav_next(items, st.selected, 1)
	}
	if rl.IsKeyPressed(.ENTER) {
		st.open = false
		return st.selected
	}

	mouse := rl.GetMousePosition()
	mouse.x -= f32(pane_origin_x)
	if !st.just_opened &&
	   (rl.IsMouseButtonPressed(.LEFT) || rl.IsMouseButtonPressed(.RIGHT)) &&
	   !rl.CheckCollisionPointRec(mouse, menu_rect) {
		st.open = false
		return -1
	}
	st.just_opened = false

	// Record all panel draws on the overlay layer in screen space so the menu
	// replays above content painted later in the frame (and outside any pane
	// scissor); the group rect also claims the covered area with the router.
	ox := pane_origin_x
	screen_rect := rl.Rectangle{f32(mx + ox), f32(my), f32(menu_w), f32(menu_h)}
	overlay_begin(screen_rect, claim_input = true)
	overlay_rect(screen_rect, theme.bg_popup)
	overlay_rect_lines(screen_rect, 1, theme.border_color)
	chosen := context_menu_rows(st, items, mx, my, menu_w, ox, mouse)
	overlay_end()
	return chosen
}

// context_menu_rows records the rows on the overlay layer and handles
// hover/click (hit-testing in pane-local coords, drawing in screen space via
// `ox`). Returns the clicked index or -1.
@(private = "file")
context_menu_rows :: proc(st: ^Context_Menu_State, items: []Menu_Item, mx, my, menu_w, ox: i32, mouse: rl.Vector2) -> int {
	assert(st.open, "context_menu_rows: menu not open")
	assert(len(items) > 0, "context_menu_rows: empty items")
	item_x := mx + 2
	item_w := menu_w - 4
	item_y := my + MENU_PAD
	chosen := -1
	for it, i in items {
		if it.separator {
			sep_h := sc(5)
			overlay_rect({f32(mx + ox + 6), f32(item_y + sep_h / 2), f32(menu_w - 12), 1}, theme.border_color)
			item_y += sep_h
			continue
		}
		row_rect := rl.Rectangle{f32(item_x), f32(item_y), f32(item_w), f32(MENU_ITEM_H)}
		hovered := rl.CheckCollisionPointRec(mouse, row_rect)
		sem: Sem_State
		if it.disabled do sem += {.Disabled}
		semantic_push(.Menu_Item, {item_x + ox, item_y, item_w, MENU_ITEM_H}, it.label, sem)
		if hovered && !it.disabled && mouse_moved() do st.selected = i
		if st.selected == i {
			overlay_rect({f32(item_x + ox), f32(item_y), f32(item_w), f32(MENU_ITEM_H)}, theme.bg_active)
		}
		if hovered && !it.disabled do request_cursor(.POINTING_HAND)
		col := theme.fg_disabled if it.disabled else theme.fg_primary
		txt := truncate_to_width(it.label, item_w - 16, FONT_SIZE)
		overlay_text(txt, item_x + ox + 8, item_y + (MENU_ITEM_H - FONT_SIZE) / 2, FONT_SIZE, col)
		if hovered && !it.disabled && rl.IsMouseButtonReleased(.LEFT) {
			st.open = false
			chosen = i
		}
		item_y += MENU_ITEM_H
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

// tooltip shows `text` near the mouse after the cursor has dwelled over
// `rect` for TOOLTIP_DELAY seconds. Call it after drawing the target; the tip
// itself is replayed through the overlay layer so it always paints on top.
// Keeps frames coming while the dwell timer runs (event-driven hosts).
tooltip :: proc(st: ^Tooltip_State, rect: Rect_I32, text: string, screen_w, screen_h: i32) {
	assert(st != nil, "tooltip: nil state")
	assert(rect.w > 0 && rect.h > 0, "tooltip: empty target rect")
	mouse := rl.GetMousePosition()
	rrect := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	key := (u64(u32(rect.x)) | u64(u32(rect.y)) << 32) ~
		((u64(u32(rect.w)) | u64(u32(rect.h)) << 32) * 0x100000001b3)
	if !rl.CheckCollisionPointRec(mouse, rrect) || route_occluded(mouse) {
		if st.key == key do st^ = {}
		return
	}
	now := rl.GetTime()
	if st.key != key {
		st.key = key
		st.hover_start = now
	}
	elapsed := now - st.hover_start
	if elapsed < TOOLTIP_DELAY {
		// Event-driven frames: schedule the repaint that reveals the tip.
		rl.RequestRedrawIn(TOOLTIP_DELAY - elapsed)
		return
	}
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	tw := measure_text(text_c, FONT_SIZE_SMALL)
	bw := tw + TOOLTIP_PAD * 2
	bh := FONT_SIZE_SMALL + TOOLTIP_PAD * 2
	tx := clamp(i32(mouse.x) + sc(12), 0, max(screen_w - bw, 0))
	ty := clamp(i32(mouse.y) + sc(18), 0, max(screen_h - bh, 0))
	tip := rl.Rectangle{f32(tx), f32(ty), f32(bw), f32(bh)}
	overlay_begin(tip, claim_input = false)
	overlay_rect(tip, theme.bg_popup)
	overlay_rect_lines(tip, 1, theme.border_color)
	overlay_text(text, tx + TOOLTIP_PAD, ty + TOOLTIP_PAD, FONT_SIZE_SMALL, theme.fg_primary)
	overlay_end()
}
