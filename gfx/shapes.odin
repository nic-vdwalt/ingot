// ingot:gfx - raylib-named 2D shape API tessellated onto the batch renderer.
// Signatures/param order match Odin's vendor:raylib so `rl.Draw*`,
// `rl.*ScissorMode`, and `rl.CheckCollisionPointRec` call sites port unchanged.
// All coordinates are in screen-space pixels; scissor is converted to
// framebuffer pixels for the render pass.
package gfx

import "core:math"
import wg "vendor:wgpu"

// SHAPE_SEGMENTS_MAX bounds the tessellation of every curved primitive (Tiger
// Style: put a limit on everything).
//
// Segment counts arrive two ways, and both are unbounded at the call site: a
// caller passes `segments` directly, or it is derived from a radius that grows
// without limit under a zoomed Camera2D. Each segment emits a triangle, so an
// absurd count does not overflow the batch - `_batch_reserve` flushes and
// retries - it converts one draw call into millions of GPU flushes and hangs
// the frame.
//
// 8192 is past the point of visible return: a circle spanning an 8K display is
// about 7680px across, so one segment per pixel of diameter already exceeds
// what the display can resolve, and the worst case costs 8192*3 vertices,
// comfortably inside BATCH_MAX_VERTICES.
SHAPE_SEGMENTS_MAX :: 8192
#assert(SHAPE_SEGMENTS_MAX * 3 <= BATCH_MAX_VERTICES)
#assert(SHAPE_SEGMENTS_MAX * 3 <= BATCH_MAX_INDICES)

// _shape_segments clamps a requested or derived segment count into
// 1..=SHAPE_SEGMENTS_MAX. It clamps rather than asserts because a large count
// is usually a large radius under zoom - ordinary data, not a programmer error
// - and refusing to draw or aborting would both be worse than tessellating at
// the resolution limit.
@(private)
_shape_segments :: proc(requested: i32, minimum: i32) -> i32 {
	assert(minimum >= 1, "_shape_segments: minimum must be at least 1")
	assert(minimum <= SHAPE_SEGMENTS_MAX, "_shape_segments: minimum exceeds the cap")
	segments := clamp(requested, minimum, SHAPE_SEGMENTS_MAX)
	assert(segments >= 1)
	assert(segments <= SHAPE_SEGMENTS_MAX)
	return segments
}

// _shape_segments_for_radius derives a segment count from a radius in logical
// pixels. A NaN radius compares false against every bound, so it falls through
// to `minimum` rather than propagating into the loop count.
@(private)
_shape_segments_for_radius :: proc(radius: f32, minimum: i32) -> i32 {
	assert(minimum >= 1, "_shape_segments_for_radius: minimum must be at least 1")
	if !(radius > f32(minimum)) do return minimum
	if radius >= f32(SHAPE_SEGMENTS_MAX) do return SHAPE_SEGMENTS_MAX
	return _shape_segments(i32(radius), minimum)
}

// _shape_geometry_is_finite is the shared precondition for the curved and
// polygon primitives: a centre and an extent that can actually be rasterised.
//
// A radius from `distance()` of coincident points, or a lerp with a NaN
// parameter, reaches these procedures easily. The tessellation bound already
// treats a non-finite radius as "minimum segments", but the vertices it then
// emits are still NaN, so the count being safe does not make the geometry
// safe. Checked at each primitive's entry, never per segment.
@(private)
_shape_geometry_is_finite :: proc(center: Vector2, extent: f32) -> bool {
	return _f32_is_finite(center.x) && _f32_is_finite(center.y) && _f32_is_finite(extent)
}

// --- filled rectangles -----------------------------------------------------

DrawRectangle :: proc(posX, posY, width, height: i32, color: Color) {
	batch_set(&g.rend, .Solid, nil)
	push_quad(&g.rend, {f32(posX), f32(posY), f32(width), f32(height)}, {0, 0, 1, 1}, col_f(color))
}

DrawRectangleRec :: proc(rec: Rectangle, color: Color) {
	batch_set(&g.rend, .Solid, nil)
	push_quad(&g.rend, rec, {0, 0, 1, 1}, col_f(color))
}

DrawRectangleV :: proc(position, size: Vector2, color: Color) {
	DrawRectangleRec({position.x, position.y, size.x, size.y}, color)
}

