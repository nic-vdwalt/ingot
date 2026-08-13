package gfx

Vec2 :: Vector2
Vec3 :: Vector3
RGBA :: Color
Rect :: Rectangle

@(private = "package")
Frame :: struct {
	owner:      ^Context,
	epoch:      u64,
	generation: u64,
	active:     bool,
}

@(private = "package")
begin_frame :: proc() -> (Frame, bool) {
	return context_begin_frame(default_context())
}

@(private = "package")
context_begin_frame :: proc(ctx: ^Context) -> (Frame, bool) {
	if ctx == nil do return {}, false
	if !ctx.initialized || ctx.frame_active do return {}, false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	BeginDrawing()
	if !ctx.frame.has_frame {
		EndDrawing()
		return {}, false
	}
	ctx.frame_generation += 1
	ctx.frame_active = true
	_ergonomic_frame_opened(ctx)
	frame := Frame {
		owner      = ctx,
		epoch      = ctx.epoch,
		generation = ctx.frame_generation,
		active     = true,
	}
	assert(frame.generation > 0)
	assert(frame.active)
	return frame, true
}

@(private = "package")
end_frame :: proc(frame: ^Frame) {
	assert(frame != nil)
	assert(frame.active)
	if !_frame_valid(frame) do return
	ctx := frame.owner
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	EndDrawing()
	frame.active = false
	ctx.frame_active = false
	_ergonomic_frame_closed(ctx)
	assert(!frame.active)
	assert(!ctx.frame_active)
}

@(private = "package")
clear_frame :: proc(frame: ^Frame, color: RGBA) {
	assert(frame != nil)
	assert(frame.active)
	if !_frame_valid(frame) do return
	ctx := frame.owner
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	ClearBackground(color)
	assert(frame.generation == ctx.frame_generation)
}

