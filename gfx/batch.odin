// ingot:gfx — CPU 2D vertex batcher over WebGPU. Three pipelines share one
// vertex layout (pos in logical pixels, rgba, uv) and one ortho projection
// uniform: `solid` (flat color), `text` (R8 atlas sampled as coverage), and
// `image` (RGBA texture). Draws accumulate into a CPU run and flush into the
// frame's render pass whenever the pipeline/texture/scissor changes or at
// EndDrawing. Scissor is render-pass state, set directly on the pass between
// flushes.
package gfx

import wg "vendor:wgpu"

Vertex :: struct {
	pos: [2]f32,
	col: [4]f32,
	uv:  [2]f32,
}

Pipe_Kind :: enum {
	Solid,
	Text,
	Image,
}

// Blend_Slot enumerates the precompiled blend states each pipeline kind is
// built against. Alpha is the default premultiplied over-blend; Additive is
// One/One (inputs are premultiplied so this is true additive); Multiplied is
// raylib's DST_COLOR × ONE_MINUS_SRC_ALPHA; Custom is rebuilt on demand from
// rlgl.SetBlendFactors.
Blend_Slot :: enum {
	Alpha,
	Additive,
	Multiplied,
	Custom,
}

GEOMETRY_STREAM_BYTES :: u64(16 * 1024 * 1024)
GEOMETRY_STREAM_ALIGN :: u64(4)
UNIFORM_STREAM_BYTES :: u64(16 * 1024 * 1024)
BATCH_MAX_VERTICES :: 262_144
BATCH_MAX_INDICES :: 393_216
MODEL_STACK_MAX :: 64

Geometry_Stream :: struct {
	buffer:              wg.Buffer,
	capacity:            u64,
	cursor:              u64,
	used:                u64,
	retirement:          u64,
	pending:             bool,
	in_flight: bool,
}

Uniform_Stream :: struct {
	buffer:     wg.Buffer,
	capacity:   u64,
	cursor:     u64,
	alignment:  u64,
	retirement: u64,
	pending:    bool,
	in_flight:  bool,
}

Renderer :: struct {
	shader: wg.ShaderModule, // kept alive so Custom pipelines can be rebuilt
	pipes:  [Pipe_Kind][Blend_Slot]wg.RenderPipeline,

	// Lazy batch pipelines for non-swapchain target formats (e.g. the galaxy
	// HDR RGBA16Float render targets). Keyed by colour format.
	alt_fmt:   [4]wg.TextureFormat,
	alt_pipes: [4][Pipe_Kind][Blend_Slot]wg.RenderPipeline,
	alt_n:     int,

	ubuf:         wg.Buffer,
	ubind:        wg.BindGroup,
	ubind_layout: wg.BindGroupLayout,
	tex_layout:   wg.BindGroupLayout, // group(1): texture + sampler

	// Alternate group(0) uniform for render-target passes: an RT renders in its
	// own pixel space, so it needs its own ortho projection that must NOT clobber
	// the window projection used by the main pass in the same frame. cur_u is the
	// group(0) bind the next flush uses (r.ubind for the window, r.rt_ubind for
	// the active render target).
	rt_ubuf:  wg.Buffer,
	rt_ubind: wg.BindGroup,
	cur_u:    wg.BindGroup,

	// current run
	verts:     [dynamic; BATCH_MAX_VERTICES]Vertex,
	indices:   [dynamic; BATCH_MAX_INDICES]u32,
	cur_kind:  Pipe_Kind,
	cur_bind:  wg.BindGroup,
	cur_blend: Blend_Slot,

	// Active custom shader (BeginShaderMode); 0 = none. When set, Image-kind
	// flushes use the shader's pipeline + uniform/extra-texture bind groups.
	active_shader: u32,

	// 2D model translation (rlgl matrix stack): applied to every emitted vertex
	// so rlgl.PushMatrix/Translatef/PopMatrix shift subsequent draws (the galaxy
	// pane origin transform).
	model_off:   [2]f32,
	model_stack: [dynamic; MODEL_STACK_MAX][2]f32,

	// Custom blend factors (set by rlgl.SetBlendFactors; default = Alpha).
	cust_src: wg.BlendFactor,
	cust_dst: wg.BlendFactor,
	cust_op:  wg.BlendOperation,

	geometry: Geometry_Stream,
	uniforms: Uniform_Stream,

	proj_w, proj_h: i32,
}

