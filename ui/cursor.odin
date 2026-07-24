// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui


Cursor_State :: struct {
	requested:   MouseCursor,
	applied:     MouseCursor,
	initialized: bool,
}

request_cursor :: proc(frame: ^Ui_Frame, cursor: MouseCursor) {
	assert(frame != nil && frame.open, "request_cursor: invalid frame")
	frame.cursor.requested = cursor
}

cursor_apply :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "cursor_apply: invalid frame")
	state := &frame.cursor
	if !frame_input(frame).window_focused || !frame_input(frame).cursor_on_screen {
		state.initialized = false
		return
	}
	if !state.initialized || state.requested != state.applied {
		assert(frame.output != nil, "cursor_apply: missing output")
		frame.output.platform.cursor = state.requested
		frame.output.platform.cursor_requested = true
		state.applied = state.requested
		state.initialized = true
	}
}