@(private = "package")
draw_rect :: proc(frame: ^Frame, rect: Rect, color: RGBA) {
	assert(frame != nil)
	assert(rect.width >= 0 && rect.height >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRectangleRec(rect, color)
	assert(frame.active)
}

@(private = "package")
draw_line :: proc(frame: ^Frame, start, end: Vec2, thick: f32, color: RGBA) {
	assert(frame != nil)
	assert(thick >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawLineEx(start, end, thick, color)
	assert(frame.active)
}

@(private = "package")
draw_circle :: proc(frame: ^Frame, center: Vec2, radius: f32, color: RGBA) {
	assert(frame != nil)
	assert(radius >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawCircleV(center, radius, color)
	assert(frame.active)
}

@(private = "package")
draw_texture :: proc(
	frame: ^Frame,
	texture: Texture2D,
	source, dest: Rect,
	origin: Vec2,
	rotation: f32,
	tint: RGBA,
) {
	assert(frame != nil)
	assert(texture.id != 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawTexturePro(texture, source, dest, origin, rotation, tint)
	assert(frame.active)
}

@(private = "package")
draw_text :: proc(
	frame: ^Frame,
	font: Font,
	text: cstring,
	position: Vec2,
	font_size, spacing: f32,
	tint: RGBA,
) {
	assert(frame != nil)
	assert(text != nil)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawTextEx(font, text, position, font_size, spacing, tint)
	assert(frame.active)
}

@(private = "package")
frame_draw_rectangle_lines :: proc(frame: ^Frame, rect: Rect, thick: f32, color: RGBA) {
	assert(frame != nil && thick >= 0, "frame_draw_rectangle_lines: invalid argument")
	assert(rect.width >= 0 && rect.height >= 0, "frame_draw_rectangle_lines: negative size")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRectangleLinesEx(rect, thick, color)
}

@(private = "package")
frame_draw_rectangle_rounded :: proc(
	frame: ^Frame,
	rect: Rect,
	roundness: f32,
	segments: i32,
	color: RGBA,
) {
	assert(frame != nil && roundness >= 0, "frame_draw_rectangle_rounded: invalid argument")
	assert(rect.width >= 0 && rect.height >= 0, "frame_draw_rectangle_rounded: negative size")
	assert(segments >= 0, "frame_draw_rectangle_rounded: negative segments")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRectangleRounded(rect, roundness, segments, color)
}

@(private = "package")
frame_draw_rectangle_rounded_lines :: proc(
	frame: ^Frame,
	rect: Rect,
	roundness: f32,
	segments: i32,
	thick: f32,
	color: RGBA,
) {
	assert(frame != nil && roundness >= 0, "frame_draw_rectangle_rounded_lines: invalid argument")
	assert(
		rect.width >= 0 && rect.height >= 0,
		"frame_draw_rectangle_rounded_lines: negative size",
	)
	assert(segments >= 0 && thick >= 0, "frame_draw_rectangle_rounded_lines: invalid stroke")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRectangleRoundedLinesEx(rect, roundness, segments, thick, color)
}

@(private = "package")
frame_draw_rectangle_gradient_v :: proc(frame: ^Frame, rect: Rect, top, bottom: RGBA) {
	assert(frame != nil, "frame_draw_rectangle_gradient_v: nil frame")
	assert(rect.width >= 0 && rect.height >= 0, "frame_draw_rectangle_gradient_v: negative size")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	_gradient_v(rect, top, bottom)
}

@(private = "package")
frame_draw_circle_lines :: proc(frame: ^Frame, center: Vec2, radius: f32, color: RGBA) {
	assert(frame != nil && radius >= 0, "frame_draw_circle_lines: invalid argument")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawCircleLinesV(center, radius, color)
}

@(private = "package")
frame_draw_ring :: proc(
	frame: ^Frame,
	center: Vec2,
	inner_radius, outer_radius, start_angle, end_angle: f32,
	segments: i32,
	color: RGBA,
) {
	assert(frame != nil && inner_radius >= 0, "frame_draw_ring: invalid argument")
	assert(outer_radius >= inner_radius && segments >= 0, "frame_draw_ring: invalid geometry")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRing(center, inner_radius, outer_radius, start_angle, end_angle, segments, color)
}

@(private = "package")
frame_draw_triangle :: proc(frame: ^Frame, p0, p1, p2: Vec2, color: RGBA) {
	assert(frame != nil, "frame_draw_triangle: nil frame")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawTriangle(p0, p1, p2, color)
	assert(frame.active)
}

@(private = "package")
frame_draw_codepoint :: proc(
	frame: ^Frame,
	font: Font,
	codepoint: rune,
	position: Vec2,
	font_size: f32,
	tint: RGBA,
) {
	assert(frame != nil && font_size >= 0, "frame_draw_codepoint: invalid argument")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawTextCodepoint(font, codepoint, position, font_size, tint)
}

@(private = "package")
frame_scissor_begin :: proc(frame: ^Frame, x, y, width, height: i32) {
	assert(frame != nil, "frame_scissor_begin: nil frame")
	assert(width >= 0 && height >= 0, "frame_scissor_begin: negative size")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	BeginScissorMode(x, y, width, height)
}

@(private = "package")
frame_scissor_end :: proc(frame: ^Frame) {
	assert(frame != nil, "frame_scissor_end: nil frame")
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	EndScissorMode()
	assert(frame.active)
}

measure_text :: proc(font: Font, text: cstring, font_size, spacing: f32) -> Vec2 {
	return context_measure_text(default_context(), font, text, font_size, spacing)
}

context_measure_text :: proc(
	ctx: ^Context,
	font: Font,
	text: cstring,
	font_size, spacing: f32,
) -> Vec2 {
	assert(ctx != nil && text != nil)
	assert(font_size >= 0)
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	result := MeasureTextEx(font, text, font_size, spacing)
	assert(result.x >= 0)
	return result
}

key_down :: proc(key: KeyboardKey) -> bool {
	return context_key_down(default_context(), key)
}

context_key_down :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsKeyDown(key)
}

key_pressed :: proc(key: KeyboardKey) -> bool {
	return context_key_pressed(default_context(), key)
}

context_key_pressed :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsKeyPressed(key)
}

mouse_position :: proc() -> Vec2 {
	return context_mouse_position(default_context())
}

context_mouse_position :: proc(ctx: ^Context) -> Vec2 {
	if ctx == nil do return {}
	return ctx.inp.mouse
}

@(private = "package")
frame_context :: proc(frame: ^Frame) -> ^Context {
	if !_frame_valid(frame) do return nil
	return frame.owner
}

@(private)
_frame_valid :: proc(frame: ^Frame) -> bool {
	assert(frame != nil)
	ctx := frame.owner
	if ctx == nil do return false
	if !frame.active || !ctx.frame_active do return false
	if frame.epoch != ctx.epoch do return false
	if frame.generation != ctx.frame_generation do return false
	assert(ctx.frame.has_frame)
	return ctx.frame.has_frame
}
