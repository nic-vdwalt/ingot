#+build windows
// LIB-CANDIDATE: imports only core:*.
package ui

import win32 "core:sys/windows"


// Custom window title bar (Windows only).
//
// Technique: keep the WS_OVERLAPPEDWINDOW styles GLFW sets (so DWM shadow,
// rounded corners, minimize/maximize animations, aero snap, and Win+arrow all
// keep working) but remove the non-client frame by returning 0 from
// WM_NCCALCSIZE, then do all hit-testing ourselves in WM_NCHITTEST. The header
// row doubles as the title bar: empty strip space drags the window
// (HTCAPTION), interactive widgets stay HTCLIENT, and three caption buttons at
// the top-right are non-client (HTMINBUTTON/HTMAXBUTTON/HTCLOSE — HTMAXBUTTON is
// what makes the Windows 11 Snap Layouts flyout appear on hover).
//
// Because the caption buttons are non-client, GLFW/raylib never receives
// mouse events over them. Hover/pressed state is tracked here from the
// WM_NC* messages and read by the draw code (draw_caption_buttons) each
// frame via titlebar_state(). The subclass proc runs on the main thread
// (GLFW pumps messages inside the host frame end), so plain globals are safe.

TITLEBAR_SUBCLASS_ID :: 2

Titlebar_Button :: enum u8 {
	None,
	Minimize,
	Maximize,
	Close,
}

// Module state. Written by the subclass proc and the per-frame layout
// publish; read by the draw code. All rects are in physical client pixels
// (identical to raylib render coordinates).
@(private = "file")
tb_hwnd: win32.HWND
@(private = "file")
tb_hover: Titlebar_Button
@(private = "file")
tb_pressed: Titlebar_Button
@(private = "file")
tb_maximized: bool
@(private = "file")
tb_activity: bool // NC state changed → request a redraw
@(private = "file")
tb_tracking: bool // TrackMouseEvent armed
@(private = "file")
tb_btn_min: Rectangle
@(private = "file")
tb_btn_max: Rectangle
@(private = "file")
tb_btn_close: Rectangle
@(private = "file")
tb_caption_h: i32
@(private = "file")
tb_interactive_right: i32

// titlebar_init installs the subclass and strips the standard frame.
// Call once after host window initialization / apply_window_style().
titlebar_init :: proc(window_handle: rawptr = nil) {
	tb_hwnd = cast(win32.HWND)window_handle
	if tb_hwnd == nil do return

	tb_caption_h = TAB_BAR_HEIGHT
	tb_maximized = bool(win32.IsZoomed(tb_hwnd))

	win32.SetWindowSubclass(tb_hwnd, titlebar_subclass_proc, TITLEBAR_SUBCLASS_ID, 0)

	// Belt-and-braces: extend 1px of DWM frame into the client area so the
	// window shadow is always drawn even with a zero non-client area.
	margins := win32.MARGINS{0, 0, 1, 0}
	win32.DwmExtendFrameIntoClientArea(tb_hwnd, &margins)

	// Force a WM_NCCALCSIZE pass so the frame disappears immediately.
	win32.SetWindowPos(
		tb_hwnd,
		nil,
		0,
		0,
		0,
		0,
		win32.SWP_NOMOVE |
		win32.SWP_NOSIZE |
		win32.SWP_NOZORDER |
		win32.SWP_NOACTIVATE |
		win32.SWP_FRAMECHANGED,
	)
}

titlebar_enabled :: proc() -> bool {
	return tb_hwnd != nil
}

// titlebar_set_layout publishes the caption button rects and the right edge
// of the interactive header region (widgets that must stay clickable) for
// non-client hit-testing. Call every frame after drawing. interactive_right
// == 0 means the whole caption band (minus buttons) is a drag region.
titlebar_set_layout :: proc(min_r, max_r, close_r: Rectangle, interactive_right: i32) {
	tb_btn_min = min_r
	tb_btn_max = max_r
	tb_btn_close = close_r
	tb_caption_h = TAB_BAR_HEIGHT
	tb_interactive_right = interactive_right
}

titlebar_state :: proc() -> (hover, pressed: Titlebar_Button, maximized: bool) {
	return tb_hover, tb_pressed, tb_maximized
}

