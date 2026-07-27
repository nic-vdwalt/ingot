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
	exit_key:             KeyboardKey,

	// per-frame edge/repeat (set by the backend, cleared each poll cycle)
	pressed:              [KEY_COUNT]bool,
	released:             [KEY_COUNT]bool,
	repeat:               [KEY_COUNT]bool,

	// char / key queues (FIFO ring)
	char_q:               [CHAR_Q]rune,
	char_h, char_t:       int,
	key_q:                [CHAR_Q]KeyboardKey,
	key_h, key_t:         int,

	// Native callbacks stage per-window events until that context publishes
	// its next frame-visible input snapshot.
	st_pressed:           [KEY_COUNT]bool,
	st_released:          [KEY_COUNT]bool,
	st_repeat:            [KEY_COUNT]bool,
	st_char_q:            [CHAR_Q]rune,
	st_char_h, st_char_t: int,
	st_key_q:             [CHAR_Q]KeyboardKey,
	st_key_h, st_key_t:   int,
	st_wheel:             Vector2,

	// mouse
	mouse:                Vector2,
	mouse_prev:           Vector2,
	mouse_delta:          Vector2,
	mb_down:              [8]bool,
	mb_pressed:           [8]bool,
	mb_released:          [8]bool,

	// wheel
	wheel:                Vector2,
	wheel_pending:        Vector2,
	cursor_on_screen:     bool,
	cur_cursor:           MouseCursor,

	// Gamepads: fixed pool, snapshot-polled once per frame through the
	// platform seam (GLFW GetGamepadState native, navigator.getGamepads()
	// web). prev_buttons gives pressed/released edge detection.
	pads:                 [MAX_GAMEPADS]Gamepad_State,
}

MAX_GAMEPADS :: 4
GAMEPAD_NAME_MAX :: 64

Gamepad_State :: struct {
	connected:    bool,
	name:         [GAMEPAD_NAME_MAX]u8,
	name_len:     i32,
	buttons:      [GAMEPAD_BUTTON_COUNT]bool,
	prev_buttons: [GAMEPAD_BUTTON_COUNT]bool,
	axes:         [GAMEPAD_AXIS_COUNT]f32,
}

// --- IME / text input ------------------------------------------------------

// PREEDIT_MAX bounds the staged composition (preedit) string in bytes.
PREEDIT_MAX :: 256

// Preedit staging: written by the platform backend while an OS input method
// is composing (web composition events; native 3c later), read by the UI via
// GetPreedit. Absolute state like the mouse position — no edge semantics.
@(private)
preedit_buf: [PREEDIT_MAX]u8
@(private)
preedit_len: int
@(private)
preedit_caret: int

// ime_rect_armed tracks whether any text field reported its caret rect this
// frame; input_poll deactivates platform text input when none did.
@(private)
ime_rect_armed: bool


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
	_input_reset_mouse_edges(inp)
	inp.char_h, inp.char_t = 0, 0
	inp.key_h, inp.key_t = 0, 0
	inp.wheel_pending = {0, 0}
	inp.mouse_prev = inp.mouse

	// Pump backend events. In event-driven mode the gate may block here
	// (platform_wait_events) until input/OS damage arrives or the timeout
	// elapses — this is where idle power saving happens. Web never waits;
	// its gate lives in step() (loop_web.odin).
	platform_drop_prepare_events()
	if should_wait, timeout := _idle_timeout(); should_wait {
		platform_wait_events(timeout)
	} else {
		platform_poll_events()
	}
	platform_drop_finish_events()
	_drop_hover_publish()
	_input_publish_staged(inp)

	mx, my := platform_cursor_pos()
	inp.mouse = {f32(mx), f32(my)}
	inp.mouse_delta = {inp.mouse.x - inp.mouse_prev.x, inp.mouse.y - inp.mouse_prev.y}
	inp.wheel = inp.wheel_pending

	for b in 0 ..< 8 {
		cur := platform_mouse_button(i32(b))
		when ODIN_OS == .JS {
			inp.mb_pressed[b] = inp.mb_pressed[b] || (cur && !inp.mb_down[b])
			inp.mb_released[b] = inp.mb_released[b] || (!cur && inp.mb_down[b])
		} else {
			inp.mb_pressed[b] = cur && !inp.mb_down[b]
			inp.mb_released[b] = !cur && inp.mb_down[b]
		}
		inp.mb_down[b] = cur
	}
	inp.cursor_on_screen = platform_window_hovered()

	// Gamepads: snapshot previous button state for edge queries, then poll.
	for p in 0 ..< MAX_GAMEPADS {
		inp.pads[p].prev_buttons = inp.pads[p].buttons
	}
	platform_gamepad_poll(&inp.pads)

	// IME: if no text field reported a caret rect since the last poll, tell
	// the platform text input is inactive (web blurs the IME proxy; native
	// clears the candidate-window rect). Active fields re-arm every frame.
	if !ime_rect_armed do platform_text_input_deactivate()
	ime_rect_armed = false
}

