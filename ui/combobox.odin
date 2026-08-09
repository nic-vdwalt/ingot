// LIB-CANDIDATE: imports only core:*.
// Combobox: a searchable dropdown. Closed it looks like a dropdown showing
// the selected label; while open the same box becomes a filter text input
// and a popup lists the matching items. All state is caller-owned.
package ui

import "core:strings"

COMBOBOX_ITEM_COUNT_MAX :: 1024
COMBOBOX_VISIBLE_MAX :: 8

// Combobox_Item pairs a stable caller id with a display label.
Combobox_Item :: struct {
	id:    u64,
	label: string,
}

// Combobox_State is the caller-owned lifecycle of one combobox. The Input_Box
// holds the filter text while open and mirrors the selected label while
// closed. Destroy with combobox_state_destroy.
Combobox_State :: struct {
	box:         Input_Box,
	open:        bool,
	just_opened: bool,
	hover:       int, // index into the *visible* (filtered) list
}

combobox_state_destroy :: proc(st: ^Combobox_State) {
	assert(st != nil, "combobox_state_destroy: nil state")
	input_box_destroy(&st.box)
	st^ = {}
}

// combobox_filter_match reports whether label matches the query with a
// case-insensitive substring test. An empty query matches everything.
combobox_filter_match :: proc(label, query: string) -> bool {
	if query == "" do return true
	lowered_label := strings.to_lower(label, context.temp_allocator)
	lowered_query := strings.to_lower(query, context.temp_allocator)
	return strings.contains(lowered_label, lowered_query)
}

// combobox_selected_label returns the label whose id equals selected, or "".
combobox_selected_label :: proc(items: []Combobox_Item, selected: u64) -> string {
	for item in items {
		if item.id == selected do return item.label
	}
	return ""
}

// combobox carves a full-width slot. See combobox_at.
combobox :: proc(
	u: ^Ui,
	key: string,
	st: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder: string,
	a11y_label: string,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "combobox: frame not open")
	assert(st != nil && selected != nil, "combobox: nil state")
	assert(a11y_label != "", "combobox: empty accessible label")
	metrics := ui_frame_metrics(u.frame)
	widget := id(u, key)
	r := slot_next_px(u, remaining(&u.layout).w, metrics.ROW_H_MD + metrics.CONTROL_GAP)
	fo := focus(u, widget) if slot_visible(r) else Focus_Opt{}
	return combobox_at(
		u.frame,
		r,
		st,
		items,
		selected,
		placeholder,
		u.screen_w,
		u.screen_h,
		fo,
		a11y_label,
		widget,
	)
}

// combobox_at draws the box at an explicit rect and drives the filter popup.
// Returns true on the frame the selection changed.
combobox_at :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	st: ^Combobox_State,
	items: []Combobox_Item,
	selected: ^u64,
	placeholder: string,
	screen_w, screen_h: i32,
	focus: Focus_Opt = {},
	a11y_label: string = "",
	widget: Widget_Id = WIDGET_ID_NONE,
) -> (
	changed: bool,
) {
	assert(frame != nil, "combobox_at: nil frame")
	assert(st != nil && selected != nil, "combobox_at: nil state")
	assert(len(items) <= COMBOBOX_ITEM_COUNT_MAX, "combobox_at: item capacity exceeded")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return false

	rrect := rect_f32(rect)
	it := interact(frame, rrect)
	focus_opt_click(frame, focus, rect.x, rect.y, rect.w, rect.h)
	active := focus_opt_focused(focus)
	if it.hovered do request_cursor(frame, .IBEAM)

	// Opening resets the filter so every option is visible; closing without a
	// choice restores the selected label so the box never lies about state.
	if !st.open && (it.clicked || (active && key_activated(frame))) {
		st.open = true
		st.just_opened = true
		st.hover = 0
		input_box_reset(&st.box)
	}
	if !st.open {
		label := combobox_selected_label(items, selected^)
		if input_box_text(&st.box) != label do input_box_set_text(&st.box, label)
	}

	shown_placeholder := placeholder if placeholder != "" else "Type to search"
	submitted := text_input_at(frame, rect, &st.box, shown_placeholder, active && st.open)

	sem: Sem_State
	if st.open do sem += {.Expanded}
	semantic_push(frame, .Dropdown, rect, a11y_label, sem, focus, widget = widget)
	if !st.open do return false

	// Visible = filtered indices, bounded for the popup.
	query := input_box_text(&st.box)
	visible := make([dynamic]int, 0, COMBOBOX_VISIBLE_MAX, ui_frame_allocator(frame))
	for item, index in items {
		if len(visible) >= COMBOBOX_VISIBLE_MAX do break
		if combobox_filter_match(item.label, query) do append(&visible, index)
	}
	if st.hover >= len(visible) do st.hover = max(len(visible) - 1, 0)
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) {
		if st.hover + 1 < len(visible) do st.hover += 1
	}
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) {
		if st.hover > 0 do st.hover -= 1
	}
	if is_key_pressed(frame, .ESCAPE) {
		st.open = false
		return false
	}
	if submitted && len(visible) > 0 {
		chosen := items[visible[st.hover]]
		changed = selected^ != chosen.id
		selected^ = chosen.id
		input_box_set_text(&st.box, chosen.label)
		st.open = false
		return changed
	}

	changed = combobox_popup(frame, st, items, visible[:], selected, rect, screen_w, screen_h)
	return changed
}

