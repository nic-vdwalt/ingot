#+build darwin
package gfx

import "base:intrinsics"
import "base:runtime"
import NS "core:sys/darwin/Foundation"
import CA "vendor:darwin/QuartzCore"
import "vendor:glfw"
import wg "vendor:wgpu"

when !INGOT_GFX_SDL3 {
	Presentation_Next_Proc :: #type proc "c" (self: NS.id, cmd: NS.SEL) -> ^CA.MetalDrawable

	foreign import presentation_objc "system:objc"
	@(default_calling_convention = "c", link_prefix = "objc_")
	foreign presentation_objc {
		allocateClassPair :: proc(superclass: rawptr, name: cstring, extra_bytes: uint) -> rawptr ---
		registerClassPair :: proc(class: rawptr) ---
		disposeClassPair :: proc(class: rawptr) ---
	}

	@(private = "file")
	g_presentation_owner: ^Context
	@(private = "file")
	g_presentation_layer: rawptr
	@(private = "file")
	g_presentation_original_class: rawptr
	@(private = "file")
	g_presentation_subclass: rawptr
	@(private = "file")
	g_presentation_next: Presentation_Next_Proc

	@(private = "file")
	presentation_done :: proc "c" (user_data: rawptr, drawable: ^CA.MetalDrawable) {
		context = runtime.default_context()
		owner := g_presentation_owner
		frame_index := u64(uintptr(user_data))
		if owner == nil || drawable == nil || frame_index == 0 do return
		_frame_delivery_presented(owner, frame_index, f64(drawable->presentedTime()))
	}

	@(private = "file")
	presentation_next_hook :: proc "c" (self: NS.id, cmd: NS.SEL) -> ^CA.MetalDrawable {
		context = runtime.default_context()
		if g_presentation_next == nil do return nil
		drawable := g_presentation_next(self, cmd)
		owner := g_presentation_owner
		if drawable == nil || owner == nil || owner.delivery.closing do return drawable
		frame_index := owner.stats_current.frame_index
		if frame_index == 0 do return drawable
		block := NS.Block_createLocalWithParam(rawptr(uintptr(frame_index)), presentation_done)
		drawable->addPresentedHandler(block)
		return drawable
	}

	@(private)
	platform_create_surface :: proc(ctx: ^Context, instance: wg.Instance) -> wg.Surface {
		assert(ctx != nil && instance != nil, "platform_create_surface: invalid argument")
		ns_window := glfw.GetCocoaWindow(_context_window(ctx))
		ns_window->contentView()->setWantsLayer(true)
		layer := CA.MetalLayer_layer()
		ns_window->contentView()->setLayer(layer)
		g_presentation_layer = rawptr(layer)
		g_presentation_owner = ctx
		return wg.InstanceCreateSurface(
			instance,
			&wg.SurfaceDescriptor {
				nextInChain = &wg.SurfaceSourceMetalLayer {
					chain = {sType = .SurfaceSourceMetalLayer},
					layer = rawptr(layer),
				},
			},
		)
	}

	@(private)
	platform_frame_delivery_init :: proc(ctx: ^Context) -> bool {
		assert(ctx != nil, "platform_frame_delivery_init: nil context")
		if g_presentation_layer == nil || g_presentation_owner != ctx do return false
		original_class := rawptr(NS.object_getClass(NS.id(g_presentation_layer)))
		if original_class == nil do return false
		if g_presentation_subclass == nil {
			subclass := allocateClassPair(original_class, "IngotPresentationMetalLayer", 0)
			if subclass == nil do return false
			method := NS.class_getInstanceMethod(NS.Class(original_class), NS.sel_registerName("nextDrawable"))
			if method == nil {
				disposeClassPair(subclass)
				return false
			}
			g_presentation_next = cast(Presentation_Next_Proc)NS.method_getImplementation(method)
			if !NS.class_addMethod(
				NS.Class(subclass),
				NS.sel_registerName("nextDrawable"),
				cast(NS.IMP)presentation_next_hook,
				"@@:",
			) {
				disposeClassPair(subclass)
				return false
			}
			registerClassPair(subclass)
			g_presentation_original_class = original_class
			g_presentation_subclass = subclass
		} else if original_class != g_presentation_original_class {
			return false
		}
		object_setClass(g_presentation_layer, g_presentation_subclass)
		return true
	}

	@(private)
	platform_frame_delivery_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_frame_delivery_shutdown: nil context")
		if g_presentation_owner != ctx do return
		if g_presentation_layer != nil && g_presentation_original_class != nil {
			object_setClass(g_presentation_layer, g_presentation_original_class)
		}
		g_presentation_owner = nil
		g_presentation_layer = nil
	}
}

when INGOT_GFX_SDL3 {
	@(private)
	platform_frame_delivery_init :: proc(ctx: ^Context) -> bool {
		assert(ctx != nil, "platform_frame_delivery_init: nil context")
		return false
	}

	@(private)
	platform_frame_delivery_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_frame_delivery_shutdown: nil context")
	}
}
