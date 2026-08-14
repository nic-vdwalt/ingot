// ingot:gfx - real offscreen render targets (raylib RenderTexture parity) over
// WebGPU. A render target is a sampleable colour texture (optionally with a
// depth attachment); BeginTextureMode..EndTextureMode redirect the batch
// renderer into a dedicated render pass on its own command encoder, submitted
// immediately at EndTextureMode so the resulting texture is ready to sample in
// the main frame pass (DrawTexturePro blit).
//
// Coordinate convention: the RT projection flips y (p.z = -1) so the stored
// texture matches raylib's bottom-left-origin RenderTexture - callers keep
// blitting with a negative source height to display it upright, unchanged.
package gfx

import wg "vendor:wgpu"

RT_PROJECTION_Y_FLIP :: f32(-1.0)

// _rt_projection_vec builds the group(0) projection vector for a render
// target: reciprocal pixel scale in x/y, the named y-flip in z, 0 in w.
// Pure - split out of BeginTextureMode so the orientation contract
// (docs/rendering.md "Render-target orientation") is locked by a unit test.
@(private)
_rt_projection_vec :: proc "contextless" (width, height: i32) -> [4]f32 {
	return [4]f32{1.0 / f32(max(width, 1)), 1.0 / f32(max(height, 1)), RT_PROJECTION_Y_FLIP, 0.0}
}

// LoadRenderTexture creates a colour render target in the swapchain format
// (so the existing batch pipelines, built against g.format, can render into it).
context_load_render_texture :: proc(ctx: ^Context, width, height: i32) -> RenderTexture2D {
	assert(ctx != nil, "context_load_render_texture: nil context")
	if !ctx.initialized do return RenderTexture2D{}
	tex := _new_rt_color(ctx, width, height, ctx.format)
	return RenderTexture2D{id = tex.id, texture = tex}
}

LoadRenderTexture :: proc(width, height: i32) -> RenderTexture2D {
	return context_load_render_texture(default_context(), width, height)
}

// LoadRenderTextureEx creates a render target with an explicit colour format
// (e.g. RGBA16Float HDR) and an optional depth attachment. Used by the rlgl
// framebuffer path for the galaxy HDR/scene targets.
context_load_render_texture_ex :: proc(
	ctx: ^Context,
	width, height: i32,
	format: wg.TextureFormat,
	with_depth: bool,
) -> RenderTexture2D {
	assert(ctx != nil, "context_load_render_texture_ex: nil context")
	if !ctx.initialized do return RenderTexture2D{}
	tex := _new_rt_color(ctx, width, height, format)
	rt := RenderTexture2D {
		id      = tex.id,
		texture = tex,
	}
	if with_depth {
		rt.depth = _new_rt_depth(ctx, width, height)
	}
	return rt
}

LoadRenderTextureEx :: proc(
	width, height: i32,
	format: wg.TextureFormat,
	with_depth: bool,
) -> RenderTexture2D {
	return context_load_render_texture_ex(default_context(), width, height, format, with_depth)
}

// UnloadRenderTexture releases the color (and optional depth) textures.
// Both route through the retire queue (context.odin), so unloading is safe
// at any point in a frame - destruction defers past this frame's submit.
context_unload_render_texture :: proc(ctx: ^Context, target: RenderTexture2D) {
	assert(ctx != nil, "context_unload_render_texture: nil context")
	if target.texture.id != 0 do context_unload_texture(ctx, target.texture)
	if target.depth.id != 0 do _unload_depth(ctx, target.depth)
}

UnloadRenderTexture :: proc(target: RenderTexture2D) {
	context_unload_render_texture(default_context(), target)
}

// BeginTextureMode redirects subsequent draws into `target`. It flushes any
// pending main-pass geometry (keeping the main pass open), switches the batch
// group(0) uniform to the target's y-flipped projection, and defers beginning
// the RT pass until the first draw/clear so ClearBackground can set the clear.
context_begin_texture_mode :: proc(ctx: ^Context, target: RenderTexture2D) {
	assert(ctx != nil, "context_begin_texture_mode: nil context")
	if !ctx.frame.has_frame do return
	e := context_get_texture(ctx, target.texture.id)
	if e == nil do return
	depth_view: wg.TextureView
	if target.depth.id != 0 {
		depth_view = context_texture_view(ctx, target.depth.id)
		if depth_view == nil do return
	}

	if ctx.frame.pass_begun {
		renderer_flush(ctx, &ctx.rend, ctx.frame.pass, .Target)
	}

	ctx.frame.rt = target.texture.id
	ctx.frame.rt_w = e.width
	ctx.frame.rt_h = e.height
	ctx.frame.rt_clear = Color{0, 0, 0, 0}
	ctx.frame.rt_should_clear = false
	ctx.frame.rt_pass_begun = false
	ctx.frame.rt_depth = target.depth.id != 0
	ctx.frame.depth_view = depth_view

	p := _rt_projection_vec(e.width, e.height)
	wg.QueueWriteBuffer(ctx.queue, ctx.rend.rt_ubuf, 0, &p, size_of(p))
	ctx.rend.cur_u = ctx.rend.rt_ubind
	renderer_state_reset(&ctx.rend)
}

BeginTextureMode :: proc(target: RenderTexture2D) {
	context_begin_texture_mode(default_context(), target)
}