// key_activated reports Space/Enter activation for keyboard-opened popups.
@(private = "file")
key_activated :: proc(frame: ^Ui_Frame) -> bool {
	return is_key_pressed(frame, .ENTER) || is_key_pressed(frame, .SPACE)
}

// combobox_popup records the filtered rows on the overlay layer, handles
// hover/click, and closes on click-away. Returns true when a row was chosen.
@(private = "file")
combobox_popup :: proc(
	frame: ^Ui_Frame,
	st: ^Combobox_State,
	items: []Combobox_Item,
	visible: []int,
	selected: ^u64,
	rect: Rect_I32,
	screen_w, screen_h: i32,
) -> (
	changed: bool,
) {
	assert(frame != nil && st != nil, "combobox_popup: invalid call")
	assert(st.open, "combobox_popup: popup not open")
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	row_h := metrics.MENU_ITEM_H
	count := max(len(visible), 1)
	menu_h := i32(count) * row_h + metrics.MENU_PAD * 2
	menu_w := rect.w
	assert(screen_w >= 0 && screen_h >= 0, "combobox_popup: negative screen bounds")
	assert(menu_w >= 0 && menu_h >= 0, "combobox_popup: negative menu size")
	box_screen := frame_to_screen(frame, {f32(rect.x), f32(rect.y)})
	sx := clamp(i32(box_screen.x), 0, max(screen_w - menu_w, 0))
	sy := i32(box_screen.y) + rect.h + 2
	if sy + menu_h > screen_h do sy = max(i32(box_screen.y) - menu_h - 2, 0)
	screen_rect := Rectangle{f32(sx), f32(sy), f32(menu_w), f32(menu_h)}
	menu_rect := frame_rect_to_local(frame, screen_rect)

	mouse := frame_to_local(frame, get_mouse_position(frame))
	box_rect := rect_f32(rect)
	if !st.just_opened &&
	   is_mouse_button_pressed(frame, .LEFT) &&
	   !point_in_rect(mouse, menu_rect) &&
	   !point_in_rect(mouse, box_rect) {
		st.open = false
		return false
	}
	st.just_opened = false

	overlay_begin(frame, screen_rect, claim_input = true)
	overlay_rect(frame, screen_rect, style.bg_popup)
	overlay_rect_lines(frame, screen_rect, ui_frame_scf(frame, 1), style.border_color)
	if len(visible) == 0 {
		overlay_text(
			frame,
			"No matches",
			sx + metrics.PADDING,
			sy + metrics.MENU_PAD + (row_h - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_secondary,
		)
	}
	item_y := menu_rect.y + f32(metrics.MENU_PAD)
	for index, row in visible {
		item := items[index]
		row_rect := Rectangle{menu_rect.x, item_y, f32(menu_w), f32(row_h)}
		row_screen := frame_rect_to_screen(frame, row_rect)
		hovered := point_in_rect(mouse, row_rect)
		if hovered && mouse_moved(frame) do st.hover = row
		if st.hover == row do overlay_rect(frame, row_screen, style.bg_active)
		if hovered do request_cursor(frame, .POINTING_HAND)
		label := truncate_to_width_frame(
			frame,
			item.label,
			menu_w - metrics.PADDING * 2,
			metrics.FONT_SIZE_BODY,
		)
		overlay_text(
			frame,
			label,
			i32(row_screen.x) + metrics.PADDING,
			i32(row_screen.y) + (row_h - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_primary,
		)
		sem: Sem_State
		if item.id == selected^ do sem += {.Selected}
		semantic_push(
			frame,
			.Option,
			{i32(row_screen.x), i32(row_screen.y), menu_w, row_h},
			item.label,
			sem,
		)
		if hovered && is_mouse_button_pressed(frame, .LEFT) {
			changed = selected^ != item.id
			selected^ = item.id
			input_box_set_text(&st.box, item.label)
			st.open = false
		}
		item_y += f32(row_h)
	}
	overlay_end(frame)
	return changed
}
