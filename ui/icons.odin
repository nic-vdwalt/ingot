package ui

import "core:math"

Icon :: enum u8 {
	Settings,
	Close,
	Chevron_Left,
	Chevron_Right,
	Play,
	Pause,
	// Appended so existing ordinals stay stable for saved views and tests.
	Globe,
	Pointer,
	Text_Cursor,
	Sliders,
	Bar_Chart,
	Document,
	Layout_Grid,
	Layers,
	Gauge,
	Swatch,
	Motion,
	Zoom,
	Search,
	Command,
	Orbit,
	Sun,
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

@(private = "file")
draw_play_icon_frame :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_play_icon_frame: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "draw_play_icon_frame: invalid rect")
	cx := f32(rect.x) + f32(rect.w) * 0.5
	cy := f32(rect.y) + f32(rect.h) * 0.5
	extent := f32(min(rect.w, rect.h)) * 0.25
	left := cx - extent * 0.8
	right := cx + extent
	draw_triangle(frame, {left, cy - extent}, {left, cy + extent}, {right, cy}, color)
}

@(private = "file")
draw_pause_icon_frame :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_pause_icon_frame: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "draw_pause_icon_frame: invalid rect")
	size := min(rect.w, rect.h)
	bar_w := max(size / 7, 1)
	bar_h := max(size / 2, 1)
	gap := max(size / 7, 1)
	left := rect.x + (rect.w - (bar_w * 2 + gap)) / 2
	top := rect.y + (rect.h - bar_h) / 2
	draw_rectangle(frame, left, top, bar_w, bar_h, color)
	draw_rectangle(frame, left + bar_w + gap, top, bar_w, bar_h, color)
}

draw_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, rect: Rect_I32, color: Color) {
	assert(frame != nil && frame.open, "draw_icon_frame: invalid frame")
	assert(rect.w >= 0 && rect.h >= 0, "draw_icon_frame: invalid rect")
	if ui_frame_drop_degenerate(frame, rect.w <= 0 || rect.h <= 0) do return
	switch icon {
	case .Settings:
		draw_settings_icon_frame(frame, rect, color)
	case .Close:
		draw_close_icon_frame(frame, rect, color)
	case .Chevron_Left, .Chevron_Right:
		draw_chevron_icon_frame(frame, icon, rect, color)
	case .Play:
		draw_play_icon_frame(frame, rect, color)
	case .Pause:
		draw_pause_icon_frame(frame, rect, color)
	case .Globe, .Orbit, .Sun, .Gauge, .Search, .Zoom:
		draw_round_icon_frame(frame, icon, icon_box(frame, rect), color)
	case .Pointer, .Text_Cursor, .Motion, .Command:
		draw_stroke_icon_frame(frame, icon, icon_box(frame, rect), color)
	case .Sliders, .Bar_Chart, .Document, .Layout_Grid, .Layers, .Swatch:
		draw_block_icon_frame(frame, icon, icon_box(frame, rect), color)
	}
}

// Icon_Box is the square drawing area shared by the appended icons: centre,
// half extent, and a DPI-scaled stroke, so every glyph keeps the same optical
// weight as the original six at any scale.
@(private = "file")
Icon_Box :: struct {
	cx, cy, half, stroke: f32,
}

