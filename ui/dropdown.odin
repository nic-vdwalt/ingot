// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Dropdown / combo box: closed state draws the current item plus a chevron;
// open state reuses the generic context-menu popup (popups.odin).
package ui

import rl "ingot:gfx"

// Dropdown_State is the caller-owned open/closed state of one dropdown.
Dropdown_State :: struct {
	menu: Context_Menu_State,
}

// dropdown draws a combo box over `items`. Clicking (or Space/Enter while
// focused) opens the item popup below the box; choosing an item stores its
// index into selected^. Returns true on the frame the selection changed.
dropdown :: proc(
	rect: Rect_I32,
	items: []string,
	selected: ^i32,
	st: ^Dropdown_State,
	screen_w, screen_h: i32,
	focus: Focus_Opt = {},
) -> (changed: bool) {
	assert(st != nil && selected != nil, "dropdown: nil state")
	assert(len(items) > 0, "dropdown: empty items")
	assert(rect.w > 0 && rect.h > 0, "dropdown: empty rect")
	if selected^ < 0 do selected^ = 0
	if int(selected^) >= len(items) do selected^ = i32(len(items) - 1)

	rrect := rl.Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(rrect)
	focus_opt_click(focus, rect.x, rect.y, rect.w, rect.h)
	if it.hovered do request_cursor(.POINTING_HAND)

	// Closed chrome: input-style box, current label, chevron.
	bg := theme.bg_input if st.menu.open || it.hovered else theme.bg_secondary
	border := theme.fg_accent if st.menu.open || it.hovered || focus_opt_focused(focus) else theme.border_color
	rl.DrawRectangleRec(rrect, bg)
	rl.DrawRectangleLinesEx(rrect, 1, border)
	chev: cstring = "\u25BE"
	chev_w := measure_text(chev, FONT_SIZE_SMALL)
	draw_text(chev, rect.x + rect.w - chev_w - sc(8), rect.y + (rect.h - FONT_SIZE_SMALL) / 2,
		FONT_SIZE_SMALL, theme.fg_secondary)
	label_w := rect.w - chev_w - sc(8) - PADDING * 2
	if label_w > 0 {
		draw_text_truncated(items[selected^], rect.x + PADDING,
			rect.y + (rect.h - FONT_SIZE) / 2, label_w, FONT_SIZE, theme.fg_primary)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(rect.x, rect.y, rect.w, rect.h)
	}

	// Open on click or keyboard activation; the opening click must not also
	// register as the popup's click-away (just_opened swallows it).
	if !st.menu.open && (it.clicked || focus_opt_activated(focus)) {
		context_menu_open(&st.menu, rect.x, rect.y + rect.h + 2)
		st.menu.selected = int(selected^)
	}
	if !st.menu.open do return false

	menu_items := make([]Menu_Item, len(items), context.temp_allocator)
	for item, i in items {
		menu_items[i] = Menu_Item{label = item}
	}
	chosen := context_menu(&st.menu, menu_items, screen_w, screen_h)
	if chosen >= 0 {
		assert(chosen < len(items), "dropdown: chosen index out of range")
		changed = i32(chosen) != selected^
		selected^ = i32(chosen)
	}
	return changed
}
