package gfx

Vec2 :: Vector2
Vec3 :: Vector3
RGBA :: Color
Rect :: Rectangle

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
	result := context_measure_text_ex(ctx, font, text, font_size, spacing)
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