// _blend_for returns the wgpu blend state for a slot. Colour and alpha share
// the same factors (the batch outputs premultiplied rgb).
@(private)
_blend_for :: proc(r: ^Renderer, slot: Blend_Slot) -> wg.BlendState {
	c: wg.BlendComponent
	switch slot {
	case .Alpha:
		c = {srcFactor = .One, dstFactor = .OneMinusSrcAlpha, operation = .Add}
	case .Additive:
		c = {srcFactor = .One, dstFactor = .One, operation = .Add}
	case .Multiplied:
		c = {srcFactor = .Dst, dstFactor = .OneMinusSrcAlpha, operation = .Add}
	case .Custom:
		c = {srcFactor = r.cust_src, dstFactor = r.cust_dst, operation = r.cust_op}
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
_make_pipe :: proc(r: ^Renderer, slot: Blend_Slot, fs: string, textured: bool, format: wg.TextureFormat) -> wg.RenderPipeline {
	attrs := [3]wg.VertexAttribute{
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
	}
	vbl := wg.VertexBufferLayout{
		arrayStride = size_of(Vertex), stepMode = .Vertex,
		attributeCount = 3, attributes = raw_data(attrs[:]),
	}
	blend := _blend_for(r, slot)
	target := wg.ColorTargetState{format = format, writeMask = wg.ColorWriteMaskFlags_All}
	if _format_blendable(format) do target.blend = &blend
	layouts := [2]wg.BindGroupLayout{r.ubind_layout, r.tex_layout}
	pl := wg.DeviceCreatePipelineLayout(g.device, &{
		bindGroupLayoutCount = textured ? 2 : 1,
		bindGroupLayouts = raw_data(layouts[:]),
	})
	return wg.DeviceCreateRenderPipeline(g.device, &{
		layout = pl,
		vertex = {module = r.shader, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = ~u32(0)},
		fragment = &wg.FragmentState{module = r.shader, entryPoint = fs, targetCount = 1, targets = &target},
	})
}

// _fs_for maps a pipeline kind to its fragment entry point + whether it samples
// a texture (needs group(1)).
@(private)
_fs_for :: proc(kind: Pipe_Kind) -> (string, bool) {
	switch kind {
	case .Solid: return "fs_solid", false
	case .Text:  return "fs_text", true
	case .Image: return "fs_image", true
	}
	return "fs_solid", false
}

// _rebuild_custom_pipes recreates the Custom-slot pipelines after the custom
// blend factors change (swapchain-format set only).
@(private)
_rebuild_custom_pipes :: proc(r: ^Renderer) {
	for kind in Pipe_Kind {
		if r.pipes[kind][.Custom] != nil {
			wg.RenderPipelineRelease(r.pipes[kind][.Custom])
		}
		fs, textured := _fs_for(kind)
		r.pipes[kind][.Custom] = _make_pipe(r, .Custom, fs, textured, g.format)
	}
	// invalidate alt-format Custom variants so they rebuild on next use
	for i in 0 ..< r.alt_n {
		if r.alt_pipes[i][.Solid][.Custom] != nil do wg.RenderPipelineRelease(r.alt_pipes[i][.Solid][.Custom])
		if r.alt_pipes[i][.Text][.Custom] != nil do wg.RenderPipelineRelease(r.alt_pipes[i][.Text][.Custom])
		if r.alt_pipes[i][.Image][.Custom] != nil do wg.RenderPipelineRelease(r.alt_pipes[i][.Image][.Custom])
		fs_s, ts := _fs_for(.Solid)
		fs_t, tt := _fs_for(.Text)
		fs_i, ti := _fs_for(.Image)
		r.alt_pipes[i][.Solid][.Custom] = _make_pipe(r, .Custom, fs_s, ts, r.alt_fmt[i])
		r.alt_pipes[i][.Text][.Custom] = _make_pipe(r, .Custom, fs_t, tt, r.alt_fmt[i])
		r.alt_pipes[i][.Image][.Custom] = _make_pipe(r, .Custom, fs_i, ti, r.alt_fmt[i])
	}
}

// _pipe_for returns the batch pipeline for (kind, blend) at the current target
// colour format. Swapchain-format pipelines are prebuilt; other formats (e.g.
// the galaxy HDR RGBA16Float targets) are built lazily and cached.
@(private)
_pipe_for :: proc(r: ^Renderer, kind: Pipe_Kind, slot: Blend_Slot) -> wg.RenderPipeline {
	fmt := _cur_target_format()
	if fmt == g.format do return r.pipes[kind][slot]
	// find or create the alt-format set
	idx := -1
	for i in 0 ..< r.alt_n {
		if r.alt_fmt[i] == fmt { idx = i; break }
	}
	if idx < 0 {
		if r.alt_n >= len(r.alt_fmt) do return r.pipes[kind][slot] // cache full: fall back
		idx = r.alt_n
		r.alt_n += 1
		r.alt_fmt[idx] = fmt
		for k in Pipe_Kind {
			fs, textured := _fs_for(k)
			for s in Blend_Slot {
				r.alt_pipes[idx][k][s] = _make_pipe(r, s, fs, textured, fmt)
			}
		}
	}
	return r.alt_pipes[idx][kind][slot]
}

BATCH_SHADER := `
struct Uniforms { p: vec4<f32> };  // p.xy = 1/size, p.z = y-flip (+1 screen, -1 RT)
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VSOut {
	@builtin(position) pos: vec4<f32>,
	@location(0) col: vec4<f32>,
	@location(1) uv: vec2<f32>,
};

@vertex
fn vs_main(@location(0) pos: vec2<f32>, @location(1) col: vec4<f32>, @location(2) uv: vec2<f32>) -> VSOut {
	var o: VSOut;
	let sx = pos.x * u.p.x * 2.0 - 1.0;
	let sy = 1.0 - pos.y * u.p.y * 2.0;
	o.pos = vec4<f32>(sx, sy * u.p.z, 0.0, 1.0);
	o.col = col;
	o.uv = uv;
	return o;
}

@fragment
fn fs_solid(in: VSOut) -> @location(0) vec4<f32> {
	return vec4<f32>(in.col.rgb * in.col.a, in.col.a);
}

@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

@fragment
fn fs_text(in: VSOut) -> @location(0) vec4<f32> {
	let a = textureSample(atlas, samp, in.uv).r * in.col.a;
	return vec4<f32>(in.col.rgb * a, a);
}

@fragment
fn fs_image(in: VSOut) -> @location(0) vec4<f32> {
	let t = textureSample(atlas, samp, in.uv);
	let a = t.a * in.col.a;
	return vec4<f32>(t.rgb * in.col.rgb * a, a);
}
`

renderer_init :: proc(r: ^Renderer) {
	shader := wg.DeviceCreateShaderModule(g.device, &{
		nextInChain = &wg.ShaderSourceWGSL{
			chain = {sType = .ShaderSourceWGSL},
			code  = BATCH_SHADER,
		},
	})
	r.shader = shader
	_uniform_stream_init(r)

	// group(0): projection uniform
	r.ubind_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 1,
		entries = &wg.BindGroupLayoutEntry{
			binding = 0,
			visibility = {.Vertex},
			buffer = {type = .Uniform, minBindingSize = size_of([4]f32)},
		},
	})
	r.ubuf = wg.DeviceCreateBuffer(g.device, &{usage = {.Uniform, .CopyDst}, size = size_of([4]f32)})
	r.ubind = wg.DeviceCreateBindGroup(g.device, &{
		layout = r.ubind_layout,
		entryCount = 1,
		entries = &wg.BindGroupEntry{binding = 0, buffer = r.ubuf, size = size_of([4]f32)},
	})

	// Separate uniform + bind for render-target passes (see struct comment).
	r.rt_ubuf = wg.DeviceCreateBuffer(g.device, &{usage = {.Uniform, .CopyDst}, size = size_of([4]f32)})
	r.rt_ubind = wg.DeviceCreateBindGroup(g.device, &{
		layout = r.ubind_layout,
		entryCount = 1,
		entries = &wg.BindGroupEntry{binding = 0, buffer = r.rt_ubuf, size = size_of([4]f32)},
	})
	r.cur_u = r.ubind

	// group(1): texture + sampler (used by text + image pipelines)
	tex_entries := [2]wg.BindGroupLayoutEntry{
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	r.tex_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 2, entries = raw_data(tex_entries[:]),
	})

	// Custom blend defaults to premultiplied over-blend until SetBlendFactors.
	r.cust_src = .One
	r.cust_dst = .OneMinusSrcAlpha
	r.cust_op  = .Add

	// build every (kind × blend_slot) pipeline once.
	for kind in Pipe_Kind {
		fs, textured := _fs_for(kind)
		for slot in Blend_Slot {
			r.pipes[kind][slot] = _make_pipe(r, slot, fs, textured, g.format)
		}
	}

	r.cur_kind = .Solid
	r.cur_blend = .Alpha
}

