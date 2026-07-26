// ingot:gfx — window + WebGPU context lifecycle and the raylib-named entry
// points apps call (InitWindow/BeginDrawing/EndDrawing/ClearBackground/...).
// All mutable package state lives in the single `g` global so every gfx file
// (batch, shapes, text, texture, input) shares one context.
package gfx

import "base:runtime"
import "core:fmt"
import "core:mem"
import wg "vendor:wgpu"

KEY_COUNT :: 349 // KB_MENU (348) + 1
RESOURCE_SLOT_BITS :: 10
RESOURCE_SLOT_COUNT :: 1 << RESOURCE_SLOT_BITS
RESOURCE_SLOT_MASK :: u32(RESOURCE_SLOT_COUNT - 1)
RESOURCE_GENERATION_MASK :: (u32(1) << 20) - 1

#assert(RESOURCE_SLOT_COUNT == 1024)
#assert(RESOURCE_GENERATION_MASK > 0)

@(private)
_resource_generation_next :: proc(generation: u32) -> u32 {
	next := (generation + 1) & RESOURCE_GENERATION_MASK
	if next == 0 do next = 1
	return next
}

@(private)
_resource_handle_make :: proc(index: int, generation: u32) -> u32 {
	assert(index >= 0 && index < RESOURCE_SLOT_COUNT)
	assert(generation > 0 && generation <= RESOURCE_GENERATION_MASK)
	handle := generation << RESOURCE_SLOT_BITS | u32(index)
	assert(handle != 0)
	return handle
}

@(private)
_resource_handle_decode :: proc(
	handle: u32,
	capacity: int,
) -> (
	index: int,
	generation: u32,
	ok: bool,
) {
	if handle == 0 do return 0, 0, false
	index = int(handle & RESOURCE_SLOT_MASK)
	generation = handle >> RESOURCE_SLOT_BITS
	if generation == 0 || index < 0 || index >= capacity do return 0, 0, false
	return index, generation, true
}

Graphics_Resources :: struct {
	textures: Texture_Resources,
	atlases:  Atlas_Resources,
	shaders:  Shader_Resources,
	rlgl:     Rlgl_Resources,
	gpu_3d:   Gpu_3D_Resources,
	retire:   [dynamic]Retired_Texture,
}

Frame_State :: struct {
	surf_tex:               wg.SurfaceTexture,
	view:                   wg.TextureView,
	encoder:                wg.CommandEncoder,
	pass:                   wg.RenderPassEncoder,
	clear_color:            Color,
	pass_begun:             bool,
	has_frame:              bool,

	// Active window-pass scissor (framebuffer pixels). Re-applied whenever the
	// window pass begins, since a fresh WebGPU pass resets scissor to full.
	scissor_on:             bool,
	scissor_empty:          bool,
	sc_x, sc_y, sc_w, sc_h: u32,

	// Render-target redirection (Phase 2): when rt != 0 the batch records into
	// rt_pass (targeting an offscreen texture) on its own command encoder,
	// submitted at EndTextureMode, instead of the swapchain pass.
	rt:                     u32,
	rt_encoder:             wg.CommandEncoder,
	rt_pass:                wg.RenderPassEncoder,
	rt_pass_begun:          bool,
	rt_clear:               Color,
	// True when ClearBackground was called after BeginTextureMode (before the
	// RT pass began). Selects loadOp = .Clear; otherwise the RT pass uses
	// loadOp = .Load to preserve the target's prior contents (raylib parity —
	// BeginTextureMode alone does not clear). Incremental renderers (the nvim
	// grid's per-row dirty redraw) and additive-accumulation passes (galaxy
	// streak combine) depend on this preserve-by-default behaviour.
	rt_should_clear:        bool,
	rt_w, rt_h:             i32,
	rt_depth:               bool, // RT pass carries a depth attachment (3D)
	// 3D mode (Phase 4): a depth-enabled pass replaces the current 2D pass.
	depth_view:             wg.TextureView,
	mode3d:                 bool,
}

