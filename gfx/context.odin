// ingot:gfx - window + WebGPU context lifecycle and the raylib-named entry
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
RESOURCE_CONTEXT_BITS :: 10
RESOURCE_GENERATION_BITS :: 32 - RESOURCE_SLOT_BITS - RESOURCE_CONTEXT_BITS
RESOURCE_SLOT_COUNT :: 1 << RESOURCE_SLOT_BITS
RESOURCE_SLOT_MASK :: u32(RESOURCE_SLOT_COUNT - 1)
RESOURCE_CONTEXT_MASK :: (u32(1) << RESOURCE_CONTEXT_BITS) - 1
RESOURCE_GENERATION_MASK :: (u32(1) << RESOURCE_GENERATION_BITS) - 1

#assert(RESOURCE_SLOT_COUNT == 1024)
#assert(RESOURCE_CONTEXT_MASK == 1023)
#assert(RESOURCE_GENERATION_MASK == 4095)

@(private)
_resource_generation_next :: proc(generation: u32) -> u32 {
	next := (generation + 1) & RESOURCE_GENERATION_MASK
	if next == 0 do next = 1
	return next
}

@(private)
_resource_handle_make_context :: proc(context_id: u32, index: int, generation: u32) -> u32 {
	assert(context_id > 0 && context_id <= RESOURCE_CONTEXT_MASK)
	assert(index >= 0 && index < RESOURCE_SLOT_COUNT)
	assert(generation > 0 && generation <= RESOURCE_GENERATION_MASK)
	handle := generation << (RESOURCE_CONTEXT_BITS + RESOURCE_SLOT_BITS)
	handle |= context_id << RESOURCE_SLOT_BITS
	handle |= u32(index)
	assert(handle != 0)
	return handle
}

@(private)
_resource_handle_make :: proc(index: int, generation: u32) -> u32 {
	return _resource_handle_make_context(1, index, generation)
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
	generation = handle >> (RESOURCE_CONTEXT_BITS + RESOURCE_SLOT_BITS)
	if generation == 0 || index < 0 || index >= capacity do return 0, 0, false
	return index, generation, true
}

Graphics_Resources :: struct {
	textures:           Texture_Resources,
	atlases:            Atlas_Resources,
	shaders:            Shader_Resources,
	rlgl:               Rlgl_Resources,
	gpu_3d:             Gpu_3D_Resources,
	retire:             [dynamic]Retired_Texture,

	// Lazily baked default font backing DrawText/MeasureText
	// (font_default.odin). Lives here so it is per-context and is cleared by
	// _graphics_resources_destroy along with the atlas slot it points at.
	default_font:       Font,
	// Set once the bake has been attempted, so a failed bake is not retried
	// every frame.
	default_font_baked: bool,
}