renderer_shutdown :: proc(r: ^Renderer) {
	if r.uniforms.buffer != nil do wg.BufferRelease(r.uniforms.buffer)
	if r.geometry.buffer != nil do wg.BufferRelease(r.geometry.buffer)
	for kind in Pipe_Kind {
		for slot in Blend_Slot {
			if r.pipes[kind][slot] != nil do wg.RenderPipelineRelease(r.pipes[kind][slot])
		}
	}
	for i in 0 ..< r.alt_n {
		for kind in Pipe_Kind {
			for slot in Blend_Slot {
				if r.alt_pipes[i][kind][slot] != nil do wg.RenderPipelineRelease(r.alt_pipes[i][kind][slot])
			}
		}
	}
	if r.shader != nil do wg.ShaderModuleRelease(r.shader)
	if r.ubind != nil do wg.BindGroupRelease(r.ubind)
	if r.ubuf != nil do wg.BufferRelease(r.ubuf)
	if r.rt_ubind != nil do wg.BindGroupRelease(r.rt_ubind)
	if r.rt_ubuf != nil do wg.BufferRelease(r.rt_ubuf)
	if r.ubind_layout != nil do wg.BindGroupLayoutRelease(r.ubind_layout)
	if r.tex_layout != nil do wg.BindGroupLayoutRelease(r.tex_layout)
}

