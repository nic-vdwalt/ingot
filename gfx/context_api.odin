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
