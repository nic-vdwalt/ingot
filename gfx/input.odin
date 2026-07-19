// ingot:gfx — GLFW-backed input with raylib-parity queries. Edge (pressed /
// released) and repeat state is collected via GLFW callbacks during PollEvents
// (driven from EndDrawing) and read by the app on the following frame, matching
// raylib's poll-at-end-of-frame model. Held state and mouse position are polled
// directly. Values match raylib names/semantics so `rl.*` input call sites port
// unchanged.
package gfx

import "core:strings"
import "vendor:glfw"

CHAR_Q :: 64

Input :: struct {
	exit_key: KeyboardKey,

	// per-frame edge/repeat (set by callbacks, cleared each poll cycle)
	pressed:  [KEY_COUNT]bool,
	released: [KEY_COUNT]bool,
	repeat:   [KEY_COUNT]bool,

	// char / key queues (FIFO ring)
	char_q:   [CHAR_Q]rune,
	char_h, char_t: int,
	key_q:    [CHAR_Q]KeyboardKey,
	key_h, key_t: int,

	// mouse
	mouse:       Vector2,
	mouse_prev:  Vector2,
	mouse_delta: Vector2,
	mb_down:     [8]bool,
	mb_pressed:  [8]bool,
	mb_released: [8]bool,

	// wheel
	wheel:         Vector2,
	wheel_pending: Vector2,

	cursor_on_screen: bool,

	cursors:     [11]glfw.CursorHandle,
	cur_cursor:  MouseCursor,
}

input_init :: proc() {
	if g.win == nil do return
	glfw.SetKeyCallback(g.win, _key_cb)
	glfw.SetCharCallback(g.win, _char_cb)
	glfw.SetScrollCallback(g.win, _scroll_cb)

	g.inp.cursors[MouseCursor.DEFAULT]       = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
	g.inp.cursors[MouseCursor.ARROW]         = glfw.CreateStandardCursor(glfw.ARROW_CURSOR)
	g.inp.cursors[MouseCursor.IBEAM]         = glfw.CreateStandardCursor(glfw.IBEAM_CURSOR)
	g.inp.cursors[MouseCursor.CROSSHAIR]     = glfw.CreateStandardCursor(glfw.CROSSHAIR_CURSOR)
	g.inp.cursors[MouseCursor.POINTING_HAND] = glfw.CreateStandardCursor(glfw.POINTING_HAND_CURSOR)
	g.inp.cursors[MouseCursor.RESIZE_EW]     = glfw.CreateStandardCursor(glfw.RESIZE_EW_CURSOR)
	g.inp.cursors[MouseCursor.RESIZE_NS]     = glfw.CreateStandardCursor(glfw.RESIZE_NS_CURSOR)
	g.inp.cursors[MouseCursor.RESIZE_NWSE]   = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g.inp.cursors[MouseCursor.RESIZE_NESW]   = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g.inp.cursors[MouseCursor.RESIZE_ALL]    = glfw.CreateStandardCursor(glfw.RESIZE_ALL_CURSOR)
	g.inp.cursors[MouseCursor.NOT_ALLOWED]   = glfw.CreateStandardCursor(glfw.NOT_ALLOWED_CURSOR)

	mx, my := glfw.GetCursorPos(g.win)
	g.inp.mouse = {f32(mx), f32(my)}
	g.inp.mouse_prev = g.inp.mouse
}

// input_poll runs once per frame from EndDrawing: reset frame-scoped state,
// pump GLFW events (fills callbacks), then finalize mouse/wheel/button deltas.
input_poll :: proc() {
	inp := &g.inp
	for i in 0 ..< KEY_COUNT {
		inp.pressed[i] = false
		inp.released[i] = false
		inp.repeat[i] = false
	}
	inp.char_h, inp.char_t = 0, 0
	inp.key_h, inp.key_t = 0, 0
	inp.wheel_pending = {0, 0}
	inp.mouse_prev = inp.mouse

	glfw.PollEvents()

	mx, my := glfw.GetCursorPos(g.win)
	inp.mouse = {f32(mx), f32(my)}
	inp.mouse_delta = {inp.mouse.x - inp.mouse_prev.x, inp.mouse.y - inp.mouse_prev.y}
	inp.wheel = inp.wheel_pending

	for b in 0 ..< 8 {
		cur := glfw.GetMouseButton(g.win, i32(b)) == glfw.PRESS
		inp.mb_pressed[b] = cur && !inp.mb_down[b]
		inp.mb_released[b] = !cur && inp.mb_down[b]
		inp.mb_down[b] = cur
	}
	inp.cursor_on_screen = glfw.GetWindowAttrib(g.win, glfw.HOVERED) != 0
}