renderer_frame_begin :: proc(r: ^Renderer) {
	_geometry_poll(r)
	_uniform_poll(r)
	clear(&r.verts)
	clear(&r.indices)
	r.cur_kind = .Solid
	r.cur_bind = nil
	r.cur_blend = .Alpha
	r.cur_u = r.ubind
	r.active_shader = 0
	r.model_off = {0, 0}
	clear(&r.model_stack)

	// keep projection in sync with the logical window size (p.z = +1: no flip)
	if r.proj_w != g.width || r.proj_h != g.height {
		p := [4]f32{1.0 / f32(max(g.width, 1)), 1.0 / f32(max(g.height, 1)), 1.0, 0.0}
		wg.QueueWriteBuffer(g.queue, r.ubuf, 0, &p, size_of(p))
		r.proj_w, r.proj_h = g.width, g.height
	}
}

// batch_set switches the active pipeline/texture, flushing the pending run
// first if the state differs. Routes to the render-target pass when one is
// bound (BeginTextureMode).
@(private)
batch_set :: proc(r: ^Renderer, kind: Pipe_Kind, bind: wg.BindGroup) {
	_ensure_active_pass()
	if kind != r.cur_kind || bind != r.cur_bind {
		if _active_pass_begun() do renderer_flush(r, active_pass())
		r.cur_kind = kind
		r.cur_bind = bind
	}
}

