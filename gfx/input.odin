// ingot:gfx — input state with raylib-parity queries. Edge (pressed /
// released) and repeat state is collected by the platform backend during the
// poll cycle (driven from EndDrawing) and read by the app on the following
// frame, matching raylib's poll-at-end-of-frame model. Held state and mouse
// position are polled directly. Values match raylib names/semantics so `rl.*`
// input call sites port unchanged. The Input struct is backend-neutral; the
// GLFW/DOM plumbing that fills it lives in platform_native.odin / platform_web.odin.
package gfx

import "core:strings"

CHAR_Q :: 64

Input :: struct {
	exit_key: KeyboardKey,

	// per-frame edge/repeat (set by the backend, cleared each poll cycle)
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

	cur_cursor:  MouseCursor,
}

// input_poll runs once per frame from EndDrawing: reset frame-scoped state,
// pump backend events (fills queues/edges), then finalize mouse/wheel/button
// deltas via the platform seam.
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

	// Pump backend events. In event-driven mode the gate may block here
	// (platform_wait_events) until input/OS damage arrives or the timeout
	// elapses — this is where idle power saving happens. Web never waits;
	// its gate lives in step() (loop_web.odin).
	if should_wait, timeout := _idle_timeout(); should_wait {
		platform_wait_events(timeout)
	} else {
		platform_poll_events()
	}

	mx, my := platform_cursor_pos()
	inp.mouse = {f32(mx), f32(my)}
	inp.mouse_delta = {inp.mouse.x - inp.mouse_prev.x, inp.mouse.y - inp.mouse_prev.y}
	inp.wheel = inp.wheel_pending

	for b in 0 ..< 8 {
		cur := platform_mouse_button(i32(b))
		inp.mb_pressed[b] = cur && !inp.mb_down[b]
		inp.mb_released[b] = !cur && inp.mb_down[b]
		inp.mb_down[b] = cur
	}
	inp.cursor_on_screen = platform_window_hovered()
}

// --- queue helpers (shared; called by the platform input backend) ----------

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
	return platform_key_down(i32(key))
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
	return platform_mouse_button(i32(button))
}

GetMousePosition :: proc() -> Vector2 { return g.inp.mouse }
GetMouseDelta    :: proc() -> Vector2 { return g.inp.mouse_delta }

GetMouseX :: proc() -> i32 { return i32(g.inp.mouse.x) }
GetMouseY :: proc() -> i32 { return i32(g.inp.mouse.y) }

// raylib mouse coordinate offset/scale — unused by the current backends; kept
// for API parity (no-op).
SetMouseOffset :: proc(offsetX, offsetY: i32) {}

GetMouseWheelMove :: proc() -> f32 {
	if abs(g.inp.wheel.x) > abs(g.inp.wheel.y) do return g.inp.wheel.x
	return g.inp.wheel.y
}
GetMouseWheelMoveV :: proc() -> Vector2 { return g.inp.wheel }

GetClipboardText :: proc() -> cstring {
	s := platform_get_clipboard()
	return strings.clone_to_cstring(s, context.temp_allocator)
}

SetClipboardText :: proc(text: cstring) {
	platform_set_clipboard(text)
}

Web_Input_Result :: struct {
	value: string,
	cursor: int,
	changed: bool,
	focused: bool,
}

SyncWebTextInput :: proc(
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> Web_Input_Result {
	return platform_sync_web_text_input(
		form_id, field_id, name, placeholder, value,
		x, y, w, h, input_type, autocomplete, active,
	)
}

SyncWebSubmitButton :: proc(
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool {
	return platform_sync_web_submit_button(
		form_id, label, x, y, w, h, style, font_size, enabled,
	)
}

SetMouseCursor :: proc(cursor: MouseCursor) {
	i := int(cursor)
	if i < 0 || i >= 11 do return
	if cursor == g.inp.cur_cursor do return
	g.inp.cur_cursor = cursor
	platform_set_mouse_cursor(cursor)
}

IsCursorOnScreen :: proc() -> bool { return g.inp.cursor_on_screen }
