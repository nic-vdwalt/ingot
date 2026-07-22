// ingot:gfx — raylib-named 2D shape API tessellated onto the batch renderer.
// Signatures/param order match Odin's vendor:raylib so `rl.Draw*`,
// `rl.*ScissorMode`, and `rl.CheckCollisionPointRec` call sites port unchanged.
// All coordinates are in logical pixels; scissor is converted to framebuffer
// pixels for the render pass.
package gfx

import "core:math"
import wg "vendor:wgpu"

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
	segs := max(segments, 2)
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)

	x, y, w, h := rec.x, rec.y, rec.width, rec.height
	// center + edge rectangles
	push_quad(&g.rend, {x + r, y, w - 2 * r, h}, {0, 0, 1, 1}, c)       // middle
	push_quad(&g.rend, {x, y + r, r, h - 2 * r}, {0, 0, 1, 1}, c)       // left
	push_quad(&g.rend, {x + w - r, y + r, r, h - 2 * r}, {0, 0, 1, 1}, c) // right

	// four corner fans (center at inset corner)
	_corner_fan(&g.rend, {x + r, y + r}, r, 180, 270, segs, c)       // top-left
	_corner_fan(&g.rend, {x + w - r, y + r}, r, 270, 360, segs, c)   // top-right
	_corner_fan(&g.rend, {x + w - r, y + h - r}, r, 0, 90, segs, c)  // bottom-right
	_corner_fan(&g.rend, {x + r, y + h - r}, r, 90, 180, segs, c)    // bottom-left
}

DrawRectangleRoundedLinesEx :: proc(rec: Rectangle, roundness: f32, segments: i32, lineThick: f32, color: Color) {
	r := _corner_radius(rec, roundness)
	segs := max(segments, 2)
	t := lineThick
	x, y, w, h := rec.x, rec.y, rec.width, rec.height
	if r <= 0 {
		DrawRectangleLinesEx(rec, t, color)
		return
	}
	// straight edges (between corner arcs)
	_rect(x + r, y, w - 2 * r, t, color)             // top
	_rect(x + r, y + h - t, w - 2 * r, t, color)     // bottom
	_rect(x, y + r, t, h - 2 * r, color)             // left
	_rect(x + w - t, y + r, t, h - 2 * r, color)     // right
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
_corner_fan :: proc(rend: ^Renderer, center: Vector2, radius: f32, a0, a1: f32, segments: i32, c: [4]f32) {
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
	segs := i32(max(12, radius))
	c := col_f(color)
	batch_set(&g.rend, .Solid, nil)
	_corner_fan(&g.rend, center, radius, 0, 360, segs, c)
}

DrawRing :: proc(center: Vector2, innerRadius, outerRadius, startAngle, endAngle: f32, segments: i32, color: Color) {
	segs := max(segments, 2)
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

@(private)
_scissor_rect :: proc(
	x, y, width, height: i32,
	logical_w, logical_h, attachment_w, attachment_h: f32,
) -> (u32, u32, u32, u32, bool) {
	if width <= 0 || height <= 0 || attachment_w <= 0 || attachment_h <= 0 {
		return 0, 0, 0, 0, false
	}
	assert(logical_w > 0)
	assert(logical_h > 0)
	sx := attachment_w / logical_w
	sy := attachment_h / logical_h
	fx := clamp(f32(x) * sx, 0, attachment_w)
	fy := clamp(f32(y) * sy, 0, attachment_h)
	pw := u32(clamp(f32(width) * sx, 0, attachment_w - fx))
	ph := u32(clamp(f32(height) * sy, 0, attachment_h - fy))
	return u32(fx), u32(fy), pw, ph, pw > 0 && ph > 0
}

BeginScissorMode :: proc(x, y, width, height: i32) {
	if !g.frame.has_frame do return
	_ensure_active_pass()
	if !_active_pass_begun() do return
	pass := active_pass()
	if !g.frame.scissor_empty {
		renderer_flush(&g.rend, pass, .Scissor)
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
		renderer_flush(&g.rend, pass, .Scissor)
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
	return point.x >= rec.x && point.x < rec.x + rec.width &&
	       point.y >= rec.y && point.y < rec.y + rec.height
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
	segs := i32(max(16, radius))
	DrawRing(center, radius - 1, radius, 0, 360, segs, color)
}

// DrawRectangleGradientH draws a rect with a left→right color gradient.
DrawRectangleGradientH :: proc(posX, posY, width, height: i32, left, right: Color) {
	if !g.frame.has_frame do return
	batch_set(&g.rend, .Solid, nil)
	x0, y0 := f32(posX), f32(posY)
	x1, y1 := x0 + f32(width), y0 + f32(height)
	cl := col_f(left)
	cr := col_f(right)
	base := u32(len(g.rend.verts))
	append(&g.rend.verts,
		Vertex{{x0, y0}, cl, {0, 0}},
		Vertex{{x0, y1}, cl, {0, 0}},
		Vertex{{x1, y0}, cr, {0, 0}},
		Vertex{{x1, y1}, cr, {0, 0}},
	)
	append(&g.rend.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

// DrawRectangleGradientV draws a rect with a top→bottom color gradient.
DrawRectangleGradientV :: proc(posX, posY, width, height: i32, top, bottom: Color) {
	if !g.frame.has_frame do return
	batch_set(&g.rend, .Solid, nil)
	x0, y0 := f32(posX), f32(posY)
	x1, y1 := x0 + f32(width), y0 + f32(height)
	ct := col_f(top)
	cb := col_f(bottom)
	base := u32(len(g.rend.verts))
	append(&g.rend.verts,
		Vertex{{x0, y0}, ct, {0, 0}},
		Vertex{{x0, y1}, cb, {0, 0}},
		Vertex{{x1, y0}, ct, {0, 0}},
		Vertex{{x1, y1}, cb, {0, 0}},
	)
	append(&g.rend.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}