Context_Lifecycle :: enum u8 {
	Empty,
	Starting,
	Ready,
	Closing,
}

Context :: struct {
	epoch:                u64,
	lifecycle:            Context_Lifecycle,
	win:                  Window_Handle,
	instance:             wg.Instance,
	surface:              wg.Surface,
	adapter:              wg.Adapter,
	device:               wg.Device,
	queue:                wg.Queue,
	format:               wg.TextureFormat,
	config:               wg.SurfaceConfiguration,
	config_flags:         ConfigFlags,

	// logical (point) size — what GetScreenWidth/Height and the ortho
	// projection use; physical framebuffer may be larger under HiDPI.
	width, height:        i32,
	fb_width, fb_height:  i32,
	dpi:                  f32,
	force_reconfigure:    bool,

	// requested window size, stashed at InitWindow for _gpu_finish (needed
	// because on web the GPU device resolves asynchronously, after InitWindow
	// has returned).
	pending_w, pending_h: i32,
	frame:                Frame_State,
	frame_generation:     u64,
	frame_active:         bool,

	// timing
	start_time_s:         f64,
	last_time:            f64,
	frame_time:           f32, // clamped to MAX_FRAME_TIME (what GetFrameTime returns)
	real_frame_time:      f32, // unclamped, for GetFPS accuracy
	target_fps:           i32,

	// event-driven frame scheduling (idle.odin)
	idle:                 Idle_State,

	// renderer (batch.odin)
	rend:                 Renderer,
	resources:            Graphics_Resources,

	// input (input.odin)
	inp:                  Input,
	submissions:          Submission_Tracker,
	initialized:          bool,
	composite_alpha:      wg.CompositeAlphaMode,
}

// Retired_Texture is one texture's GPU handles awaiting end-of-frame
// destruction. Views/samplers/binds are release-only; the texture itself is
// destroyed (delete-now semantics) once the frame's submit no longer
// references it.
Retired_Texture :: struct {
	bind:    wg.BindGroup,
	sampler: wg.Sampler,
	view:    wg.TextureView,
	tex:     wg.Texture,
}

// MAX_RETIRED_PER_FRAME bounds mid-frame texture retirements (Tiger Style:
// put a limit on everything). Real apps unload a handful per frame; hitting
// the bound means a caller is leaking unloads in a loop.
MAX_RETIRED_PER_FRAME :: 64

// _retire_texture destroys a texture's GPU handles, deferring to after this
// frame's queue submit while a frame is recording (wgpu validates that
// submitted command buffers reference no destroyed textures).
@(private)
_retire_texture :: proc(
	bind: wg.BindGroup,
	sampler: wg.Sampler,
	view: wg.TextureView,
	tex: wg.Texture,
) {
	// Why assert: all-nil handles mean the entry was already destroyed — a
	// double-unload of the same font/texture.
	assert(
		bind != nil || sampler != nil || view != nil || tex != nil,
		"_retire_texture: all handles nil (double unload?)",
	)
	if g.frame.has_frame {
		assert(
			len(g.resources.retire) < MAX_RETIRED_PER_FRAME,
			"_retire_texture: retire queue full (unload loop within one frame?)",
		)
		append(&g.resources.retire, Retired_Texture{bind, sampler, view, tex})
		return
	}
	_destroy_retired(Retired_Texture{bind, sampler, view, tex})
}

@(private)
_destroy_retired :: proc(r: Retired_Texture) {
	if r.bind != nil do wg.BindGroupRelease(r.bind)
	if r.sampler != nil do wg.SamplerRelease(r.sampler)
	if r.view != nil do wg.TextureViewRelease(r.view)
	if r.tex != nil {
		wg.TextureDestroy(r.tex)
		wg.TextureRelease(r.tex)
	}
}

