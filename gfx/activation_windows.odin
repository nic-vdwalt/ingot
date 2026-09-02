#+build windows
package gfx

import win32 "core:sys/windows"

@(private)
_platform_activate_window :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activate_window: nil context")
	hwnd := win32.HWND(context_get_window_handle(ctx))
	if hwnd == nil do return
	if win32.IsIconic(hwnd) do win32.ShowWindow(hwnd, win32.SW_RESTORE)
	if win32.GetForegroundWindow() != hwnd {
		if !bool(win32.SetForegroundWindow(hwnd)) do return
	}
	_ = win32.SetActiveWindow(hwnd)
	_ = win32.SetFocus(hwnd)
}

@(private)
_platform_activation_poll :: proc(ctx: ^Context) {
	assert(ctx != nil, "_platform_activation_poll: nil context")
}

@(private)
_platform_native_window_focus :: proc(ctx: ^Context) -> (focused, known: bool) {
	if ctx == nil || ctx.win == nil do return false, false
	hwnd := win32.HWND(context_get_window_handle(ctx))
	if hwnd == nil do return false, false
	foreground := win32.GetForegroundWindow()
	if foreground != hwnd do return false, true
	focus := win32.GetFocus()
	return focus == nil || focus == hwnd || bool(win32.IsChild(hwnd, focus)), true
}