Drop_State :: struct {
	hover_staged: bool,
	hover_frame:  bool,
	ready:        bool,
	windowed_x:   i32,
	windowed_y:   i32,
	windowed_w:   i32,
	windowed_h:   i32,
	paths:        [dynamic]cstring,
	web_names:    [MAX_DROPPED_FILES][DROP_NAME_MAX]u8,
	web_cstrs:    [MAX_DROPPED_FILES]cstring,
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
	// loadOp = .Load to preserve the target's prior contents (raylib parity -
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
	id:                         u32,
	epoch:                      u64,
	lifecycle:                  Context_Lifecycle,
	win:                        Window_Handle,
	instance:                   wg.Instance,
	surface:                    wg.Surface,
	adapter:                    wg.Adapter,
	device:                     wg.Device,
	queue:                      wg.Queue,
	format:                     wg.TextureFormat,
	config:                     wg.SurfaceConfiguration,
	config_flags:               ConfigFlags,
	// Pool sizes negotiated against the adapter's reported limits before the
	// device was requested (limits.odin). The renderer and font atlas size
	// themselves from this rather than from desktop constants.
	budget:                     Gpu_Budget,

	// logical (point) size - what GetScreenWidth/Height and the ortho
	// projection use; physical framebuffer may be larger under HiDPI.
	width, height:              i32,
	fb_width, fb_height:        i32,
	dpi:                        f32,
	force_reconfigure:          bool,
	// Set by _maybe_reconfigure when the logical size changed at the start of
	// this frame, so IsWindowResized answers for the frame the caller is in.
	resized_this_frame:         bool,

	// requested window size, stashed at InitWindow for _gpu_finish (needed
	// because on web the GPU device resolves asynchronously, after InitWindow
	// has returned).
	pending_w, pending_h:       i32,
	frame:                      Frame_State,

	// timing
	start_time_s:               f64,
	last_time:                  f64,
	frame_time:                 f32, // clamped to MAX_FRAME_TIME (what GetFrameTime returns)
	real_frame_time:            f32, // unclamped, for GetFPS accuracy
	target_fps:                 i32,

	// event-driven frame scheduling (idle.odin)
	idle:                       Idle_State,

	// renderer (batch.odin)
	rend:                       Renderer,
	cam2d:                      Camera2D,
	cam2d_saved:                Affine,
	cam2d_active:               bool,
	cam3d_active:               bool,
	cam3d_vp:                   Matrix,
	cam3d_proj:                 Matrix,
	cam3d_view:                 Matrix,
	cam3d:                      Camera3D,
	cam3d_right:                Vector3,
	cam3d_up:                   Vector3,
	cam3d_fwd:                  Vector3,
	cam3d_projection_available: bool,
	resources:                  Graphics_Resources,
	stats_current:              Renderer_Stats,
	stats_latest:               Renderer_Stats,

	// input (input.odin)
	inp:                        Input,
	drop:                       Drop_State,
	a11y:                       A11y_State,
	submissions:                Submission_Tracker,
	initialized:                bool,
	composite_alpha:            wg.CompositeAlphaMode,
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
// put a limit on everything). The true physical maximum is one retirement per
// live texture slot plus one per font atlas: nothing else can be destroyed in
// a single frame, so exceeding this bound means the same handle was retired
// twice. A tile-cache consumer legitimately recycles hundreds of textures per
// frame while the user flick-zooms, so the previous policy cap of 64 turned an
// ordinary workload into an abort.
MAX_RETIRED_PER_FRAME :: RESOURCE_SLOT_COUNT + MAX_ATLASES
#assert(MAX_RETIRED_PER_FRAME == 1280)

// _retire_texture destroys a texture's GPU handles, deferring to after this
// frame's queue submit while a frame is recording (wgpu validates that
// submitted command buffers reference no destroyed textures).
@(private)
_retire_texture :: proc(
	ctx: ^Context,
	bind: wg.BindGroup,
	sampler: wg.Sampler,
	view: wg.TextureView,
	tex: wg.Texture,
) {
	assert(ctx != nil, "_retire_texture: nil context")
	// Why assert: all-nil handles mean the entry was already destroyed - a
	// double-unload of the same font/texture.
	assert(
		bind != nil || sampler != nil || view != nil || tex != nil,
		"_retire_texture: all handles nil (double unload?)",
	)
	if ctx.frame.has_frame {
		// Why assert: the bound is the physical maximum (every texture slot
		// plus every atlas), so overflowing it means a handle was retired
		// twice rather than that the caller is simply busy.
		assert(
			len(ctx.resources.retire) < MAX_RETIRED_PER_FRAME,
			"_retire_texture: retire queue full (double unload?)",
		)
		append(&ctx.resources.retire, Retired_Texture{bind, sampler, view, tex})
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
_flush_retired :: proc(ctx: ^Context) {
	assert(ctx != nil, "_flush_retired: nil context")
	// Why assert: flushing while a frame still records would recreate the
	// destroy-before-submit validation abort this queue exists to prevent.
	assert(!ctx.frame.has_frame, "_flush_retired: called while a frame is recording")
	for retired in ctx.resources.retire do _destroy_retired(retired)
	clear(&ctx.resources.retire)
}

// The default context is deliberately NOT statically initialised, and the id
// is assigned by _default_context_init below instead.
//
// A static initialiser - even `= {id = 1}`, a single non-zero byte - forces
// LLVM to place the whole struct in .data rather than .bss. Context is ~11 MB
// (mostly Renderer's vertex and index arrays), and .data is emitted verbatim
// into the binary while .bss is elided, because WebAssembly and every ELF
// loader zero fresh memory anyway. On the wasm target that one byte cost
// 11.1 MB of zeros in the module: 12.3 MB down to 1.2 MB when removed.
//
// Keep this declaration bare. If a field ever needs a non-zero default, set it
// in _default_context_init.
@(private)
default_context_storage: Context
@(private)
g: ^Context = &default_context_storage

// DEFAULT_CONTEXT_ID is the reserved id of the default context. Every other
// context is numbered from CONTEXT_ID_FIRST upward by _context_assign_id.
DEFAULT_CONTEXT_ID :: u32(1)
CONTEXT_ID_FIRST :: DEFAULT_CONTEXT_ID + 1

// The reserved id must not be handed out again, and both must fit the field
// width resource handles pack them into. Derived rather than written as a
// literal 2 so the two cannot drift apart.
#assert(CONTEXT_ID_FIRST > DEFAULT_CONTEXT_ID)
#assert(CONTEXT_ID_FIRST <= RESOURCE_CONTEXT_MASK)

@(private)
context_id_next: u32 = CONTEXT_ID_FIRST

// @(init) runs before main on every target, so the id is in place before any
// caller can observe it - the property the old static initialiser provided.
//
// The ordering between @(init) procedures is not specified by the language. It
// is Odin's init_procedures_cmp: package import order, then filename, then
// source offset. Both halves matter here, and only one of them is safe by
// construction:
//
//   Across packages, it holds. Import cycles are a compile error, so the
//   import graph is a DAG and an imported package always sorts before its
//   importer. Anything that reaches gfx must import gfx, so its @(init) runs
//   after this one.
//
//   Within gfx, it does not. The tiebreak is the filename, and context.odin is
//   not first - roughly half the package sorts ahead of it (api.odin,
//   audio.odin, batch.odin, camera.odin, colors.odin, ...). A second @(init)
//   in any of those files would run before this one and read an unassigned id.
//
// So the invariant this trade rests on is: _default_context_init is the only
// @(init) in gfx. scripts/check_init_order.py enforces that; if you need
// initialisation elsewhere in the package, call it from here rather than
// adding another @(init). context_id and _texture_slot_context assert a
// non-zero id so a violation aborts instead of silently aliasing handles.
@(init, private)
_default_context_init :: proc "contextless" () {
	default_context_storage.id = DEFAULT_CONTEXT_ID
}

default_context :: proc() -> ^Context {
	return g
}

set_default_context :: proc(ctx: ^Context) -> ^Context {
	assert(ctx != nil, "set_default_context: nil context")
	previous := g
	g = ctx
	return previous
}

context_epoch :: proc(ctx: ^Context) -> u64 {
	if ctx == nil do return 0
	return ctx.epoch
}

context_id :: proc(ctx: ^Context) -> u32 {
	if ctx == nil do return 0
	// Zero means "unassigned" everywhere in the resource handle code, and a
	// context that has not opened a window legitimately reads as zero -
	// _context_assign_id runs at window creation. The default context is the
	// exception: its id comes from _default_context_init, so a zero here means
	// that @(init) has not run yet and the caller is about to mint or match
	// handles against context 0. See the note above _default_context_init.
	if ctx == &default_context_storage do assert(ctx.id != 0, "context_id: no id before init")
	return ctx.id
}

@(private)
_context_assign_id :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_context_assign_id: nil context")
	if ctx.id != 0 do return true
	if context_id_next == 0 || context_id_next > RESOURCE_CONTEXT_MASK do return false
	ctx.id = context_id_next
	context_id_next += 1
	return true
}

context_ready :: proc(ctx: ^Context) -> bool {
	return ctx != nil && ctx.lifecycle == .Ready && ctx.initialized
}

// context_live reports a context a host may run a frame loop against: ready to
// draw now, or - on the web only - still resolving its GPU device on the
// browser event loop.
//
// Hosts must gate startup on this rather than on context_ready. On the web the
// adapter and device resolve several animation frames AFTER context_init
// returns, so context_ready is necessarily false at startup; a host that reads
// that as failure and tears the context down also cancels the in-flight
// adapter request, because _web_on_adapter drops any request whose context is
// no longer .Starting. The result is a permanently black canvas with no error
// logged on either side of the wasm boundary. ui_gfx.app_start shipped exactly
// that bug, so keep the rule here where both callers share it.
//
// Waiting is safe: gfx.step skips the app callback until ctx.initialized flips,
// and context_begin_frame refuses to open a frame before then.
context_live :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	when ODIN_OS == .JS {
		return ctx.lifecycle == .Starting || context_ready(ctx)
	} else {
		return context_ready(ctx)
	}
}

context_frame_available :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	return ctx.frame.has_frame
}

