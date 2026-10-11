#+build darwin
package gfx

import "base:intrinsics"
@(require) import "base:runtime"
import "core:sync"
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
	g_presentation_registry_mutex: sync.Mutex

	@(private = "file")
	_presentation_reserve :: proc(layer: rawptr) -> (^Context, Frame_Delivery_Identity) {
		assert(layer != nil, "_presentation_reserve: nil layer")
		sync.mutex_lock(&g_presentation_registry_mutex)
		defer sync.mutex_unlock(&g_presentation_registry_mutex)
		for index in 0 ..< len(g_presentation_layers) {
			if g_presentation_layers[index] != layer do continue
			owner := g_presentation_owners[index]
			assert(owner != nil, "_presentation_reserve: missing owner")
			identity, reserved := _frame_delivery_callback_reserve(owner)
			if reserved do return owner, identity
			return nil, {}
		}
		return nil, {}
	}

	@(private = "file")
	_presentation_layer_for_owner :: proc(ctx: ^Context) -> rawptr {
		if ctx == nil do return nil
		sync.mutex_lock(&g_presentation_registry_mutex)
		defer sync.mutex_unlock(&g_presentation_registry_mutex)
		for index in 0 ..< len(g_presentation_owners) {
			if g_presentation_owners[index] == ctx do return g_presentation_layers[index]
		}
		return nil
	}

	@(private = "file")
	_presentation_bind_layer :: proc(layer: rawptr, ctx: ^Context) {
		assert(layer != nil && ctx != nil, "_presentation_bind_layer: invalid argument")
		sync.mutex_lock(&g_presentation_registry_mutex)
		defer sync.mutex_unlock(&g_presentation_registry_mutex)
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
		sync.mutex_lock(&g_presentation_registry_mutex)
		defer sync.mutex_unlock(&g_presentation_registry_mutex)
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
		assert(owner != nil, "presentation_done: missing owner")
		if drawable != nil {
			_frame_delivery_presented(owner, identity, f64(drawable->presentedTime()))
		}
		_frame_delivery_callback_release(owner)
	}

	@(private = "file")
	presentation_next_hook :: proc "c" (self: NS.id, cmd: NS.SEL) -> ^CA.MetalDrawable {
		context = runtime.default_context()
		if g_presentation_next == nil do return nil
		drawable := g_presentation_next(self, cmd)
		if drawable == nil do return drawable
		owner, identity := _presentation_reserve(rawptr(self))
		if owner == nil do return drawable
		callback := new(Presentation_Callback)
		if callback == nil {
			_frame_delivery_callback_release(owner)
			_frame_delivery_hook_release(owner)
			return drawable
		}
		callback.owner = owner
		callback.identity = identity
		block := NS.Block_createLocalWithParam(rawptr(callback), presentation_done)
		if block == nil {
			free(callback)
			_frame_delivery_callback_release(owner)
			_frame_delivery_hook_release(owner)
			return drawable
		}
		drawable->addPresentedHandler(block)
		NS.release(block)
		_frame_delivery_hook_release(owner)
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