// --- GLFW callbacks --------------------------------------------------------

@(private)
_key_cb :: proc "c" (win: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if key < 0 || key >= KEY_COUNT do return
	switch action {
	case glfw.PRESS:
		g.inp.pressed[key] = true
		_push_key(KeyboardKey(key))
	case glfw.RELEASE:
		g.inp.released[key] = true
	case glfw.REPEAT:
		g.inp.repeat[key] = true
	}
}

@(private)
_char_cb :: proc "c" (win: glfw.WindowHandle, codepoint: rune) {
	_push_char(codepoint)
}

@(private)
_scroll_cb :: proc "c" (win: glfw.WindowHandle, xoffset, yoffset: f64) {
	g.inp.wheel_pending.x += f32(xoffset)
	g.inp.wheel_pending.y += f32(yoffset)
}

@(private)
_push_char :: proc "c" (r: rune) {
	nt := (g.inp.char_t + 1) % CHAR_Q
	if nt == g.inp.char_h do return // full
	g.inp.char_q[g.inp.char_t] = r
	g.inp.char_t = nt
}

@(private)
_push_key :: proc "c" (k: KeyboardKey) {
	nt := (g.inp.key_t + 1) % CHAR_Q
	if nt == g.inp.key_h do return
	g.inp.key_q[g.inp.key_t] = k
	g.inp.key_t = nt
}

// --- raylib-named queries --------------------------------------------------

IsKeyPressed :: proc(key: KeyboardKey) -> bool {
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return g.inp.pressed[i]
}

IsKeyPressedRepeat :: proc(key: KeyboardKey) -> bool {
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return g.inp.repeat[i]
}

IsKeyReleased :: proc(key: KeyboardKey) -> bool {
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return g.inp.released[i]
}

IsKeyDown :: proc(key: KeyboardKey) -> bool {
	if g.win == nil do return false
	return glfw.GetKey(g.win, i32(key)) == glfw.PRESS
}

GetCharPressed :: proc() -> rune {
	if g.inp.char_h == g.inp.char_t do return 0
	r := g.inp.char_q[g.inp.char_h]
	g.inp.char_h = (g.inp.char_h + 1) % CHAR_Q
	return r
}

GetKeyPressed :: proc() -> KeyboardKey {
	if g.inp.key_h == g.inp.key_t do return .KEY_NULL
	k := g.inp.key_q[g.inp.key_h]
	g.inp.key_h = (g.inp.key_h + 1) % CHAR_Q
	return k
}

IsMouseButtonPressed :: proc(button: MouseButton) -> bool {
	b := int(button)
	if b < 0 || b >= 8 do return false
	return g.inp.mb_pressed[b]
}

IsMouseButtonReleased :: proc(button: MouseButton) -> bool {
	b := int(button)
	if b < 0 || b >= 8 do return false
	return g.inp.mb_released[b]
}

IsMouseButtonDown :: proc(button: MouseButton) -> bool {
	if g.win == nil do return false
	return glfw.GetMouseButton(g.win, i32(button)) == glfw.PRESS
}

GetMousePosition :: proc() -> Vector2 { return g.inp.mouse }
GetMouseDelta    :: proc() -> Vector2 { return g.inp.mouse_delta }

GetMouseWheelMove :: proc() -> f32 {
	if abs(g.inp.wheel.x) > abs(g.inp.wheel.y) do return g.inp.wheel.x
	return g.inp.wheel.y
}
GetMouseWheelMoveV :: proc() -> Vector2 { return g.inp.wheel }

GetClipboardText :: proc() -> cstring {
	if g.win == nil do return ""
	s := glfw.GetClipboardString(g.win)
	return strings.clone_to_cstring(s, context.temp_allocator)
}

SetClipboardText :: proc(text: cstring) {
	if g.win == nil do return
	glfw.SetClipboardString(g.win, text)
}

SetMouseCursor :: proc(cursor: MouseCursor) {
	if g.win == nil do return
	i := int(cursor)
	if i < 0 || i >= len(g.inp.cursors) do return
	if cursor == g.inp.cur_cursor do return
	g.inp.cur_cursor = cursor
	glfw.SetCursor(g.win, g.inp.cursors[i])
}

IsCursorOnScreen :: proc() -> bool { return g.inp.cursor_on_screen }
