// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

Cursor_State :: struct {
	requested:   rl.MouseCursor,
	applied:     rl.MouseCursor,
	initialized: bool,
}

request_cursor :: proc(frame: ^Ui_Frame, cursor: rl.MouseCursor) {
	assert(frame != nil && frame.open, "request_cursor: invalid frame")
	frame.cursor.requested = cursor
}

cursor_apply :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "cursor_apply: invalid frame")
	state := &frame.cursor
	if !rl.IsWindowFocused() || !rl.IsCursorOnScreen() {
		state.initialized = false
		return
	}
	if !state.initialized || state.requested != state.applied {
		rl.SetMouseCursor(state.requested)
		state.applied = state.requested
		state.initialized = true
	}
}