context_init :: proc(ctx: ^Context, width, height: i32, title: cstring) -> bool {
	assert(ctx != nil && title != nil, "context_init: nil argument")
	when ODIN_OS == .JS {
		if ctx != &default_context_storage do return false
	}
	_init_window_context(ctx, width, height, title)
	return context_live(ctx)
}

context_close :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_close: nil context")
	_close_window_context(ctx)
}

context_should_close :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return true
	return platform_should_close(ctx)
}

@(private)
_graphics_resources_init :: proc(resources: ^Graphics_Resources) {
	assert(resources != nil, "_graphics_resources_init: nil resources")
	resources^ = {}
}

@(private)
_graphics_resources_destroy :: proc(ctx: ^Context, resources: ^Graphics_Resources) {
	assert(ctx != nil, "_graphics_resources_destroy: nil context")
	assert(resources != nil, "_graphics_resources_destroy: nil resources")
	assert(!ctx.frame.has_frame, "_graphics_resources_destroy: active frame")
	_gpu_3d_resources_destroy(ctx, &resources.gpu_3d)
	_rlgl_resources_destroy(&resources.rlgl)
	_shader_resources_destroy(&resources.shaders)
	_atlas_resources_destroy(ctx, &resources.atlases)
	_texture_resources_destroy(ctx, &resources.textures)
	_flush_retired(ctx)
	delete(resources.retire)
	resources^ = {}
}

