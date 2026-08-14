package gfx

Frame :: struct {
	owner:     ^Context,
	epoch:     u64,
	open:      bool,
	available: bool,
}

frame_begin :: proc(frame: ^Frame, ctx: ^Context) -> bool {
	assert(frame != nil && ctx != nil, "frame_begin: nil argument")
	assert(!frame.open, "frame_begin: frame already open")
	frame.owner = ctx
	frame.epoch = context_epoch(ctx)
	frame.open = true
	context_begin_drawing(ctx)
	frame.available = context_frame_available(ctx)
	assert(frame.owner == ctx && frame.open, "frame_begin: invalid frame")
	return frame.available
}

frame_end :: proc(frame: ^Frame) {
	assert(frame != nil && frame.open, "frame_end: frame not open")
	assert(
		frame.owner != nil && frame.epoch == context_epoch(frame.owner),
		"frame_end: stale owner",
	)
	context_end_drawing(frame.owner)
	frame^ = {}
}

frame_owner :: proc(frame: ^Frame) -> ^Context {
	assert(frame != nil && frame.open, "frame_owner: frame not open")
	assert(
		frame.owner != nil && frame.epoch == context_epoch(frame.owner),
		"frame_owner: stale owner",
	)
	return frame.owner
}

frame_available :: proc(frame: ^Frame) -> bool {
	return frame != nil && frame.open && frame.available
}

frame_draw_text :: proc(
	frame: ^Frame,
	font: Font,
	text: cstring,
	position: Vector2,
	font_size, spacing: f32,
	tint: Color,
) {
	_ = frame_owner(frame)
	DrawTextEx(font, text, position, font_size, spacing, tint)
}

frame_draw_codepoint :: proc(
	frame: ^Frame,
	font: Font,
	codepoint: rune,
	position: Vector2,
	font_size: f32,
	tint: Color,
) {
	_ = frame_owner(frame)
	DrawTextCodepoint(font, codepoint, position, font_size, tint)
}

frame_draw_rectangle :: proc(frame: ^Frame, rect: Rectangle, color: Color) {
	_ = frame_owner(frame)
	DrawRectangleRec(rect, color)
}

frame_draw_rectangle_lines :: proc(frame: ^Frame, rect: Rectangle, thickness: f32, color: Color) {
	_ = frame_owner(frame)
	DrawRectangleLinesEx(rect, thickness, color)
}

frame_draw_rectangle_rounded :: proc(
	frame: ^Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	color: Color,
) {
	_ = frame_owner(frame)
	DrawRectangleRounded(rect, roundness, segments, color)
}

frame_draw_rectangle_rounded_lines :: proc(
	frame: ^Frame,
	rect: Rectangle,
	roundness: f32,
	segments: i32,
	thickness: f32,
	color: Color,
) {
	_ = frame_owner(frame)
	DrawRectangleRoundedLinesEx(rect, roundness, segments, thickness, color)
}

frame_draw_rectangle_gradient_v :: proc(frame: ^Frame, rect: Rectangle, top, bottom: Color) {
	assert(frame != nil, "frame_draw_rectangle_gradient_v: nil frame")
	_ = frame_owner(frame)
	DrawRectangleGradientV(
		i32(rect.x),
		i32(rect.y),
		i32(rect.width),
		i32(rect.height),
		top,
		bottom,
	)
}

frame_draw_line :: proc(frame: ^Frame, from, to: Vector2, thickness: f32, color: Color) {
	_ = frame_owner(frame)
	DrawLineEx(from, to, thickness, color)
}

frame_draw_circle :: proc(frame: ^Frame, center: Vector2, radius: f32, color: Color) {
	_ = frame_owner(frame)
	DrawCircleV(center, radius, color)
}

frame_draw_circle_lines :: proc(frame: ^Frame, center: Vector2, radius: f32, color: Color) {
	_ = frame_owner(frame)
	DrawCircleLinesV(center, radius, color)
}

frame_draw_ring :: proc(
	frame: ^Frame,
	center: Vector2,
	inner_radius, outer_radius, start_angle, end_angle: f32,
	segments: i32,
	color: Color,
) {
	_ = frame_owner(frame)
	DrawRing(center, inner_radius, outer_radius, start_angle, end_angle, segments, color)
}

