// ingot:gfx - window + WebGPU context lifecycle and the raylib-named entry
// points apps call (InitWindow/BeginDrawing/EndDrawing/ClearBackground/...).
// All per-window mutable state lives in a `Context`. The PascalCase facade
// routes through `default_context()`, which `set_default_context` rebinds as a
// host-level handoff; explicit `context_*`/`frame_*` procedures take the owner.
// The only package-scope variables are the default-context storage, process-
// wide platform handles, and per-window owner tables keyed by native handle;
// the `gfx-context` rule of `tools/odingate` enforces that inventory.
package gfx

import "core:fmt"
import wg "vendor:wgpu"

KEY_COUNT :: 349 // KB_MENU (348) + 1
RESOURCE_SLOT_BITS :: 11
RESOURCE_CONTEXT_BITS :: 9
RESOURCE_GENERATION_BITS :: 32 - RESOURCE_SLOT_BITS - RESOURCE_CONTEXT_BITS
RESOURCE_SLOT_COUNT :: 1 << RESOURCE_SLOT_BITS
RESOURCE_SLOT_MASK :: u32(RESOURCE_SLOT_COUNT - 1)
RESOURCE_CONTEXT_MASK :: (u32(1) << RESOURCE_CONTEXT_BITS) - 1
RESOURCE_GENERATION_MASK :: (u32(1) << RESOURCE_GENERATION_BITS) - 1

#assert(RESOURCE_SLOT_COUNT == 2048)
#assert(RESOURCE_CONTEXT_MASK == 511)
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
	compute:            Gpu_Compute_Resources,
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
	timing:                 Gpu_Timing_Token,
	pass:                   wg.RenderPassEncoder,
	pass_name:              string,
	clear_color:            Color,
	pass_begun:             bool,
	pass_preserve:          bool,
	has_frame:              bool,
	draw_started:           f64,

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
	rt_timing:              Gpu_Timing_Token,
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

// Context_Error records why the most recent lifecycle call on a Context
// failed. It is sticky: context_init clears it before trying, every failure
// path sets it before returning, and nothing else resets it, so a caller that
// saw false from context_init or context_close can read the reason afterwards.
Context_Error :: enum u8 {
	None,
	Window,
	Instance,
	Surface,
	Adapter,
	Device,
	Device_Lost,
	Swapchain,
	Stream_Allocation,
	Close_Refused,
}

