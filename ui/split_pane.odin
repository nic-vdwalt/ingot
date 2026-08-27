package ui

Split_Pane_State :: struct {
	ratio:    f32,
	dragging: bool,
	focus:    Focus_State,
}

Split_Pane_Result :: struct {
	first:   Rect_I32,
	divider: Rect_I32,
	second:  Rect_I32,
	changed: bool,
}

split_pane_layout :: proc(
	rect: Rect_I32,
	ratio: f32,
	divider_width, minimum_first, minimum_second: i32,
) -> Split_Pane_Result {
	assert(divider_width > 0, "split_pane_layout: non-positive divider")
	assert(minimum_first >= 0 && minimum_second >= 0, "split_pane_layout: negative minimum")
	available := max(rect.w - divider_width, 0)
	minimum := min(minimum_first, available)
	maximum := max(available - minimum_second, minimum)
	first_width := clamp(i32(f32(available) * clamp(ratio, 0, 1)), minimum, maximum)
	return {
		first = {rect.x, rect.y, first_width, rect.h},
		divider = {rect.x + first_width, rect.y, divider_width, rect.h},
		second = {
			rect.x + first_width + divider_width,
			rect.y,
			max(available - first_width, 0),
			rect.h,
		},
	}
}

split_pane :: proc(
	frame: ^Ui_Frame,
	state: ^Split_Pane_State,
	rect: Rect_I32,
	label: string,
	widget: Widget_Id,
	minimum_first: i32 = 0,
	minimum_second: i32 = 0,
) -> Split_Pane_Result {
	assert(frame != nil && frame.open, "split_pane: invalid frame")
	assert(state != nil && label != "" && widget != WIDGET_ID_NONE, "split_pane: invalid argument")
	divider_width := ui_frame_metrics(frame).SPLIT_DIVIDER_W
	if state.ratio <= 0 || state.ratio >= 1 do state.ratio = 0.5
	result := split_pane_layout(rect, state.ratio, divider_width, minimum_first, minimum_second)
	if rect.w <= divider_width || rect.h <= 0 do return result
	focus := focus_link(&state.focus, focus_id(1))
	focus_opt_click(frame, focus, result.divider.x, result.divider.y, result.divider.w, result.divider.h)
	interaction := interact(frame, rect_f32(result.divider), &state.dragging)
	if interaction.hovered || interaction.held do request_cursor(frame, .RESIZE_EW)
	available := rect.w - divider_width
	if interaction.held {
		mouse := get_mouse_position(frame)
		first_width := clamp(i32(mouse.x) - rect.x, minimum_first, available - minimum_second)
		next := f32(first_width) / f32(available)
		result.changed = next != state.ratio
		state.ratio = next
	}
	if focus_opt_focused(focus) {
		step := 1.0 / f32(available)
		if is_key_pressed_or_repeat(frame, .LEFT) do state.ratio -= step
		if is_key_pressed_or_repeat(frame, .RIGHT) do state.ratio += step
		normalized := split_pane_layout(rect, state.ratio, divider_width, minimum_first, minimum_second)
		next := f32(normalized.first.w) / f32(available)
		result.changed ||= next != state.ratio
		state.ratio = next
	}
	result = split_pane_layout(rect, state.ratio, divider_width, minimum_first, minimum_second)
	draw_rectangle_rec(frame, rect_f32(result.divider), ui_frame_theme(frame).border_color)
	if focus_opt_focused(focus) {
		draw_focus_ring(frame, result.divider.x, result.divider.y, result.divider.w, result.divider.h)
	}
	semantic_push(
		frame,
		.Slider,
		result.divider,
		label,
		focus = focus,
		value = state.ratio,
		lo = 0,
		hi = 1,
		widget = widget,
	)
	return result
}
