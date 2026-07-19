// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

import rl "ingot:gfx"

// Deferred, focus-gated mouse-cursor management.
//
// Two bugs motivated this:
//
//  1. raylib's SetMouseCursor only issues a platform cursor change when the
//     requested value differs from the current one. Resetting the cursor to
//     DEFAULT at the start of every frame and letting hover handlers set
//     POINTING_HAND during render produces a DEFAULT->HAND toggle every frame
//     while the pointer sits over a button — on macOS the cursor visibly
//     flickers between the arrow and the hand.
//
//  2. Setting the cursor every frame with no focus check keeps pushing cursor
//     changes to the OS even while another app is focused.
//
// Instead we accumulate the desired cursor for the frame without touching the
// OS, then apply it once at the end of the frame: only when it actually
// changed and only when our window is focused and the pointer is over it.

@(private = "file")
g_requested_cursor: rl.MouseCursor = .DEFAULT

@(private = "file")
g_applied_cursor: rl.MouseCursor = .DEFAULT

@(private = "file")
g_cursor_initialized: bool

// begin_cursor_frame resets the requested cursor to DEFAULT. Call once at the
// start of each frame, before any UI is drawn.
begin_cursor_frame :: proc() {
	g_requested_cursor = .DEFAULT
}

// request_cursor records the desired cursor for this frame. Hover handlers
// call this instead of rl.SetMouseCursor; the last caller wins.
request_cursor :: proc(c: rl.MouseCursor) {
	g_requested_cursor = c
}

// apply_cursor applies the requested cursor once per frame. Call once at the
// end of each frame, after all UI is drawn.
apply_cursor :: proc() {
	if !rl.IsWindowFocused() || !rl.IsCursorOnScreen() {
		g_cursor_initialized = false
		return
	}
	if !g_cursor_initialized || g_requested_cursor != g_applied_cursor {
		rl.SetMouseCursor(g_requested_cursor)
		g_applied_cursor = g_requested_cursor
		g_cursor_initialized = true
	}
}