// _flush_retired destroys all mid-frame-retired textures. Call after
// QueueSubmit: from that point wgpu keeps the submitted work's resources
// alive internally, so destroy is safe.
@(private)
_flush_retired :: proc() {
	// Why assert: flushing while a frame still records would recreate the
	// destroy-before-submit validation abort this queue exists to prevent.
	assert(!g.frame.has_frame, "_flush_retired: called while a frame is recording")
	for retired in g.resources.retire do _destroy_retired(retired)
	clear(&g.resources.retire)
}

@(private)
g: Context

default_context :: proc() -> ^Context {
	return &g
}

context_epoch :: proc(ctx: ^Context) -> u64 {
	if ctx == nil do return 0
	return ctx.epoch
}

context_ready :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.lifecycle == .Ready && ctx.initialized
}

context_init :: proc(ctx: ^Context, width, height: i32, title: cstring) -> bool {
	assert(ctx != nil && title != nil, "context_init: nil argument")
	if ctx != default_context() do return false
	InitWindow(width, height, title)
	return context_ready(ctx)
}

context_close :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_close: nil context")
	if ctx != default_context() do return
	CloseWindow()
}

context_should_close :: proc(ctx: ^Context) -> bool {
	if ctx == nil || ctx != default_context() do return true
	return WindowShouldClose()
}

@(private)
_graphics_resources_init :: proc(resources: ^Graphics_Resources) {
	assert(resources != nil, "_graphics_resources_init: nil resources")
	resources^ = {}
}

@(private)
_graphics_resources_destroy :: proc(resources: ^Graphics_Resources) {
	assert(resources != nil, "_graphics_resources_destroy: nil resources")
	assert(!g.frame.has_frame, "_graphics_resources_destroy: active frame")
	_gpu_3d_resources_destroy(&resources.gpu_3d)
	_rlgl_resources_destroy(&resources.rlgl)
	_shader_resources_destroy(&resources.shaders)
	_atlas_resources_destroy(&resources.atlases)
	_texture_resources_destroy(&resources.textures)
	_flush_retired()
	delete(resources.retire)
	resources^ = {}
}

// --- async adapter/device request helpers ----------------------------------

@(private)
Adapter_Res :: struct {
	adapter: wg.Adapter,
	done:    bool,
}
@(private)
Device_Res :: struct {
	device: wg.Device,
	done:   bool,
}

@(private)
_on_adapter :: proc "c" (
	status: wg.RequestAdapterStatus,
	adapter: wg.Adapter,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	r := (^Adapter_Res)(u1)
	r.adapter = adapter
	r.done = true
}

@(private)
_on_device :: proc "c" (
	status: wg.RequestDeviceStatus,
	device: wg.Device,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	if status != .Success {
		context = runtime.default_context()
		fmt.eprintfln("gfx: device request failed (status=%v): %s", status, string(msg))
	}
	r := (^Device_Res)(u1)
	r.device = device
	r.done = true
}

// INGOT_GPU_STRICT turns any uncaptured wgpu validation message into an
// immediate abort. Fuzz harnesses build with it (fuzz/run.sh gfx-frame) so
// GPU misuse that would otherwise be logged and survived fails the run —
// partial compensation for wgpu-native being a prebuilt release library
// outside AddressSanitizer's reach.
INGOT_GPU_STRICT :: #config(INGOT_GPU_STRICT, false)

// Uncaptured GPU errors (e.g. an invalid pipeline/vertex layout) would
// otherwise reach wgpu-native's default handler, which panics and aborts the
// whole process with no message. Logging them here keeps the app alive and
// surfaces a diagnosable error instead of a bare SIGABRT. Under
// INGOT_GPU_STRICT the error is fatal by design.
@(private)
_on_uncaptured_error :: proc "c" (
	device: ^wg.Device,
	type: wg.ErrorType,
	message: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	fmt.eprintfln("gfx: wgpu uncaptured error (%v): %s", type, string(message))
	when INGOT_GPU_STRICT {
		panic("INGOT_GPU_STRICT: aborting on wgpu validation error")
	}
}

// --- window lifecycle ------------------------------------------------------