// DrawRectanglePro matches raylib: the rectangle is rotated (degrees, clockwise)
// about `rec.xy + origin` after its corners are offset by `-origin`, so `origin`
// is both the pivot and the anchor that lands on `rec.x/rec.y`. Corner math
// mirrors DrawTexturePro.
DrawRectanglePro :: proc(rec: Rectangle, origin: Vector2, rotation: f32, color: Color) {
	assert(
		_shape_geometry_is_finite({rec.x, rec.y}, rec.width) &&
		_f32_is_finite(rec.height) &&
		_f32_is_finite(rotation),
		"DrawRectanglePro: non-finite geometry",
	)
	if rotation == 0 {
		DrawRectangleRec({rec.x - origin.x, rec.y - origin.y, rec.width, rec.height}, color)
		return
	}

	w := rec.width
	h := rec.height
	tl := [2]f32{-origin.x, -origin.y}
	tr := [2]f32{w - origin.x, -origin.y}
	br := [2]f32{w - origin.x, h - origin.y}
	bl := [2]f32{-origin.x, h - origin.y}

	rad := rotation * DEG2RAD
	c := math.cos(rad)
	s := math.sin(rad)
	rot :: proc(p: [2]f32, c, s: f32) -> [2]f32 {
		return {p.x * c - p.y * s, p.x * s + p.y * c}
	}
	tl = rot(tl, c, s); tr = rot(tr, c, s); br = rot(br, c, s); bl = rot(bl, c, s)

	off := [2]f32{rec.x, rec.y}
	top_left := Vector2{tl.x + off.x, tl.y + off.y}
	top_right := Vector2{tr.x + off.x, tr.y + off.y}
	bottom_right := Vector2{br.x + off.x, br.y + off.y}
	bottom_left := Vector2{bl.x + off.x, bl.y + off.y}
	// Reuse the existing triangle submission boundary so this compatibility
	// wrapper does not reach into the default graphics context directly.
	DrawTriangle(top_left, top_right, bottom_right, color)
	DrawTriangle(top_left, bottom_right, bottom_left, color)
}

// --- rectangle outlines ----------------------------------------------------

DrawRectangleLines :: proc(posX, posY, width, height: i32, color: Color) {
	x, y := f32(posX), f32(posY)
	w, h := f32(width), f32(height)
	_rect(x, y, w, 1, color)
	_rect(x, y + h - 1, w, 1, color)
	_rect(x, y, 1, h, color)
	_rect(x + w - 1, y, 1, h, color)
}

DrawRectangleLinesEx :: proc(rec: Rectangle, lineThick: f32, color: Color) {
	t := lineThick
	_rect(rec.x, rec.y, rec.width, t, color)
	_rect(rec.x, rec.y + rec.height - t, rec.width, t, color)
	_rect(rec.x, rec.y + t, t, rec.height - 2 * t, color)
	_rect(rec.x + rec.width - t, rec.y + t, t, rec.height - 2 * t, color)
}

@(private)
_rect :: proc(x, y, w, h: f32, color: Color) {
	batch_set(&g.rend, .Solid, nil)
	push_quad(&g.rend, {x, y, w, h}, {0, 0, 1, 1}, col_f(color))
}

// --- rounded rectangles ----------------------------------------------------

DrawRectangleRounded :: proc(rec: Rectangle, roundness: f32, segments: i32, color: Color) {
	r := _corner_radius(rec, roundness)
	if r <= 0 {
		DrawRectangleRec(rec, color)
		return
	}
	segs := _shape_segments(segments, 2)
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)

	x, y, w, h := rec.x, rec.y, rec.width, rec.height
	// center + edge rectangles
	push_quad(&g.rend, {x + r, y, w - 2 * r, h}, {0, 0, 1, 1}, c) // middle
	push_quad(&g.rend, {x, y + r, r, h - 2 * r}, {0, 0, 1, 1}, c) // left
	push_quad(&g.rend, {x + w - r, y + r, r, h - 2 * r}, {0, 0, 1, 1}, c) // right

	// four corner fans (center at inset corner)
	_corner_fan(&g.rend, {x + r, y + r}, r, 180, 270, segs, c) // top-left
	_corner_fan(&g.rend, {x + w - r, y + r}, r, 270, 360, segs, c) // top-right
	_corner_fan(&g.rend, {x + w - r, y + h - r}, r, 0, 90, segs, c) // bottom-right
	_corner_fan(&g.rend, {x + r, y + h - r}, r, 90, 180, segs, c) // bottom-left
}

