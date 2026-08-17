#+build !darwin
#+build !js
// ingot:gfx - native-fullscreen detection stub.
//
// Windows and Linux have no OS-owned fullscreen mode that bypasses GLFW the way
// macOS Spaces do: every fullscreen transition there goes through
// SetWindowMonitor, which GetWindowMonitor already reports. Borderless-maximised
// windows are deliberately not counted as fullscreen - they are ordinary
// windows and consumers size to the client rect either way.
package gfx

@(private)
_platform_native_fullscreen :: proc(ctx: ^Context) -> bool {
	return false
}