// --- async adapter/device request helpers ----------------------------------

@(private)
Adapter_Res :: struct {
	adapter: wg.Adapter,
	status:  wg.RequestAdapterStatus,
	done:    bool,
}
@(private)
Device_Res :: struct {
	device: wg.Device,
	status: wg.RequestDeviceStatus,
	done:   bool,
}

@(private)
_on_adapter :: proc "c" (
	status: wg.RequestAdapterStatus,
	adapter: wg.Adapter,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	r := (^Adapter_Res)(u1)
	assert(r != nil, "_on_adapter: nil result")
	r.adapter = adapter
	r.status = status
	r.done = true
}

@(private)
_on_device :: proc "c" (
	status: wg.RequestDeviceStatus,
	device: wg.Device,
	msg: wg.StringView,
	u1, u2: rawptr,
) {
	context = runtime.default_context()
	if status != .Success {
		fmt.eprintfln("gfx: device request failed (status=%v): %s", status, string(msg))
	}
	r := (^Device_Res)(u1)
	assert(r != nil, "_on_device: nil result")
	r.device = device
	r.status = status
	r.done = true
}

// INGOT_GPU_STRICT turns any uncaptured wgpu validation message into an
// immediate abort. Fuzz harnesses build with it (fuzz/run.sh gfx-frame) so
// GPU misuse that would otherwise be logged and survived fails the run -
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
	_ = device
	_ = u1
	_ = u2
	fmt.eprintfln("gfx: wgpu uncaptured error (%v): %s", type, string(message))
	when INGOT_GPU_STRICT {
		panic("INGOT_GPU_STRICT: aborting on wgpu validation error")
	}
}

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
		fmt.eprintln("gfx: window creation failed")
		ctx.lifecycle = .Empty
		return
	}

	ctx.instance = wg.CreateInstance()
	if ctx.instance == nil {
		fmt.eprintln("gfx: WebGPU instance creation failed")
		_close_window_context(ctx)
		return
	}
	ctx.surface = platform_create_surface(ctx, ctx.instance)
	if ctx.surface == nil {
		fmt.eprintln("gfx: WebGPU surface creation failed")
		_close_window_context(ctx)
		return
	}
	ctx.pending_w, ctx.pending_h = width, height

	// Acquire the GPU adapter+device. On native this resolves synchronously
	// (busy-wait) and calls _gpu_finish before returning; on web the requests
	// resolve on the browser event loop and _gpu_finish runs from the device
	// callback a few RAF ticks later (ctx.initialized stays false until then).
	platform_start_gpu(ctx)
}