@(private = "file")
icon_box :: proc(frame: ^Ui_Frame, rect: Rect_I32) -> Icon_Box {
	assert(frame != nil && frame.open, "icon_box: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "icon_box: invalid rect")
	return {
		cx = f32(rect.x) + f32(rect.w) * 0.5,
		cy = f32(rect.y) + f32(rect.h) * 0.5,
		half = f32(min(rect.w, rect.h)) * 0.32,
		stroke = max(ui_frame_scf(frame, 1.5), 1),
	}
}

@(private = "file")
icon_line :: proc(frame: ^Ui_Frame, box: Icon_Box, a, b: Vector2, color: Color) {
	assert(frame != nil && frame.open, "icon_line: invalid frame")
	assert(box.half > 0, "icon_line: empty box")
	draw_line_ex(
		frame,
		{box.cx + a.x * box.half, box.cy + a.y * box.half},
		{box.cx + b.x * box.half, box.cy + b.y * box.half},
		box.stroke,
		color,
	)
}

@(private = "file")
icon_rect :: proc(frame: ^Ui_Frame, box: Icon_Box, x, y, w, h: f32, color: Color) {
	assert(frame != nil && frame.open, "icon_rect: invalid frame")
	assert(w > 0 && h > 0, "icon_rect: empty rect")
	rect := Rect{box.cx + x * box.half, box.cy + y * box.half, w * box.half, h * box.half}
	draw_rectangle_rec(frame, rect, color)
}

@(private = "file")
icon_outline :: proc(frame: ^Ui_Frame, box: Icon_Box, x, y, w, h: f32, color: Color) {
	assert(frame != nil && frame.open, "icon_outline: invalid frame")
	assert(w > 0 && h > 0, "icon_outline: empty rect")
	rect := Rect{box.cx + x * box.half, box.cy + y * box.half, w * box.half, h * box.half}
	draw_rectangle_lines_ex(frame, rect, box.stroke, color)
}

@(private = "file")
draw_round_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, box: Icon_Box, color: Color) {
	assert(frame != nil && frame.open, "draw_round_icon_frame: invalid frame")
	assert(box.half > 0, "draw_round_icon_frame: empty box")
	center := Vector2{box.cx, box.cy}
	ring_in := max(box.half - box.stroke, 0)
	#partial switch icon {
	case .Globe:
		draw_ring(frame, center, ring_in, box.half, 0, 360, 24, color)
		icon_line(frame, box, {-1, 0}, {1, 0}, color)
		icon_line(frame, box, {0, -1}, {0, 1}, color)
		draw_ring(
			frame,
			center,
			ring_in * 0.45,
			box.half * 0.45 + box.stroke * 0.5,
			0,
			360,
			18,
			color,
		)
	case .Orbit:
		draw_circle_v(frame, center, box.half * 0.38, color)
		draw_ring(frame, center, ring_in, box.half, 200, 520, 24, color)
		draw_circle_v(
			frame,
			{box.cx + box.half * 0.7, box.cy - box.half * 0.7},
			box.stroke * 1.4,
			color,
		)
	case .Sun:
		draw_circle_v(frame, center, box.half * 0.45, color)
		for step in 0 ..< 8 {
			angle := f32(step) * 0.7853982
			direction := Vector2{math.cos(angle), math.sin(angle)}
			icon_line(frame, box, direction * 0.68, direction, color)
		}
	case .Gauge:
		draw_ring(frame, center, ring_in, box.half, 180, 360, 18, color)
		icon_line(frame, box, {0, 0}, {0.55, -0.55}, color)
		draw_circle_v(frame, center, box.stroke * 1.3, color)
	case .Search, .Zoom:
		lens := Vector2{box.cx - box.half * 0.2, box.cy - box.half * 0.2}
		radius := box.half * 0.62
		draw_ring(frame, lens, max(radius - box.stroke, 0), radius, 0, 360, 20, color)
		icon_line(frame, box, {0.25, 0.25}, {0.95, 0.95}, color)
		if icon == .Zoom {
			icon_line(frame, box, {-0.5, -0.2}, {0.1, -0.2}, color)
			icon_line(frame, box, {-0.2, -0.5}, {-0.2, 0.1}, color)
		}
	}
}

