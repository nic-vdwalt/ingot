// ingot:gfx - window lifecycle: InitWindow/CloseWindow and their context
// forms, surface configuration, the shared _gpu_finish setup step, and
// swapchain reconfiguration on resize.
package gfx

import "core:fmt"
import "core:mem"
import wg "vendor:wgpu"

// --- window lifecycle ------------------------------------------------------

// SetConfigFlags stashes flags to apply at InitWindow (raylib order).
SetConfigFlags :: proc(flags: ConfigFlags) {
	context_set_config_flags(default_context(), flags)
}

InitWindow :: proc(width, height: i32, title: cstring) {
	context_init(default_context(), width, height, title)
}

@(private)
_init_window_context :: proc(ctx: ^Context, width, height: i32, title: cstring) {
	assert(ctx != nil, "_init_window_context: nil context")
	if ctx.lifecycle != .Empty do return
	if !_context_assign_id(ctx) do return
	ctx.epoch += 1
	ctx.lifecycle = .Starting
	if !platform_create_window(ctx, width, height, title, ctx.config_flags) {
		ctx.last_error = .Window
		fmt.eprintln("gfx: window creation failed")
		ctx.lifecycle = .Empty
		return
	}

	ctx.instance = wg.CreateInstance()
	if ctx.instance == nil {
		ctx.last_error = .Instance
		fmt.eprintln("gfx: WebGPU instance creation failed")
		_abandon_window_context(ctx)
		return
	}
	ctx.surface = platform_create_surface(ctx, ctx.instance)
	if ctx.surface == nil {
		ctx.last_error = .Surface
		fmt.eprintln("gfx: WebGPU surface creation failed")
		_abandon_window_context(ctx)
		return
	}
	ctx.pending_w, ctx.pending_h = width, height

	// Acquire the GPU adapter+device. On native this resolves synchronously
	// (busy-wait) and calls _gpu_finish before returning; on web the requests
	// resolve on the browser event loop and _gpu_finish runs from the device
	// callback a few RAF ticks later (ctx.initialized stays false until then).
	platform_start_gpu(ctx)
}

@(private)
_surface_present_mode :: proc(flags: ConfigFlags, supported: []wg.PresentMode) -> wg.PresentMode {
	if .PRESENT_IMMEDIATE in flags {
		for mode in supported {
			if mode == .Immediate do return .Immediate
		}
	}
	return .Fifo
}

@(private)
_surface_alpha_mode :: proc(
	flags: ConfigFlags,
	supported: []wg.CompositeAlphaMode,
) -> wg.CompositeAlphaMode {
	if .WINDOW_TRANSPARENT not_in flags do return .Opaque
	// pick a surface-supported non-opaque mode for the transparent backdrop
	want := [?]wg.CompositeAlphaMode{.Premultiplied, .Unpremultiplied, .Inherit, .Auto}
	for wanted in want {
		for mode in supported {
			if mode == wanted do return wanted
		}
	}
	return .Opaque
}

// _gpu_finish completes context setup once ctx.adapter/device/queue are ready.
// Shared by both targets (native calls it inline from platform_start_gpu; web
// calls it from the async device callback). Everything here is pure wgpu.

@(private)
_gpu_finish :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_finish: nil context")
	if ctx.surface == nil || ctx.adapter == nil || ctx.device == nil || ctx.queue == nil {
		ctx.last_error = .Swapchain
		fmt.eprintln("gfx: incomplete GPU state; cannot configure swapchain")
		_abandon_window_context(ctx)
		return false
	}
	width, height := ctx.pending_w, ctx.pending_h
	if width <= 0 || height <= 0 {
		ctx.last_error = .Swapchain
		fmt.eprintln("gfx: invalid pending window dimensions")
		_abandon_window_context(ctx)
		return false
	}

	caps, status := wg.SurfaceGetCapabilities(ctx.surface, ctx.adapter)
	if status != .Success || caps.formatCount == 0 || caps.formats == nil {
		ctx.last_error = .Swapchain
		fmt.eprintln("gfx: surface reports no supported formats; cannot configure swapchain")
		_abandon_window_context(ctx)
		return false
	}
	// Prefer a non-sRGB (linear UNORM) surface. raylib writes 8-bit sRGB color
	// values straight to a UNORM framebuffer with no gamma applied; an sRGB
	// surface re-encodes them linear->sRGB on output, washing the frame out
	// (too bright). Match raylib by choosing the *Unorm format when offered.
	ensure(caps.formatCount <= uint(max(int)))
	ctx.format = caps.formats[0]
	for i in 0 ..< int(caps.formatCount) {
		f := caps.formats[i]
		if f == .BGRA8Unorm || f == .RGBA8Unorm {
			ctx.format = f
			break
		}
	}

	ctx.width, ctx.height = width, height
	fbw, fbh := platform_framebuffer_size(ctx)
	ctx.fb_width, ctx.fb_height = fbw, fbh
	ctx.dpi = platform_content_scale(ctx)

	alpha := _surface_alpha_mode(ctx.config_flags, caps.alphaModes[:caps.alphaModeCount])
	ctx.composite_alpha = alpha
	_stats_set_alpha_mode(ctx, alpha)
	ctx.present_immediate_supported = false
	for mode in caps.presentModes[:caps.presentModeCount] {
		if mode == .Immediate do ctx.present_immediate_supported = true
	}
	present_mode := _surface_present_mode(
		ctx.config_flags,
		caps.presentModes[:caps.presentModeCount],
	)
	ctx.config = wg.SurfaceConfiguration {
		device      = ctx.device,
		format      = ctx.format,
		usage       = {.RenderAttachment},
		width       = u32(fbw),
		height      = u32(fbh),
		alphaMode   = alpha,
		presentMode = present_mode,
	}
	wg.SurfaceConfigure(ctx.surface, &ctx.config)
	when ODIN_OS != .JS do ctx.force_reconfigure = true

	ctx.start_time_s = platform_now()
	ctx.last_time = _now(ctx)
	ctx.target_fps = 0

	_submission_init(&ctx.submissions, ctx)
	_frame_delivery_init(ctx)
	_ = _gpu_timing_init(ctx)
	if !renderer_init(ctx, &ctx.rend) {
		// The device could not supply the stream pools even at the floor.
		// Closing here surfaces a diagnosable state; the alternative used to
		// be an assert, which on web traps the module and freezes the canvas.
		// No frame ran, so no timing map is armed and this cannot refuse.
		timing_closed := _gpu_timing_shutdown(ctx)
		assert(timing_closed, "_gpu_finish: unused timing state refused to close")
		_abandon_window_context(ctx)
		return false
	}
	_graphics_resources_init(&ctx.resources)
	platform_input_init(ctx)
	platform_drop_init(ctx)
	platform_window_ready(ctx)

	ctx.initialized = true
	ctx.lifecycle = .Ready
	assert(context_ready(ctx), "_gpu_finish: context not ready")
	return true
}