// SetConfigFlags stashes flags to apply at InitWindow (raylib order).
SetConfigFlags :: proc(flags: ConfigFlags) {
	g.config_flags = flags
}

InitWindow :: proc(width, height: i32, title: cstring) {
	if g.lifecycle != .Empty do return
	g.epoch += 1
	g.lifecycle = .Starting
	if !platform_create_window(width, height, title, g.config_flags) {
		fmt.eprintln("gfx: window creation failed")
		g.lifecycle = .Empty
		return
	}

	g.instance = wg.CreateInstance()
	g.surface = platform_create_surface(g.instance)
	g.pending_w, g.pending_h = width, height

	// Acquire the GPU adapter+device. On native this resolves synchronously
	// (busy-wait) and calls _gpu_finish before returning; on web the requests
	// resolve on the browser event loop and _gpu_finish runs from the device
	// callback a few RAF ticks later (g.initialized stays false until then).
	platform_start_gpu()
}

// _gpu_finish completes context setup once g.adapter/g.device/g.queue are ready.
// Shared by both targets (native calls it inline from platform_start_gpu; web
// calls it from the async device callback). Everything here is pure wgpu.
@(private)
_gpu_finish :: proc() {
	width, height := g.pending_w, g.pending_h

	caps, _ := wg.SurfaceGetCapabilities(g.surface, g.adapter)
	// Prefer a non-sRGB (linear UNORM) surface. raylib writes 8-bit sRGB color
	// values straight to a UNORM framebuffer with no gamma applied; an sRGB
	// surface re-encodes them linear->sRGB on output, washing the frame out
	// (too bright). Match raylib by choosing the *Unorm format when offered.
	g.format = caps.formats[0]
	for i in 0 ..< int(caps.formatCount) {
		f := caps.formats[i]
		if f == .BGRA8Unorm || f == .RGBA8Unorm {
			g.format = f
			break
		}
	}

	g.width, g.height = width, height
	fbw, fbh := platform_framebuffer_size()
	g.fb_width, g.fb_height = fbw, fbh
	g.dpi = platform_content_scale()

	alpha: wg.CompositeAlphaMode = .Opaque
	if .WINDOW_TRANSPARENT in g.config_flags {
		// pick a surface-supported non-opaque mode for the transparent backdrop
		want := [?]wg.CompositeAlphaMode{.Premultiplied, .Unpremultiplied, .Inherit, .Auto}
		outer: for w in want {
			for i in 0 ..< int(caps.alphaModeCount) {
				if caps.alphaModes[i] == w {
					alpha = w
					break outer
				}
			}
		}
	}
	g.composite_alpha = alpha
	_stats_set_alpha_mode(alpha)
	g.config = wg.SurfaceConfiguration {
		device      = g.device,
		format      = g.format,
		usage       = {.RenderAttachment},
		width       = u32(fbw),
		height      = u32(fbh),
		alphaMode   = alpha,
		presentMode = .Fifo,
	}
	wg.SurfaceConfigure(g.surface, &g.config)

	g.start_time_s = platform_now()
	g.last_time = _now()
	g.target_fps = 0

	_submission_init(&g.submissions)
	renderer_init(&g.rend)
	_graphics_resources_init(&g.resources)
	platform_input_init()
	platform_drop_init()

	g.initialized = true
	g.lifecycle = .Ready
}

CloseWindow :: proc() {
	if g.instance == nil && g.win == nil do return
	assert(!g.frame.has_frame, "CloseWindow: frame is still recording")
	g.lifecycle = .Closing
	if g.initialized {
		platform_drop_shutdown()
		_graphics_resources_destroy(&g.resources)
		renderer_shutdown(&g.rend)
		_submission_shutdown(&g.submissions)
	}
	if g.surface != nil do wg.SurfaceRelease(g.surface)
	if g.queue != nil do wg.QueueRelease(g.queue)
	if g.device != nil do wg.DeviceRelease(g.device)
	if g.adapter != nil do wg.AdapterRelease(g.adapter)
	if g.instance != nil do wg.InstanceRelease(g.instance)
	platform_terminate()
	flags := g.config_flags
	closing_epoch := g.epoch
	mem.zero(&g, size_of(Context))
	g.epoch = closing_epoch
	g.config_flags = flags
}

