#+build windows
// LIB-CANDIDATE: imports only core:* and vendor:raylib.
package ui

import rl "vendor:raylib"
import win32 "core:sys/windows"

// DWM attribute constants (not in core:sys/windows).
DWMWA_USE_IMMERSIVE_DARK_MODE :: 20
DWMWA_SYSTEMBACKDROP_TYPE :: 38

// Backdrop types for Windows 11.
DWMSBT_MAINWINDOW :: 2   // Mica
DWMSBT_TABBEDWINDOW :: 4 // Mica Alt (tabbed)

foreign import dwmapi "system:dwmapi.lib"
@(default_calling_convention = "stdcall")
foreign dwmapi {
	DwmSetWindowAttribute :: proc(hwnd: win32.HWND, attr: win32.DWORD, value: rawptr, size: win32.DWORD) -> win32.HRESULT ---
}

// Apply modern Windows 11 Mica effect and dark mode to the window title bar.
// Call after rl.InitWindow(). Silently fails on older Windows versions.
apply_window_style :: proc() {
	hwnd := cast(win32.HWND)rl.GetWindowHandle()
	if hwnd == nil do return

	// Enable dark mode for title bar (matches app's dark theme).
	dark: win32.BOOL = true
	DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, &dark, size_of(dark))

	// Apply Mica backdrop (Windows 11 22H2+).
	backdrop: win32.DWORD = DWMSBT_MAINWINDOW
	DwmSetWindowAttribute(hwnd, DWMWA_SYSTEMBACKDROP_TYPE, &backdrop, size_of(backdrop))
}