// _gpu_finish completes context setup once ctx.adapter/device/queue are ready.
// Shared by both targets (native calls it inline from platform_start_gpu; web
// calls it from the async device callback). Everything here is pure wgpu.
@(private)
_gpu_finish :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "_gpu_finish: nil context")
	if ctx.surface == nil || ctx.adapter == nil || ctx.device == nil || ctx.queue == nil {
		fmt.eprintln("gfx: incomplete GPU state; cannot configure swapchain")
		_close_window_context(ctx)
		return false
	}
	width, height := ctx.pending_w, ctx.pending_h
	if width <= 0 || height <= 0 {
		fmt.eprintln("gfx: invalid pending window dimensions")
		_close_window_context(ctx)
		return false
	}

	caps, status := wg.SurfaceGetCapabilities(ctx.surface, ctx.adapter)
	if status != .Success || caps.formatCount == 0 || caps.formats == nil {
		fmt.eprintln("gfx: surface reports no supported formats; cannot configure swapchain")
		_close_window_context(ctx)
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

	alpha: wg.CompositeAlphaMode = .Opaque
	if .WINDOW_TRANSPARENT in ctx.config_flags {
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
	ctx.composite_alpha = alpha
	_stats_set_alpha_mode(ctx, alpha)
	ctx.config = wg.SurfaceConfiguration {
		device      = ctx.device,
		format      = ctx.format,
		usage       = {.RenderAttachment},
		width       = u32(fbw),
		height      = u32(fbh),
		alphaMode   = alpha,
		presentMode = .Fifo,
	}
	wg.SurfaceConfigure(ctx.surface, &ctx.config)
	when ODIN_OS != .JS do ctx.force_reconfigure = true

	ctx.start_time_s = platform_now()
	ctx.last_time = _now(ctx)
	ctx.target_fps = 0

	_submission_init(&ctx.submissions, ctx)
	if !renderer_init(ctx, &ctx.rend) {
		// The device could not supply the stream pools even at the floor.
		// Closing here surfaces a diagnosable state; the alternative used to
		// be an assert, which on web traps the module and freezes the canvas.
		_close_window_context(ctx)
		return false
	}
	_graphics_resources_init(&ctx.resources)
	platform_input_init(ctx)
	platform_drop_init(ctx)

	ctx.initialized = true
	ctx.lifecycle = .Ready
	assert(context_ready(ctx), "_gpu_finish: context not ready")
	return true
}

CloseWindow :: proc() {
	context_close(default_context())
}

@(private)
_close_window_context :: proc(ctx: ^Context) {
	assert(ctx != nil, "_close_window_context: nil context")
	if ctx.instance == nil && ctx.win == nil do return
	assert(!ctx.frame.has_frame, "CloseWindow: frame is still recording")
	ctx.lifecycle = .Closing
	if ctx.initialized {
		context_close_accessibility(ctx)
		platform_drop_shutdown(ctx)
		_graphics_resources_destroy(ctx, &ctx.resources)
		renderer_shutdown(&ctx.rend)
		ensure(_submission_shutdown(&ctx.submissions), "gfx: submissions did not drain")
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
	mem.zero(ctx, size_of(Context))
	ctx.id = context_id
	ctx.epoch = closing_epoch
	ctx.config_flags = flags
}

WindowShouldClose :: proc() -> bool {
	return context_should_close(default_context())
}

// --- per-frame -------------------------------------------------------------

BeginDrawing :: proc() {
	context_begin_drawing(default_context())
}

context_begin_drawing :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_begin_drawing: nil context")
	_maybe_reconfigure(ctx)
	_stats_frame_begin(ctx)
	platform_web_input_frame_begin(ctx)

	if !renderer_frame_begin(ctx, &ctx.rend) {
		ctx.frame.has_frame = false
		return
	}
	acquire_started := platform_now()
	ctx.frame.surf_tex = wg.SurfaceGetCurrentTexture(ctx.surface)
	acquire_elapsed := platform_now() - acquire_started
	_stats_context_cpu_times(ctx, 0, acquire_elapsed, 0, 0, 0)
	#partial switch ctx.frame.surf_tex.status {
	case .SuccessOptimal, .SuccessSuboptimal:
	// ok
	case .Outdated, .Lost:
		// The swapchain is stale (e.g. display change); reconfigure so the
		// next frame can acquire a fresh texture.
		_release_surface_texture(ctx)
		_stream_slot_abandon(&ctx.rend)
		if ctx.fb_width > 0 && ctx.fb_height > 0 {
			wg.SurfaceConfigure(ctx.surface, &ctx.config)
		}
		ctx.frame.has_frame = false
		return
	case:
		_release_surface_texture(ctx)
		_stream_slot_abandon(&ctx.rend)
		ctx.frame.has_frame = false
		return
	}
	_assert_window_frame_contract(ctx)
	renderer_window_projection_refresh(&ctx.rend, ctx.queue, ctx.width, ctx.height)
	ctx.frame.view = wg.TextureCreateView(ctx.frame.surf_tex.texture, nil)
	ctx.frame.encoder = wg.DeviceCreateCommandEncoder(ctx.device, nil)
	ctx.frame.clear_color = Color{0, 0, 0, 255}
	ctx.frame.pass_begun = false
	ctx.frame.has_frame = true
	ctx.frame.scissor_on = false
	ctx.frame.scissor_empty = false
}

@(private)
_assert_window_frame_contract :: proc(ctx: ^Context) {
	assert(ctx != nil, "_assert_window_frame_contract: nil context")
	assert(ctx.width > 0 && ctx.height > 0, "_assert_window_frame_contract: invalid logical size")
	assert(
		ctx.fb_width > 0 && ctx.fb_height > 0,
		"_assert_window_frame_contract: invalid framebuffer",
	)
	assert(ctx.config.width == u32(ctx.fb_width), "_assert_window_frame_contract: width mismatch")
	assert(
		ctx.config.height == u32(ctx.fb_height),
		"_assert_window_frame_contract: height mismatch",
	)
	assert(ctx.frame.surf_tex.texture != nil, "_assert_window_frame_contract: nil texture")
}

