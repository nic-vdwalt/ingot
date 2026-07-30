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
ingot_web_key :: proc "contextless" (key: i32, down: bool, repeat: bool) {
	_idle_note_activity(&g.idle)
	if key < 0 || key >= KEY_COUNT do return
	if down {
		if repeat {
			g.inp.st_repeat[key] = true
		} else {
			g.inp.st_pressed[key] = true
			st_held[key] = true
			_stage_key(&g.inp, KeyboardKey(key))
		}
	} else {
		g.inp.st_released[key] = true
		st_held[key] = false
	}
}

@(export)
ingot_web_char :: proc "contextless" (codepoint: rune) {
	_idle_note_activity(&g.idle)
	_stage_char(&g.inp, codepoint)
}

// ingot_web_preedit_clear resets the staged IME composition string. Called
// from JS on compositionstart/compositionend and before each update.
@(export)
ingot_web_preedit_clear :: proc "contextless" () {
	_idle_note_activity(&g.idle)
	preedit_len = 0
	preedit_caret = 0
}

// ingot_web_preedit_char appends one codepoint of the in-progress composition
// (compositionupdate forwards the preedit string codepoint-by-codepoint).
// Manual UTF-8 encode: core:unicode/utf8 needs a context, this is contextless.
@(export)
ingot_web_preedit_char :: proc "contextless" (codepoint: rune) {
	_idle_note_activity(&g.idle)
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
	if preedit_len + n > PREEDIT_MAX do return // bounded: drop overflow
	for i in 0 ..< n {
		preedit_buf[preedit_len + i] = buf[i]
	}
	preedit_len += n
	preedit_caret = preedit_len
}

// x, y are in CSS pixels (logical points) - matching GetScreenWidth/Height and
// the native macOS GetCursorPos convention.
@(export)
ingot_web_mouse_move :: proc "contextless" (x, y: f32) {
	_idle_note_activity(&g.idle)
	st_mouse = {x, y}
	st_hovered = true
}

@(export)
ingot_web_mouse_button :: proc "contextless" (button: i32, down: bool) {
	_idle_note_activity(&g.idle)
	if button < 0 || button >= 8 do return
	if down && !st_mb[button] do st_mb_pressed[button] = true
	if !down && st_mb[button] do st_mb_released[button] = true
	st_mb[button] = down
}

@(export)
ingot_web_wheel :: proc "contextless" (dx, dy: f32) {
	_idle_note_activity(&g.idle)
	g.inp.st_wheel.x += dx
	g.inp.st_wheel.y += dy
}

@(export)
ingot_web_hover :: proc "contextless" (hovered: bool) {
	_idle_note_activity(&g.idle)
	st_hovered = hovered
	if !hovered {
		// releasing focus/hover: clear held keys and buttons so nothing sticks
		for i in 0 ..< KEY_COUNT do st_held[i] = false
		for i in 0 ..< 8 do st_mb[i] = false
	}
}

@(export)
ingot_web_file_drag_over :: proc "contextless" (over: bool) {
	_idle_note_activity(&g.idle)
	_drop_hover_stage(over)
}

// ingot_web_drop_notify is called from JS (ingot_web.js attachDrop) after
// dropped files are staged; IsFileDropped flips on the next frame and the
// idle gate wakes so an event-driven app processes the drop immediately.
@(export)
ingot_web_drop_notify :: proc "contextless" () {
	_idle_note_activity(&g.idle)
	_drop_complete()
}

// ingot_web_resize is called from web/ingot_web.js on window resize so an
// idle event-driven app re-renders at the new canvas size (the shared
// _maybe_reconfigure picks the size up at the next BeginDrawing).
@(export)
ingot_web_resize :: proc "contextless" () {
	_idle_note_activity(&g.idle)
}

@(export)
ingot_web_resume :: proc "contextless" () {
	g.force_reconfigure = true
	_idle_note_activity(&g.idle)
}
