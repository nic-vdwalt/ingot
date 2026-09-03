#+build darwin
package gfx

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

when !INGOT_GFX_SDL3 {

	@(objc_class = "NSWindow")
	@(private = "file")
	Promotion_NS_Window :: struct {
		using _: intrinsics.objc_object,
	}

	@(objc_class = "NSView")
	@(private = "file")
	Promotion_NS_View :: struct {
		using _: intrinsics.objc_object,
	}

	@(objc_class = "CAMetalLayer")
	@(private = "file")
	Promotion_CA_Metal_Layer :: struct {
		using _: intrinsics.objc_object,
	}

	@(objc_class = "CADisplayLink")
	@(private = "file")
	Promotion_CA_Display_Link :: struct {
		using _: intrinsics.objc_object,
	}

	@(objc_class = "NSObject")
	@(private = "file")
	Promotion_NS_Object :: struct {
		using _: intrinsics.objc_object,
	}

	CA_Frame_Rate_Range :: struct #align(4) {
		minimum:   f32,
		maximum:   f32,
		preferred: f32,
	}

	Promotion_Tick_Proc :: #type proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id)

	@(private = "file")
	promotion_tick :: proc "c" (self: NS.id, cmd: NS.SEL, sender: NS.id) {}

	@(private = "file")
	promotion_target_create :: proc() -> ^Promotion_NS_Object {
		class := NS.objc_lookUpClass("IngotRefreshTarget")
		if class == nil {
			superclass := NS.objc_lookUpClass("NSObject")
			if superclass == nil do return nil
			class = NS.objc_allocateClassPair(superclass, "IngotRefreshTarget", 0)
			if class == nil do return nil
			added := NS.class_addMethod(
				class,
				NS.sel_registerName("displayLinkTick:"),
				cast(NS.IMP)(cast(Promotion_Tick_Proc)promotion_tick),
				"v@:@",
			)
			if !added {
				NS.objc_disposeClassPair(class)
				return nil
			}
			NS.objc_registerClassPair(class)
		}
		target := NS.class_createInstance(class, 0)
		return cast(^Promotion_NS_Object)target
	}

	@(private = "file")
	promotion_link_install :: proc(ctx: ^Context, view: ^Promotion_NS_View) {
		assert(ctx != nil, "promotion_link_install: nil context")
		assert(view != nil, "promotion_link_install: nil view")
		if ctx.refresh_link != nil do return
		selector := NS.sel_registerName("displayLinkWithTarget:selector:")
		if !bool(NS.respondsToSelector(cast(^NS.Object)(view), selector)) do return
		target := promotion_target_create()
		if target == nil do return
		link := intrinsics.objc_send(
			^Promotion_CA_Display_Link,
			view,
			"displayLinkWithTarget:selector:",
			target,
			NS.sel_registerName("displayLinkTick:"),
		)
		if link == nil {
			intrinsics.objc_send(nil, target, "release")
			return
		}
		rate := f32(platform_monitor_refresh_rate(ctx))
		if rate <= 0 do rate = 120
		range := CA_Frame_Rate_Range{minimum = 30, maximum = rate, preferred = rate}
		intrinsics.objc_send(nil, link, "setPreferredFrameRateRange:", range)
		run_loop := NS.RunLoop_mainRunLoop()
		if run_loop == nil {
			intrinsics.objc_send(nil, target, "release")
			return
		}
		intrinsics.objc_send(nil, link, "addToRunLoop:forMode:", run_loop, NS.RunLoopCommonModes)
		ctx.refresh_link = rawptr(intrinsics.objc_send(^Promotion_CA_Display_Link, link, "retain"))
		ctx.refresh_target = rawptr(target)
	}

	@(private)
	platform_promote_refresh :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_promote_refresh: nil context")
		if ctx.win == nil do return
		window := cast(^Promotion_NS_Window)context_get_window_handle(ctx)
		if window == nil do return
		view := intrinsics.objc_send(^Promotion_NS_View, window, "contentView")
		if view == nil do return
		layer := intrinsics.objc_send(^Promotion_CA_Metal_Layer, view, "layer")
		if layer == nil do return
		intrinsics.objc_send(nil, layer, "setMaximumDrawableCount:", uint(3))
		intrinsics.objc_send(nil, layer, "setDisplaySyncEnabled:", NS.BOOL(true))
		promotion_link_install(ctx, view)
	}

	@(private)
	platform_refresh_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_refresh_shutdown: nil context")
		if ctx.refresh_link != nil {
			link := cast(^Promotion_CA_Display_Link)ctx.refresh_link
			intrinsics.objc_send(nil, link, "invalidate")
			intrinsics.objc_send(nil, link, "release")
			ctx.refresh_link = nil
		}
		if ctx.refresh_target != nil {
			target := cast(^Promotion_NS_Object)ctx.refresh_target
			intrinsics.objc_send(nil, target, "release")
			ctx.refresh_target = nil
		}
	}

} else {

	@(private)
	platform_promote_refresh :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_promote_refresh: nil context")
	}

	@(private)
	platform_refresh_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_refresh_shutdown: nil context")
	}

}
