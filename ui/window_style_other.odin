#+build !darwin
#+build !windows
// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

// No-op on Linux/web (Windows uses Mica, macOS uses a vibrancy backdrop; the
// browser owns the tab chrome).
apply_window_style :: proc() {}