@(private = "file")
draw_stroke_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, box: Icon_Box, color: Color) {
	assert(frame != nil && frame.open, "draw_stroke_icon_frame: invalid frame")
	assert(box.half > 0, "draw_stroke_icon_frame: empty box")
	#partial switch icon {
	case .Pointer:
		tip := Vector2{box.cx - box.half * 0.6, box.cy - box.half * 0.9}
		draw_triangle(
			frame,
			tip,
			{tip.x, tip.y + box.half * 1.5},
			{tip.x + box.half * 1.1, tip.y + box.half * 1.05},
			color,
		)
		icon_line(frame, box, {0.05, 0.3}, {0.5, 0.95}, color)
	case .Text_Cursor:
		icon_line(frame, box, {0, -0.9}, {0, 0.9}, color)
		icon_line(frame, box, {-0.35, -0.9}, {0.35, -0.9}, color)
		icon_line(frame, box, {-0.35, 0.9}, {0.35, 0.9}, color)
	case .Motion:
		icon_line(frame, box, {-1, -0.5}, {0.2, -0.5}, color)
		icon_line(frame, box, {-0.7, 0}, {0.5, 0}, color)
		icon_line(frame, box, {-1, 0.5}, {0.2, 0.5}, color)
		draw_circle_v(frame, {box.cx + box.half * 0.65, box.cy}, box.half * 0.32, color)
	case .Command:
		icon_outline(frame, box, -0.9, -0.9, 0.6, 0.6, color)
		icon_outline(frame, box, 0.3, -0.9, 0.6, 0.6, color)
		icon_outline(frame, box, -0.9, 0.3, 0.6, 0.6, color)
		icon_outline(frame, box, 0.3, 0.3, 0.6, 0.6, color)
		icon_outline(frame, box, -0.3, -0.3, 0.6, 0.6, color)
	}
}

@(private = "file")
draw_block_icon_frame :: proc(frame: ^Ui_Frame, icon: Icon, box: Icon_Box, color: Color) {
	assert(frame != nil && frame.open, "draw_block_icon_frame: invalid frame")
	assert(box.half > 0, "draw_block_icon_frame: empty box")
	#partial switch icon {
	case .Sliders:
		for row in 0 ..< 3 {
			y := -0.6 + f32(row) * 0.6
			knob := [3]f32{0.35, -0.4, 0.1}
			icon_line(frame, box, {-1, y}, {1, y}, color)
			draw_circle_v(
				frame,
				{box.cx + knob[row] * box.half, box.cy + y * box.half},
				box.half * 0.2,
				color,
			)
		}
	case .Bar_Chart:
		icon_rect(frame, box, -0.9, 0.1, 0.45, 0.8, color)
		icon_rect(frame, box, -0.22, -0.6, 0.45, 1.5, color)
		icon_rect(frame, box, 0.45, -0.2, 0.45, 1.1, color)
	case .Document:
		icon_outline(frame, box, -0.7, -0.95, 1.4, 1.9, color)
		for row in 0 ..< 3 {
			y := -0.45 + f32(row) * 0.42
			icon_line(frame, box, {-0.4, y}, {0.4, y}, color)
		}
	case .Layout_Grid:
		icon_rect(frame, box, -0.95, -0.95, 0.85, 0.85, color)
		icon_rect(frame, box, 0.1, -0.95, 0.85, 0.85, color)
		icon_rect(frame, box, -0.95, 0.1, 0.85, 0.85, color)
		icon_outline(frame, box, 0.1, 0.1, 0.85, 0.85, color)
	case .Layers:
		icon_outline(frame, box, -0.95, -0.95, 1.3, 1.1, color)
		icon_rect(frame, box, -0.35, -0.15, 1.3, 1.1, color)
	case .Swatch:
		draw_circle_v(
			frame,
			{box.cx - box.half * 0.45, box.cy - box.half * 0.4},
			box.half * 0.45,
			color,
		)
		icon_rect(frame, box, 0.05, -0.85, 0.8, 0.8, color)
		draw_triangle(
			frame,
			{box.cx - box.half * 0.9, box.cy + box.half * 0.9},
			{box.cx + box.half * 0.9, box.cy + box.half * 0.9},
			{box.cx, box.cy + box.half * 0.05},
			color,
		)
	}
}
