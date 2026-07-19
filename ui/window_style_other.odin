#+build linux
// LIB-CANDIDATE: imports only core:* and ingot:gfx.
package ui

// No-op on Linux (Windows uses Mica, macOS uses a vibrancy backdrop).
apply_window_style :: proc() {}
