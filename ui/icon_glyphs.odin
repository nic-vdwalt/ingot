package ui

// Glyph geometry in 24-unit viewBox coordinates, Lucide style: content sits in
// units 2..22, one 2-unit stroke, round caps and joins, outlines only. Each
// group proc owns a family of related icons so every switch stays short.

ICON_GEAR_TEETH :: 8

#assert(ICON_GEAR_TEETH * 4 == ICON_POLYLINE_POINTS_MAX)

// icon_gear_points traces the gear outline: each tooth is a flat-topped
// trapezoid on the 9.5 radius joined to the next by a 7 radius root, so the
// closed polyline reads as one continuous stroked path.
icon_gear_points :: proc() -> [ICON_POLYLINE_POINTS_MAX]Vector2 {
	center := Vector2{12, 12}
	offsets := [4]f32{-9, 9, 14, 31}
	radii := [4]f32{9.5, 9.5, 7, 7}
	points: [ICON_POLYLINE_POINTS_MAX]Vector2
	for tooth in 0 ..< ICON_GEAR_TEETH {
		base := f32(tooth) * 360 / f32(ICON_GEAR_TEETH)
		for corner in 0 ..< 4 {
			angle := base + offsets[corner]
			points[tooth * 4 + corner] = icon_pen_polar(center, radii[corner], angle)
		}
	}
	assert(points[0] != points[1], "icon_gear_points: collapsed tooth")
	assert(points[ICON_POLYLINE_POINTS_MAX - 1] != points[0], "icon_gear_points: open outline")
	return points
}

draw_icon_controls :: proc(frame: ^Ui_Frame, pen: Icon_Pen, icon: Icon) {
	assert(frame != nil && frame.open, "draw_icon_controls: invalid frame")
	assert(pen.unit > 0 && pen.stroke > 0, "draw_icon_controls: empty pen")
	#partial switch icon {
	case .Settings:
		gear := icon_gear_points()
		icon_pen_polyline(frame, pen, gear[:], true, true)
		icon_pen_circle(frame, pen, {12, 12}, 3)
	case .Close:
		icon_pen_line(frame, pen, {6, 6}, {18, 18})
		icon_pen_line(frame, pen, {18, 6}, {6, 18})
	case .Chevron_Left:
		points := [3]Vector2{{15, 6}, {9, 12}, {15, 18}}
		icon_pen_polyline(frame, pen, points[:], false, true)
	case .Chevron_Right:
		points := [3]Vector2{{9, 6}, {15, 12}, {9, 18}}
		icon_pen_polyline(frame, pen, points[:], false, true)
	case .Play:
		points := [3]Vector2{{7, 4}, {19, 12}, {7, 20}}
		icon_pen_polyline(frame, pen, points[:], true, true)
	case .Pause:
		icon_pen_rect(frame, pen, 6, 4, 4, 16, 1)
		icon_pen_rect(frame, pen, 14, 4, 4, 16, 1)
	case:
		assert(false, "draw_icon_controls: icon outside group")
	}
}

@(private = "file")
draw_icon_lens :: proc(frame: ^Ui_Frame, pen: Icon_Pen) {
	assert(frame != nil && frame.open, "draw_icon_lens: invalid frame")
	assert(pen.stroke > 0, "draw_icon_lens: empty pen")
	icon_pen_circle(frame, pen, {11, 11}, 7)
	icon_pen_line(frame, pen, {16, 16}, {21, 21})
}

draw_icon_round :: proc(frame: ^Ui_Frame, pen: Icon_Pen, icon: Icon) {
	assert(frame != nil && frame.open, "draw_icon_round: invalid frame")
	assert(pen.unit > 0 && pen.stroke > 0, "draw_icon_round: empty pen")
	center := Vector2{12, 12}
	#partial switch icon {
	case .Globe:
		icon_pen_circle(frame, pen, center, 10)
		icon_pen_line(frame, pen, {2, 12}, {22, 12})
		icon_pen_ellipse(frame, pen, center, 4.5, 10)
	case .Orbit:
		// The ring breaks around 315 degrees so the satellite reads as riding it.
		icon_pen_circle(frame, pen, center, 3)
		icon_pen_arc(frame, pen, center, 9, 330, 660)
		icon_pen_circle(frame, pen, icon_pen_polar(center, 9, 315), 2)
	case .Sun:
		icon_pen_circle(frame, pen, center, 4)
		for ray in 0 ..< 8 {
			angle := f32(ray) * 45
			icon_pen_line(
				frame,
				pen,
				icon_pen_polar(center, 7, angle),
				icon_pen_polar(center, 9.5, angle),
			)
		}
	case .Gauge:
		icon_pen_arc(frame, pen, {12, 14}, 9, 150, 390)
		icon_pen_line(frame, pen, {12, 14}, {16, 10})
	case .Search:
		draw_icon_lens(frame, pen)
	case .Zoom:
		draw_icon_lens(frame, pen)
		icon_pen_line(frame, pen, {11, 8}, {11, 14})
		icon_pen_line(frame, pen, {8, 11}, {14, 11})
	case:
		assert(false, "draw_icon_round: icon outside group")
	}
}