// titlebar_consume_activity reports (and clears) whether non-client state
// changed since the last frame — used to wake the render loop out of
// IDLE_FPS so caption-button hover feedback is immediate.
titlebar_consume_activity :: proc() -> bool {
	a := tb_activity
	tb_activity = false
	return a
}

// --- Internal ---------------------------------------------------------------

@(private = "file")
tb_set_hover :: proc "system" (b: Titlebar_Button) {
	if tb_hover != b {
		tb_hover = b
		tb_activity = true
	}
}

@(private = "file")
tb_set_pressed :: proc "system" (b: Titlebar_Button) {
	if tb_pressed != b {
		tb_pressed = b
		tb_activity = true
	}
}

@(private = "file")
tb_button_from_hittest :: proc "system" (ht: win32.LRESULT) -> Titlebar_Button {
	switch ht {
	case win32.HTMINBUTTON:
		return .Minimize
	case win32.HTMAXBUTTON:
		return .Maximize
	case win32.HTCLOSE:
		return .Close
	}
	return .None
}

@(private = "file")
tb_point_in_rect :: proc "system" (x, y: i32, r: Rectangle) -> bool {
	return(
		r.width > 0 &&
		r.height > 0 &&
		f32(x) >= r.x &&
		f32(x) < r.x + r.width &&
		f32(y) >= r.y &&
		f32(y) < r.y + r.height \
	)
}

// Resize border thickness in physical px for the window's DPI.
@(private = "file")
tb_border_px :: proc "system" (hwnd: win32.HWND) -> i32 {
	dpi := win32.GetDpiForWindow(hwnd)
	return i32(
		win32.GetSystemMetricsForDpi(win32.SM_CXSIZEFRAME, dpi) +
		win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi),
	)
}

// Full hit test in client coordinates.
@(private = "file")
tb_hittest :: proc "system" (hwnd: win32.HWND, cx, cy: i32) -> win32.LRESULT {
	rc: win32.RECT
	win32.GetClientRect(hwnd, &rc)
	w := i32(rc.right - rc.left)
	h := i32(rc.bottom - rc.top)

	// Resize borders (none when maximized — also puts the close button in the
	// exact top-right corner for easy clicking).
	if !tb_maximized {
		b := tb_border_px(hwnd)
		on_left := cx < b
		on_right := cx >= w - b
		on_top := cy < b
		on_bottom := cy >= h - b
		if on_top {
			if on_left do return win32.HTTOPLEFT
			if on_right do return win32.HTTOPRIGHT
			return win32.HTTOP
		}
		if on_bottom {
			if on_left do return win32.HTBOTTOMLEFT
			if on_right do return win32.HTBOTTOMRIGHT
			return win32.HTBOTTOM
		}
		if on_left do return win32.HTLEFT
		if on_right do return win32.HTRIGHT
	}

	// Caption buttons (HTMAXBUTTON triggers the Win11 Snap Layouts flyout).
	if tb_point_in_rect(cx, cy, tb_btn_min) do return win32.HTMINBUTTON
	if tb_point_in_rect(cx, cy, tb_btn_max) do return win32.HTMAXBUTTON
	if tb_point_in_rect(cx, cy, tb_btn_close) do return win32.HTCLOSE

	// Caption band: interactive widgets stay client, the rest drags.
	if cy < tb_caption_h {
		if cx < tb_interactive_right do return win32.HTCLIENT
		return win32.HTCAPTION
	}

	return win32.HTCLIENT
}

@(private = "file")
tb_handle_nccalcsize :: proc "system" (
	hwnd: win32.HWND,
	wparam: win32.WPARAM,
	lparam: win32.LPARAM,
) -> (
	win32.LRESULT,
	bool,
) {
	if wparam == 0 do return 0, false
	if win32.IsZoomed(hwnd) {
		params := cast(^win32.NCCALCSIZE_PARAMS)uintptr(lparam)
		dpi := win32.GetDpiForWindow(hwnd)
		border_x :=
			win32.GetSystemMetricsForDpi(win32.SM_CXSIZEFRAME, dpi) +
			win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
		border_y :=
			win32.GetSystemMetricsForDpi(win32.SM_CYSIZEFRAME, dpi) +
			win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
		params.rgrc[0].left += border_x
		params.rgrc[0].right -= border_x
		params.rgrc[0].top += border_y
		params.rgrc[0].bottom -= border_y
	}
	return 0, true
}

