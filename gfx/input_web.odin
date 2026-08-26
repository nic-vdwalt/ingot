#+build js
// ingot:gfx - browser input entry points.
//
// These procs are exported to WASM and called from web/ingot_input.js when DOM
// events fire (keydown/keyup, pointer, wheel, focus). Keys, characters and
// wheel stage into g.inp's staging buffer - the same one the GLFW callbacks in
// platform_native.odin write - and input_poll's _input_publish_staged drains it
// each frame, so the app sees the same g.inp state and raylib-named queries
// (IsKeyPressed, GetMousePosition, …) as on native.
//
// Publishing directly here instead would be silently undone: input_poll clears
// the published edges before the pump and fills them from staging after it.
// Held/hover/cursor state is different in kind - it answers a live platform
// query rather than describing an event - so it lives in platform_web.odin.
//
// Key codes are pre-mapped in JS (browser KeyboardEvent.code → ingot/raylib
// KeyboardKey integer, which equals the GLFW value the native path uses), so the
// Odin side stays a thin, backend-neutral sink.
package gfx

@(export)
ingot_web_pointer :: proc "contextless" (
	id: u32,
	pointer_type, kind, button: i32,
	buttons: u32,
	x, y, pressure: f32,
	primary: bool,
) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	if pointer_type < i32(Pointer_Type.Unknown) || pointer_type > i32(Pointer_Type.Pen) do return
	if kind < i32(Pointer_Event_Kind.Move) || kind > i32(Pointer_Event_Kind.Cancel) do return
	if button < -1 || button > i32(Pointer_Button.Back) do return
	if buttons & ~u32(POINTER_BUTTON_MASK) != 0 do return
	if !(pressure >= 0 && pressure <= 1) do pressure = 0
	event := Pointer_Event {
		id           = Pointer_Id(id),
		position     = {x, y},
		pressure     = pressure,
		buttons      = Pointer_Buttons(buttons),
		kind         = Pointer_Event_Kind(kind),
		pointer_type = Pointer_Type(pointer_type),
		button       = Pointer_Button(button),
		primary      = primary,
	}
	if !pointer_event_valid(event) do return
	_ = pointer_stage(&ctx.inp, event)
}

@(export)
ingot_web_key :: proc "contextless" (key: i32, down: bool, repeat: bool) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	if key < 0 || key >= KEY_COUNT do return
	if down {
		if repeat {
			ctx.inp.st_repeat[key] = true
		} else {
			ctx.inp.st_pressed[key] = true
			ctx.inp.key_down[key] = true
			_stage_key(&ctx.inp, KeyboardKey(key))
		}
	} else {
		ctx.inp.st_released[key] = true
		ctx.inp.key_down[key] = false
	}
}

@(export)
ingot_web_char :: proc "contextless" (codepoint: rune) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	_stage_char(&ctx.inp, codepoint)
}

// ingot_web_preedit_clear resets the staged IME composition string. Called
// from JS on compositionstart/compositionend and before each update.
@(export)
ingot_web_preedit_clear :: proc "contextless" () {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	ctx.inp.preedit_len = 0
	ctx.inp.preedit_caret = 0
}

// ingot_web_preedit_char appends one codepoint of the in-progress composition
// (compositionupdate forwards the preedit string codepoint-by-codepoint).
// Manual UTF-8 encode: core:unicode/utf8 needs a context, this is contextless.
@(export)
ingot_web_preedit_char :: proc "contextless" (codepoint: rune) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	c := u32(codepoint)
	if c > 0x10FFFF do return
	n: int
	buf: [4]u8
	switch {
	case c < 0x80:
		buf[0] = u8(c)
		n = 1
	case c < 0x800:
		buf[0] = 0xC0 | u8(c >> 6)
		buf[1] = 0x80 | u8(c & 0x3F)
		n = 2
	case c < 0x10000:
		buf[0] = 0xE0 | u8(c >> 12)
		buf[1] = 0x80 | u8(c >> 6 & 0x3F)
		buf[2] = 0x80 | u8(c & 0x3F)
		n = 3
	case:
		buf[0] = 0xF0 | u8(c >> 18)
		buf[1] = 0x80 | u8(c >> 12 & 0x3F)
		buf[2] = 0x80 | u8(c >> 6 & 0x3F)
		buf[3] = 0x80 | u8(c & 0x3F)
		n = 4
	}
	if ctx.inp.preedit_len + n > PREEDIT_MAX do return // bounded: drop overflow
	for i in 0 ..< n {
		ctx.inp.preedit_buf[ctx.inp.preedit_len + i] = buf[i]
	}
	ctx.inp.preedit_len += n
	ctx.inp.preedit_caret = ctx.inp.preedit_len
}

// x, y are in CSS pixels (logical points) - matching GetScreenWidth/Height and
// the native macOS GetCursorPos convention.
@(export)
ingot_web_mouse_move :: proc "contextless" (x, y: f32) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	ctx.inp.st_mouse = {x, y}
	ctx.inp.st_mouse_valid = true
	ctx.inp.cursor_on_screen = true
}

@(export)
ingot_web_mouse_button :: proc "contextless" (button: i32, down: bool) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	if button < 0 || button >= 8 do return
	if down && !ctx.inp.mb_down[button] do ctx.inp.web_mb_pressed[button] = true
	if !down && ctx.inp.mb_down[button] do ctx.inp.web_mb_released[button] = true
	ctx.inp.mb_down[button] = down
}

@(export)
ingot_web_wheel :: proc "contextless" (dx, dy: f32) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	ctx.inp.st_wheel.x += dx
	ctx.inp.st_wheel.y += dy
}

@(export)
ingot_web_hover :: proc "contextless" (hovered: bool) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	ctx.inp.cursor_on_screen = hovered
	if !hovered {
		// releasing focus/hover: clear held keys and buttons so nothing sticks
		ctx.inp.key_down = {}
		ctx.inp.mb_down = {}
		ctx.inp.st_mouse_valid = false
		ctx.inp.mouse_initialized = false
	}
}

@(export)
ingot_web_file_drag_over :: proc "contextless" (over: bool) {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	_drop_hover_stage_context(ctx, over)
}

// ingot_web_drop_notify is called from JS (ingot_web.js attachDrop) after
// dropped files are staged; IsFileDropped flips on the next frame and the
// idle gate wakes so an event-driven app processes the drop immediately.
@(export)
ingot_web_drop_notify :: proc "contextless" () {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
	_drop_complete_context(ctx)
}

// ingot_web_resize is called from web/ingot_web.js on window resize so an
// idle event-driven app re-renders at the new canvas size (the shared
// _maybe_reconfigure picks the size up at the next BeginDrawing).
@(export)
ingot_web_resize :: proc "contextless" () {
	ctx := _web_owner_context()
	if ctx == nil do return
	_idle_note_activity(&ctx.idle)
}

@(export)
ingot_web_resume :: proc "contextless" () {
	ctx := _web_owner_context()
	if ctx == nil do return
	ctx.force_reconfigure = true
	_idle_note_activity(&ctx.idle)
}