// _ensure_rt_pass lazily begins the render-target pass on its own encoder.
@(private)
context_ensure_rt_pass :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_ensure_rt_pass: nil context")
	if ctx.frame.rt == 0 || ctx.frame.rt_pass_begun do return
	view := context_texture_view(ctx, ctx.frame.rt)
	if view == nil do return
	ctx.frame.rt_encoder = wg.DeviceCreateCommandEncoder(ctx.device, nil)
	cc := ctx.frame.rt_clear
	// Preserve the target's contents by default (raylib: BeginTextureMode does
	// not clear). Only clear when ClearBackground was called after
	// BeginTextureMode this frame.
	load_op := wg.LoadOp.Load if !ctx.frame.rt_should_clear else wg.LoadOp.Clear
	color := wg.RenderPassColorAttachment {
		view       = view,
		depthSlice = wg.DEPTH_SLICE_UNDEFINED,
		loadOp     = load_op,
		storeOp    = .Store,
		clearValue = {f64(cc.r) / 255.0, f64(cc.g) / 255.0, f64(cc.b) / 255.0, f64(cc.a) / 255.0},
	}
	desc := wg.RenderPassDescriptor {
		colorAttachmentCount = 1,
		colorAttachments     = &color,
	}
	// NOTE: the CPU-projected 3D approximation does not depth-test, and the 2D
	// batch pipelines carry no depth-stencil state, so we intentionally do not
	// attach a depth buffer here (attaching one would mismatch those pipelines).
	// depth textures created via rlgl.LoadTextureDepth are simply unused.
	ctx.frame.rt_pass = wg.CommandEncoderBeginRenderPass(ctx.frame.rt_encoder, &desc)
	_stats_render_pass(ctx)
	ctx.frame.rt_pass_begun = true
}

@(private)
_ensure_rt_pass :: proc() {
	context_ensure_rt_pass(default_context())
}

// EndTextureMode flushes and submits the render-target pass, then restores the
// batch to the window projection so the main pass continues correctly.
context_end_texture_mode :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_end_texture_mode: nil context")
	if ctx.frame.rt == 0 {
		ctx.rend.cur_u = ctx.rend.ubind
		return
	}
	context_ensure_rt_pass(ctx)
	if ctx.frame.rt_pass_begun {
		renderer_flush(ctx, &ctx.rend, ctx.frame.rt_pass, .Target)
		wg.RenderPassEncoderEnd(ctx.frame.rt_pass)
		wg.RenderPassEncoderRelease(ctx.frame.rt_pass)
		assert(_stream_slot_upload(ctx, &ctx.rend))
		cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(ctx, ctx.frame.rt_encoder, true)
		_stats_context_cpu_times(ctx, 0, encode_elapsed, submit_elapsed, 0)
		_stats_queue_submission(ctx)
		wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(ctx.frame.rt_encoder)
	}
	ctx.frame.rt = 0
	ctx.frame.rt_encoder = nil
	ctx.frame.rt_pass = nil
	ctx.frame.rt_pass_begun = false
	ctx.frame.rt_depth = false
	ctx.frame.depth_view = nil
	ctx.rend.cur_u = ctx.rend.ubind
	renderer_state_reset(&ctx.rend)
}

EndTextureMode :: proc() {
	context_end_texture_mode(default_context())
}

// --- rlgl framebuffer backing ----------------------------------------------
// The galaxy assembles its HDR targets from raw rlgl calls (LoadFramebuffer +
// LoadTexture/LoadTextureDepth + FramebufferAttach). These helpers create the
// real backing gfx textures so the resulting RenderTexture2D works with
// BeginTextureMode. FramebufferAttach/Complete are bookkeeping no-ops since the
// RenderTexture2D already carries the colour + depth texture ids.

@(private)
_pf_to_wg :: proc(ctx: ^Context, pf: PixelFormat) -> wg.TextureFormat {
	assert(ctx != nil, "_pf_to_wg: nil context")
	#partial switch pf {
	case .UNCOMPRESSED_R16G16B16A16:
		return .RGBA16Float
	case .UNCOMPRESSED_R32:
		return .R32Float
	case .UNCOMPRESSED_R32G32B32A32:
		return .RGBA32Float
	case .UNCOMPRESSED_R8G8B8A8:
		return .RGBA8Unorm
	}
	return ctx.format
}

// RlLoadColorTexture creates a render-target colour texture of `pf` and returns
// its registry id (rlgl.LoadTexture parity for framebuffer colour attachments).
context_rl_load_color_texture :: proc(ctx: ^Context, w, h: i32, pf: PixelFormat) -> u32 {
	assert(ctx != nil, "context_rl_load_color_texture: nil context")
	if !ctx.initialized do return 0
	t := _new_rt_color(ctx, w, h, _pf_to_wg(ctx, pf))
	return t.id
}

RlLoadColorTexture :: proc(w, h: i32, pf: PixelFormat) -> u32 {
	return context_rl_load_color_texture(default_context(), w, h, pf)
}

// RlLoadDepthTexture creates a depth attachment (rlgl.LoadTextureDepth parity).
context_rl_load_depth_texture :: proc(ctx: ^Context, w, h: i32) -> u32 {
	assert(ctx != nil, "context_rl_load_depth_texture: nil context")
	if !ctx.initialized do return 0
	t := _new_rt_depth(ctx, w, h)
	return t.id
}

RlLoadDepthTexture :: proc(w, h: i32) -> u32 {
	return context_rl_load_depth_texture(default_context(), w, h)
}

// RlUnloadTextureId releases a texture by raw id (rlgl.UnloadTexture parity).
context_rl_unload_texture_id :: proc(ctx: ^Context, id: u32) {
	assert(ctx != nil, "context_rl_unload_texture_id: nil context")
	if id == 0 do return
	context_unload_texture(ctx, Texture2D{id = id})
}

RlUnloadTextureId :: proc(id: u32) {
	context_rl_unload_texture_id(default_context(), id)
}