frame_draw_triangle :: proc(frame: ^Frame, first, second, third: Vector2, color: Color) {
	_ = frame_owner(frame)
	DrawTriangle(first, second, third, color)
}

frame_scissor_begin :: proc(frame: ^Frame, x, y, width, height: i32) {
	_ = frame_owner(frame)
	BeginScissorMode(x, y, width, height)
}

frame_scissor_end :: proc(frame: ^Frame) {
	_ = frame_owner(frame)
	EndScissorMode()
}

Context_Scope :: struct {
	previous: ^Context,
	active:   bool,
}

context_scope_enter :: proc(ctx: ^Context) -> Context_Scope {
	assert(ctx != nil, "context_scope_enter: nil context")
	return {previous = _context_activate(ctx), active = true}
}

context_scope_leave :: proc(scope: ^Context_Scope) {
	assert(scope != nil && scope.active, "context_scope_leave: invalid scope")
	_context_restore(scope.previous)
	scope.active = false
}

context_get_char_pressed :: proc(ctx: ^Context) -> rune {
	if ctx == nil do return 0
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return GetCharPressed()
}

context_is_key_down :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	index := i32(key)
	if index < 0 || index >= KEY_COUNT do return false
	return ctx.inp.key_down[index]
}

context_is_mouse_button_down :: proc(ctx: ^Context, button: MouseButton) -> bool {
	if ctx == nil do return false
	index := int(button)
	if index < 0 || index >= len(ctx.inp.mb_down) do return false
	return ctx.inp.mb_down[index]
}

context_window_focused :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsWindowFocused()
}

context_window_fullscreen :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsWindowFullscreen()
}

context_get_clipboard_text :: proc(ctx: ^Context) -> cstring {
	if ctx == nil do return ""
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return GetClipboardText()
}

context_set_frame_strategy :: proc(ctx: ^Context, strategy: Frame_Strategy) {
	if ctx == nil do return
	ctx.idle.strategy = strategy
	_idle_note_activity(&ctx.idle)
}

context_get_frame_strategy :: proc(ctx: ^Context) -> Frame_Strategy {
	if ctx == nil do return .Continuous
	return ctx.idle.strategy
}

context_set_config_flags :: proc(ctx: ^Context, flags: ConfigFlags) {
	if ctx == nil do return
	ctx.config_flags = flags
}

context_set_target_fps :: proc(ctx: ^Context, fps: i32) {
	if ctx == nil do return
	ctx.target_fps = fps
}

context_monitor_refresh_rate :: proc(ctx: ^Context) -> i32 {
	if ctx == nil || !context_ready(ctx) do return 0
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return platform_monitor_refresh_rate()
}

context_set_mouse_cursor :: proc(ctx: ^Context, cursor: MouseCursor) {
	if ctx == nil do return
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	SetMouseCursor(cursor)
}

context_set_clipboard_text :: proc(ctx: ^Context, text: cstring) {
	assert(ctx != nil && text != nil, "context_set_clipboard_text: nil argument")
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	SetClipboardText(text)
}

context_set_text_input_rect :: proc(ctx: ^Context, x, y, width, height: i32) {
	assert(ctx != nil, "context_set_text_input_rect: nil context")
	assert(width >= 0 && height >= 0, "context_set_text_input_rect: negative size")
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	SetTextInputRect(x, y, width, height)
}

context_toggle_fullscreen :: proc(ctx: ^Context) {
	if ctx == nil do return
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	ToggleFullscreen()
}

context_load_font_from_memory :: proc(
	ctx: ^Context,
	file_type: cstring,
	file_data: [^]u8,
	data_size, font_size: i32,
	codepoints: [^]rune,
	codepoint_count: i32,
) -> Font {
	assert(ctx != nil && file_type != nil, "context_load_font_from_memory: nil argument")
	assert(data_size > 0 && font_size > 0, "context_load_font_from_memory: invalid size")
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return LoadFontFromMemory(
		file_type,
		file_data,
		data_size,
		font_size,
		codepoints,
		codepoint_count,
	)
}

context_unload_font :: proc(ctx: ^Context, font: Font) {
	if ctx == nil || font.glyphCount <= 0 do return
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	UnloadFont(font)
}

context_set_texture_filter :: proc(ctx: ^Context, texture: Texture2D, filter: TextureFilter) {
	if ctx == nil || texture.id == 0 do return
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	SetTextureFilter(texture, filter)
}
