#+build darwin
// LIB-CANDIDATE: imports only core:*, base:intrinsics and vendor:raylib.
package ui

// macOS: give the window a native vibrancy ("glass") backdrop. We make the
// NSWindow non-opaque with a clear background and insert an NSVisualEffectView
// behind raylib's GL content view. Combined with FLAG_WINDOW_TRANSPARENT (set
// by the app in its SetConfigFlags) and translucent surface fills, the app's
// large backgrounds blend into the frosted blur.

import NS "core:sys/darwin/Foundation"
import "base:intrinsics"
import rl "vendor:raylib"

// Typed Objective-C class wrappers so intrinsics.objc_send can resolve the
// receiver's class for message dispatch.
@(objc_class = "NSApplication")
Cocoa_App :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSWindow")
Cocoa_Window :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSVisualEffectView")
NS_Effect_View :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSView")
NS_View :: struct {
	using _: intrinsics.objc_object,
}

@(objc_class = "NSColor")
NS_Color :: struct {
	using _: intrinsics.objc_object,
}

// NSVisualEffect* constants (stable on arm64 + x86_64).
NS_VE_BLENDING_BEHIND_WINDOW :: 0 // NSVisualEffectBlendingModeBehindWindow
NS_VE_STATE_ACTIVE           :: 1 // NSVisualEffectStateActive
// Sidebar (7) produces a cool-neutral dark frosted backdrop in both windowed
// and fullscreen modes.
NS_VE_MATERIAL :: 7 // NSVisualEffectMaterialSidebar

// NSView autoresizing mask bits.
NS_VIEW_WIDTH_SIZABLE  :: 2  // NSViewWidthSizable
NS_VIEW_HEIGHT_SIZABLE :: 16 // NSViewHeightSizable

apply_window_style :: proc() {
	// Use raylib's window handle (glfwGetCocoaWindow → NSWindow*): it is valid
	// immediately after InitWindow. NSApplication.mainWindow is nil until the
	// app finishes activating, which made the vibrancy install racy.
	win := cast(^Cocoa_Window)rl.GetWindowHandle()
	if win == nil {
		app := intrinsics.objc_send(^Cocoa_App, Cocoa_App, "sharedApplication")
		if app == nil do return
		win = intrinsics.objc_send(^Cocoa_Window, app, "mainWindow")
		if win == nil do return
	}

	// Non-opaque window + clear background so the framebuffer alpha and the
	// vibrancy view show through.
	intrinsics.objc_send(nil, win, "setOpaque:", NS.BOOL(false))
	clear := intrinsics.objc_send(NS.id, NS_Color, "clearColor")
	intrinsics.objc_send(nil, win, "setBackgroundColor:", clear)

	content := intrinsics.objc_send(^NS_View, win, "contentView")
	if content == nil do return
	bounds := intrinsics.objc_send(NS.Rect, content, "bounds")

	// Build the vibrancy view sized to the current content bounds.
	fx := intrinsics.objc_send(^NS_Effect_View, NS_Effect_View, "alloc")
	fx = intrinsics.objc_send(^NS_Effect_View, fx, "initWithFrame:", bounds)
	if fx == nil do return
	intrinsics.objc_send(nil, fx, "setMaterial:", i64(NS_VE_MATERIAL))
	intrinsics.objc_send(nil, fx, "setBlendingMode:", i64(NS_VE_BLENDING_BEHIND_WINDOW))
	intrinsics.objc_send(nil, fx, "setState:", i64(NS_VE_STATE_ACTIVE))
	intrinsics.objc_send(nil, fx, "setAutoresizingMask:",
		u64(NS_VIEW_WIDTH_SIZABLE | NS_VIEW_HEIGHT_SIZABLE))

	// Reparent: the effect view becomes the content view and the GL view rides
	// on top, resizing with it.
	intrinsics.objc_send(nil, content, "setAutoresizingMask:",
		u64(NS_VIEW_WIDTH_SIZABLE | NS_VIEW_HEIGHT_SIZABLE))
	intrinsics.objc_send(nil, win, "setContentView:", fx)
	intrinsics.objc_send(nil, fx, "addSubview:", content)
}
