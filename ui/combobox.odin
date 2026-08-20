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
	hover:       int, // index into the visible filtered window
	window:      int, // first matching item shown in the bounded popup
	match_count: int,
}

combobox_state_destroy :: proc(st: ^Combobox_State) {
	assert(st != nil, "combobox_state_destroy: nil state")
	input_box_destroy(&st.box)
	st^ = {}
}

// combobox_filter_match reports whether label matches the query with a
// case-insensitive substring test. An empty query matches everything.
combobox_filter_match_lowered :: proc(label, lowered_query: string) -> bool {
	if lowered_query == "" do return true
	lowered_label := strings.to_lower(label, context.temp_allocator)
	return strings.contains(lowered_label, lowered_query)
}

combobox_filter_match :: proc(label, query: string) -> bool {
	lowered_query := strings.to_lower(query, context.temp_allocator)
	return combobox_filter_match_lowered(label, lowered_query)
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

	query := input_box_text(&st.box)
	lowered_query := strings.to_lower(query, context.temp_allocator)
	match_count := 0
	for item in items {
		if combobox_filter_match_lowered(item.label, lowered_query) do match_count += 1
	}
	st.match_count = match_count
	max_window := max(match_count - COMBOBOX_VISIBLE_MAX, 0)
	st.window = clamp(st.window, 0, max_window)
	visible_count := min(match_count - st.window, COMBOBOX_VISIBLE_MAX)
	st.hover = clamp(st.hover, 0, max(visible_count - 1, 0))
	if is_key_pressed(frame, .DOWN) || is_key_pressed_repeat(frame, .DOWN) {
		if st.hover + 1 < visible_count {
			st.hover += 1
		} else if st.window < max_window {
			st.window += 1
		}
	}
	if is_key_pressed(frame, .UP) || is_key_pressed_repeat(frame, .UP) {
		if st.hover > 0 {
			st.hover -= 1
		} else if st.window > 0 {
			st.window -= 1
		}
	}
	visible: [COMBOBOX_VISIBLE_MAX]int
	visible_count = 0
	match_index := 0
	for item, index in items {
		if !combobox_filter_match_lowered(item.label, lowered_query) do continue
		if match_index >= st.window && visible_count < COMBOBOX_VISIBLE_MAX {
			visible[visible_count] = index
			visible_count += 1
		}
		match_index += 1
	}
	if is_key_pressed(frame, .ESCAPE) {
		st.open = false
		return false
	}
	if submitted && visible_count > 0 {
		chosen := items[visible[st.hover]]
		changed = selected^ != chosen.id
		selected^ = chosen.id
		input_box_set_text(&st.box, chosen.label)
		st.open = false
		return changed
	}

	changed = combobox_popup(
		frame,
		st,
		items,
		visible[:visible_count],
		selected,
		rect,
		screen_w,
		screen_h,
		focus,
		widget,
	)
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
	focus: Focus_Opt,
	widget: Widget_Id,
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
	anchor_y := i32(box_screen.y) + rect.h + 2
	if anchor_y + menu_h > screen_h do anchor_y = max(i32(box_screen.y) - menu_h - 2, 0)
	layout := popup_layout(
		{box_screen.x, f32(anchor_y)},
		menu_w,
		menu_h,
		{0, 0, screen_w, screen_h},
	)
	screen_rect := layout.rect
	menu_w = layout.content_w
	menu_h = layout.content_h
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

	mouse_screen := get_mouse_position(frame)
	layer_begin(frame, Z_POPUP, claim = screen_rect)
	draw_rectangle_rec(frame, screen_rect, style.bg_popup)
	draw_rectangle_lines_ex(frame, screen_rect, ui_frame_scf(frame, 1), style.border_color)
	if len(visible) == 0 {
		draw_text_string(
			frame,
			"No matches",
			i32(screen_rect.x) + metrics.PADDING,
			i32(screen_rect.y) + metrics.MENU_PAD + (row_h - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_secondary,
		)
	}
	item_y := screen_rect.y + f32(metrics.MENU_PAD)
	owner_id := sem_node_id(.Dropdown, focus, "", 0, widget)
	visible_rows := int(max((menu_h - metrics.MENU_PAD * 2) / row_h, 0))
	for index, row in visible {
		if row >= visible_rows do break
		item := items[index]
		row_screen := Rectangle{screen_rect.x, item_y, f32(menu_w), f32(row_h)}
		hovered := point_in_rect(mouse_screen, row_screen)
		if hovered && mouse_moved(frame) do st.hover = row
		if st.hover == row do draw_rectangle_rec(frame, row_screen, style.bg_active)
		if hovered do request_cursor(frame, .POINTING_HAND)
		label := truncate_to_width_frame(
			frame,
			item.label,
			menu_w - metrics.PADDING * 2,
			metrics.FONT_SIZE_BODY,
		)
		draw_text_string(
			frame,
			label,
			i32(row_screen.x) + metrics.PADDING,
			i32(row_screen.y) + (row_h - metrics.FONT_SIZE_BODY) / 2,
			metrics.FONT_SIZE_BODY,
			style.fg_primary,
		)
		sem: Sem_State
		if item.id == selected^ do sem += {.Selected}
		option_widget := Widget_Id(id_finish(id_hash_u64(owner_id, item.id)))
		semantic_push(
			frame,
			.Option,
			{i32(row_screen.x), i32(row_screen.y), menu_w, row_h},
			item.label,
			sem,
			position_in_set = st.window + row + 1,
			size_of_set = st.match_count,
			widget = option_widget,
		)
		option_id := sem_node_id(.Option, {}, "", 0, option_widget)
		activated := hovered && is_mouse_button_pressed(frame, .LEFT)
		activated = activated || a11y_take_click(frame.runtime, option_id)
		if activated {
			changed = selected^ != item.id
			selected^ = item.id
			input_box_set_text(&st.box, item.label)
			st.open = false
		}
		item_y += f32(row_h)
	}
	layer_end(frame)
	return changed
}