@(private = "file")
tb_handle_ncbutton_up :: proc "system" (hwnd: win32.HWND, wparam: win32.WPARAM) -> bool {
	button := tb_button_from_hittest(win32.LRESULT(wparam))
	if tb_pressed == .None do return false
	if button == tb_pressed {
		switch button {
		case .Minimize:
			win32.ShowWindow(hwnd, win32.SW_MINIMIZE)
		case .Maximize:
			win32.ShowWindow(hwnd, win32.SW_RESTORE if win32.IsZoomed(hwnd) else win32.SW_MAXIMIZE)
		case .Close:
			win32.PostMessageW(hwnd, win32.WM_CLOSE, 0, 0)
		case .None:
		}
	}
	tb_set_pressed(.None)
	return true
}

@(private = "file")
titlebar_subclass_proc :: proc "system" (
	hwnd: win32.HWND,
	msg: win32.UINT,
	wparam: win32.WPARAM,
	lparam: win32.LPARAM,
	id_subclass: win32.UINT_PTR,
	ref_data: win32.DWORD_PTR,
) -> win32.LRESULT {
	switch msg {
	case win32.WM_NCCALCSIZE:
		if result, handled := tb_handle_nccalcsize(hwnd, wparam, lparam); handled do return result

	case win32.WM_NCHITTEST:
		// Screen coords, sign-extended (negative on monitors left/above the
		// primary), converted to client px == raylib render coordinates.
		pt := win32.POINT {
			x = win32.LONG(i16(u16(uintptr(lparam) & 0xFFFF))),
			y = win32.LONG(i16(u16((uintptr(lparam) >> 16) & 0xFFFF))),
		}
		win32.ScreenToClient(hwnd, &pt)
		ht := tb_hittest(hwnd, i32(pt.x), i32(pt.y))
		tb_set_hover(tb_button_from_hittest(ht))
		return ht

	case win32.WM_NCMOUSEMOVE:
		tb_set_hover(tb_button_from_hittest(win32.LRESULT(wparam)))
		if !tb_tracking {
			tme := win32.TRACKMOUSEEVENT {
				cbSize      = size_of(win32.TRACKMOUSEEVENT),
				dwFlags     = win32.TME_LEAVE | win32.TME_NONCLIENT,
				hwndTrack   = hwnd,
				dwHoverTime = 0,
			}
			win32.TrackMouseEvent(&tme)
			tb_tracking = true
		}

	case win32.WM_NCMOUSELEAVE:
		tb_tracking = false
		tb_set_hover(.None)
		tb_set_pressed(.None)

	case win32.WM_MOUSEMOVE:
		// Mouse entered the client area — clear any caption button hover.
		tb_set_hover(.None)

	case win32.WM_NCLBUTTONDOWN:
		btn := tb_button_from_hittest(win32.LRESULT(wparam))
		if btn != .None {
			// Swallow: DefWindowProc would draw legacy Win95-style buttons.
			tb_set_pressed(btn)
			return 0
		}

	case win32.WM_NCLBUTTONUP:
		if tb_handle_ncbutton_up(hwnd, wparam) do return 0

	case win32.WM_NCLBUTTONDBLCLK:
		// Double-click on a caption button must not toggle maximize;
		// HTCAPTION double-click (maximize) passes through to DefWindowProc.
		if tb_button_from_hittest(win32.LRESULT(wparam)) != .None {
			return 0
		}

	case win32.WM_SIZE:
		was := tb_maximized
		tb_maximized = wparam == win32.SIZE_MAXIMIZED
		if was != tb_maximized do tb_activity = true

	case win32.WM_NCACTIVATE:
		// lparam = -1 suppresses the legacy frame repaint on focus change.
		return win32.DefSubclassProc(hwnd, msg, wparam, transmute(win32.LPARAM)i64(-1))
	}

	return win32.DefSubclassProc(hwnd, msg, wparam, lparam)
}
