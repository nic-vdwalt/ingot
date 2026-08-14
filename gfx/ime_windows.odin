#+build windows
// ingot:gfx - Windows IME composition-window positioning.
//
// GLFW delivers final composed characters via WM_CHAR but never positions the
// IME composition/candidate window, so it floats at a default location. We
// point it at the caret with ImmSetCompositionWindow (CFS_POINT) using the
// rect the UI reports via SetTextInputRect each frame.
package gfx

import win32 "core:sys/windows"

foreign import imm32 "system:imm32.lib"
@(default_calling_convention = "system")
foreign imm32 {
	ImmGetContext :: proc(hwnd: win32.HWND) -> rawptr ---
	ImmSetCompositionWindow :: proc(himc: rawptr, form: ^COMPOSITIONFORM) -> win32.BOOL ---
	ImmReleaseContext :: proc(hwnd: win32.HWND, himc: rawptr) -> win32.BOOL ---
}

@(private = "file")
CFS_POINT :: u32(0x0002)

@(private = "file")
COMPOSITIONFORM :: struct {
	dwStyle:      u32,
	ptCurrentPos: win32.POINT,
	rcArea:       win32.RECT,
}

// _ime_set_rect places the composition window at the caret's bottom-left.
// Coordinates are client-area pixels: on Windows the UI lays out in physical
// pixels (ui_scale carries the DPI factor - see ui/dpi.odin), which is what
// IMM expects.
@(private)
_ime_set_rect :: proc(ctx: ^Context, x, y, w, h: i32) {
	assert(ctx != nil, "_ime_set_rect: nil context")
	assert(w >= 0 && h >= 0, "_ime_set_rect: negative size")
	assert(ctx.win != nil, "_ime_set_rect: no window")
	hwnd := win32.HWND(context_get_window_handle(ctx))
	if hwnd == nil do return
	himc := ImmGetContext(hwnd)
	if himc == nil do return
	form := COMPOSITIONFORM {
		dwStyle      = CFS_POINT,
		ptCurrentPos = {x, y + h},
	}
	ImmSetCompositionWindow(himc, &form)
	ImmReleaseContext(hwnd, himc)
}

// _ime_deactivate: keep the IMM context untouched; the last position is
// harmless while no text field is focused.
@(private)
_ime_deactivate :: proc() {
}
