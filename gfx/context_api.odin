package gfx

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
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsKeyDown(key)
}

context_is_mouse_button_down :: proc(ctx: ^Context, button: MouseButton) -> bool {
	if ctx == nil do return false
	previous := _context_activate(ctx)
	defer _context_restore(previous)
	return IsMouseButtonDown(button)
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