DrawRectangleRoundedLinesEx :: proc(
	rec: Rectangle,
	roundness: f32,
	segments: i32,
	lineThick: f32,
	color: Color,
) {
	r := _corner_radius(rec, roundness)
	segs := _shape_segments(segments, 2)
	t := lineThick
	x, y, w, h := rec.x, rec.y, rec.width, rec.height
	if r <= 0 {
		DrawRectangleLinesEx(rec, t, color)
		return
	}
	// straight edges (between corner arcs)
	_rect(x + r, y, w - 2 * r, t, color) // top
	_rect(x + r, y + h - t, w - 2 * r, t, color) // bottom
	_rect(x, y + r, t, h - 2 * r, color) // left
	_rect(x + w - t, y + r, t, h - 2 * r, color) // right
	// corner arcs as thick ring segments
	DrawRing({x + r, y + r}, r - t, r, 180, 270, segs, color)
	DrawRing({x + w - r, y + r}, r - t, r, 270, 360, segs, color)
	DrawRing({x + w - r, y + h - r}, r - t, r, 0, 90, segs, color)
	DrawRing({x + r, y + h - r}, r - t, r, 90, 180, segs, color)
}

@(private)
_corner_radius :: proc(rec: Rectangle, roundness: f32) -> f32 {
	rn := clamp(roundness, 0, 1)
	return rn * min(rec.width, rec.height) / 2.0
}

@(private)
_corner_fan :: proc(
	rend: ^Renderer,
	center: Vector2,
	radius: f32,
	a0, a1: f32,
	segments: i32,
	c: [4]f32,
) {
	assert(rend != nil, "_corner_fan: nil renderer")
	// Every caller routes through _shape_segments, so the loop below is
	// bounded. Asserting it here keeps the bound true for future callers
	// rather than relying on each one to remember.
	assert(segments >= 1, "_corner_fan: segment count must be at least 1")
	assert(segments <= SHAPE_SEGMENTS_MAX, "_corner_fan: unbounded segment count")
	// Non-finite geometry is the silent failure this fans out into: _polar
	// turns it into NaN vertices, the GPU discards the primitives, and the
	// frame comes out blank with nothing logged. Checked once per primitive
	// here rather than per segment, and once for every filled curved shape
	// because they all tessellate through this fan.
	assert(_shape_geometry_is_finite(center, radius), "_corner_fan: non-finite center or radius")
	assert(_f32_is_finite(a0) && _f32_is_finite(a1), "_corner_fan: non-finite sweep angle")
	step := (a1 - a0) / f32(segments)
	prev := _polar(center, radius, a0)
	for i in 1 ..= segments {
		ang := a0 + step * f32(i)
		cur := _polar(center, radius, ang)
		push_tri(rend, center, prev, cur, c)
		prev = cur
	}
}

@(private)
_polar :: proc(center: Vector2, radius, deg: f32) -> [2]f32 {
	rad := deg * math.PI / 180.0
	return {center.x + radius * math.cos(rad), center.y + radius * math.sin(rad)}
}

// --- lines -----------------------------------------------------------------

DrawLine :: proc(startPosX, startPosY, endPosX, endPosY: i32, color: Color) {
	DrawLineEx({f32(startPosX), f32(startPosY)}, {f32(endPosX), f32(endPosY)}, 1.0, color)
}

DrawLineV :: proc(startPos, endPos: Vector2, color: Color) {
	DrawLineEx(startPos, endPos, 1.0, color)
}

DrawLineEx :: proc(startPos, endPos: Vector2, thick: f32, color: Color) {
	dx := endPos.x - startPos.x
	dy := endPos.y - startPos.y
	length := math.sqrt(dx * dx + dy * dy)
	if length <= 0 do return
	// perpendicular offset
	nx := -dy / length * thick / 2.0
	ny := dx / length * thick / 2.0
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	a := [2]f32{startPos.x + nx, startPos.y + ny}
	b := [2]f32{startPos.x - nx, startPos.y - ny}
	cc := [2]f32{endPos.x - nx, endPos.y - ny}
	d := [2]f32{endPos.x + nx, endPos.y + ny}
	push_tri(&g.rend, a, b, cc, c)
	push_tri(&g.rend, a, cc, d, c)
}

