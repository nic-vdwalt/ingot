// ingot:gfx - input state with raylib-parity queries. Edge (pressed /
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
	key_down:             [KEY_COUNT]bool,

	// char / key queues (FIFO ring)
	char_q:               [CHAR_Q]rune,
	char_h, char_t:       int,
	key_q:                [CHAR_Q]KeyboardKey,
	key_h, key_t:         int,

	// Platform event callbacks stage per-window events here until that
	// context publishes its next frame-visible input snapshot. Every backend
	// writes these and only _input_publish_staged reads them, so the browser
	// and GLFW paths cannot disagree about who owns an edge.
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
	web_mb_pressed:       [8]bool,
	web_mb_released:      [8]bool,

	// wheel
	wheel:                Vector2,
	wheel_pending:        Vector2,
	cursor_on_screen:     bool,
	cur_cursor:           MouseCursor,
	cursor_hidden:        bool,
	preedit_buf:          [PREEDIT_MAX]u8,
	preedit_len:          int,
	preedit_caret:        int,
	ime_rect_armed:       bool,
	ime_screen_rect:      [4]f64,

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

// input_poll runs once per frame from EndDrawing: reset frame-scoped state,
// pump backend events (fills queues/edges), then finalize mouse/wheel/button
// deltas via the platform seam.
input_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "input_poll: nil context")
	inp := &ctx.inp
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
	// elapses - this is where idle power saving happens. Web never waits;
	// its gate lives in step() (loop_web.odin).
	platform_drop_prepare_events()
	if should_wait, timeout := _idle_timeout(ctx); should_wait {
		platform_wait_events(timeout)
	} else {
		platform_poll_events(ctx)
	}
	platform_drop_finish_events()
	_drop_hover_publish(ctx)
	_input_publish_staged(inp)

	mx, my := platform_cursor_pos(ctx)
	inp.mouse = {f32(mx), f32(my)}
	inp.mouse_delta = {inp.mouse.x - inp.mouse_prev.x, inp.mouse.y - inp.mouse_prev.y}
	inp.wheel = inp.wheel_pending

	for b in 0 ..< 8 {
		cur := platform_mouse_button(ctx, i32(b))
		when ODIN_OS == .JS {
			inp.mb_pressed[b] = inp.mb_pressed[b] || (cur && !inp.mb_down[b])
			inp.mb_released[b] = inp.mb_released[b] || (!cur && inp.mb_down[b])
		} else {
			inp.mb_pressed[b] = cur && !inp.mb_down[b]
			inp.mb_released[b] = !cur && inp.mb_down[b]
		}
		inp.mb_down[b] = cur
	}
	inp.cursor_on_screen = platform_window_hovered(ctx)

	// Gamepads: snapshot previous button state for edge queries, then poll.
	for p in 0 ..< MAX_GAMEPADS {
		inp.pads[p].prev_buttons = inp.pads[p].buttons
	}
	platform_gamepad_poll(&inp.pads, &ctx.idle)

	// IME: if no text field reported a caret rect since the last poll, tell
	// the platform text input is inactive (web blurs the IME proxy; native
	// clears the candidate-window rect). Active fields re-arm every frame.
	if !inp.ime_rect_armed do platform_text_input_deactivate(ctx)
	inp.ime_rect_armed = false
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

// _stage_key and _stage_char are the only way an event reaches the input
// snapshot. Both backends enqueue here - GLFW from its window callbacks,
// the browser from the exported DOM entry points - so there is exactly one
// staging buffer per context and exactly one publisher draining it.
//
// Both run from platform callbacks with no Odin context, so the index
// contract is checked with assert_contextless. A ring index out of range is a
// programmer error; a full ring is an operating condition (the user out-typed
// one frame) and drops the newest event instead.
@(private)
_stage_key :: proc "contextless" (inp: ^Input, key: KeyboardKey) {
	if inp == nil do return
	assert_contextless(inp.st_key_h >= 0 && inp.st_key_h < CHAR_Q, "_stage_key: bad head")
	assert_contextless(inp.st_key_t >= 0 && inp.st_key_t < CHAR_Q, "_stage_key: bad tail")
	nt := (inp.st_key_t + 1) % CHAR_Q
	if nt == inp.st_key_h do return // full: drop rather than overwrite unread keys
	inp.st_key_q[inp.st_key_t] = key
	inp.st_key_t = nt
}

