package ui

import "core:math"

// Icons are authored in the 24-unit viewBox that Lucide and Feather use, so
// glyph coordinates read like the SVG they imitate and every icon shares one
// grid, one stroke weight, and one padding.
ICON_VIEWBOX :: f32(24)
// The viewBox covers this share of the shorter rect side. Callers pass rects
// from tight nav slots to whole buttons; 0.8 keeps the drawn content (units
// 2..22) near the 0.64 extent the previous glyphs used, so no call site moves.
ICON_VIEWBOX_FRACTION :: f32(0.8)
// SVG stroke-width in viewBox units.
ICON_STROKE_UNITS :: f32(2)
// Small icons would otherwise thin below the weight of adjacent text strokes.
ICON_STROKE_MIN_LOGICAL :: f32(1.5)
// The gear outline is the largest polyline any glyph needs.
ICON_POLYLINE_POINTS_MAX :: 32
// 15-degree steps keep ellipse butt joins below one pixel of error.
ICON_ELLIPSE_POINTS :: 24
ICON_ARC_SEGMENTS_MIN :: i32(6)
ICON_ARC_SEGMENTS_MAX :: i32(48)
// Per-icon paint bound; draw_icon_frame asserts every glyph stays within it so
// a frame full of icons cannot crowd other widgets out of the paint list.
ICON_COMMANDS_MAX :: 96

#assert(ICON_ELLIPSE_POINTS <= ICON_POLYLINE_POINTS_MAX)
#assert(ICON_ARC_SEGMENTS_MIN <= ICON_ARC_SEGMENTS_MAX)

// Icon_Pen maps viewBox units to screen pixels and carries the one stroke
// every primitive uses. The 2D renderer has no stroke caps, joins, or paths,
// so the pen emulates SVG `stroke-linecap: round` and `stroke-linejoin: round`
// by placing a stroke-wide dot at every end point and vertex. Theme inks are
// opaque, so the overlap is invisible; a translucent ink shows darker joins.
Icon_Pen :: struct {
	origin: Vector2,
	unit:   f32,
	stroke: f32,
	color:  Color,
}

icon_pen_make :: proc(frame: ^Ui_Frame, rect: Rect_I32, color: Color) -> Icon_Pen {
	assert(frame != nil && frame.open, "icon_pen_make: invalid frame")
	assert(rect.w > 0 && rect.h > 0, "icon_pen_make: degenerate rect")
	side := f32(min(rect.w, rect.h))
	unit := side * ICON_VIEWBOX_FRACTION / ICON_VIEWBOX
	center := Vector2{f32(rect.x) + f32(rect.w) * 0.5, f32(rect.y) + f32(rect.h) * 0.5}
	stroke := max(ICON_STROKE_UNITS * unit, ui_frame_scf(frame, ICON_STROKE_MIN_LOGICAL))
	pen := Icon_Pen {
		origin = center - ICON_VIEWBOX * 0.5 * unit,
		unit   = unit,
		stroke = stroke,
		color  = color,
	}
	assert(pen.unit > 0 && pen.stroke > 0, "icon_pen_make: empty pen")
	return pen
}

icon_pen_point :: proc(pen: Icon_Pen, point: Vector2) -> Vector2 {
	assert(pen.unit > 0, "icon_pen_point: empty pen")
	assert(
		scale_f32_is_finite(point.x) && scale_f32_is_finite(point.y),
		"icon_pen_point: non-finite point",
	)
	return pen.origin + point * pen.unit
}

// icon_pen_dot is the round cap and round join: a disc one stroke wide.
icon_pen_dot :: proc(frame: ^Ui_Frame, pen: Icon_Pen, point: Vector2) {
	assert(frame != nil && frame.open, "icon_pen_dot: invalid frame")
	assert(pen.stroke > 0, "icon_pen_dot: empty pen")
	draw_circle_v(frame, icon_pen_point(pen, point), pen.stroke * 0.5, pen.color)
}

icon_pen_line :: proc(frame: ^Ui_Frame, pen: Icon_Pen, a, b: Vector2) {
	assert(frame != nil && frame.open, "icon_pen_line: invalid frame")
	assert(pen.stroke > 0, "icon_pen_line: empty pen")
	draw_line_ex(frame, icon_pen_point(pen, a), icon_pen_point(pen, b), pen.stroke, pen.color)
	icon_pen_dot(frame, pen, a)
	icon_pen_dot(frame, pen, b)
}

// icon_pen_polyline is the SVG <polyline>/<polygon>. Without round joins only an
// open path's two ends are capped; that suits dense sampled curves, whose butt
// joins are already seamless, at half the command cost.
icon_pen_polyline :: proc(
	frame: ^Ui_Frame,
	pen: Icon_Pen,
	points: []Vector2,
	closed, round_joins: bool,
) {
	assert(frame != nil && frame.open, "icon_pen_polyline: invalid frame")
	assert(pen.stroke > 0, "icon_pen_polyline: empty pen")
	assert(
		len(points) >= 2 && len(points) <= ICON_POLYLINE_POINTS_MAX,
		"icon_pen_polyline: point count out of bounds",
	)
	count := len(points)
	segments := count - 1
	if closed do segments = count
	for index in 0 ..< segments {
		a := icon_pen_point(pen, points[index])
		b := icon_pen_point(pen, points[(index + 1) % count])
		draw_line_ex(frame, a, b, pen.stroke, pen.color)
	}
	if round_joins {
		for point in points do icon_pen_dot(frame, pen, point)
	} else if !closed {
		icon_pen_dot(frame, pen, points[0])
		icon_pen_dot(frame, pen, points[count - 1])
	}
}