Context :: struct {
	id:                          u32,
	epoch:                       u64,
	lifecycle:                   Context_Lifecycle,
	last_error:                  Context_Error,
	win:                         Window_Handle,
	instance:                    wg.Instance,
	surface:                     wg.Surface,
	adapter:                     wg.Adapter,
	device:                      wg.Device,
	queue:                       wg.Queue,
	format:                      wg.TextureFormat,
	config:                      wg.SurfaceConfiguration,
	config_flags:                ConfigFlags,
	activation_retries_pending:  u8,
	application_was_active:      bool,
	activation_next_at:          f64,
	activation_view:             rawptr,
	// Hover focus (platform.odin _hover_focus_step): enter/leave drive
	// pointer_inside and arm one focus request; motion is per-poll.
	pointer_inside:              bool,
	hover_focus_armed:           bool,
	hover_focus_motion:          bool,
	// Pool sizes negotiated against the adapter's reported limits before the
	// device was requested (limits.odin). The renderer and font atlas size
	// themselves from this rather than from desktop constants.
	budget:                      Gpu_Budget,

	// logical (point) size - what GetScreenWidth/Height and the ortho
	// projection use; physical framebuffer may be larger under HiDPI.
	width, height:               i32,
	fb_width, fb_height:         i32,
	dpi:                         f32,
	force_reconfigure:           bool,
	// Whether the surface offered .Immediate at setup; gates context_set_vsync.
	present_immediate_supported: bool,
	// Set once the browser revoked the WebGPU device. Terminal: frames stop
	// and the host page offers a reload (platform_web.odin).
	device_lost:                 bool,
	// Set by _maybe_reconfigure when the logical size changed at the start of
	// this frame, so IsWindowResized answers for the frame the caller is in.
	resized_this_frame:          bool,
	// Frames that acquired and presented a surface texture. Read by the web
	// crash heartbeat to tell rendered frames apart from idle rAF ticks.
	presented_frames:            u32,

	// requested window size, stashed at InitWindow for _gpu_finish (needed
	// because on web the GPU device resolves asynchronously, after InitWindow
	// has returned).
	pending_w, pending_h:        i32,
	frame:                       Frame_State,

	// timing
	start_time_s:                f64,
	last_time:                   f64,
	frame_time:                  f32, // clamped to MAX_FRAME_TIME (what GetFrameTime returns)
	real_frame_time:             f32, // unclamped, for GetFPS accuracy
	fps_meter:                   Fps_Meter,
	target_fps:                  i32,

	// event-driven frame scheduling (idle.odin)
	idle:                        Idle_State,

	// renderer (batch.odin)
	rend:                        Renderer,
	cam2d:                       Camera2D,
	cam2d_saved:                 Affine,
	cam2d_active:                bool,
	cam3d_active:                bool,
	cam3d_vp:                    Matrix,
	cam3d_proj:                  Matrix,
	cam3d_view:                  Matrix,
	cam3d:                       Camera3D,
	cam3d_right:                 Vector3,
	cam3d_up:                    Vector3,
	cam3d_fwd:                   Vector3,
	cam3d_projection_available:  bool,
	resources:                   Graphics_Resources,
	stats_current:               Renderer_Stats,
	stats_latest:                Renderer_Stats,
	gpu_timing:                  Gpu_Timing_State,
	screenshot:                  Screenshot_Map,
	delivery:                    Frame_Delivery_State,

	// input (input.odin)
	inp:                         Input,
	drop:                        Drop_State,
	a11y:                        A11y_State,
	submissions:                 Submission_Tracker,
	initialized:                 bool,
	composite_alpha:             wg.CompositeAlphaMode,
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

// NATIVE_WINDOW_TABLE_MAX bounds the per-window owner tables kept by native
// platform hooks (SDL window state, IME views, drop views, Metal layers).
NATIVE_WINDOW_TABLE_MAX :: 16

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
// @(init) in gfx. The `init-order` rule of `tools/odingate` enforces that; if you need
// initialisation elsewhere in the package, call it from here rather than
// adding another @(init). context_id and _texture_slot_context assert a
// non-zero id so a violation aborts instead of silently aliasing handles.
@(init, private)
_default_context_init :: proc "contextless" () {
	default_context_storage.id = DEFAULT_CONTEXT_ID
}

default_context :: proc "contextless" () -> ^Context {
	return g
}

set_default_context :: proc(ctx: ^Context) -> ^Context {
	assert(ctx != nil, "set_default_context: nil context")
	previous := g
	g = ctx
	return previous
}

// tigerstyle: pure
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

// tigerstyle: pure
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
	ctx.last_error = .None
	_init_window_context(ctx, width, height, title)
	return context_live(ctx)
}

// context_error reports why the last context_init or context_close on ctx
// failed, or .None. The value survives _close_window_context's storage reset
// so a refused close and an abandoned init both stay readable.
context_error :: proc(ctx: ^Context) -> Context_Error {
	assert(ctx != nil, "context_error: nil context")
	return ctx.last_error
}

// context_close retires every backend callback registration before releasing
// anything they publish into. A false return is a refusal: the context stays
// in .Closing with all storage and GPU objects intact, and the caller must
// not free the Context or unload code until a retry returns true.
context_close :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "context_close: nil context")
	closed := _close_window_context(ctx)
	if !closed {
		ctx.last_error = .Close_Refused
		fmt.eprintln("gfx: context_close refused; backend callbacks outstanding, storage retained")
	} else {
		ctx.last_error = .None
	}
	return closed
}

// context_quiesce_gpu drives every outstanding backend callback registration
// (submissions, timing maps, the screenshot map) to its terminal callback
// without closing the context. Hosts call it before unloading code that may
// have registered callbacks, such as a hot-reloaded game library that links
// its own copy of the renderer. False means a registration is still unproved
// after the bounded polls and that code must stay loaded.
context_quiesce_gpu :: proc(ctx: ^Context) -> bool {
	assert(ctx != nil, "context_quiesce_gpu: nil context")
	assert(!ctx.frame.has_frame, "context_quiesce_gpu: frame is still recording")
	if !ctx.initialized do return true
	if !_submission_quiesce(&ctx.submissions) do return false
	if !_screenshot_retire(ctx, true) do return false
	return _gpu_timing_quiesce(ctx)
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
	_gpu_compute_resources_destroy(&resources.compute)
	_gpu_3d_resources_destroy(ctx, &resources.gpu_3d)
	_rlgl_resources_destroy(&resources.rlgl)
	_shader_resources_destroy(&resources.shaders)
	_atlas_resources_destroy(ctx, &resources.atlases)
	_texture_resources_destroy(ctx, &resources.textures)
	_flush_retired(ctx)
	delete(resources.retire)
	resources^ = {}
}