@(private)
_stage_char :: proc "contextless" (inp: ^Input, value: rune) {
	if inp == nil do return
	assert_contextless(inp.st_char_h >= 0 && inp.st_char_h < CHAR_Q, "_stage_char: bad head")
	assert_contextless(inp.st_char_t >= 0 && inp.st_char_t < CHAR_Q, "_stage_char: bad tail")
	nt := (inp.st_char_t + 1) % CHAR_Q
	if nt == inp.st_char_h do return // full: drop rather than overwrite unread chars
	inp.st_char_q[inp.st_char_t] = value
	inp.st_char_t = nt
}

// _input_publish_staged moves one frame of staged events into the published
// snapshot. It is the single writer of the published key edges: input_poll
// clears them immediately before calling this, and every producer stages
// instead of publishing. A backend that wrote the published arrays directly
// would have its edges silently overwritten here - that erased every browser
// key edge (Enter, Backspace, Tab, arrows) while typed characters, which ride
// the char ring, kept working and hid the fault. The entry assertions are the
// standing oracle for that contract.
@(private)
_input_publish_staged :: proc(inp: ^Input) {
	assert(inp != nil, "_input_publish_staged: nil input")
	for index in 0 ..< KEY_COUNT {
		assert(!inp.pressed[index], "_input_publish_staged: press published before staging")
		assert(!inp.released[index], "_input_publish_staged: release published before staging")
		assert(!inp.repeat[index], "_input_publish_staged: repeat published before staging")
		inp.pressed[index] = inp.st_pressed[index]
		inp.released[index] = inp.st_released[index]
		inp.repeat[index] = inp.st_repeat[index]
		inp.st_pressed[index] = false
		inp.st_released[index] = false
		inp.st_repeat[index] = false
	}
	// Both rings hold at most CHAR_Q - 1 entries (the head/tail encoding
	// keeps one slot empty), so the drains are bounded by construction; the
	// loop bound states it rather than trusting the indices to stay sane.
	for _ in 0 ..< CHAR_Q {
		if inp.st_key_h == inp.st_key_t do break
		_push_key_input(inp, inp.st_key_q[inp.st_key_h])
		inp.st_key_h = (inp.st_key_h + 1) % CHAR_Q
	}
	for _ in 0 ..< CHAR_Q {
		if inp.st_char_h == inp.st_char_t do break
		_push_char_input(inp, inp.st_char_q[inp.st_char_h])
		inp.st_char_h = (inp.st_char_h + 1) % CHAR_Q
	}
	assert(inp.st_key_h == inp.st_key_t, "_input_publish_staged: key ring not drained")
	assert(inp.st_char_h == inp.st_char_t, "_input_publish_staged: char ring not drained")
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
	return context_is_key_down(default_context(), key)
}

context_get_char_pressed_impl :: proc(ctx: ^Context) -> rune {
	if ctx == nil || ctx.inp.char_h == ctx.inp.char_t do return 0
	r := ctx.inp.char_q[ctx.inp.char_h]
	ctx.inp.char_h = (ctx.inp.char_h + 1) % CHAR_Q
	return r
}

GetCharPressed :: proc() -> rune {
	return context_get_char_pressed_impl(default_context())
}

context_get_key_pressed :: proc(ctx: ^Context) -> KeyboardKey {
	if ctx == nil || ctx.inp.key_h == ctx.inp.key_t do return .KEY_NULL
	k := ctx.inp.key_q[ctx.inp.key_h]
	ctx.inp.key_h = (ctx.inp.key_h + 1) % CHAR_Q
	return k
}

GetKeyPressed :: proc() -> KeyboardKey {
	return context_get_key_pressed(default_context())
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
	return context_is_mouse_button_down(default_context(), button)
}

// --- gamepad queries (raylib-named) ----------------------------------------

context_is_gamepad_available :: proc(ctx: ^Context, gamepad: i32) -> bool {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	return ctx.inp.pads[gamepad].connected
}

IsGamepadAvailable :: proc(gamepad: i32) -> bool {
	return context_is_gamepad_available(default_context(), gamepad)
}

