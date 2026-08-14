#+build darwin
// ingot:gfx - macOS IME candidate-window positioning.
//
// GLFW's GLFWContentView conforms to NSTextInputClient but hard-codes
// firstRectForCharacterRange: to the window frame, so the IME candidate list
// (Pinyin / Japanese conversion) pops up at the window corner instead of the
// caret. We replace that one method on the view's class with an IMP returning
// the caret rect the UI reports via SetTextInputRect each frame.
package gfx

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

foreign import objc_rt "system:objc"
@(default_calling_convention = "c")
foreign objc_rt {
	sel_registerName :: proc(name: cstring) -> rawptr ---
	object_getClass :: proc(obj: rawptr) -> rawptr ---
	class_replaceMethod :: proc(cls: rawptr, sel: rawptr, imp: rawptr, types: cstring) -> rawptr ---
}

@(objc_class = "NSWindow")
IME_NS_Window :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSView")
IME_NS_View :: struct {
	using _: intrinsics.objc_object,
}

@(private = "file")
g_ime_swizzled: bool
@(private = "file")
g_ime_views: [16]rawptr
@(private = "file")
g_ime_owners: [16]^Context

@(private = "file")
_ime_owner_for_view :: proc "contextless" (view: rawptr) -> ^Context {
	for index in 0 ..< len(g_ime_views) {
		if g_ime_views[index] == view do return g_ime_owners[index]
	}
	return nil
}

@(private = "file")
_ime_bind_view :: proc(view: rawptr, ctx: ^Context) {
	for index in 0 ..< len(g_ime_views) {
		if g_ime_views[index] == view || g_ime_views[index] == nil {
			g_ime_views[index] = view
			g_ime_owners[index] = ctx
			return
		}
	}
	assert(false, "_ime_bind_view: too many views")
}

// Replacement for -[GLFWContentView firstRectForCharacterRange:actualRange:].
// NSRange in, NSRect out - both pass in registers on arm64/x86_64 C ABI.
@(private = "file")
_ime_first_rect_imp :: proc "c" (
	self: rawptr,
	cmd: rawptr,
	range: NS.Range,
	actual: rawptr,
) -> NS.Rect {
	ctx := _ime_owner_for_view(self)
	if ctx == nil do return {}
	rect := ctx.inp.ime_screen_rect
	return NS.Rect {
		origin = {NS.Float(rect[0]), NS.Float(rect[1])},
		size = {NS.Float(rect[2]), NS.Float(rect[3])},
	}
}

// _ime_set_rect converts the caret rect (view points, top-left origin - the
// GLFW content view is flipped) to screen coordinates and stores it for the
// swizzled method. Installs the method replacement on first use.
@(private)
_ime_set_rect :: proc(ctx: ^Context, x, y, w, h: i32) {
	assert(ctx != nil, "_ime_set_rect: nil context")
	assert(w >= 0 && h >= 0, "_ime_set_rect: negative size")
	assert(ctx.win != nil, "_ime_set_rect: no window")
	win := cast(^IME_NS_Window)context_get_window_handle(ctx)
	if win == nil do return
	content := intrinsics.objc_send(^IME_NS_View, win, "contentView")
	if content == nil do return
	_ime_bind_view(rawptr(content), ctx)

	if !g_ime_swizzled {
		cls := object_getClass(rawptr(content))
		sel := sel_registerName("firstRectForCharacterRange:actualRange:")
		if cls != nil && sel != nil {
			class_replaceMethod(
				cls,
				sel,
				rawptr(_ime_first_rect_imp),
				"{CGRect={CGPoint=dd}{CGSize=dd}}@:{_NSRange=QQ}^{_NSRange=QQ}",
			)
			g_ime_swizzled = true
		}
	}

	view_rect := NS.Rect {
		origin = {NS.Float(x), NS.Float(y)},
		size   = {NS.Float(w), NS.Float(h)},
	}
	win_rect := intrinsics.objc_send(
		NS.Rect,
		content,
		"convertRect:toView:",
		view_rect,
		rawptr(nil),
	)
	screen_rect := intrinsics.objc_send(NS.Rect, win, "convertRectToScreen:", win_rect)
	ctx.inp.ime_screen_rect = {
		f64(screen_rect.origin.x),
		f64(screen_rect.origin.y),
		f64(screen_rect.size.width),
		f64(screen_rect.size.height),
	}
}

// _ime_deactivate: nothing to tear down - the swizzled method keeps returning
// the last caret rect, which is harmless while no text field is focused.
@(private)
_ime_deactivate :: proc() {
}
