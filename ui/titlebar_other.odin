#+build !windows
// LIB-CANDIDATE: imports only core:*.
package ui


// No-op custom title bar on non-Windows platforms (native title bar is used).

Titlebar_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

titlebar_init :: proc(window_handle: rawptr = nil) {
	_ = window_handle
}

titlebar_enabled :: proc() -> bool {
	return false
}

titlebar_set_layout :: proc(
	min_r, max_r, close_r: Rectangle,
	interactive_right, caption_height: i32,
) {}

titlebar_state :: proc() -> (hover, pressed: Titlebar_Button, maximized: bool) {
	return .None, .None, false
}

titlebar_consume_activity :: proc() -> bool {
	return false
}