// GetGamepadName returns the backend-reported device name (empty when the
// slot is empty). The cstring is temp-allocated; clone to keep past the frame.
context_get_gamepad_name :: proc(ctx: ^Context, gamepad: i32) -> cstring {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return ""
	pad := &ctx.inp.pads[gamepad]
	assert(
		pad.name_len >= 0 && pad.name_len <= GAMEPAD_NAME_MAX,
		"context_get_gamepad_name: corrupt length",
	)
	return strings.clone_to_cstring(string(pad.name[:pad.name_len]), context.temp_allocator)
}

GetGamepadName :: proc(gamepad: i32) -> cstring {
	return context_get_gamepad_name(default_context(), gamepad)
}

context_is_gamepad_button_down :: proc(
	ctx: ^Context,
	gamepad: i32,
	button: GamepadButton,
) -> bool {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	return ctx.inp.pads[gamepad].buttons[b]
}

IsGamepadButtonDown :: proc(gamepad: i32, button: GamepadButton) -> bool {
	return context_is_gamepad_button_down(default_context(), gamepad, button)
}

context_is_gamepad_button_pressed :: proc(
	ctx: ^Context,
	gamepad: i32,
	button: GamepadButton,
) -> bool {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	pad := &ctx.inp.pads[gamepad]
	return pad.buttons[b] && !pad.prev_buttons[b]
}

IsGamepadButtonPressed :: proc(gamepad: i32, button: GamepadButton) -> bool {
	return context_is_gamepad_button_pressed(default_context(), gamepad, button)
}

context_is_gamepad_button_released :: proc(
	ctx: ^Context,
	gamepad: i32,
	button: GamepadButton,
) -> bool {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return false
	b := i32(button)
	if b < 0 || b >= GAMEPAD_BUTTON_COUNT do return false
	pad := &ctx.inp.pads[gamepad]
	return !pad.buttons[b] && pad.prev_buttons[b]
}

IsGamepadButtonReleased :: proc(gamepad: i32, button: GamepadButton) -> bool {
	return context_is_gamepad_button_released(default_context(), gamepad, button)
}

// GetGamepadAxisMovement returns the axis position in -1..1 (triggers rest at
// -1, matching raylib/GLFW). 0 for disconnected pads or out-of-range axes.
context_get_gamepad_axis_movement :: proc(ctx: ^Context, gamepad: i32, axis: GamepadAxis) -> f32 {
	if ctx == nil || gamepad < 0 || gamepad >= MAX_GAMEPADS do return 0
	a := i32(axis)
	if a < 0 || a >= GAMEPAD_AXIS_COUNT do return 0
	if !ctx.inp.pads[gamepad].connected do return 0
	v := ctx.inp.pads[gamepad].axes[a]
	assert(v >= -1.001 && v <= 1.001, "context_get_gamepad_axis_movement: axis out of range")
	return v
}

