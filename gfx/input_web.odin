#+build js
// ingot:gfx — browser input entry points.
//
// These procs are exported to WASM and called from web/ingot_input.js when DOM
// events fire (keydown/keyup, pointer, wheel, focus). They write into the
// staging buffer in platform_web.odin, which platform_poll_events drains into
// the shared Input struct each frame — so the app sees the same g.inp state and
// raylib-named queries (IsKeyPressed, GetMousePosition, …) as on native.
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
			st_repeat[key] = true
		} else {
			st_pressed[key] = true
			st_held[key] = true
			_st_push_key(KeyboardKey(key))
		}
	} else {
		st_released[key] = true
		st_held[key] = false
	}
}

@(export)
ingot_web_char :: proc "contextless" (codepoint: rune) {
	_idle_note_activity(&g.idle)
	_st_push_char(codepoint)
}

// x, y are in CSS pixels (logical points) — matching GetScreenWidth/Height and
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
	st_mb[button] = down
}

@(export)
ingot_web_wheel :: proc "contextless" (dx, dy: f32) {
	_idle_note_activity(&g.idle)
	st_wheel.x += dx
	st_wheel.y += dy
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

// ingot_web_resize is called from web/ingot_web.js on window resize so an
// idle event-driven app re-renders at the new canvas size (the shared
// _maybe_reconfigure picks the size up at the next BeginDrawing).
@(export)
ingot_web_resize :: proc "contextless" () {
	_idle_note_activity(&g.idle)
}