ClearBackground :: proc(c: Color) {
	context_clear_background(default_context(), c)
}

context_clear_background :: proc(ctx: ^Context, c: Color) {
	assert(ctx != nil, "context_clear_background: nil context")
	// While a render target is bound but its pass hasn't begun yet, the clear
	// applies to the target (raylib: ClearBackground after BeginTextureMode
	// clears the target). Otherwise it sets the swapchain clear.
	if ctx.frame.rt != 0 && !ctx.frame.rt_pass_begun {
		ctx.frame.rt_clear = c
		ctx.frame.rt_should_clear = true
		return
	}
	ctx.frame.clear_color = c
}

// context_ensure_pass lazily begins the frame render pass so ClearBackground
// (called after BeginDrawing in raylib order) can set the loadOp clear value first.
@(private)
context_ensure_pass :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_ensure_pass: nil context")
	if !ctx.frame.has_frame || ctx.frame.pass_begun do return
	cc := ctx.frame.clear_color
	ctx.frame.pass = wg.CommandEncoderBeginRenderPass(
		ctx.frame.encoder,
		&{
			colorAttachmentCount = 1,
			colorAttachments = &wg.RenderPassColorAttachment {
				view = ctx.frame.view,
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
	_stats_render_pass(ctx)
	ctx.frame.pass_begun = true
	// A new pass starts with a full-attachment scissor; restore any active clip.
	if ctx.frame.scissor_on && !ctx.frame.scissor_empty {
		assert(ctx.frame.sc_w > 0)
		assert(ctx.frame.sc_h > 0)
		wg.RenderPassEncoderSetScissorRect(
			ctx.frame.pass,
			ctx.frame.sc_x,
			ctx.frame.sc_y,
			ctx.frame.sc_w,
			ctx.frame.sc_h,
		)
	}
}

EndDrawing :: proc() {
	context_end_drawing(default_context())
}

context_end_drawing :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_end_drawing: nil context")
	if ctx.frame.has_frame {
		context_ensure_pass(ctx) // guarantee a clear even on empty frames
		if !ctx.frame.scissor_empty {
			renderer_flush(ctx, &ctx.rend, ctx.frame.pass, .Frame_End)
		} else {
			clear(&ctx.rend.verts)
			clear(&ctx.rend.indices)
		}
		wg.RenderPassEncoderEnd(ctx.frame.pass)
		wg.RenderPassEncoderRelease(ctx.frame.pass)

		retirement := _submission_reserve(&ctx.submissions)
		if retirement != 0 do assert(_stream_slot_upload(ctx, &ctx.rend))
		cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(
			ctx,
			ctx.frame.encoder,
			retirement != 0,
		)
		if retirement != 0 && cmd != nil {
			_stats_queue_submission(ctx)
			assert(_submission_commit(&ctx.submissions, retirement))
			if !_stream_slot_submitted(&ctx.rend, retirement) {
				_stats_stream_retirement_failure(ctx)
			}
		} else {
			if retirement != 0 do assert(_submission_rollback(&ctx.submissions, retirement))
			_stream_slot_abandon(&ctx.rend)
			_stats_stream_retirement_failure(ctx)
		}
		if cmd != nil do wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(ctx.frame.encoder)
		present_elapsed := _stats_present(ctx)
		_stats_context_cpu_times(ctx, 0, 0, encode_elapsed, submit_elapsed, present_elapsed)
		wg.TextureViewRelease(ctx.frame.view)
		_release_surface_texture(ctx)
		ctx.frame.has_frame = false
		_flush_retired(ctx)
		_renderer_report_overflow(&ctx.rend)
	} else {
		clear(&ctx.rend.verts)
		clear(&ctx.rend.indices)
	}

	platform_web_input_frame_end(ctx)
	_stats_frame_end(ctx)
	when ODIN_OS != .JS {
		input_poll(ctx)
	}
	_frame_timing(ctx, platform_should_close(ctx))
}

// _release_surface_texture drops the owned reference returned by
// SurfaceGetCurrentTexture. Failing to do this leaks one texture per frame
// until the process runs out of address space.
@(private)
_release_surface_texture :: proc(ctx: ^Context) {
	assert(ctx != nil, "_release_surface_texture: nil context")
	if ctx.frame.surf_tex.texture != nil {
		wg.TextureRelease(ctx.frame.surf_tex.texture)
		ctx.frame.surf_tex.texture = nil
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
_frame_pacing_enabled :: proc(target_fps: i32, close_requested: bool) -> bool {
	return target_fps > 0 && !close_requested
}

@(private)
_frame_timing :: proc(ctx: ^Context, close_requested: bool) {
	assert(ctx != nil, "_frame_timing: nil context")
	// Native pacing uses a bounded spin so a stalled clock cannot hang a frame.
	when ODIN_OS != .JS {
		if _frame_pacing_enabled(ctx.target_fps, close_requested) {
			target := 1.0 / f64(ctx.target_fps)
			assert(target > 0, "_frame_timing: non-positive target")
			remaining := _frame_pacing_remaining(_now(ctx), ctx.last_time, target)
			if remaining > FRAME_PACING_SLEEP_THRESHOLD {
				platform_sleep(remaining - FRAME_PACING_SLEEP_MARGIN)
			}
			for _ in 0 ..< FRAME_PACING_SPINS_MAX {
				remaining = _frame_pacing_remaining(_now(ctx), ctx.last_time, target)
				if remaining <= 0 do break
			}
			if remaining > 0 {
				platform_sleep(min(remaining, FRAME_PACING_SLEEP_THRESHOLD))
			}
		}
	}
	now := _now(ctx)
	raw := f32(max(now - ctx.last_time, 0))
	ctx.real_frame_time = raw
	// Clamp dt so a long gap (idle wait, browser tab hidden then resumed)
	// doesn't feed a huge step into animations/physics on the next frame.
	ctx.frame_time = min(raw, MAX_FRAME_TIME)
	ctx.last_time = now
}

// MAX_FRAME_TIME caps GetFrameTime's reported delta (seconds).
MAX_FRAME_TIME :: 0.25

@(private)
_now :: proc(ctx: ^Context) -> f64 {
	assert(ctx != nil, "_now: nil context")
	return platform_now() - ctx.start_time_s
}

// --- window/screen queries (raylib-named) ----------------------------------

context_screen_width :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.width}
context_screen_height :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.height}
context_window_scale_dpi :: proc(ctx: ^Context) -> Vector2 {
	if ctx == nil do return {1, 1}
	return {ctx.dpi, ctx.dpi}
}
context_render_width :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.fb_width}
context_render_height :: proc(ctx: ^Context) -> i32 {return ctx == nil ? 0 : ctx.fb_height}
context_frame_time :: proc(ctx: ^Context) -> f32 {return ctx == nil ? 0 : ctx.frame_time}
context_time :: proc(ctx: ^Context) -> f64 {
	if ctx == nil do return 0
	return platform_now() - ctx.start_time_s
}
context_fps :: proc(ctx: ^Context) -> i32 {
	if ctx == nil || ctx.real_frame_time <= 0 do return 0
	return i32(1.0 / ctx.real_frame_time + 0.5)
}