@(private)
_input_reset_mouse_edges :: proc(inp: ^Input) {
	assert(inp != nil, "_input_reset_mouse_edges: nil input")
	for button in 0 ..< 8 {
		inp.mb_pressed[button] = false
		inp.mb_released[button] = false
	}
}

// --- queue helpers (shared; called by the platform input backend) ----------

@(private)
_input_publish_staged :: proc(inp: ^Input) {
	assert(inp != nil, "_input_publish_staged: nil input")
	for index in 0 ..< KEY_COUNT {
		inp.pressed[index] = inp.st_pressed[index]
		inp.released[index] = inp.st_released[index]
		inp.repeat[index] = inp.st_repeat[index]
		inp.st_pressed[index] = false
		inp.st_released[index] = false
		inp.st_repeat[index] = false
	}
	for inp.st_key_h != inp.st_key_t {
		_push_key_input(inp, inp.st_key_q[inp.st_key_h])
		inp.st_key_h = (inp.st_key_h + 1) % CHAR_Q
	}
	for inp.st_char_h != inp.st_char_t {
		_push_char_input(inp, inp.st_char_q[inp.st_char_h])
		inp.st_char_h = (inp.st_char_h + 1) % CHAR_Q
	}
	inp.wheel_pending += inp.st_wheel
	inp.st_wheel = {}
}

@(private)
_push_char_input :: proc "contextless" (inp: ^Input, r: rune) {
	if inp == nil do return
	nt := (inp.char_t + 1) % CHAR_Q
	if nt == inp.char_h do return
	inp.char_q[inp.char_t] = r
	inp.char_t = nt
}

@(private)
_push_key_input :: proc "contextless" (inp: ^Input, k: KeyboardKey) {
	if inp == nil do return
	nt := (inp.key_t + 1) % CHAR_Q
	if nt == inp.key_h do return
	inp.key_q[inp.key_t] = k
	inp.key_t = nt
}

@(private)
_push_char :: proc "c" (r: rune) {
	_push_char_input(&g.inp, r)
}

@(private)
_push_key :: proc "c" (k: KeyboardKey) {
	_push_key_input(&g.inp, k)
}

// --- raylib-named queries --------------------------------------------------

context_is_key_pressed :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return ctx.inp.pressed[i]
}

IsKeyPressed :: proc(key: KeyboardKey) -> bool {
	return context_is_key_pressed(default_context(), key)
}

context_is_key_pressed_repeat :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return ctx.inp.repeat[i]
}

IsKeyPressedRepeat :: proc(key: KeyboardKey) -> bool {
	return context_is_key_pressed_repeat(default_context(), key)
}

context_is_key_released :: proc(ctx: ^Context, key: KeyboardKey) -> bool {
	if ctx == nil do return false
	i := i32(key)
	if i < 0 || i >= KEY_COUNT do return false
	return ctx.inp.released[i]
}

IsKeyReleased :: proc(key: KeyboardKey) -> bool {
	return context_is_key_released(default_context(), key)
}

