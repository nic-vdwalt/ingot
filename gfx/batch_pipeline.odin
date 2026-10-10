// ingot:gfx - render pipeline construction for the 2D batcher: blend states
// per slot, pipeline creation per (kind, blend, target format), and the rlgl
// custom blend factor mapping that rebuilds the Custom-slot pipelines.
package gfx

import wg "vendor:wgpu"

// _blend_for returns the wgpu blend state for a slot. Colour and alpha share
// the same factors (the batch outputs premultiplied rgb).
@(private)
_blend_for :: proc(r: ^Renderer, slot: Blend_Slot) -> wg.BlendState {
	assert(r != nil, "_blend_for: nil r")
	c: wg.BlendComponent
	switch slot {
	case .Alpha:
		c = {
			srcFactor = .One,
			dstFactor = .OneMinusSrcAlpha,
			operation = .Add,
		}
	case .Additive:
		c = {
			srcFactor = .One,
			dstFactor = .One,
			operation = .Add,
		}
	case .Multiplied:
		c = {
			srcFactor = .Dst,
			dstFactor = .OneMinusSrcAlpha,
			operation = .Add,
		}
	case .Custom:
		c = {
			srcFactor = r.cust_src,
			dstFactor = r.cust_dst,
			operation = r.cust_op,
		}
	}
	return {color = c, alpha = c}
}

// _format_blendable reports whether a colour target format supports blending.
// 32-bit float formats are not blendable under WebGPU without the optional
// float32-blendable feature, so a pipeline that attaches a blend state to such
// a target is invalid and aborts the process on submit. Callers drop the blend
// state (plain overwrite) for these formats instead of building a doomed pipe.
@(private)
_format_blendable :: proc(format: wg.TextureFormat) -> bool {
	#partial switch format {
	case .R32Float, .RG32Float, .RGBA32Float:
		return false
	}
	return true
}