// push_quad emits two triangles for rect `d` sampling uv rect `s`.
@(private)
push_quad :: proc(r: ^Renderer, d: Rectangle, s: Rectangle, col: [4]f32) {
	if !g.frame.has_frame do return
	ox, oy := r.model_off.x, r.model_off.y
	x0, y0 := d.x + ox, d.y + oy
	x1, y1 := d.x + d.width + ox, d.y + d.height + oy
	u0, v0 := s.x, s.y
	u1, v1 := s.x + s.width, s.y + s.height
	base := u32(len(r.verts))
	append(&r.verts,
		Vertex{{x0, y0}, col, {u0, v0}},
		Vertex{{x0, y1}, col, {u0, v1}},
		Vertex{{x1, y0}, col, {u1, v0}},
		Vertex{{x1, y1}, col, {u1, v1}},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

@(private)
push_tri :: proc(r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	if !g.frame.has_frame do return
	o := r.model_off
	base := u32(len(r.verts))
	append(&r.verts,
		Vertex{{a.x + o.x, a.y + o.y}, col, {0, 0}},
		Vertex{{b.x + o.x, b.y + o.y}, col, {0, 0}},
		Vertex{{c.x + o.x, c.y + o.y}, col, {0, 0}},
	)
	append(&r.indices, base, base + 1, base + 2)
}

// push_quad4 emits an arbitrary (possibly rotated) quad with per-corner uv.
// Corners must be given in order tl, tr, br, bl.
@(private)
push_quad4 :: proc(r: ^Renderer, tl, tr, br, bl: [2]f32, uv_tl, uv_tr, uv_br, uv_bl: [2]f32, col: [4]f32) {
	if !g.frame.has_frame do return
	o := r.model_off
	tlo := [2]f32{tl.x + o.x, tl.y + o.y}
	tro := [2]f32{tr.x + o.x, tr.y + o.y}
	bro := [2]f32{br.x + o.x, br.y + o.y}
	blo := [2]f32{bl.x + o.x, bl.y + o.y}
	base := u32(len(r.verts))
	append(&r.verts,
		Vertex{tlo, col, uv_tl},
		Vertex{blo, col, uv_bl},
		Vertex{tro, col, uv_tr},
		Vertex{bro, col, uv_br},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

// --- rlgl matrix-stack backing (2D model translation) ----------------------

MatrixModePush :: proc() {
	append(&g.rend.model_stack, g.rend.model_off)
}
MatrixModePop :: proc() {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass())
	n := len(g.rend.model_stack)
	if n == 0 { g.rend.model_off = {0, 0}; return }
	g.rend.model_off = g.rend.model_stack[n - 1]
	pop(&g.rend.model_stack)
}
MatrixModeTranslate :: proc(x, y: f32) {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass())
	g.rend.model_off.x += x
	g.rend.model_off.y += y
}

renderer_flush :: proc(r: ^Renderer, pass: wg.RenderPassEncoder) {
	n := len(r.verts)
	if n == 0 do return

	index_count := len(r.indices)
	assert(index_count > 0)
	vertex_bytes := u64(n) * size_of(Vertex)
	index_bytes := u64(index_count) * size_of(u32)
	vbuf, vertex_offset, _ := _geometry_upload(r, raw_data(r.verts[:]), vertex_bytes, {.Vertex})
	ibuf, index_offset, _ := _geometry_upload(r, raw_data(r.indices[:]), index_bytes, {.Index})
	if vbuf == nil || ibuf == nil do return
	_stats_flush(u64(n), vertex_bytes + index_bytes)
	when RENDER_STATS_ENABLED {
		renderer_stats_current.indices_uploaded += u64(index_count)
	}

	// Custom-shader path: an active shader overrides the pipeline + bind groups
	// for the current draw (fullscreen post-process / custom 2D passes).
	if r.active_shader != 0 {
		if _shader_flush(r, pass, vbuf, vertex_offset, ibuf, index_offset, u32(index_count)) {
			clear(&r.verts)
			clear(&r.indices)
			return
		}
	}

	wg.RenderPassEncoderSetPipeline(pass, _pipe_for(r, r.cur_kind, r.cur_blend))
	_stats_pipeline_switch()
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(1)
	if r.cur_kind != .Solid && r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, vertex_offset, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(pass, ibuf, .Uint32, index_offset, index_bytes)
	wg.RenderPassEncoderDrawIndexed(pass, u32(index_count), 1, 0, 0, 0)

	clear(&r.verts)
	clear(&r.indices)
}

@(private)
_geometry_upload :: proc(
	r: ^Renderer,
	data: rawptr,
	size: u64,
	usage: wg.BufferUsageFlags,
) -> (wg.Buffer, u64, bool) {
	assert(r != nil)
	assert(data != nil)
	assert(size > 0)
	_geometry_poll(r)
	stream := &r.geometry
	if stream.buffer == nil {
		_geometry_create(stream, usage)
	}
	offset := _align_u64(stream.cursor, GEOMETRY_STREAM_ALIGN)
	if offset + size > stream.capacity do return nil, 0, false
	wg.QueueWriteBuffer(g.queue, stream.buffer, offset, data, uint(size))
	stream.cursor = offset + size
	stream.used = max(stream.used, stream.cursor)
	stream.pending = true
	when RENDER_STATS_ENABLED {
		renderer_stats_current.peak_geometry_arena_bytes = max(
			renderer_stats_current.peak_geometry_arena_bytes,
			stream.used,
		)
	}
	return stream.buffer, offset, true
}

@(private)
_geometry_create :: proc(stream: ^Geometry_Stream, usage: wg.BufferUsageFlags) {
	assert(stream != nil)
	assert(stream.buffer == nil)
	stream^ = {
		buffer = wg.DeviceCreateBuffer(g.device, &{
			usage = {.Vertex, .Index, .CopyDst},
			size = GEOMETRY_STREAM_BYTES,
		}),
		capacity = GEOMETRY_STREAM_BYTES,
	}
	_stats_buffer_created(false)
	assert(stream.buffer != nil)
	assert(stream.capacity == GEOMETRY_STREAM_BYTES)
}

@(private)
_geometry_poll :: proc(r: ^Renderer) {
	assert(r != nil)
	stream := &r.geometry
	completed := _submission_completed(&g.submissions)
	if stream.in_flight && completed >= stream.retirement {
		stream.in_flight = false
		stream.retirement = 0
		stream.cursor = 0
		stream.used = 0
	}
	assert(stream.cursor <= stream.capacity || stream.buffer == nil)
}

@(private)
_geometry_submitted :: proc(r: ^Renderer, retirement: u64) {
	assert(r != nil)
	if !r.geometry.pending do return
	if retirement == 0 do return
	r.geometry.pending = false
	r.geometry.in_flight = true
	r.geometry.retirement = retirement
	assert(r.geometry.retirement > 0)
}

@(private)
_uniform_stream_init :: proc(r: ^Renderer) {
	assert(r != nil)
	limits, status := wg.DeviceGetLimits(g.device)
	alignment := u64(limits.minUniformBufferOffsetAlignment)
	if status != .Success || alignment == 0 do alignment = 256
	r.uniforms = {
		buffer = wg.DeviceCreateBuffer(g.device, &{
			usage = {.Uniform, .CopyDst},
			size = UNIFORM_STREAM_BYTES,
		}),
		capacity = UNIFORM_STREAM_BYTES,
		alignment = alignment,
	}
	_stats_buffer_created(false)
	assert(r.uniforms.buffer != nil)
	assert(r.uniforms.alignment > 0)
}

@(private)
_uniform_upload :: proc(r: ^Renderer, data: rawptr, size: u64) -> (u32, bool) {
	assert(r != nil)
	assert(data != nil)
	assert(size > 0)
	_uniform_poll(r)
	offset := _align_u64(r.uniforms.cursor, r.uniforms.alignment)
	if offset + size > r.uniforms.capacity do return 0, false
	wg.QueueWriteBuffer(g.queue, r.uniforms.buffer, offset, data, uint(size))
	r.uniforms.cursor = offset + size
	r.uniforms.pending = true
	when RENDER_STATS_ENABLED {
		renderer_stats_current.peak_uniform_arena_bytes = max(
			renderer_stats_current.peak_uniform_arena_bytes,
			r.uniforms.cursor,
		)
	}
	assert(offset <= u64(max(u32)))
	return u32(offset), true
}

@(private)
_uniform_poll :: proc(r: ^Renderer) {
	assert(r != nil)
	completed := _submission_completed(&g.submissions)
	if r.uniforms.in_flight && completed >= r.uniforms.retirement {
		r.uniforms.in_flight = false
		r.uniforms.retirement = 0
		r.uniforms.cursor = 0
	}
	assert(r.uniforms.cursor <= r.uniforms.capacity)
}

@(private)
_uniform_submitted :: proc(r: ^Renderer, retirement: u64) {
	assert(r != nil)
	if !r.uniforms.pending || retirement == 0 do return
	r.uniforms.pending = false
	r.uniforms.in_flight = true
	r.uniforms.retirement = retirement
	assert(r.uniforms.retirement > 0)
}

@(private)
_align_u64 :: proc(value, alignment: u64) -> u64 {
	assert(alignment > 0)
	aligned := (value + alignment - 1) / alignment * alignment
	assert(aligned >= value)
	return aligned
}

// col_f converts an 8-bit Color to normalized rgba for the vertex stream.
@(private)
col_f :: proc(c: Color) -> [4]f32 {
	return {f32(c.r) / 255.0, f32(c.g) / 255.0, f32(c.b) / 255.0, f32(c.a) / 255.0}
}

// SetCustomBlend records custom blend factors and rebuilds the Custom-slot
// pipelines. Called by rlgl.SetBlendFactors (GL enums already mapped to wgpu).
SetCustomBlend :: proc(src, dst: BlendFactorRL, op: BlendOpRL) {
	ns := _rl_factor(src)
	nd := _rl_factor(dst)
	no := _rl_op(op)
	if ns == g.rend.cust_src && nd == g.rend.cust_dst && no == g.rend.cust_op do return
	g.rend.cust_src = ns
	g.rend.cust_dst = nd
	g.rend.cust_op = no
	_rebuild_custom_pipes(&g.rend)
}

// GL blend enum aliases (values match rlgl / OpenGL) so rlgl can forward raw
// ints without importing wgpu.
BlendFactorRL :: distinct i32
BlendOpRL :: distinct i32

@(private)
_rl_factor :: proc(v: BlendFactorRL) -> wg.BlendFactor {
	switch i32(v) {
	case 0:      return .Zero               // GL_ZERO
	case 1:      return .One                // GL_ONE
	case 0x0300: return .Src                // GL_SRC_COLOR
	case 0x0301: return .OneMinusSrc        // GL_ONE_MINUS_SRC_COLOR
	case 0x0302: return .SrcAlpha           // GL_SRC_ALPHA
	case 0x0303: return .OneMinusSrcAlpha   // GL_ONE_MINUS_SRC_ALPHA
	case 0x0304: return .DstAlpha           // GL_DST_ALPHA
	case 0x0305: return .OneMinusDstAlpha   // GL_ONE_MINUS_DST_ALPHA
	case 0x0306: return .Dst                // GL_DST_COLOR
	case 0x0307: return .OneMinusDst        // GL_ONE_MINUS_DST_COLOR
	}
	return .One
}

@(private)
_rl_op :: proc(v: BlendOpRL) -> wg.BlendOperation {
	switch i32(v) {
	case 0x8006: return .Add                // GL_FUNC_ADD
	case 0x800A: return .Subtract           // GL_FUNC_SUBTRACT
	case 0x800B: return .ReverseSubtract    // GL_FUNC_REVERSE_SUBTRACT
	case 0x8007: return .Min                // GL_MIN
	case 0x8008: return .Max                // GL_MAX
	}
	return .Add
}
