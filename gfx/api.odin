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
	if ctx == nil || ctx != default_context() do return {}, false
	if !ctx.initialized || ctx.frame_active do return {}, false
	BeginDrawing()
	if !g.frame.has_frame do return {}, false
	g.frame_generation += 1
	g.frame_active = true
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
	EndDrawing()
	frame.active = false
	g.frame_active = false
	assert(!frame.active)
	assert(!g.frame_active)
}

clear_frame :: proc(frame: ^Frame, color: RGBA) {
	assert(frame != nil)
	assert(frame.active)
	if !_frame_valid(frame) do return
	ClearBackground(color)
	assert(frame.generation == g.frame_generation)
}

draw_rect :: proc(frame: ^Frame, rect: Rect, color: RGBA) {
	assert(frame != nil)
	assert(rect.width >= 0 && rect.height >= 0)
	if !_frame_valid(frame) do return
	DrawRectangleRec(rect, color)
	assert(frame.active)
}

draw_line :: proc(frame: ^Frame, start, end: Vec2, thick: f32, color: RGBA) {
	assert(frame != nil)
	assert(thick >= 0)
	if !_frame_valid(frame) do return
	DrawLineEx(start, end, thick, color)
	assert(frame.active)
}

draw_circle :: proc(frame: ^Frame, center: Vec2, radius: f32, color: RGBA) {
	assert(frame != nil)
	assert(radius >= 0)
	if !_frame_valid(frame) do return
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
	if ctx == nil || ctx != default_context() do return false
	if !frame.active || !ctx.frame_active do return false
	if frame.epoch != ctx.epoch do return false
	if frame.generation != ctx.frame_generation do return false
	assert(ctx.frame.has_frame)
	return ctx.frame.has_frame
}