GetScreenWidth :: proc() -> i32 {return context_screen_width(default_context())}
GetScreenHeight :: proc() -> i32 {return context_screen_height(default_context())}
GetWindowScaleDPI :: proc() -> Vector2 {return context_window_scale_dpi(default_context())}
GetRenderWidth :: proc() -> i32 {return context_render_width(default_context())}
GetRenderHeight :: proc() -> i32 {return context_render_height(default_context())}

SetTargetFPS :: proc(fps: i32) {context_set_target_fps(default_context(), fps)}
GetFrameTime :: proc() -> f32 {return context_frame_time(default_context())}
GetTime :: proc() -> f64 {return context_time(default_context())}
GetFPS :: proc() -> i32 {return context_fps(default_context())}

context_set_window_min_size :: proc(ctx: ^Context, w, h: i32) {
	platform_set_window_min_size(ctx, w, h)
}
SetWindowMinSize :: proc(w, h: i32) {
	context_set_window_min_size(default_context(), w, h)
}
context_set_window_size :: proc(ctx: ^Context, w, h: i32) {
	platform_set_window_size(ctx, w, h)
}
SetWindowSize :: proc(w, h: i32) {
	context_set_window_size(default_context(), w, h)
}

context_set_window_title :: proc(ctx: ^Context, title: cstring) {
	assert(ctx != nil, "context_set_window_title: nil context")
	assert(title != nil, "context_set_window_title: nil title")
	platform_set_window_title(ctx, title)
}
SetWindowTitle :: proc(title: cstring) {
	context_set_window_title(default_context(), title)
}