// --- circles / rings -------------------------------------------------------

DrawCircle :: proc(centerX, centerY: i32, radius: f32, color: Color) {
	DrawCircleV({f32(centerX), f32(centerY)}, radius, color)
}

DrawCircleV :: proc(center: Vector2, radius: f32, color: Color) {
	segs := _shape_segments_for_radius(radius, 12)
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	_corner_fan(&g.rend, center, radius, 0, 360, segs, c)
}

DrawRing :: proc(
	center: Vector2,
	innerRadius, outerRadius, startAngle, endAngle: f32,
	segments: i32,
	color: Color,
) {
	assert(
		_shape_geometry_is_finite(center, innerRadius) && _f32_is_finite(outerRadius),
		"DrawRing: non-finite center or radius",
	)
	segs := _shape_segments(segments, 2)
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	step := (endAngle - startAngle) / f32(segs)
	for i in 0 ..< segs {
		a0 := startAngle + step * f32(i)
		a1 := a0 + step
		i0 := _polar(center, innerRadius, a0)
		i1 := _polar(center, innerRadius, a1)
		o0 := _polar(center, outerRadius, a0)
		o1 := _polar(center, outerRadius, a1)
		push_tri(&g.rend, i0, o0, o1, c)
		push_tri(&g.rend, i0, o1, i1, c)
	}
}

// --- scissor ---------------------------------------------------------------

// _scissor_rect converts a logical clip rect into attachment pixels.
//
// flip_y selects the attachment's origin. The window pass and WebGPU scissor
// rects both count y down from the top, so the window path passes false. A
// render target is drawn through a y-flipped projection (RT_PROJECTION_Y_FLIP,
// render_target.odin) so its logical y=0 is the attachment's *bottom* row;
// without the flip a clipped widget inside a render target kept its size but
// mirrored its position, which hid short bands such as a text input's inner
// clip entirely.
@(private)
_scissor_rect :: proc(
	x, y, width, height: i32,
	logical_w, logical_h, attachment_w, attachment_h: f32,
	flip_y: bool = false,
) -> (
	u32,
	u32,
	u32,
	u32,
	bool,
) {
	if width <= 0 || height <= 0 || attachment_w <= 0 || attachment_h <= 0 {
		return 0, 0, 0, 0, false
	}
	assert(logical_w > 0)
	assert(logical_h > 0)
	sx := f64(attachment_w) / f64(logical_w)
	sy := f64(attachment_h) / f64(logical_h)
	x0 := u32(math.floor(clamp(f64(x) * sx, 0, f64(attachment_w))))
	x1 := u32(math.ceil(clamp(f64(x) + f64(width), 0, f64(logical_w)) * sx))
	y0 := u32(math.floor(clamp(f64(y) * sy, 0, f64(attachment_h))))
	y1 := u32(math.ceil(clamp(f64(y) + f64(height), 0, f64(logical_h)) * sy))
	pw := x1 - x0
	ph := y1 - y0
	if flip_y {
		top := u32(attachment_h) - y1
		return x0, top, pw, ph, pw > 0 && ph > 0
	}
	return x0, y0, pw, ph, pw > 0 && ph > 0
}

BeginScissorMode :: proc(x, y, width, height: i32) {
	if !g.frame.has_frame do return
	_ensure_active_pass()
	if !_active_pass_begun() do return
	pass := active_pass()
	if !g.frame.scissor_empty {
		renderer_flush(default_context(), &g.rend, pass, .Scissor)
	} else {
		clear(&g.rend.verts)
		clear(&g.rend.indices)
	}
	fbw, fbh := _attachment_px()
	logical_w, logical_h := fbw, fbh
	if g.frame.rt == 0 {
		logical_w = f32(max(g.width, 1))
		logical_h = f32(max(g.height, 1))
	}
	px, py, pw, ph, visible := _scissor_rect(
		x,
		y,
		width,
		height,
		logical_w,
		logical_h,
		fbw,
		fbh,
		g.frame.rt != 0,
	)
	g.frame.scissor_empty = !visible
	if visible {
		assert(pw > 0)
		assert(ph > 0)
		wg.RenderPassEncoderSetScissorRect(pass, px, py, pw, ph)
	}
	if g.frame.rt == 0 {
		g.frame.scissor_on = true
		g.frame.sc_x, g.frame.sc_y, g.frame.sc_w, g.frame.sc_h = px, py, pw, ph
	}
}

