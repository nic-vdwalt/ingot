#+build darwin
package gfx

import "base:intrinsics"
@(require) import "base:runtime"
@(require) import NS "core:sys/darwin/Foundation"
@(require) import CA "vendor:darwin/QuartzCore"
@(require) import "vendor:glfw"
@(require) import wg "vendor:wgpu"

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
	g_presentation_layers: [NATIVE_WINDOW_TABLE_MAX]rawptr
	@(private = "file")
	g_presentation_owners: [NATIVE_WINDOW_TABLE_MAX]^Context
	@(private = "file")
	g_presentation_original_class: rawptr
	@(private = "file")
	g_presentation_subclass: rawptr
	@(private = "file")
	g_presentation_next: Presentation_Next_Proc

	@(private = "file")
	_presentation_owner_for_layer :: proc "contextless" (layer: rawptr) -> ^Context {
		if layer == nil do return nil
		for index in 0 ..< len(g_presentation_layers) {
			if g_presentation_layers[index] == layer do return g_presentation_owners[index]
		}
		return nil
	}

	@(private = "file")
	_presentation_layer_for_owner :: proc "contextless" (ctx: ^Context) -> rawptr {
		if ctx == nil do return nil
		for index in 0 ..< len(g_presentation_owners) {
			if g_presentation_owners[index] == ctx do return g_presentation_layers[index]
		}
		return nil
	}

	@(private = "file")
	_presentation_bind_layer :: proc(layer: rawptr, ctx: ^Context) {
		assert(layer != nil && ctx != nil, "_presentation_bind_layer: invalid argument")
		for index in 0 ..< len(g_presentation_layers) {
			if g_presentation_layers[index] == layer || g_presentation_owners[index] == ctx {
				g_presentation_layers[index] = layer
				g_presentation_owners[index] = ctx
				return
			}
		}
		for index in 0 ..< len(g_presentation_layers) {
			if g_presentation_layers[index] == nil {
				g_presentation_layers[index] = layer
				g_presentation_owners[index] = ctx
				return
			}
		}
		assert(false, "_presentation_bind_layer: too many layers")
	}

	@(private = "file")
	_presentation_unbind_owner :: proc(ctx: ^Context) -> rawptr {
		if ctx == nil do return nil
		for index in 0 ..< len(g_presentation_owners) {
			if g_presentation_owners[index] == ctx {
				layer := g_presentation_layers[index]
				g_presentation_layers[index] = nil
				g_presentation_owners[index] = nil
				return layer
			}
		}
		return nil
	}

	@(private = "file")
	Presentation_Callback :: struct {
		owner:    ^Context,
		identity: Frame_Delivery_Identity,
	}

	@(private = "file")
	presentation_done :: proc "c" (user_data: rawptr, drawable: ^CA.MetalDrawable) {
		context = runtime.default_context()
		callback := (^Presentation_Callback)(user_data)
		if callback == nil do return
		owner := callback.owner
		identity := callback.identity
		free(callback)
		if owner == nil || drawable == nil do return
		_frame_delivery_presented(owner, identity, f64(drawable->presentedTime()))
	}

	@(private = "file")
	presentation_next_hook :: proc "c" (self: NS.id, cmd: NS.SEL) -> ^CA.MetalDrawable {
		context = runtime.default_context()
		if g_presentation_next == nil do return nil
		drawable := g_presentation_next(self, cmd)
		owner := _presentation_owner_for_layer(rawptr(self))
		if drawable == nil || owner == nil || owner.delivery.closing do return drawable
		frame_index := owner.stats_current.frame_index
		if frame_index == 0 do return drawable
		callback := new(Presentation_Callback)
		if callback == nil do return drawable
		callback.owner = owner
		callback.identity = {
			epoch       = owner.epoch,
			frame_index = frame_index,
		}
		block := NS.Block_createLocalWithParam(rawptr(callback), presentation_done)
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
		_presentation_bind_layer(rawptr(layer), ctx)
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
		layer := _presentation_layer_for_owner(ctx)
		if layer == nil do return false
		original_class := rawptr(NS.object_getClass(NS.id(layer)))
		if original_class == nil do return false
		if g_presentation_subclass == nil {
			subclass := allocateClassPair(original_class, "IngotPresentationMetalLayer", 0)
			if subclass == nil do return false
			method := NS.class_getInstanceMethod(
				NS.Class(original_class),
				NS.sel_registerName("nextDrawable"),
			)
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
		object_setClass(layer, g_presentation_subclass)
		return true
	}

	@(private)
	platform_frame_delivery_shutdown :: proc(ctx: ^Context) {
		assert(ctx != nil, "platform_frame_delivery_shutdown: nil context")
		layer := _presentation_unbind_owner(ctx)
		if layer == nil do return
		if g_presentation_original_class != nil &&
		   rawptr(NS.object_getClass(NS.id(layer))) == g_presentation_subclass {
			object_setClass(layer, g_presentation_original_class)
		}
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