// SetWindowPosition and GetWindowPosition address the window's placement on a
// monitor. A browser has no such placement: the page cannot move its own
// window and a canvas has no monitor coordinates, so on web the setter does
// nothing and the getter reports the canvas origin.
context_set_window_position :: proc(ctx: ^Context, x, y: i32) {
	platform_set_window_position(ctx, x, y)
}
SetWindowPosition :: proc(x, y: i32) {
	context_set_window_position(default_context(), x, y)
}

context_get_window_position :: proc(ctx: ^Context) -> Vector2 {
	assert(ctx != nil, "context_get_window_position: nil context")
	x, y := platform_window_position(ctx)
	return {f32(x), f32(y)}
}
GetWindowPosition :: proc() -> Vector2 {
	return context_get_window_position(default_context())
}

// IsWindowResized reports whether the logical window size changed at the start
// of the current frame. A DPI-only change is not a resize; see GetWindowScaleDPI.
IsWindowResized :: proc() -> bool {
	return context_window_resized(default_context())
}

context_window_resized :: proc(ctx: ^Context) -> bool {
	if ctx == nil do return false
	return ctx.resized_this_frame
}
context_set_exit_key :: proc(ctx: ^Context, key: KeyboardKey) {
	if ctx == nil do return
	ctx.inp.exit_key = key
}
SetExitKey :: proc(key: KeyboardKey) {context_set_exit_key(default_context(), key)}

GetMonitorRefreshRate :: proc(monitor: i32) -> i32 {
	return context_monitor_refresh_rate(default_context())
}
GetCurrentMonitor :: proc() -> i32 {return 0}

IsWindowFocused :: proc() -> bool {
	return context_window_focused(default_context())
}

// FlushBatch forces pending 2D geometry to record into the current render pass
// (raylib rlDrawRenderBatchActive parity - used to order custom draws).
context_flush_batch :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_flush_batch: nil context")
	if ctx.frame.has_frame && context_active_pass_begun(ctx) && !ctx.frame.scissor_empty {
		renderer_flush(ctx, &ctx.rend, context_active_pass(ctx))
	}
}

FlushBatch :: proc() {
	context_flush_batch(default_context())
}

// --- active pass routing (render targets) ----------------------------------
// When a render target is bound (BeginTextureMode) the batch records into the
// target's pass on its own command encoder; otherwise the swapchain pass.

// context_active_pass returns the render pass the batch renderer should record into.
@(private)
context_active_pass :: proc(ctx: ^Context) -> wg.RenderPassEncoder {
	assert(ctx != nil, "context_active_pass: nil context")
	if ctx.frame.rt != 0 do return ctx.frame.rt_pass
	return ctx.frame.pass
}

// _cur_target_format returns the wgpu colour format of the pass draws currently
// target (the swapchain, or the bound render target). Custom-shader pipelines
// are format-specific, so they are built lazily per target format.
@(private)
_cur_target_format :: proc(ctx: ^Context) -> wg.TextureFormat {
	assert(ctx != nil, "_cur_target_format: nil context")
	if ctx.frame.rt != 0 {
		e := context_get_texture(ctx, ctx.frame.rt)
		if e != nil && e.wgformat != .Undefined do return e.wgformat
	}
	return ctx.format
}

// context_active_pass_begun reports whether the active pass has begun.
@(private)
context_active_pass_begun :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "context_active_pass_begun: nil context")
	if !ctx.frame.has_frame do return false
	if ctx.frame.rt != 0 do return ctx.frame.rt_pass_begun
	return ctx.frame.pass_begun
}

// context_attachment_px returns the real pixel dimensions of the current 2D
// pass target: the bound render target, else the configured swapchain surface.
// ctx.config is authoritative for the swapchain texture size (kept in lockstep
// with SurfaceConfigure), so scissor rects computed from it can never exceed
// the attachment even if ctx.fb_width lags an async web resize for a frame.
@(private)
context_attachment_px :: proc(ctx: ^Context) -> (f32, f32) {
	assert(ctx != nil, "context_attachment_px: nil context")
	if ctx.frame.rt != 0 do return f32(ctx.frame.rt_w), f32(ctx.frame.rt_h)
	return f32(max(ctx.config.width, 1)), f32(max(ctx.config.height, 1))
}

// context_ensure_active_pass lazily begins whichever pass is current: the
// render target's pass while one is bound, otherwise the swapchain pass.
@(private)
context_ensure_active_pass :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_ensure_active_pass: nil context")
	if ctx.frame.rt != 0 {
		context_ensure_rt_pass(ctx)
	} else {
		context_ensure_pass(ctx)
	}
}
