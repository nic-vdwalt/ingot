// LIB-CANDIDATE: imports only core:*.
// Tab bar: a facade strip of text tabs with an accent underline on the
// active one. The caller owns the active index and the panel switching.
package ui

TAB_COUNT_MAX :: 16

Tabs_Spec :: struct {
	id:     Widget_Id,
	labels: []string,
	active: ^i32,
	height: i32,
	motion: ^Control_Motion_State,
}

tabs_spec_size :: proc(u: ^Ui, spec: Tabs_Spec) -> Intrinsic_Size {
	assert(u != nil && u.open && spec.id != WIDGET_ID_NONE, "tabs spec: invalid UI")
	assert(spec.active != nil && len(spec.labels) > 0 && len(spec.labels) <= TAB_COUNT_MAX)
	height := spec.height if spec.height > 0 else 36
	return intrinsic_leaf(remaining(&u.layout).w, ui_frame_sc(u.frame, height))
}

tabs_spec_at :: proc(u: ^Ui, spec: Tabs_Spec, rect: Rect_I32) -> bool {
	assert(u != nil && u.open && spec.id != WIDGET_ID_NONE, "tabs spec: invalid UI")
	layout_push_rect(&u.layout, .Column, rect, 0, .Start)
	defer layout_pop(&u.layout)
	return tab_bar_id(u, spec.id, spec.labels, spec.active, spec.height, spec.motion)
}

// tab_bar carves one row of focusable tabs. Returns true on the frame the
// active tab changed. Labels must be non-empty and stable for identity.
tab_bar_id :: proc(
	u: ^Ui,
	key: Widget_Id,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	motion: ^Control_Motion_State = nil,
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
	scope_begin(u, u64(key))
	defer scope_end(u)
	row_begin(u, height, gap = .MD, align = .Center)
	defer row_end(u)
	rects: [TAB_COUNT_MAX]Rect_I32
	focuses: [TAB_COUNT_MAX]Focus_Opt
	hovers: [TAB_COUNT_MAX]bool
	identity := u64(key)
	for label, index in labels {
		assert(label != "", "tab_bar: empty tab label")
		label_w := text_width(frame, label, .Body)
		pad := metrics.CONTROL_GAP
		rect := slot_next_px(u, label_w + pad * 2, ui_frame_sc(frame, height))
		rects[index] = rect
		identity = id_hash_u64(identity, u64(widget_id_string(label)))
		if !slot_visible(rect) do continue
		widget := id(u, label)
		fo := focus(u, widget)
		focus_opt_click(frame, fo, rect.x, rect.y, rect.w, rect.h)
		rrect := rect_f32(rect)
		it := interact(frame, rrect)
		if it.hovered do request_cursor(frame, .POINTING_HAND)
		if it.clicked || focus_opt_activated(frame, fo, .Tab, widget) {
			changed |= active^ != i32(index)
			active^ = i32(index)
		}
		focuses[index], hovers[index] = fo, it.hovered
	}
	indicator := tabs_motion_rect(frame, rects[active^], motion, identity)
	for label, index in labels {
		rect := rects[index]
		if !slot_visible(rect) do continue
		fo := focuses[index]
		widget := id(u, label)
		is_active := active^ == i32(index)
		color := Ink.Primary if is_active || hovers[index] else .Secondary
		pad := metrics.CONTROL_GAP
		if !rect_culled_frame(frame, rect) {
			text(
				frame,
				label,
				rect.x + pad,
				rect.y + (rect.h - text_role_size(frame, .Body)) / 2,
				.Body,
				color,
			)
		}
		if is_active && !rect_culled_frame(frame, rect) {
			draw_rectangle(
				frame,
				indicator.x,
				indicator.y,
				indicator.w,
				indicator.h,
				ui_frame_theme(frame).fg_accent,
			)
		}
		if focus_opt_focused(fo) && !rect_culled_frame(frame, rect) {
			draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
		}
		sem: Sem_State
		if is_active do sem += {.Selected}
		semantic_push(frame, .Tab, rect, label, sem, fo, widget = widget)
	}
	return changed
}

tabs_motion_rect :: proc(
	frame: ^Ui_Frame,
	rect: Rect_I32,
	motion: ^Control_Motion_State,
	identity: u64,
) -> Rect_I32 {
	assert(frame != nil && frame.open, "tabs motion: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "tabs motion: invalid rect")
	target := Rect_I32 {
		rect.x,
		rect.y + rect.h - ui_frame_sc(frame, 2),
		rect.w,
		ui_frame_sc(frame, 2),
	}
	if motion == nil do return target
	snap := motion.identity != identity || !slot_visible(rect) || rect_culled_frame(frame, rect)
	motion.identity = identity
	return control_motion_indicator(frame, &motion.indicator, target, snap)
}

tab_bar_string :: proc(
	u: ^Ui,
	key: string,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(u != nil && u.open && key != "", "tab_bar: invalid argument")
	return tab_bar_id(u, id(u, key), labels, active, height, motion)
}

tab_bar_u64 :: proc(
	u: ^Ui,
	key: u64,
	labels: []string,
	active: ^i32,
	height: i32 = 36,
	motion: ^Control_Motion_State = nil,
) -> bool {
	assert(u != nil && u.open && key != 0, "tab_bar: invalid argument")
	return tab_bar_id(u, id(u, key), labels, active, height, motion)
}

tab_bar :: proc {
	tab_bar_string,
	tab_bar_u64,
	tab_bar_id,
}