IsKeyDown :: proc(key: KeyboardKey) -> bool {
	when INGOT_INPUT_SIM {
		return sim_key_down(i32(key))
	} else {
		return platform_key_down(i32(key))
	}
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

context_is_mouse_button_pressed :: proc(ctx: ^Context, button: MouseButton) -> bool {
	if ctx == nil do return false
	b := int(button)
	if b < 0 || b >= 8 do return false
	return ctx.inp.mb_pressed[b]
}

IsMouseButtonPressed :: proc(button: MouseButton) -> bool {
	return context_is_mouse_button_pressed(default_context(), button)
}

context_is_mouse_button_released :: proc(ctx: ^Context, button: MouseButton) -> bool {
	if ctx == nil do return false
	b := int(button)
	if b < 0 || b >= 8 do return false
	return ctx.inp.mb_released[b]
}

IsMouseButtonReleased :: proc(button: MouseButton) -> bool {
	return context_is_mouse_button_released(default_context(), button)
}

IsMouseButtonDown :: proc(button: MouseButton) -> bool {
	when INGOT_INPUT_SIM {
		return sim_mouse_button_down(i32(button))
	} else {
		return platform_mouse_button(i32(button))
	}
}

// --- gamepad queries (raylib-named) ----------------------------------------

IsGamepadAvailable :: proc(gamepad: i32) -> bool {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	return g.inp.pads[gamepad].connected
}

// GetGamepadName returns the backend-reported device name (empty when the
// slot is empty). The cstring is temp-allocated; clone to keep past the frame.
GetGamepadName :: proc(gamepad: i32) -> cstring {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return ""
	pad := &g.inp.pads[gamepad]
	assert(pad.name_len >= 0 && pad.name_len <= GAMEPAD_NAME_MAX, "GetGamepadName: corrupt length")
	return strings.clone_to_cstring(string(pad.name[:pad.name_len]), context.temp_allocator)
}

IsGamepadButtonDown :: proc(gamepad: i32, button: GamepadButton) -> bool {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	return g.inp.pads[gamepad].buttons[b]
}

IsGamepadButtonPressed :: proc(gamepad: i32, button: GamepadButton) -> bool {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	pad := &g.inp.pads[gamepad]
	return pad.buttons[b] && !pad.prev_buttons[b]
}

IsGamepadButtonReleased :: proc(gamepad: i32, button: GamepadButton) -> bool {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	pad := &g.inp.pads[gamepad]
	return !pad.buttons[b] && pad.prev_buttons[b]
}

// GetGamepadAxisMovement returns the axis position in -1..1 (triggers rest at
// -1, matching raylib/GLFW). 0 for disconnected pads or out-of-range axes.
GetGamepadAxisMovement :: proc(gamepad: i32, axis: GamepadAxis) -> f32 {
	if gamepad < 0 || gamepad >= MAX_GAMEPADS do return 0
	a := i32(axis)
	if a < 0 || a >= GAMEPAD_AXIS_COUNT do return 0
	if !g.inp.pads[gamepad].connected do return 0
	v := g.inp.pads[gamepad].axes[a]
	assert(v >= -1.001 && v <= 1.001, "GetGamepadAxisMovement: axis out of range")
	return v
}

context_get_mouse_position :: proc(ctx: ^Context) -> Vector2 {
	return ctx == nil ? Vector2{} : ctx.inp.mouse
}
context_get_mouse_delta :: proc(ctx: ^Context) -> Vector2 {
	return ctx == nil ? Vector2{} : ctx.inp.mouse_delta
}
context_get_mouse_wheel_move_v :: proc(ctx: ^Context) -> Vector2 {
	return ctx == nil ? Vector2{} : ctx.inp.wheel
}

GetMousePosition :: proc() -> Vector2 {return context_get_mouse_position(default_context())}
GetMouseDelta :: proc() -> Vector2 {return context_get_mouse_delta(default_context())}

GetMouseX :: proc() -> i32 {return i32(g.inp.mouse.x)}
GetMouseY :: proc() -> i32 {return i32(g.inp.mouse.y)}

GetMouseWheelMove :: proc() -> f32 {
	if abs(g.inp.wheel.x) > abs(g.inp.wheel.y) do return g.inp.wheel.x
	return g.inp.wheel.y
}
GetMouseWheelMoveV :: proc() -> Vector2 {return context_get_mouse_wheel_move_v(default_context())}

GetClipboardText :: proc() -> cstring {
	s := platform_get_clipboard()
	return strings.clone_to_cstring(s, context.temp_allocator)
}

SetClipboardText :: proc(text: cstring) {
	platform_set_clipboard(text)
}

Web_Input_Result :: struct {
	value:   string,
	cursor:  int,
	changed: bool,
	focused: bool,
}

SyncWebTextInput :: proc(
	form_id, field_id, name, placeholder, value: string,
	x, y, w, h, input_type, autocomplete: i32,
	active: bool,
) -> Web_Input_Result {
	return platform_sync_web_text_input(
		form_id,
		field_id,
		name,
		placeholder,
		value,
		x,
		y,
		w,
		h,
		input_type,
		autocomplete,
		active,
	)
}

SyncWebSubmitButton :: proc(
	form_id, label: string,
	x, y, w, h, style, font_size: i32,
	enabled: bool,
) -> bool {
	return platform_sync_web_submit_button(form_id, label, x, y, w, h, style, font_size, enabled)
}

Web_Control_Result :: struct {
	value:     f32,
	activated: bool,
	changed:   bool,
}

// SyncWebControl mirrors one semantic node (ui/semantics.odin) into a real
// DOM control with an ARIA role — buttons, checkboxes, radios, sliders,
// dropdowns become genuine browser elements assistive tech can reach, which
// is stronger than a canvas-side accessibility tree. No-op on native targets
// (AccessKit covers those). `role` is the Sem_Role ordinal; `state` is the
// Sem_State bit_set transmuted to its u8 backing.
SyncWebControl :: proc(
	role: i32,
	id: u64,
	label: string,
	x, y, w, h: i32,
	state: u8,
	value, lo, hi: f32,
	position_in_set, size_of_set: i32,
) -> Web_Control_Result {
	return platform_sync_web_control(
		role,
		id,
		label,
		x,
		y,
		w,
		h,
		state,
		value,
		lo,
		hi,
		position_in_set,
		size_of_set,
	)
}

SetMouseCursor :: proc(cursor: MouseCursor) {
	i := int(cursor)
	if i < 0 || i >= 11 do return
	if cursor == g.inp.cur_cursor do return
	g.inp.cur_cursor = cursor
	platform_set_mouse_cursor(cursor)
}

context_is_cursor_on_screen :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.inp.cursor_on_screen
}

IsCursorOnScreen :: proc() -> bool {return context_is_cursor_on_screen(default_context())}

// SetTextInputRect reports the focused text field's caret rect (UI logical
// pixels, top-left origin). Call every frame while a field is active; the OS
// input method uses it to place the composition candidate window (macOS /
// Windows) or the hidden IME proxy element (web). Cheap; safe to call even
// when no IME is composing.
SetTextInputRect :: proc(x, y, w, h: i32) {
	assert(w >= 0 && h >= 0, "SetTextInputRect: negative size")
	assert(g.win != nil, "SetTextInputRect: window not initialized")
	ime_rect_armed = true
	platform_set_text_input_rect(x, y, w, h)
}

// GetPreedit returns the in-progress IME composition string (empty when not
// composing) and the caret byte offset within it. The string aliases an
// internal buffer valid until the next composition event; clone to keep.
GetPreedit :: proc() -> (text: string, caret: int) {
	assert(preedit_len >= 0 && preedit_len <= PREEDIT_MAX, "GetPreedit: corrupt length")
	assert(preedit_caret >= 0 && preedit_caret <= preedit_len, "GetPreedit: corrupt caret")
	return string(preedit_buf[:preedit_len]), preedit_caret
}