EndScissorMode :: proc() {
	if !g.frame.has_frame || !_active_pass_begun() do return
	pass := active_pass()
	if !g.frame.scissor_empty {
		renderer_flush(default_context(), &g.rend, pass, .Scissor)
	} else {
		clear(&g.rend.verts)
		clear(&g.rend.indices)
	}
	fbw, fbh := _attachment_px()
	assert(fbw > 0)
	assert(fbh > 0)
	wg.RenderPassEncoderSetScissorRect(pass, 0, 0, u32(fbw), u32(fbh))
	g.frame.scissor_empty = false
	if g.frame.rt == 0 do g.frame.scissor_on = false
}

// --- collision helper ------------------------------------------------------

CheckCollisionPointRec :: proc(point: Vector2, rec: Rectangle) -> bool {
	return(
		point.x >= rec.x &&
		point.x < rec.x + rec.width &&
		point.y >= rec.y &&
		point.y < rec.y + rec.height \
	)
}

// --- triangles / gradients -------------------------------------------------

DrawTriangle :: proc(v1, v2, v3: Vector2, color: Color) {
	batch_set(&g.rend, .Solid, nil)
	push_tri(&g.rend, v1, v2, v3, col_f(color))
}

DrawCircleLines :: proc(centerX, centerY: i32, radius: f32, color: Color) {
	DrawCircleLinesV({f32(centerX), f32(centerY)}, radius, color)
}

DrawCircleLinesV :: proc(center: Vector2, radius: f32, color: Color) {
	segs := _shape_segments_for_radius(radius, 16)
	DrawRing(center, radius - 1, radius, 0, 360, segs, color)
}

// _gradient_quad emits a rect whose four corners carry independent colors,
// given in order tl, tr, br, bl. It goes through the batch's model transform
// like every other primitive, so gradients pan, zoom, and rotate with a
// Camera2D instead of staying pinned to the screen.
@(private)
_gradient_quad :: proc(rec: Rectangle, tl, tr, br, bl: [4]f32) {
	if !g.frame.has_frame do return
	batch_set(&g.rend, .Solid, nil)
	_emit_gradient_quad(&g.rend, rec, tl, tr, br, bl)
}

@(private)
_gradient_v :: proc(rec: Rectangle, top, bottom: Color) {
	color_top := col_f(top)
	color_bottom := col_f(bottom)
	_gradient_quad(rec, color_top, color_top, color_bottom, color_bottom)
}

@(private)
_emit_gradient_v :: proc(r: ^Renderer, rec: Rectangle, top, bottom: Color) {
	assert(r != nil, "_emit_gradient_v: nil renderer")
	assert(rec.width >= 0 && rec.height >= 0, "_emit_gradient_v: negative size")
	color_top := col_f(top)
	color_bottom := col_f(bottom)
	_emit_gradient_quad(r, rec, color_top, color_top, color_bottom, color_bottom)
}

