// LIB-CANDIDATE: imports only core:*.
// Dropdown / combo box: closed state draws the current item plus a chevron;
// open state reuses the generic context-menu popup (popups.odin).
package ui


// Dropdown_State is the caller-owned open/closed state of one dropdown.
Dropdown_State :: struct {
	menu: Context_Menu_State,
}

// dropdown draws a combo box over `items`. Clicking (or Space/Enter while
// focused) opens the item popup below the box; choosing an item stores its
// index into selected^. Returns true on the frame the selection changed.
dropdown :: proc {
	dropdown_at,
	dropdown_auto,
}

dropdown_auto :: proc(
	u: ^Ui,
	id: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	width: i32 = 0,
	a11y_label: string = "",
) -> (changed: bool) {
	assert(u != nil && u.open, "dropdown: frame not open")
	assert(id != WIDGET_ID_NONE, "dropdown: zero stable id")
	assert(a11y_label != "", "dropdown: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	resolved_width := width if width > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 2
	r := slot_next_px(u, resolved_width, metrics.ROW_H_MD)
	focus := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return dropdown_at(
		u.frame,
		r,
		items,
		selected,
		state,
		u.screen_w,
		u.screen_h,
		focus,
		a11y_label,
		id,
	)
}

// dropdown_ui carves its slot (width w, 0 = sensible default), reads screen
// size from the Ui, and auto-registers focus.
dropdown_ui :: proc(
	u: ^Ui,
	items: []string,
	selected: ^i32,
	st: ^Dropdown_State,
	w: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(a11y_label != "", "dropdown_ui: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	ww := w if w > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 2
	r := ui_slot(u, ww, metrics.ROW_H_MD)
	fo := ui_focus(u) if ui_slot_visible(r) else Focus_Opt{}
	return dropdown_at(u.frame, r, items, selected, st, u.screen_w, u.screen_h, fo, a11y_label)
}

dropdown_ui_id :: proc(
	u: ^Ui,
	id: Widget_Id,
	items: []string,
	selected: ^i32,
	st: ^Dropdown_State,
	w: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(a11y_label != "", "dropdown_ui_id: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	ww := w if w > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 2
	r := ui_slot(u, ww, metrics.ROW_H_MD)
	fo := ui_focus(u, id) if ui_slot_visible(r) else Focus_Opt{}
	return dropdown_at(u.frame, r, items, selected, st, u.screen_w, u.screen_h, fo, a11y_label, id)
}

dropdown_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	items: []string,
	selected: ^i32,
	st: ^Dropdown_State,
	screen_w, screen_h: i32,
	focus: Focus_Opt = {},
	a11y_label: string = "",
	widget: Widget_Id = WIDGET_ID_NONE,
) -> (
	changed: bool,
) {
	assert(st != nil && selected != nil, "dropdown: nil state")
	if len(items) == 0 {
		selected^ = -1
		st.menu.open = false
		_ = ui_frame_drop_degenerate(frame, true)
		return false
	}
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false
	if selected^ < 0 do selected^ = 0
	if int(selected^) >= len(items) do selected^ = i32(len(items) - 1)

	rrect := Rectangle{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	it := interact(frame, rrect)
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	if it.hovered do request_cursor(frame, .POINTING_HAND)

	// Closed chrome: input-style box, current label, chevron.
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	bg := style.bg_input if st.menu.open || it.hovered else style.bg_secondary
	border :=
		style.fg_accent if st.menu.open || it.hovered || focus_opt_focused(focus) else style.border_color
	draw_rectangle_rec(frame, rrect, bg)
	draw_rectangle_lines_ex(frame, rrect, 1, border)
	chev: cstring = "\u25BE"
	chev_w := measure_text_frame(frame, chev, metrics.FONT_SIZE_LABEL)
	draw_text_frame(
		frame,
		chev,
		rect.x + rect.w - chev_w - ui_frame_sc(frame, 8),
		rect.y + (rect.h - metrics.FONT_SIZE_LABEL) / 2,
		metrics.FONT_SIZE_LABEL,
		style.fg_secondary,
	)
	label_w := rect.w - chev_w - ui_frame_sc(frame, 8) - metrics.PADDING * 2
	if label_w > 0 {
		draw_text_truncated_frame(
			frame,
			items[selected^],
			rect.x + metrics.PADDING,
			rect.y + (rect.h - metrics.FONT_SIZE_BODY) / 2,
			label_w,
			metrics.FONT_SIZE_BODY,
			style.fg_primary,
		)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	}

	// Open on click or keyboard activation; the opening click must not also
	// register as the popup's click-away (just_opened swallows it).
	if !st.menu.open && (it.clicked || focus_opt_activated(frame, focus)) {
		context_menu_open(&st.menu, rect.x, rect.y + rect.h + 2)
		st.menu.selected = int(selected^)
	}
	sem: Sem_State
	if st.menu.open do sem += {.Expanded}
	sem_label := a11y_label if a11y_label != "" else items[selected^]
	semantic_push(frame, .Dropdown, rect, sem_label, sem, focus, widget = widget)
	if !st.menu.open do return false

	menu_items := make([]Menu_Item, len(items), context.temp_allocator)
	for item, i in items {
		menu_items[i] = Menu_Item {
			label = item,
		}
	}
	chosen := context_menu(frame, &st.menu, menu_items, screen_w, screen_h)
	if chosen >= 0 {
		assert(chosen < len(items), "dropdown: chosen index out of range")
		changed = i32(chosen) != selected^
		selected^ = i32(chosen)
	}
	return changed
}
