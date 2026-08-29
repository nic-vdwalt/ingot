// LIB-CANDIDATE: imports only core:*.
// Dropdown / combo box: closed state draws the current item plus a chevron;
// open state reuses the generic context-menu popup (popups.odin).
package ui

DROPDOWN_ITEM_COUNT_MAX :: 256

// Dropdown_State is the caller-owned open/closed state of one dropdown.
Dropdown_State :: struct {
	menu: Context_Menu_State,
}

Dropdown_Spec :: struct {
	id:         Widget_Id,
	items:      []string,
	selected:   ^i32,
	state:      ^Dropdown_State,
	a11y_label: string,
}

dropdown_spec_size :: proc(u: ^Ui, spec: Dropdown_Spec) -> Intrinsic_Size {
	assert(u != nil && u.open && spec.id != WIDGET_ID_NONE, "dropdown spec: invalid UI")
	assert(spec.selected != nil && spec.state != nil && spec.a11y_label != "")
	metrics := ui_frame_metrics(u.frame)
	return intrinsic_leaf(metrics.MENU_MIN_W + metrics.CONTROL_BOX * 2, metrics.ROW_H_MD)
}

dropdown_spec_at :: proc(u: ^Ui, spec: Dropdown_Spec, rect: Rect_I32) -> bool {
	assert(u != nil && u.open && spec.id != WIDGET_ID_NONE, "dropdown spec: invalid UI")
	focus := focus(u, spec.id) if slot_visible(rect) else Focus_Opt{}
	return dropdown_at(
		u.frame,
		rect,
		spec.items,
		spec.selected,
		spec.state,
		u.screen_w,
		u.screen_h,
		focus,
		spec.a11y_label,
		spec.id,
	)
}

// dropdown draws a combo box over `items`. Clicking (or Space/Enter while
// focused) opens the item popup below the box; choosing an item stores its
// index into selected^. Returns true on the frame the selection changed.
// dropdown carves its own slot (width 0 = sensible default) and reads screen
// size from the Ui; dropdown_at takes an explicit rect and explicit bounds.
dropdown :: proc(
	u: ^Ui,
	id: Widget_Id,
	items: []string,
	selected: ^i32,
	state: ^Dropdown_State,
	width: i32 = 0,
	a11y_label: string = "",
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "dropdown: frame not open")
	assert(id != WIDGET_ID_NONE, "dropdown: zero stable id")
	assert(selected != nil && state != nil, "dropdown: nil state")
	assert(a11y_label != "", "dropdown: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	resolved_width :=
		ui_frame_sc(u.frame, width) if width > 0 else metrics.MENU_MIN_W + metrics.CONTROL_BOX * 2
	r := slot_next_px(u, resolved_width, metrics.ROW_H_MD)
	fo := focus(u, id) if slot_visible(r) else Focus_Opt{}
	return dropdown_at(
		u.frame,
		r,
		items,
		selected,
		state,
		u.screen_w,
		u.screen_h,
		fo,
		a11y_label,
		id,
	)
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
	assert(len(items) <= DROPDOWN_ITEM_COUNT_MAX, "dropdown: item capacity exceeded")
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
	draw_rectangle_lines_ex(frame, rrect, border_pixels(frame, .Hairline), border)
	chev :: "\u25BE"
	chev_size := text_role_size(frame, .Label)
	chev_w := text_width(frame, chev, .Label)
	text(
		frame,
		chev,
		rect.x + rect.w - chev_w - ui_frame_sc(frame, 8),
		rect.y + (rect.h - chev_size) / 2,
		.Label,
		.Secondary,
	)
	label_w := rect.w - chev_w - ui_frame_sc(frame, 8) - metrics.PADDING * 2
	if label_w > 0 {
		text_truncated(
			frame,
			items[selected^],
			rect.x + metrics.PADDING,
			rect.y + (rect.h - text_role_size(frame, .Body)) / 2,
			label_w,
			.Body,
			.Primary,
		)
	}
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
	}

	// Open on click or keyboard activation; the opening click must not also
	// register as the popup's click-away (just_opened swallows it).
	if !st.menu.open && (it.clicked || focus_opt_activated(frame, focus, .Dropdown, widget)) {
		context_menu_open(&st.menu, rect.x, rect.y + rect.h + 2)
		st.menu.selected = int(selected^)
	}
	sem: Sem_State
	if st.menu.open do sem += {.Expanded}
	sem_label := a11y_label if a11y_label != "" else items[selected^]
	semantic_push(frame, .Dropdown, rect, sem_label, sem, focus, widget = widget)
	if !st.menu.open do return false
	st.menu.anchor_x = rect.x
	st.menu.anchor_y = rect.y + rect.h + 2

	menu_items := make([]Menu_Item, len(items), ui_frame_allocator(frame))
	for item, i in items {
		menu_items[i] = Menu_Item {
			label = item,
		}
	}
	chosen := context_menu(frame, &st.menu, menu_items, {0, 0, screen_w, screen_h})
	if chosen >= 0 {
		assert(chosen < len(items), "dropdown: chosen index out of range")
		changed = i32(chosen) != selected^
		selected^ = i32(chosen)
	}
	return changed
}