WindowShouldClose :: proc() -> bool {
	return platform_should_close()
}

// --- per-frame -------------------------------------------------------------

BeginDrawing :: proc() {
	_maybe_reconfigure()
	_stats_frame_begin()
	platform_web_input_frame_begin()

	g.frame.surf_tex = wg.SurfaceGetCurrentTexture(g.surface)
	#partial switch g.frame.surf_tex.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// ok
	case .Outdated, .Lost:
		// The swapchain is stale (e.g. display change); reconfigure so the
		// next frame can acquire a fresh texture.
		_release_surface_texture()
		if g.fb_width > 0 && g.fb_height > 0 {
			wg.SurfaceConfigure(g.surface, &g.config)
		}
		g.frame.has_frame = false
		return
	case:
		_release_surface_texture()
		g.frame.has_frame = false
		return
	}
	g.frame.view = wg.TextureCreateView(g.frame.surf_tex.texture, nil)
	if !renderer_frame_begin(&g.rend) {
		wg.TextureViewRelease(g.frame.view)
		_release_surface_texture()
		g.frame.has_frame = false
		return
	}
	g.frame.encoder = wg.DeviceCreateCommandEncoder(g.device, nil)
	g.frame.clear_color = Color{0, 0, 0, 255}
	g.frame.pass_begun = false
	g.frame.has_frame = true
	g.frame.scissor_on = false
	g.frame.scissor_empty = false
}

ClearBackground :: proc(c: Color) {
	// While a render target is bound but its pass hasn't begun yet, the clear
	// applies to the target (raylib: ClearBackground after BeginTextureMode
	// clears the target). Otherwise it sets the swapchain clear.
	if g.frame.rt != 0 && !g.frame.rt_pass_begun {
		g.frame.rt_clear = c
		g.frame.rt_should_clear = true
		return
	}
	g.frame.clear_color = c
}

// _ensure_pass lazily begins the frame render pass so ClearBackground (called
// after BeginDrawing in raylib order) can set the loadOp clear value first.
@(private)
_ensure_pass :: proc() {
	if !g.frame.has_frame || g.frame.pass_begun do return
	cc := g.frame.clear_color
	g.frame.pass = wg.CommandEncoderBeginRenderPass(
		g.frame.encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wg.RenderPassColorAttachment {
				view = g.frame.view,
				depthSlice = wg.DEPTH_SLICE_UNDEFINED,
				loadOp = .Clear,
				storeOp = .Store,
				clearValue = {
					f64(cc.r) / 255.0,
					f64(cc.g) / 255.0,
					f64(cc.b) / 255.0,
					f64(cc.a) / 255.0,
				},
			},
		},
	)
	_stats_render_pass()
	g.frame.pass_begun = true
	// A new pass starts with a full-attachment scissor; restore any active clip.
	if g.frame.scissor_on && !g.frame.scissor_empty {
		assert(g.frame.sc_w > 0)
		assert(g.frame.sc_h > 0)
		wg.RenderPassEncoderSetScissorRect(
			g.frame.pass,
			g.frame.sc_x,
			g.frame.sc_y,
			g.frame.sc_w,
			g.frame.sc_h,
		)
	}
}