@(private)
_emit_gradient_quad :: proc(r: ^Renderer, rec: Rectangle, tl, tr, br, bl: [4]f32) {
	assert(r != nil, "_emit_gradient_quad: nil renderer")
	if !_batch_reserve(r, 4, 6) do return
	transform := r.model_xf
	x0, y0 := rec.x, rec.y
	x1, y1 := rec.x + rec.width, rec.y + rec.height
	p_tl := _affine_apply(transform, {x0, y0})
	p_tr := _affine_apply(transform, {x1, y0})
	p_br := _affine_apply(transform, {x1, y1})
	p_bl := _affine_apply(transform, {x0, y1})
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{p_tl, tl, {0, 0}, .Solid},
		Vertex{p_bl, bl, {0, 0}, .Solid},
		Vertex{p_tr, tr, {0, 0}, .Solid},
		Vertex{p_br, br, {0, 0}, .Solid},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

// DrawRectangleGradientH draws a rect with a left→right color gradient.
DrawRectangleGradientH :: proc(posX, posY, width, height: i32, left, right: Color) {
	rec := Rectangle{f32(posX), f32(posY), f32(width), f32(height)}
	cl := col_f(left)
	cr := col_f(right)
	_gradient_quad(rec, cl, cr, cr, cl)
}

// DrawRectangleGradientV draws a rect with a top→bottom color gradient.
DrawRectangleGradientV :: proc(posX, posY, width, height: i32, top, bottom: Color) {
	rec := Rectangle{f32(posX), f32(posY), f32(width), f32(height)}
	_gradient_v(rec, top, bottom)
}

// DrawRectangleGradientEx draws a rect with an independent color per corner.
// raylib's parameter order is topLeft, bottomLeft, topRight, bottomRight.
DrawRectangleGradientEx :: proc(
	rec: Rectangle,
	topLeft, bottomLeft, topRight, bottomRight: Color,
) {
	_gradient_quad(rec, col_f(topLeft), col_f(topRight), col_f(bottomRight), col_f(bottomLeft))
}

// --- pixels ----------------------------------------------------------------

DrawPixel :: proc(posX, posY: i32, color: Color) {
	DrawPixelV({f32(posX), f32(posY)}, color)
}

DrawPixelV :: proc(position: Vector2, color: Color) {
	_rect(position.x, position.y, 1, 1, color)
}

// --- ellipses --------------------------------------------------------------

// _polar_ellipse is _polar with independent radii, for ellipse and sector work.
@(private)
_polar_ellipse :: proc(center: Vector2, radiusH, radiusV, deg: f32) -> [2]f32 {
	rad := deg * math.PI / 180.0
	return {center.x + radiusH * math.cos(rad), center.y + radiusV * math.sin(rad)}
}

// _ellipse_segments picks a tessellation fine enough for the larger radius, so
// a wide flat ellipse does not become visibly polygonal along its long axis,
// bounded by SHAPE_SEGMENTS_MAX.
@(private)
_ellipse_segments :: proc(radiusH, radiusV: f32) -> i32 {
	return _shape_segments_for_radius(max(abs(radiusH), abs(radiusV)), 16)
}

DrawEllipse :: proc(centerX, centerY: i32, radiusH, radiusV: f32, color: Color) {
	assert(_f32_is_finite(radiusH) && _f32_is_finite(radiusV), "DrawEllipse: non-finite radius")
	center := Vector2{f32(centerX), f32(centerY)}
	segments := _ellipse_segments(radiusH, radiusV)
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	step := 360.0 / f32(segments)
	prev := _polar_ellipse(center, radiusH, radiusV, 0)
	for i in 1 ..= segments {
		cur := _polar_ellipse(center, radiusH, radiusV, step * f32(i))
		push_tri(&g.rend, center, prev, cur, c)
		prev = cur
	}
}

DrawEllipseLines :: proc(centerX, centerY: i32, radiusH, radiusV: f32, color: Color) {
	assert(
		_f32_is_finite(radiusH) && _f32_is_finite(radiusV),
		"DrawEllipseLines: non-finite radius",
	)
	center := Vector2{f32(centerX), f32(centerY)}
	segments := _ellipse_segments(radiusH, radiusV)
	step := 360.0 / f32(segments)
	prev := _polar_ellipse(center, radiusH, radiusV, 0)
	for i in 1 ..= segments {
		cur := _polar_ellipse(center, radiusH, radiusV, step * f32(i))
		DrawLineEx(prev, cur, 1, color)
		prev = cur
	}
}

// --- circle sectors --------------------------------------------------------

DrawCircleSector :: proc(
	center: Vector2,
	radius: f32,
	startAngle, endAngle: f32,
	segments: i32,
	color: Color,
) {
	segs := _shape_segments(segments, 1)
	batch_set(&g.rend, .Solid, nil)
	_corner_fan(&g.rend, center, radius, startAngle, endAngle, segs, col_f(color))
}

// DrawCircleSectorLines outlines the sector: the arc plus the two radii that
// close it back to the center, which is what makes it a sector rather than an
// arc.
DrawCircleSectorLines :: proc(
	center: Vector2,
	radius: f32,
	startAngle, endAngle: f32,
	segments: i32,
	color: Color,
) {
	assert(
		_shape_geometry_is_finite(center, radius),
		"DrawCircleSectorLines: non-finite center or radius",
	)
	segs := _shape_segments(segments, 1)
	step := (endAngle - startAngle) / f32(segs)
	first := _polar(center, radius, startAngle)
	prev := first
	for i in 1 ..= segs {
		cur := _polar(center, radius, startAngle + step * f32(i))
		DrawLineEx(prev, cur, 1, color)
		prev = cur
	}
	DrawLineEx(center, first, 1, color)
	DrawLineEx(center, prev, 1, color)
}

// --- regular polygons ------------------------------------------------------

DrawPoly :: proc(center: Vector2, sides: i32, radius: f32, rotation: f32, color: Color) {
	if sides < 3 do return
	segs := _shape_segments(sides, 3)
	batch_set(&g.rend, .Solid, nil)
	_corner_fan(&g.rend, center, radius, rotation, rotation + 360, segs, col_f(color))
}

DrawPolyLines :: proc(center: Vector2, sides: i32, radius: f32, rotation: f32, color: Color) {
	DrawPolyLinesEx(center, sides, radius, rotation, 1, color)
}

DrawPolyLinesEx :: proc(
	center: Vector2,
	sides: i32,
	radius: f32,
	rotation: f32,
	lineThick: f32,
	color: Color,
) {
	assert(
		_shape_geometry_is_finite(center, radius),
		"DrawPolyLinesEx: non-finite center or radius",
	)
	assert(_f32_is_finite(lineThick), "DrawPolyLinesEx: non-finite line thickness")
	if sides < 3 do return
	segs := _shape_segments(sides, 3)
	step := 360.0 / f32(segs)
	prev := _polar(center, radius, rotation)
	for i in 1 ..= segs {
		cur := _polar(center, radius, rotation + step * f32(i))
		DrawLineEx(prev, cur, lineThick, color)
		prev = cur
	}
}

// --- triangle fans and strips ----------------------------------------------

// SHAPE_POINTS_MAX bounds a single fan or strip. Unlike a segment count this
// cannot be clamped - dropping points would silently corrupt the caller's
// shape - so it is asserted instead. The bound is the batch's own vertex
// capacity: one fan needing more vertices than the entire batch can hold is a
// caller passing a bad count, not a legitimate 2D primitive.
SHAPE_POINTS_MAX :: BATCH_MAX_VERTICES / 3
#assert(SHAPE_POINTS_MAX >= SHAPE_SEGMENTS_MAX)

// DrawTriangleFan draws points[0] joined to every consecutive pair after it.
//
// `points` is a raw multi-pointer, so this cannot verify it really holds
// `pointCount` elements; that stays the caller's contract. What it can check
// is the part that is unambiguously a programmer error.
DrawTriangleFan :: proc(points: [^]Vector2, pointCount: i32, color: Color) {
	assert(pointCount >= 0, "DrawTriangleFan: negative point count")
	assert(pointCount <= SHAPE_POINTS_MAX, "DrawTriangleFan: point count exceeds the batch")
	if pointCount > 0 do assert(points != nil, "DrawTriangleFan: nil points with a positive count")
	// Too few points to form a triangle is ordinary empty input, not an
	// error: raylib draws nothing and so does this.
	if points == nil || pointCount < 3 do return
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	for i in 1 ..< pointCount - 1 {
		push_tri(&g.rend, points[0], points[i], points[i + 1], c)
	}
}

// DrawTriangleStrip draws each consecutive triple, alternating winding so the
// strip stays consistently oriented the way raylib's does.
DrawTriangleStrip :: proc(points: [^]Vector2, pointCount: i32, color: Color) {
	assert(pointCount >= 0, "DrawTriangleStrip: negative point count")
	assert(pointCount <= SHAPE_POINTS_MAX, "DrawTriangleStrip: point count exceeds the batch")
	if pointCount > 0 {
		assert(points != nil, "DrawTriangleStrip: nil points with a positive count")
	}
	if points == nil || pointCount < 3 do return
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	for i in 2 ..< pointCount {
		if i % 2 == 0 {
			push_tri(&g.rend, points[i], points[i - 2], points[i - 1], c)
		} else {
			push_tri(&g.rend, points[i], points[i - 1], points[i - 2], c)
		}
	}
}