GetGamepadAxisMovement :: proc(gamepad: i32, axis: GamepadAxis) -> f32 {
	return context_get_gamepad_axis_movement(default_context(), gamepad, axis)
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

// SetMousePosition warps the cursor to window coordinates (raylib parity).
// The buffered position updates immediately so the frame that requests the warp
// already reads the new value; the platform is told as well so the next poll
// agrees. No-op on web, where a page cannot move the system cursor.
//
// Deterministic capture depends on this: hover, tooltips, and focus rings are
// derived from the pointer, so a recorded frame is only reproducible when the
// harness owns the cursor rather than inheriting wherever the user left it.
SetMousePosition :: proc(x, y: i32) {
	context_set_mouse_position(default_context(), x, y)
}

context_set_mouse_position :: proc(ctx: ^Context, x, y: i32) {
	if ctx == nil || !ctx.initialized do return
	position := Vector2{f32(x), f32(y)}
	ctx.inp.mouse = position
	ctx.inp.mouse_delta = {}
	platform_set_cursor_pos(ctx, f64(x), f64(y))
	assert(ctx.inp.mouse == position, "SetMousePosition: buffered position not applied")
	assert(ctx.inp.mouse_delta == Vector2{}, "SetMousePosition: warp must not report a delta")
}

context_get_mouse_x :: proc(ctx: ^Context) -> i32 {return i32(context_get_mouse_position(ctx).x)}
context_get_mouse_y :: proc(ctx: ^Context) -> i32 {return i32(context_get_mouse_position(ctx).y)}

GetMouseX :: proc() -> i32 {return context_get_mouse_x(default_context())}
GetMouseY :: proc() -> i32 {return context_get_mouse_y(default_context())}

context_get_mouse_wheel_move :: proc(ctx: ^Context) -> f32 {
	wheel := context_get_mouse_wheel_move_v(ctx)
	if abs(wheel.x) > abs(wheel.y) do return wheel.x
	return wheel.y
}

GetMouseWheelMove :: proc() -> f32 {
	return context_get_mouse_wheel_move(default_context())
}
GetMouseWheelMoveV :: proc() -> Vector2 {return context_get_mouse_wheel_move_v(default_context())}

context_get_clipboard_text_impl :: proc(ctx: ^Context) -> cstring {
	if ctx == nil do return ""
	s := platform_get_clipboard(ctx)
	return strings.clone_to_cstring(s, context.temp_allocator)
}

GetClipboardText :: proc() -> cstring {
	return context_get_clipboard_text_impl(default_context())
}

context_set_clipboard_text_impl :: proc(ctx: ^Context, text: cstring) {
	if ctx == nil do return
	platform_set_clipboard(ctx, text)
}

SetClipboardText :: proc(text: cstring) {
	context_set_clipboard_text_impl(default_context(), text)
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
// DOM control with an ARIA role - buttons, checkboxes, radios, sliders,
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

context_set_mouse_cursor_impl :: proc(ctx: ^Context, cursor: MouseCursor) {
	if ctx == nil do return
	i := int(cursor)
	if i < 0 || i >= 11 do return
	if cursor == ctx.inp.cur_cursor do return
	ctx.inp.cur_cursor = cursor
	if !ctx.inp.cursor_hidden do platform_set_mouse_cursor(ctx, cursor)
}

SetMouseCursor :: proc(cursor: MouseCursor) {
	context_set_mouse_cursor_impl(default_context(), cursor)
}

// HideCursor hides the OS cursor over the window; SetMouseCursor calls made
// while hidden are remembered and reapplied by ShowCursor.
context_hide_cursor :: proc(ctx: ^Context) {
	if ctx == nil || ctx.inp.cursor_hidden do return
	ctx.inp.cursor_hidden = true
	platform_set_cursor_hidden(ctx, true)
}

HideCursor :: proc() {
	context_hide_cursor(default_context())
}

context_show_cursor :: proc(ctx: ^Context) {
	if ctx == nil || !ctx.inp.cursor_hidden do return
	ctx.inp.cursor_hidden = false
	platform_set_cursor_hidden(ctx, false)
	platform_set_mouse_cursor(ctx, ctx.inp.cur_cursor)
}

ShowCursor :: proc() {
	context_show_cursor(default_context())
}

context_is_cursor_hidden :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.inp.cursor_hidden
}

IsCursorHidden :: proc() -> bool {
	return context_is_cursor_hidden(default_context())
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
context_set_text_input_rect_impl :: proc(ctx: ^Context, x, y, w, h: i32) {
	assert(ctx != nil, "context_set_text_input_rect: nil context")
	assert(w >= 0 && h >= 0, "context_set_text_input_rect: negative size")
	assert(ctx.win != nil, "context_set_text_input_rect: window not initialized")
	ctx.inp.ime_rect_armed = true
	platform_set_text_input_rect(ctx, x, y, w, h)
}

SetTextInputRect :: proc(x, y, w, h: i32) {
	context_set_text_input_rect_impl(default_context(), x, y, w, h)
}

// GetPreedit returns the in-progress IME composition string (empty when not
// composing) and the caret byte offset within it. The string aliases an
// internal buffer valid until the next composition event; clone to keep.
context_get_preedit :: proc(ctx: ^Context) -> (text: string, caret: int) {
	if ctx == nil do return "", 0
	assert(
		ctx.inp.preedit_len >= 0 && ctx.inp.preedit_len <= PREEDIT_MAX,
		"context_get_preedit: corrupt length",
	)
	assert(
		ctx.inp.preedit_caret >= 0 && ctx.inp.preedit_caret <= ctx.inp.preedit_len,
		"context_get_preedit: corrupt caret",
	)
	return string(ctx.inp.preedit_buf[:ctx.inp.preedit_len]), ctx.inp.preedit_caret
}

GetPreedit :: proc() -> (text: string, caret: int) {
	return context_get_preedit(default_context())
}