EndDrawing :: proc() {
	if g.frame.has_frame {
		_ensure_pass() // guarantee a clear even on empty frames
		if !g.frame.scissor_empty {
			renderer_flush(&g.rend, g.frame.pass, .Frame_End)
		} else {
			clear(&g.rend.verts)
			clear(&g.rend.indices)
		}
		wg.RenderPassEncoderEnd(g.frame.pass)
		wg.RenderPassEncoderRelease(g.frame.pass)

		retirement := _submission_reserve(&g.submissions)
		cmd := wg.CommandEncoderFinish(g.frame.encoder, nil)
		if retirement != 0 && cmd != nil {
			wg.QueueSubmit(g.queue, {cmd})
			_stats_queue_submission()
			assert(_submission_commit(&g.submissions, retirement))
			if !_stream_slot_submitted(&g.rend, retirement) do _stats_stream_retirement_failure()
		} else {
			if retirement != 0 do assert(_submission_rollback(&g.submissions, retirement))
			_stream_slot_abandon(&g.rend)
			_stats_stream_retirement_failure()
		}
		if cmd != nil do wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(g.frame.encoder)
		wg.SurfacePresent(g.surface)
		wg.TextureViewRelease(g.frame.view)
		_release_surface_texture()
		g.frame.has_frame = false
		_flush_retired()
	} else {
		clear(&g.rend.verts)
		clear(&g.rend.indices)
	}

	platform_web_input_frame_end()
	_stats_frame_end()
	input_poll()
	_frame_timing()
}

// _release_surface_texture drops the owned reference returned by
// SurfaceGetCurrentTexture. Failing to do this leaks one texture per frame
// until the process runs out of address space.
@(private)
_release_surface_texture :: proc() {
	if g.frame.surf_tex.texture != nil {
		wg.TextureRelease(g.frame.surf_tex.texture)
		g.frame.surf_tex.texture = nil
	}
}

@(private)
_maybe_reconfigure :: proc() {
	fbw, fbh := platform_framebuffer_size()
	w, h := platform_window_size()
	changed := fbw != g.fb_width || fbh != g.fb_height
	g.width, g.height = w, h
	if (changed || g.force_reconfigure) && fbw > 0 && fbh > 0 {
		g.fb_width, g.fb_height = fbw, fbh
		g.config.width = u32(fbw)
		g.config.height = u32(fbh)
		wg.SurfaceConfigure(g.surface, &g.config)
		g.force_reconfigure = false
	}
	g.dpi = platform_content_scale()
}

FRAME_PACING_SLEEP_THRESHOLD :: 0.002
FRAME_PACING_SLEEP_MARGIN :: 0.001
FRAME_PACING_SPINS_MAX :: 4096
#assert(FRAME_PACING_SLEEP_MARGIN > 0)
#assert(FRAME_PACING_SLEEP_THRESHOLD > FRAME_PACING_SLEEP_MARGIN)
#assert(FRAME_PACING_SPINS_MAX > 0)

@(private)
_frame_pacing_remaining :: proc(now, last, target: f64) -> f64 {
	assert(target > 0, "_frame_pacing_remaining: non-positive target")
	return clamp(target - (now - last), 0, target)
}

@(private)
_frame_timing :: proc() {
	// Native pacing uses a bounded spin so a stalled clock cannot hang a frame.
	when ODIN_OS != .JS {
		if g.target_fps > 0 {
			target := 1.0 / f64(g.target_fps)
			assert(target > 0, "_frame_timing: non-positive target")
			remaining := _frame_pacing_remaining(_now(), g.last_time, target)
			if remaining > FRAME_PACING_SLEEP_THRESHOLD {
				platform_sleep(remaining - FRAME_PACING_SLEEP_MARGIN)
			}
			for _ in 0 ..< FRAME_PACING_SPINS_MAX {
				remaining = _frame_pacing_remaining(_now(), g.last_time, target)
				if remaining <= 0 do break
			}
			if remaining > 0 {
				platform_sleep(min(remaining, FRAME_PACING_SLEEP_THRESHOLD))
			}
		}
	}
	now := _now()
	raw := f32(max(now - g.last_time, 0))
	g.real_frame_time = raw
	// Clamp dt so a long gap (idle wait, browser tab hidden then resumed)
	// doesn't feed a huge step into animations/physics on the next frame.
	g.frame_time = min(raw, MAX_FRAME_TIME)
	g.last_time = now
}

