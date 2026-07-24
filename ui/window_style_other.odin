#+build !darwin
#+build !windows
// LIB-CANDIDATE: imports only core:*.
package ui

// No-op on Linux/web (Windows uses Mica, macOS uses a vibrancy backdrop; the
// browser owns the tab chrome).
apply_window_style :: proc(window_handle: rawptr = nil) {
	_ = window_handle
}
