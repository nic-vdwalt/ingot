package ui

Icon :: enum u8 {
	Settings,
	Close,
	Chevron_Left,
	Chevron_Right,
}

@(private = "file")
draw_settings_icon_frame :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_settings_icon_frame: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "draw_settings_icon_frame: invalid rect")
	cx := f32(rect.x) + f32(rect.w) * 0.5
	cy := f32(rect.y) + f32(rect.h) * 0.5
	size := f32(min(rect.w, rect.h))
	outer := max(size * 0.31, 2)
	inner := max(size * 0.18, 1)
	hub := max(size * 0.09, 1)
	stroke := max(ui_frame_scf(frame, 1.5), 1)
	diagonal: f32 = 0.70710677
	directions := [8]Vector2 {
		{0, -1},
		{diagonal, -diagonal},
		{1, 0},
		{diagonal, diagonal},
		{0, 1},
		{-diagonal, diagonal},
		{-1, 0},
		{-diagonal, -diagonal},
	}
	for direction in directions {
		draw_line_ex(
			frame,
			{cx + direction.x * inner, cy + direction.y * inner},
			{cx + direction.x * outer, cy + direction.y * outer},
			stroke,
			color,
		)
	}
	draw_circle_lines_v(frame, {cx, cy}, inner, color)
	draw_circle_v(frame, {cx, cy}, hub, color)
}

@(private = "file")
draw_close_icon_frame :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_close_icon_frame: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "draw_close_icon_frame: invalid rect")
	inset := f32(min(rect.w, rect.h)) * 0.3
	left := f32(rect.x) + inset
	right := f32(rect.x + rect.w) - inset
	top := f32(rect.y) + inset
	bottom := f32(rect.y + rect.h) - inset
	stroke := max(ui_frame_scf(frame, 1.5), 1)
	draw_line_ex(frame, {left, top}, {right, bottom}, stroke, color)
	draw_line_ex(frame, {right, top}, {left, bottom}, stroke, color)
}

@(private = "file")
draw_chevron_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_chevron_icon_frame: invalid frame")
	assert(
		icon == .Chevron_Left || icon == .Chevron_Right,
		"draw_chevron_icon_frame: invalid icon",
	)
	assert(rect.w > 0 && rect.h > 0, "draw_chevron_icon_frame: invalid rect")
	cx := f32(rect.x) + f32(rect.w) * 0.5
	cy := f32(rect.y) + f32(rect.h) * 0.5
	extent := f32(min(rect.w, rect.h)) * 0.2
	direction: f32 = 1
	if icon == .Chevron_Right do direction = -1
	stroke := max(ui_frame_scf(frame, 1.5), 1)
	draw_line_ex(
		frame,
		{cx + extent * direction, cy - extent},
		{cx - extent * direction, cy},
		stroke,
		color,
	)
	draw_line_ex(
		frame,
		{cx - extent * direction, cy},
		{cx + extent * direction, cy + extent},
		stroke,
		color,
	)
}

draw_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_icon_frame: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "draw_icon_frame: invalid rect")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return
	#partial switch icon {
	case .Settings:
		draw_settings_icon_frame(frame, rect, color)
	case .Close:
		draw_close_icon_frame(frame, rect, color)
	case .Chevron_Left, .Chevron_Right:
		draw_chevron_icon_frame(frame, icon, rect, color)
	}
}