CloseWindow :: proc() -> bool {
	return context_close(default_context())
}

// _abandon_window_context tears down a context that never finished
// initialising. Nothing has registered a backend callback yet, so the close
// cannot be refused; a refusal here means the initialisation order changed.
@(private)
_abandon_window_context :: proc(ctx: ^Context) {
	assert(ctx != nil, "_abandon_window_context: nil context")
	assert(!ctx.initialized, "_abandon_window_context: initialised context")
	closed := _close_window_context(ctx)
	assert(closed, "_abandon_window_context: uninitialised context refused to close")
}

@(private)
_close_window_context :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_close_window_context: nil context")
	if ctx.instance == nil && ctx.win == nil do return true
	assert(!ctx.frame.has_frame, "CloseWindow: frame is still recording")
	ctx.lifecycle = .Closing
	if ctx.initialized {
		// Every registration must be proved terminal before anything that
		// owns its storage goes away. Each retire is idempotent, so a refused
		// close can be retried from here without re-destroying resources.
		if !_submission_shutdown(&ctx.submissions) do return false
		if !_screenshot_retire(ctx, true) do return false
		if !_gpu_timing_retire(ctx) do return false
		if !_frame_delivery_shutdown(ctx) do return false
		context_close_accessibility(ctx)
		platform_drop_shutdown(ctx)
		_graphics_resources_destroy(ctx, &ctx.resources)
		renderer_shutdown(&ctx.rend)
		_gpu_timing_release(ctx)
	} else {
		if !_frame_delivery_shutdown(ctx) do return false
	}
	if ctx.surface != nil do wg.SurfaceRelease(ctx.surface)
	if ctx.queue != nil do wg.QueueRelease(ctx.queue)
	if ctx.device != nil do wg.DeviceRelease(ctx.device)
	if ctx.adapter != nil do wg.AdapterRelease(ctx.adapter)
	if ctx.instance != nil do wg.InstanceRelease(ctx.instance)
	platform_terminate(ctx)
	context_id := ctx.id
	flags := ctx.config_flags
	closing_epoch := ctx.epoch
	last_error := ctx.last_error
	mem.zero(ctx, size_of(Context))
	ctx.id = context_id
	ctx.epoch = closing_epoch
	ctx.config_flags = flags
	ctx.last_error = last_error
	return true
}

WindowShouldClose :: proc() -> bool {
	return context_should_close(default_context())
}

// context_set_vsync switches the surface present mode at runtime (Fifo when
// enabled, Immediate when disabled). The next _maybe_reconfigure applies it.
// Returns false when VSync-off is unavailable (no .Immediate on the surface).
context_set_vsync :: proc(ctx: ^Context, enabled: bool) -> bool {
	if ctx == nil || !context_ready(ctx) do return false
	when ODIN_OS == .JS {
		return enabled
	} else {
		if !enabled && !ctx.present_immediate_supported do return false
		mode := wg.PresentMode.Fifo if enabled else wg.PresentMode.Immediate
		if ctx.config.presentMode == mode do return true
		ctx.config.presentMode = mode
		if enabled {
			ctx.config_flags -= {.PRESENT_IMMEDIATE}
		} else {
			ctx.config_flags += {.PRESENT_IMMEDIATE}
		}
		ctx.force_reconfigure = true
		return true
	}
}

@(private)
_surface_should_reconfigure :: proc(changed, forced: bool, fbw, fbh: i32) -> bool {
	return (changed || forced) && fbw > 0 && fbh > 0
}

@(private)
_maybe_reconfigure :: proc(ctx: ^Context) {
	assert(ctx != nil, "_maybe_reconfigure: nil context")
	fbw, fbh := platform_framebuffer_size(ctx)
	w, h := platform_window_size(ctx)
	changed := fbw != ctx.fb_width || fbh != ctx.fb_height
	// IsWindowResized reports the logical size the application lays out
	// against, which is what changes under a user drag. A pure DPI change
	// moves the framebuffer without moving it, and is reported through
	// GetWindowScaleDPI instead.
	ctx.resized_this_frame = w != ctx.width || h != ctx.height
	ctx.width, ctx.height = w, h
	if _surface_should_reconfigure(changed, ctx.force_reconfigure, fbw, fbh) {
		ctx.fb_width, ctx.fb_height = fbw, fbh
		ctx.config.width = u32(fbw)
		ctx.config.height = u32(fbh)
		wg.SurfaceConfigure(ctx.surface, &ctx.config)
		ctx.force_reconfigure = false
	}
	ctx.dpi = platform_content_scale(ctx)
}
