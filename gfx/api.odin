package gfx

Vec2 :: Vector2
Vec3 :: Vector3
RGBA :: Color
Rect :: Rectangle

Frame :: struct {
	owner:      ^Context,
	epoch:      u64,
	generation: u64,
	active:     bool,
}

begin_frame :: proc() -> (Frame, bool) {
	return context_begin_frame(default_context())
}

context_begin_frame :: proc(ctx: ^Context) -> (Frame, bool) {
	if ctx == nil do return {}, false
	if !ctx.initialized || ctx.frame_active do return {}, false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	BeginDrawing()
	if !ctx.frame.has_frame do return {}, false
	ctx.frame_generation += 1
	ctx.frame_active = true
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
	assert(!frame.active)
	assert(!ctx.frame_active)
}

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

draw_rect :: proc(frame: ^Frame, rect: Rect, color: RGBA) {
	assert(frame != nil)
	assert(rect.width >= 0 && rect.height >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawRectangleRec(rect, color)
	assert(frame.active)
}

draw_line :: proc(frame: ^Frame, start, end: Vec2, thick: f32, color: RGBA) {
	assert(frame != nil)
	assert(thick >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawLineEx(start, end, thick, color)
	assert(frame.active)
}

draw_circle :: proc(frame: ^Frame, center: Vec2, radius: f32, color: RGBA) {
	assert(frame != nil)
	assert(radius >= 0)
	if !_frame_valid(frame) do return
	previous := _context_activate(frame.owner)
	defer _context_restore(previous)
	DrawCircleV(center, radius, color)
	assert(frame.active)
}

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

measure_text :: proc(font: Font, text: cstring, font_size, spacing: f32) -> Vec2 {
	assert(text != nil)
	assert(font_size >= 0)
	result := MeasureTextEx(font, text, font_size, spacing)
	assert(result.x >= 0)
	return result
}

key_down :: proc(key: KeyboardKey) -> bool {
	return IsKeyDown(key)
}

key_pressed :: proc(key: KeyboardKey) -> bool {
	return IsKeyPressed(key)
}

mouse_position :: proc() -> Vec2 {
	return GetMousePosition()
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