// _make_pipe builds one (kind × blend) render pipeline over the shared batch
// vertex layout. File-scope so both renderer_init and _rebuild_custom_pipes
// can call it.
@(private)
_make_pipe :: proc(
	device: wg.Device,
	r: ^Renderer,
	slot: Blend_Slot,
	fs: string,
	textured: bool,
	format: wg.TextureFormat,
) -> wg.RenderPipeline {
	assert(device != nil, "_make_pipe: nil device")
	assert(r != nil, "_make_pipe: nil renderer")
	assert(r.shader != nil, "_make_pipe: nil shader")
	assert(r.ubind_layout != nil, "_make_pipe: nil uniform layout")
	if textured do assert(r.tex_layout != nil, "_make_pipe: nil texture layout")
	attrs := _gpu_vertex_attributes()
	vbl := wg.VertexBufferLayout {
		arrayStride    = size_of(Gpu_Vertex),
		stepMode       = .Vertex,
		attributeCount = 4,
		attributes     = raw_data(attrs[:]),
	}
	blend := _blend_for(r, slot)
	target := wg.ColorTargetState {
		format    = format,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	if _format_blendable(format) do target.blend = &blend
	primitive := wg.PrimitiveState {
		topology  = .TriangleList,
		frontFace = .CCW,
		cullMode  = .None,
	}
	multisample := wg.MultisampleState {
		count = 1,
		mask  = ~u32(0),
	}
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_batch_pipeline(r, slot, fs, format, vbl, primitive, multisample, blend, target)
	}
	layouts := [2]wg.BindGroupLayout{r.ubind_layout, r.tex_layout}
	pl := wg.DeviceCreatePipelineLayout(
		device,
		&{bindGroupLayoutCount = textured ? 2 : 1, bindGroupLayouts = raw_data(layouts[:])},
	)
	if pl == nil do return nil
	pipe := wg.DeviceCreateRenderPipeline(
		device,
		&{
			layout = pl,
			vertex = {module = r.shader, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
			primitive = primitive,
			multisample = multisample,
			fragment = &wg.FragmentState {
				module = r.shader,
				entryPoint = fs,
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(pl)
	return pipe
}

// _fs_for maps a pipeline kind to its fragment entry point + whether it samples
// a texture (needs group(1)).
@(private)
_fs_for :: proc(kind: Pipe_Kind) -> (string, bool) {
	switch kind {
	case .Solid:
		return "fs_ui", true
	case .Image:
		return "fs_image", true
	}
	return "fs_ui", true
}

// _rebuild_custom_pipes recreates the Custom-slot pipelines after the custom
// blend factors change (swapchain-format set only).
@(private)
_rebuild_custom_pipes :: proc(ctx: ^Context, r: ^Renderer) {
	assert(ctx != nil, "_rebuild_custom_pipes: nil context")
	assert(r == &ctx.rend, "_rebuild_custom_pipes: foreign renderer")
	for kind in Pipe_Kind {
		if r.pipes[kind][.Custom] != nil {
			wg.RenderPipelineRelease(r.pipes[kind][.Custom])
		}
		fs, textured := _fs_for(kind)
		r.pipes[kind][.Custom] = _make_pipe(ctx.device, r, .Custom, fs, textured, ctx.format)
	}
	// invalidate alt-format Custom variants so they rebuild on next use
	for i in 0 ..< r.alt_n {
		if r.alt_pipes[i][.Solid][.Custom] != nil {
			wg.RenderPipelineRelease(r.alt_pipes[i][.Solid][.Custom])
		}
		if r.alt_pipes[i][.Image][.Custom] != nil {
			wg.RenderPipelineRelease(r.alt_pipes[i][.Image][.Custom])
		}
		fs_s, ts := _fs_for(.Solid)
		fs_i, ti := _fs_for(.Image)
		r.alt_pipes[i][.Solid][.Custom] = _make_pipe(
			ctx.device,
			r,
			.Custom,
			fs_s,
			ts,
			r.alt_fmt[i],
		)
		r.alt_pipes[i][.Image][.Custom] = _make_pipe(
			ctx.device,
			r,
			.Custom,
			fs_i,
			ti,
			r.alt_fmt[i],
		)
	}
}

// _pipe_for returns the batch pipeline for (kind, blend) at the current target
// colour format. Swapchain-format pipelines are prebuilt; other formats (e.g.
// the galaxy HDR RGBA16Float targets) are built lazily and cached.
@(private)
_pipe_for :: proc(
	ctx: ^Context,
	r: ^Renderer,
	kind: Pipe_Kind,
	slot: Blend_Slot,
) -> wg.RenderPipeline {
	assert(ctx != nil, "_pipe_for: nil context")
	assert(r == &ctx.rend, "_pipe_for: foreign renderer")
	fmt := _cur_target_format(ctx)
	if fmt == ctx.format do return r.pipes[kind][slot]
	// find or create the alt-format set
	idx := -1
	for i in 0 ..< r.alt_n {
		if r.alt_fmt[i] == fmt {idx = i; break}
	}
	if idx < 0 {
		if r.alt_n >= len(r.alt_fmt) do return nil
		idx = r.alt_n
		r.alt_n += 1
		r.alt_fmt[idx] = fmt
		for k in Pipe_Kind {
			fs, textured := _fs_for(k)
			for s in Blend_Slot {
				r.alt_pipes[idx][k][s] = _make_pipe(ctx.device, r, s, fs, textured, fmt)
			}
		}
	}
	return r.alt_pipes[idx][kind][slot]
}

// set_custom_blend records custom blend factors and rebuilds the Custom-slot
// pipelines. Called by rlgl.SetBlendFactors (GL enums already mapped to wgpu).
context_set_custom_blend :: proc(ctx: ^Context, src, dst: BlendFactorRL, op: BlendOpRL) {
	assert(ctx != nil, "context_set_custom_blend: nil context")
	r := &ctx.rend
	ns := _rl_factor(src)
	nd := _rl_factor(dst)
	no := _rl_op(op)
	if ns == r.cust_src && nd == r.cust_dst && no == r.cust_op do return
	r.cust_src = ns
	r.cust_dst = nd
	r.cust_op = no
	_rebuild_custom_pipes(ctx, r)
}

set_custom_blend :: proc(src, dst: BlendFactorRL, op: BlendOpRL) {
	context_set_custom_blend(default_context(), src, dst, op)
}

// GL blend enum aliases (values match rlgl / OpenGL) so rlgl can forward raw
// ints without importing wgpu.
BlendFactorRL :: distinct i32
BlendOpRL :: distinct i32

@(private)
_rl_factor :: proc(v: BlendFactorRL) -> wg.BlendFactor {
	switch i32(v) {
	case 0:
		return .Zero // GL_ZERO
	case 1:
		return .One // GL_ONE
	case 0x0300:
		return .Src // GL_SRC_COLOR
	case 0x0301:
		return .OneMinusSrc // GL_ONE_MINUS_SRC_COLOR
	case 0x0302:
		return .SrcAlpha // GL_SRC_ALPHA
	case 0x0303:
		return .OneMinusSrcAlpha // GL_ONE_MINUS_SRC_ALPHA
	case 0x0304:
		return .DstAlpha // GL_DST_ALPHA
	case 0x0305:
		return .OneMinusDstAlpha // GL_ONE_MINUS_DST_ALPHA
	case 0x0306:
		return .Dst // GL_DST_COLOR
	case 0x0307:
		return .OneMinusDst // GL_ONE_MINUS_DST_COLOR
	}
	return .One
}

@(private)
_rl_op :: proc(v: BlendOpRL) -> wg.BlendOperation {
	switch i32(v) {
	case 0x8006:
		return .Add // GL_FUNC_ADD
	case 0x800A:
		return .Subtract // GL_FUNC_SUBTRACT
	case 0x800B:
		return .ReverseSubtract // GL_FUNC_REVERSE_SUBTRACT
	case 0x8007:
		return .Min // GL_MIN
	case 0x8008:
		return .Max // GL_MAX
	}
	return .Add
}
