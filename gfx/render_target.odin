// ingot:gfx — real offscreen render targets (raylib RenderTexture parity) over
// WebGPU. A render target is a sampleable colour texture (optionally with a
// depth attachment); BeginTextureMode..EndTextureMode redirect the batch
// renderer into a dedicated render pass on its own command encoder, submitted
// immediately at EndTextureMode so the resulting texture is ready to sample in
// the main frame pass (DrawTexturePro blit).
//
// Coordinate convention: the RT projection flips y (p.z = -1) so the stored
// texture matches raylib's bottom-left-origin RenderTexture — callers keep
// blitting with a negative source height to display it upright, unchanged.
package gfx

import wg "vendor:wgpu"

RT_PROJECTION_Y_FLIP :: f32(-1.0)

// _rt_projection_vec builds the group(0) projection vector for a render
// target: reciprocal pixel scale in x/y, the named y-flip in z, 0 in w.
// Pure — split out of BeginTextureMode so the orientation contract
// (docs/rendering.md "Render-target orientation") is locked by a unit test.
@(private)
_rt_projection_vec :: proc "contextless" (width, height: i32) -> [4]f32 {
	return [4]f32{1.0 / f32(max(width, 1)), 1.0 / f32(max(height, 1)), RT_PROJECTION_Y_FLIP, 0.0}
}

// LoadRenderTexture creates a colour render target in the swapchain format
// (so the existing batch pipelines, built against g.format, can render into it).
LoadRenderTexture :: proc(width, height: i32) -> RenderTexture2D {
	if !g.initialized do return RenderTexture2D{}
	tex := _new_rt_color(width, height, g.format)
	return RenderTexture2D{id = tex.id, texture = tex}
}

// LoadRenderTextureEx creates a render target with an explicit colour format
// (e.g. RGBA16Float HDR) and an optional depth attachment. Used by the rlgl
// framebuffer path for the galaxy HDR/scene targets.
LoadRenderTextureEx :: proc(
	width, height: i32,
	format: wg.TextureFormat,
	with_depth: bool,
) -> RenderTexture2D {
	if !g.initialized do return RenderTexture2D{}
	tex := _new_rt_color(width, height, format)
	rt := RenderTexture2D {
		id      = tex.id,
		texture = tex,
	}
	if with_depth {
		rt.depth = _new_rt_depth(width, height)
	}
	return rt
}

// UnloadRenderTexture releases the color (and optional depth) textures.
// Both route through the retire queue (context.odin), so unloading is safe
// at any point in a frame — destruction defers past this frame's submit.
UnloadRenderTexture :: proc(target: RenderTexture2D) {
	if target.texture.id != 0 do UnloadTexture(target.texture)
	if target.depth.id != 0 do _unload_depth(target.depth)
}

// BeginTextureMode redirects subsequent draws into `target`. It flushes any
// pending main-pass geometry (keeping the main pass open), switches the batch
// group(0) uniform to the target's y-flipped projection, and defers beginning
// the RT pass until the first draw/clear so ClearBackground can set the clear.
BeginTextureMode :: proc(target: RenderTexture2D) {
	if !g.frame.has_frame do return
	e := get_texture(target.texture.id)
	if e == nil do return

	// finish pending window geometry into the main pass (still open)
	if g.frame.pass_begun {
		renderer_flush(&g.rend, g.frame.pass, .Target)
	}

	g.frame.rt = target.texture.id
	g.frame.rt_w = e.width
	g.frame.rt_h = e.height
	g.frame.rt_clear = Color{0, 0, 0, 0}
	g.frame.rt_should_clear = false
	g.frame.rt_pass_begun = false
	g.frame.rt_depth = target.depth.id != 0
	g.frame.depth_view = g.frame.rt_depth ? _texture_view(target.depth.id) : nil

	// RT projection: y-flipped (p.z = -1) so the texture matches raylib.
	p := _rt_projection_vec(e.width, e.height)
	wg.QueueWriteBuffer(g.queue, g.rend.rt_ubuf, 0, &p, size_of(p))
	g.rend.cur_u = g.rend.rt_ubind

	// reset the batch run for the target
	renderer_state_reset(&g.rend)
}

// _ensure_rt_pass lazily begins the render-target pass on its own encoder.
@(private)
_ensure_rt_pass :: proc() {
	if g.frame.rt == 0 || g.frame.rt_pass_begun do return
	view := _texture_view(g.frame.rt)
	if view == nil do return
	g.frame.rt_encoder = wg.DeviceCreateCommandEncoder(g.device, nil)
	cc := g.frame.rt_clear
	// Preserve the target's contents by default (raylib: BeginTextureMode does
	// not clear). Only clear when ClearBackground was called after
	// BeginTextureMode this frame.
	load_op := wg.LoadOp.Load if !g.frame.rt_should_clear else wg.LoadOp.Clear
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
	g.frame.rt_pass = wg.CommandEncoderBeginRenderPass(g.frame.rt_encoder, &desc)
	_stats_render_pass()
	g.frame.rt_pass_begun = true
}

// EndTextureMode flushes and submits the render-target pass, then restores the
// batch to the window projection so the main pass continues correctly.
EndTextureMode :: proc() {
	if g.frame.rt == 0 {
		g.rend.cur_u = g.rend.ubind
		return
	}
	_ensure_rt_pass()
	if g.frame.rt_pass_begun {
		renderer_flush(&g.rend, g.frame.rt_pass, .Target)
		wg.RenderPassEncoderEnd(g.frame.rt_pass)
		wg.RenderPassEncoderRelease(g.frame.rt_pass)
		cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(g, g.frame.rt_encoder, true)
		_stats_cpu_times(0, encode_elapsed, submit_elapsed, 0)
		_stats_queue_submission()
		wg.CommandBufferRelease(cmd)
		wg.CommandEncoderRelease(g.frame.rt_encoder)
	}
	g.frame.rt = 0
	g.frame.rt_pass = nil
	g.frame.rt_pass_begun = false
	g.frame.rt_depth = false
	g.frame.depth_view = nil

	// back to the window projection for the (still-open) main pass
	g.rend.cur_u = g.rend.ubind
	renderer_state_reset(&g.rend)
}

// --- rlgl framebuffer backing ----------------------------------------------
// The galaxy assembles its HDR targets from raw rlgl calls (LoadFramebuffer +
// LoadTexture/LoadTextureDepth + FramebufferAttach). These helpers create the
// real backing gfx textures so the resulting RenderTexture2D works with
// BeginTextureMode. FramebufferAttach/Complete are bookkeeping no-ops since the
// RenderTexture2D already carries the colour + depth texture ids.

@(private)
_pf_to_wg :: proc(pf: PixelFormat) -> wg.TextureFormat {
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
	return g.format
}

// RlLoadColorTexture creates a render-target colour texture of `pf` and returns
// its registry id (rlgl.LoadTexture parity for framebuffer colour attachments).
RlLoadColorTexture :: proc(w, h: i32, pf: PixelFormat) -> u32 {
	if !g.initialized do return 0
	t := _new_rt_color(w, h, _pf_to_wg(pf))
	return t.id
}

// RlLoadDepthTexture creates a depth attachment (rlgl.LoadTextureDepth parity).
RlLoadDepthTexture :: proc(w, h: i32) -> u32 {
	if !g.initialized do return 0
	t := _new_rt_depth(w, h)
	return t.id
}

// RlUnloadTextureId releases a texture by raw id (rlgl.UnloadTexture parity).
RlUnloadTextureId :: proc(id: u32) {
	if id == 0 do return
	UnloadTexture(Texture2D{id = id})
}