// icon_pen_polar returns a viewBox point using the renderer's ring convention:
// degrees, 0 on +x, increasing clockwise on screen because y points down.
icon_pen_polar :: proc(center: Vector2, radius, degrees: f32) -> Vector2 {
	assert(radius >= 0, "icon_pen_polar: negative radius")
	assert(scale_f32_is_finite(degrees), "icon_pen_polar: non-finite angle")
	radians := degrees * math.PI / 180
	return center + {radius * math.cos(radians), radius * math.sin(radians)}
}

@(private = "file")
icon_pen_ring :: proc(frame: ^Ui_Frame, pen: Icon_Pen, center: Vector2, radius, a0, a1: f32) {
	assert(frame != nil && frame.open, "icon_pen_ring: invalid frame")
	assert(radius > 0 && a1 > a0 && a1 - a0 <= 360, "icon_pen_ring: invalid arc")
	pixels := radius * pen.unit
	half := pen.stroke * 0.5
	segments := clamp(i32((a1 - a0) / 360 * pixels), ICON_ARC_SEGMENTS_MIN, ICON_ARC_SEGMENTS_MAX)
	draw_ring(
		frame,
		icon_pen_point(pen, center),
		max(pixels - half, 0),
		pixels + half,
		a0,
		a1,
		segments,
		pen.color,
	)
}

// icon_pen_arc strokes a circular arc; open arcs get round caps because the
// renderer's ring ends are cut flat.
icon_pen_arc :: proc(
	frame: ^Ui_Frame,
	pen: Icon_Pen,
	center: Vector2,
	radius, start_degrees, end_degrees: f32,
) {
	assert(frame != nil && frame.open, "icon_pen_arc: invalid frame")
	assert(radius > 0, "icon_pen_arc: non-positive radius")
	assert(end_degrees > start_degrees, "icon_pen_arc: empty sweep")
	assert(end_degrees - start_degrees <= 360, "icon_pen_arc: sweep over a full turn")
	icon_pen_ring(frame, pen, center, radius, start_degrees, end_degrees)
	if end_degrees - start_degrees < 360 {
		icon_pen_dot(frame, pen, icon_pen_polar(center, radius, start_degrees))
		icon_pen_dot(frame, pen, icon_pen_polar(center, radius, end_degrees))
	}
}

icon_pen_circle :: proc(frame: ^Ui_Frame, pen: Icon_Pen, center: Vector2, radius: f32) {
	assert(frame != nil && frame.open, "icon_pen_circle: invalid frame")
	assert(radius > 0, "icon_pen_circle: non-positive radius")
	icon_pen_arc(frame, pen, center, radius, 0, 360)
}

// icon_pen_rect is the SVG <rect rx>. Rounded corners are quarter rings whose
// flat ends meet the straight edges exactly, so they need no caps.
icon_pen_rect :: proc(frame: ^Ui_Frame, pen: Icon_Pen, x, y, w, h, rx: f32) {
	assert(frame != nil && frame.open, "icon_pen_rect: invalid frame")
	assert(w > 0 && h > 0, "icon_pen_rect: empty rect")
	assert(rx >= 0 && rx <= min(w, h) * 0.5, "icon_pen_rect: corner radius out of range")
	right := x + w
	bottom := y + h
	if rx == 0 {
		corners := [4]Vector2{{x, y}, {right, y}, {right, bottom}, {x, bottom}}
		icon_pen_polyline(frame, pen, corners[:], true, true)
		return
	}
	edges := [4][2]Vector2 {
		{{x + rx, y}, {right - rx, y}},
		{{right, y + rx}, {right, bottom - rx}},
		{{right - rx, bottom}, {x + rx, bottom}},
		{{x, bottom - rx}, {x, y + rx}},
	}
	for edge in edges {
		a := icon_pen_point(pen, edge[0])
		b := icon_pen_point(pen, edge[1])
		draw_line_ex(frame, a, b, pen.stroke, pen.color)
	}
	icon_pen_ring(frame, pen, {x + rx, y + rx}, rx, 180, 270)
	icon_pen_ring(frame, pen, {right - rx, y + rx}, rx, 270, 360)
	icon_pen_ring(frame, pen, {right - rx, bottom - rx}, rx, 0, 90)
	icon_pen_ring(frame, pen, {x + rx, bottom - rx}, rx, 90, 180)
}

icon_pen_ellipse :: proc(frame: ^Ui_Frame, pen: Icon_Pen, center: Vector2, rx, ry: f32) {
	assert(frame != nil && frame.open, "icon_pen_ellipse: invalid frame")
	assert(rx > 0 && ry > 0, "icon_pen_ellipse: non-positive radius")
	points: [ICON_ELLIPSE_POINTS]Vector2
	for index in 0 ..< ICON_ELLIPSE_POINTS {
		radians := f32(index) * 2 * math.PI / f32(ICON_ELLIPSE_POINTS)
		points[index] = center + {rx * math.cos(radians), ry * math.sin(radians)}
	}
	icon_pen_polyline(frame, pen, points[:], true, false)
}
