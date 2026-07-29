// LIB-CANDIDATE: imports only core:*.
// Tab bar: a facade strip of text tabs with an accent underline on the
// active one. The caller owns the active index and the panel switching.
package ui

TAB_COUNT_MAX :: 16

// tab_bar carves one row of focusable tabs. Returns true on the frame the
// active tab changed. Labels must be non-empty and stable for identity.
tab_bar :: proc(
	u: ^Ui,
	key: string,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "tab_bar: frame not open")
	assert(active != nil, "tab_bar: nil active index")
	assert(len(labels) > 0, "tab_bar: empty labels")
	assert(len(labels) <= TAB_COUNT_MAX, "tab_bar: too many tabs")
	if active^ < 0 do active^ = 0
	if int(active^) >= len(labels) do active^ = i32(len(labels) - 1)
	frame := u.frame
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	scope_begin(u, key)
	defer scope_end(u)
	row_begin(u, height, gap = .MD, align = .Center)
	defer row_end(u)
	for label, index in labels {
		assert(label != "", "tab_bar: empty tab label")
		label_w := text_width(frame, label, .Body)
		pad := metrics.CONTROL_GAP
		rect := slot_next_px(u, label_w + pad * 2, ui_frame_sc(frame, height))
		if !slot_visible(rect) do continue
		widget := id(u, label)
		fo := focus(u, widget)
		focus_opt_click(frame, fo, rect.x, rect.y, rect.w, rect.h)
		rrect := rect_f32(rect)
		it := interact(frame, rrect)
		if it.hovered do request_cursor(frame, .POINTING_HAND)
		if it.clicked || focus_opt_activated(frame, fo) {
			changed |= active^ != i32(index)
			active^ = i32(index)
		}
		is_active := active^ == i32(index)
		color := Ink.Primary if is_active || it.hovered else .Secondary
		text(
			frame,
			label,
			rect.x + pad,
			rect.y + (rect.h - text_role_size(frame, .Body)) / 2,
			.Body,
			color,
		)
		if is_active {
			draw_rectangle(
				frame,
				rect.x,
				rect.y + rect.h - ui_frame_sc(frame, 2),
				rect.w,
				ui_frame_sc(frame, 2),
				style.fg_accent,
			)
		}
		if focus_opt_focused(fo) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
		sem: Sem_State
		if is_active do sem += {.Selected}
		semantic_push(frame, .Tab, rect, label, sem, fo, widget = widget)
	}
	return changed
}
