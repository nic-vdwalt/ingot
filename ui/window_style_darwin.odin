#+build darwin
package ui

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

@(objc_class = "NSWindow")
Window_Style_Window :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSVisualEffectView")
Window_Style_Effect_View :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSView")
Window_Style_View :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSColor")
Window_Style_Color :: struct {
	using _: intrinsics.objc_object,
}

WINDOW_STYLE_BLENDING_BEHIND :: 0
WINDOW_STYLE_STATE_ACTIVE :: 1
WINDOW_STYLE_MATERIAL_SIDEBAR :: 7
WINDOW_STYLE_WIDTH_SIZABLE :: 2
WINDOW_STYLE_HEIGHT_SIZABLE :: 16

#assert(WINDOW_STYLE_BLENDING_BEHIND == 0)
#assert(WINDOW_STYLE_WIDTH_SIZABLE | WINDOW_STYLE_HEIGHT_SIZABLE == 18)

apply_window_style :: proc(window_handle: rawptr = nil) {
	window := cast(^Window_Style_Window)window_handle
	if window == nil do return

	intrinsics.objc_send(nil, window, "setOpaque:", NS.BOOL(false))
	clear := intrinsics.objc_send(NS.id, Window_Style_Color, "clearColor")
	intrinsics.objc_send(nil, window, "setBackgroundColor:", clear)

	content := intrinsics.objc_send(^Window_Style_View, window, "contentView")
	if content == nil do return
	bounds := intrinsics.objc_send(NS.Rect, content, "bounds")

	effect := intrinsics.objc_send(
		^Window_Style_Effect_View,
		Window_Style_Effect_View,
		"alloc",
	)
	effect = intrinsics.objc_send(^Window_Style_Effect_View, effect, "initWithFrame:", bounds)
	if effect == nil do return

	intrinsics.objc_send(nil, effect, "setMaterial:", i64(WINDOW_STYLE_MATERIAL_SIDEBAR))
	intrinsics.objc_send(nil, effect, "setBlendingMode:", i64(WINDOW_STYLE_BLENDING_BEHIND))
	intrinsics.objc_send(nil, effect, "setState:", i64(WINDOW_STYLE_STATE_ACTIVE))
	resize_mask := u64(WINDOW_STYLE_WIDTH_SIZABLE | WINDOW_STYLE_HEIGHT_SIZABLE)
	intrinsics.objc_send(nil, effect, "setAutoresizingMask:", resize_mask)
	intrinsics.objc_send(nil, content, "setAutoresizingMask:", resize_mask)
	intrinsics.objc_send(nil, window, "setContentView:", effect)
	intrinsics.objc_send(nil, effect, "addSubview:", content)
}
