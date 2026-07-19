#+build !windows
// LIB-CANDIDATE: imports only core:* and vendor:raylib.
package ui

import rl "vendor:raylib"

// No-op custom title bar on non-Windows platforms (native title bar is used).

Titlebar_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

titlebar_init :: proc() {}

titlebar_enabled :: proc() -> bool {
	return false
}

titlebar_set_layout :: proc(min_r, max_r, close_r: rl.Rectangle, interactive_right: i32) {}

titlebar_state :: proc() -> (hover, pressed: Titlebar_Button, maximized: bool) {
	return .None, .None, false
}

titlebar_consume_activity :: proc() -> bool {
	return false
}