// MAX_FRAME_TIME caps GetFrameTime's reported delta (seconds).
MAX_FRAME_TIME :: 0.25

@(private)
_now :: proc() -> f64 {
	return platform_now() - g.start_time_s
}

// --- window/screen queries (raylib-named) ----------------------------------

GetScreenWidth :: proc() -> i32 {return g.width}
GetScreenHeight :: proc() -> i32 {return g.height}
GetWindowScaleDPI :: proc() -> Vector2 {return {g.dpi, g.dpi}}
GetRenderWidth :: proc() -> i32 {return g.fb_width}
GetRenderHeight :: proc() -> i32 {return g.fb_height}

SetTargetFPS :: proc(fps: i32) {g.target_fps = fps}
GetFrameTime :: proc() -> f32 {return g.frame_time}
GetTime :: proc() -> f64 {return _now()}
GetFPS :: proc() -> i32 {
	if g.real_frame_time <= 0 do return 0
	return i32(1.0 / g.real_frame_time + 0.5)
}

SetWindowMinSize :: proc(w, h: i32) {
	platform_set_window_min_size(w, h)
}
SetWindowSize :: proc(w, h: i32) {
	platform_set_window_size(w, h)
}
SetExitKey :: proc(key: KeyboardKey) {g.inp.exit_key = key}

GetMonitorRefreshRate :: proc(monitor: i32) -> i32 {
	return platform_monitor_refresh_rate()
}
GetCurrentMonitor :: proc() -> i32 {return 0}

IsWindowFocused :: proc() -> bool {
	return platform_window_focused()
}

// FlushBatch forces pending 2D geometry to record into the current render pass
// (raylib rlDrawRenderBatchActive parity — used to order custom draws).
FlushBatch :: proc() {
	if g.frame.has_frame && _active_pass_begun() && !g.frame.scissor_empty {
		renderer_flush(&g.rend, active_pass())
	}
}

// --- active pass routing (render targets) ----------------------------------
// When a render target is bound (BeginTextureMode) the batch records into the
// target's pass on its own command encoder; otherwise the swapchain pass.

// active_pass returns the render pass the batch renderer should record into.
@(private)
active_pass :: proc() -> wg.RenderPassEncoder {
	if g.frame.rt != 0 do return g.frame.rt_pass
	return g.frame.pass
}

// _cur_target_format returns the wgpu colour format of the pass draws currently
// target (the swapchain, or the bound render target). Custom-shader pipelines
// are format-specific, so they are built lazily per target format.
@(private)
_cur_target_format :: proc() -> wg.TextureFormat {
	if g.frame.rt != 0 {
		e := get_texture(g.frame.rt)
		if e != nil && e.wgformat != .Undefined do return e.wgformat
	}
	return g.format
}

// _active_pass_begun reports whether the pass active_pass() returns has begun.
@(private)
_active_pass_begun :: proc() -> bool {
	if !g.frame.has_frame do return false
	if g.frame.rt != 0 do return g.frame.rt_pass_begun
	return g.frame.pass_begun
}

// _attachment_px returns the real pixel dimensions of the current 2D pass
// target: the bound render target, else the configured swapchain surface.
// g.config is authoritative for the swapchain texture size (kept in lockstep
// with SurfaceConfigure), so scissor rects computed from it can never exceed
// the attachment even if g.fb_width lags an async web resize for a frame.
@(private)
_attachment_px :: proc() -> (f32, f32) {
	if g.frame.rt != 0 do return f32(g.frame.rt_w), f32(g.frame.rt_h)
	return f32(max(g.config.width, 1)), f32(max(g.config.height, 1))
}

// _ensure_active_pass lazily begins whichever pass is current: the render
// target's pass while one is bound, otherwise the swapchain pass.
@(private)
_ensure_active_pass :: proc() {
	if g.frame.rt != 0 {
		_ensure_rt_pass()
	} else {
		_ensure_pass()
	}
}