draw_icon_tools :: proc(frame: ^Ui_Frame, pen: Icon_Pen, icon: Icon) {
	assert(frame != nil && frame.open, "draw_icon_tools: invalid frame")
	assert(pen.unit > 0 && pen.stroke > 0, "draw_icon_tools: empty pen")
	#partial switch icon {
	case .Pointer:
		points := [4]Vector2{{4, 4}, {10.5, 20}, {13, 13}, {20, 10.5}}
		icon_pen_polyline(frame, pen, points[:], true, true)
	case .Text_Cursor:
		icon_pen_line(frame, pen, {12, 4}, {12, 20})
		icon_pen_line(frame, pen, {9, 4}, {15, 4})
		icon_pen_line(frame, pen, {9, 20}, {15, 20})
	case .Motion:
		icon_pen_line(frame, pen, {3, 7}, {10, 7})
		icon_pen_line(frame, pen, {2, 12}, {9, 12})
		icon_pen_line(frame, pen, {3, 17}, {10, 17})
		icon_pen_circle(frame, pen, {16, 12}, 5)
	case .Command:
		// Each loop starts and ends on the tangent points of the two bars it
		// joins, so the arcs and lines read as one continuous path.
		icon_pen_line(frame, pen, {9, 6}, {9, 18})
		icon_pen_line(frame, pen, {15, 6}, {15, 18})
		icon_pen_line(frame, pen, {6, 9}, {18, 9})
		icon_pen_line(frame, pen, {6, 15}, {18, 15})
		icon_pen_arc(frame, pen, {6, 6}, 3, 90, 360)
		icon_pen_arc(frame, pen, {18, 6}, 3, 180, 450)
		icon_pen_arc(frame, pen, {18, 18}, 3, 270, 540)
		icon_pen_arc(frame, pen, {6, 18}, 3, 0, 270)
	case:
		assert(false, "draw_icon_tools: icon outside group")
	}
}

draw_icon_blocks :: proc(frame: ^Ui_Frame, pen: Icon_Pen, icon: Icon) {
	assert(frame != nil && frame.open, "draw_icon_blocks: invalid frame")
	assert(pen.unit > 0 && pen.stroke > 0, "draw_icon_blocks: empty pen")
	#partial switch icon {
	case .Sliders:
		knobs := [3]f32{15, 8, 12}
		for knob, row in knobs {
			y := 6 + f32(row) * 6
			icon_pen_line(frame, pen, {3, y}, {knob - 2, y})
			icon_pen_line(frame, pen, {knob + 2, y}, {21, y})
			icon_pen_circle(frame, pen, {knob, y}, 2)
		}
	case .Bar_Chart:
		axis := [3]Vector2{{3, 3}, {3, 21}, {21, 21}}
		icon_pen_polyline(frame, pen, axis[:], false, true)
		icon_pen_line(frame, pen, {8, 17}, {8, 11})
		icon_pen_line(frame, pen, {13, 17}, {13, 6})
		icon_pen_line(frame, pen, {18, 17}, {18, 14})
	case .Document:
		outline := [5]Vector2{{14, 2}, {5, 2}, {5, 22}, {19, 22}, {19, 7}}
		icon_pen_polyline(frame, pen, outline[:], true, true)
		fold := [3]Vector2{{14, 2}, {14, 7}, {19, 7}}
		icon_pen_polyline(frame, pen, fold[:], false, true)
		icon_pen_line(frame, pen, {9, 13}, {15, 13})
		icon_pen_line(frame, pen, {9, 17}, {15, 17})
		icon_pen_line(frame, pen, {9, 9}, {10, 9})
	case .Layout_Grid:
		icon_pen_rect(frame, pen, 3, 3, 7, 7, 1)
		icon_pen_rect(frame, pen, 14, 3, 7, 7, 1)
		icon_pen_rect(frame, pen, 14, 14, 7, 7, 1)
		icon_pen_rect(frame, pen, 3, 14, 7, 7, 1)
	case .Layers:
		top := [4]Vector2{{12, 2}, {22, 7}, {12, 12}, {2, 7}}
		icon_pen_polyline(frame, pen, top[:], true, true)
		middle := [3]Vector2{{2, 12}, {12, 17}, {22, 12}}
		icon_pen_polyline(frame, pen, middle[:], false, true)
		bottom := [3]Vector2{{2, 17}, {12, 22}, {22, 17}}
		icon_pen_polyline(frame, pen, bottom[:], false, true)
	case .Swatch:
		// Paint wells are SVG fill="currentColor" dots, the one filled shape.
		icon_pen_circle(frame, pen, {12, 12}, 10)
		wells := [4]Vector2{{8, 9}, {12, 6.5}, {16, 9}, {7.5, 14}}
		for well in wells {
			draw_circle_v(frame, icon_pen_point(pen, well), 1.5 * pen.unit, pen.color)
		}
	case:
		assert(false, "draw_icon_blocks: icon outside group")
	}
}
