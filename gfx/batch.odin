// ingot:gfx — CPU 2D vertex batcher over WebGPU. Two pipelines share one
// vertex layout (pos in logical pixels, rgba, uv, mode) and one ortho projection
// uniform: `solid` handles flat color and R8 text coverage, while `image`
// handles RGBA textures. Draws accumulate into a CPU run and flush into the
// frame's render pass whenever the pipeline/texture/scissor changes or at
// EndDrawing. Scissor is render-pass state, set directly on the pass between
// flushes.
package gfx

import "core:mem"
import wg "vendor:wgpu"

Vertex :: struct {
	pos:  [2]f32,
	col:  [4]f32,
	uv:   [2]f32,
	mode: Vertex_Mode,
}

Vertex_Mode :: enum u32 {
	Solid,
	Text,
}

Pipe_Kind :: enum {
	Solid,
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
STREAM_SLOT_COUNT :: 3
BATCH_MAX_VERTICES :: 262_144
BATCH_MAX_INDICES :: 393_216
BATCH_TRANSIENT_BUFFERS_MAX :: 4096
MODEL_STACK_MAX :: 64
STREAMED_RENDERER_ENABLED :: #config(INGOT_STREAMED_RENDERER, true)

Stream_Slot_State :: enum {
	Free,
	Recording,
	Submitted,
}

Stream_Slot :: struct {
	geometry_buffer: wg.Buffer,
	uniform_buffer:  wg.Buffer,
	geometry_shadow: [dynamic]byte,
	uniform_shadow:  [dynamic]byte,
	geometry_write:  u64,
	uniform_write:   u64,
	ticket:          u64,
	state:           Stream_Slot_State,
}

Renderer :: struct {
	shader:             wg.ShaderModule, // kept alive so Custom pipelines can be rebuilt
	pipes:              [Pipe_Kind][Blend_Slot]wg.RenderPipeline,

	// Lazy batch pipelines for non-swapchain target formats (e.g. the galaxy
	// HDR RGBA16Float render targets). Keyed by colour format.
	alt_fmt:            [4]wg.TextureFormat,
	alt_pipes:          [4][Pipe_Kind][Blend_Slot]wg.RenderPipeline,
	alt_n:              int,
	ubuf:               wg.Buffer,
	ubind:              wg.BindGroup,
	ubind_layout:       wg.BindGroupLayout,
	tex_layout:         wg.BindGroupLayout, // group(1): texture + sampler
	neutral_tex:        wg.Texture,
	neutral_view:       wg.TextureView,
	neutral_sampler:    wg.Sampler,
	neutral_bind:       wg.BindGroup,

	// Alternate group(0) uniform for render-target passes: an RT renders in its
	// own pixel space, so it needs its own ortho projection that must NOT clobber
	// the window projection used by the main pass in the same frame. cur_u is the
	// group(0) bind the next flush uses (r.ubind for the window, r.rt_ubind for
	// the active render target).
	rt_ubuf:            wg.Buffer,
	rt_ubind:           wg.BindGroup,
	cur_u:              wg.BindGroup,

	// current run
	verts:              [dynamic; BATCH_MAX_VERTICES]Vertex,
	indices:            [dynamic; BATCH_MAX_INDICES]u32,
	cur_kind:           Pipe_Kind,
	cur_bind:           wg.BindGroup,
	cur_blend:          Blend_Slot,

	// Active custom shader (BeginShaderMode); 0 = none. When set, Image-kind
	// flushes use the shader's pipeline + uniform/extra-texture bind groups.
	active_shader:      u32,

	// 2D model transform (rlgl matrix stack and BeginMode2D): applied to every
	// emitted vertex so rlgl.PushMatrix/Translatef/PopMatrix shift subsequent
	// draws (the galaxy pane origin transform) and a Camera2D pans, zooms, and
	// rotates the world it wraps.
	model_xf:           Affine,
	model_stack:        [dynamic; MODEL_STACK_MAX]Affine,

	// Custom blend factors (set by rlgl.SetBlendFactors; default = Alpha).
	cust_src:           wg.BlendFactor,
	cust_dst:           wg.BlendFactor,
	cust_op:            wg.BlendOperation,
	stream_slots:       [STREAM_SLOT_COUNT]Stream_Slot,
	active_stream_slot: i32,
	uniform_alignment:  u64,
	transient_buffers:  [dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	retired_buffers:    [STREAM_SLOT_COUNT][dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	proj_w, proj_h:     i32,
}

// _blend_for returns the wgpu blend state for a slot. Colour and alpha share
// the same factors (the batch outputs premultiplied rgb).
@(private)
_blend_for :: proc(r: ^Renderer, slot: Blend_Slot) -> wg.BlendState {
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
	r: ^Renderer,
	slot: Blend_Slot,
	fs: string,
	textured: bool,
	format: wg.TextureFormat,
) -> wg.RenderPipeline {
	attrs := [4]wg.VertexAttribute {
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
		{format = .Uint32, offset = u64(offset_of(Vertex, mode)), shaderLocation = 3},
	}
	vbl := wg.VertexBufferLayout {
		arrayStride    = size_of(Vertex),
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
	layouts := [2]wg.BindGroupLayout{r.ubind_layout, r.tex_layout}
	pl := wg.DeviceCreatePipelineLayout(
		g.device,
		&{bindGroupLayoutCount = textured ? 2 : 1, bindGroupLayouts = raw_data(layouts[:])},
	)
	if pl == nil do return nil
	pipe := wg.DeviceCreateRenderPipeline(
		g.device,
		&{
			layout = pl,
			vertex = {module = r.shader, entryPoint = "vs_main", bufferCount = 1, buffers = &vbl},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
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
		if r.alt_pipes[i][.Solid][.Custom] != nil {
			wg.RenderPipelineRelease(r.alt_pipes[i][.Solid][.Custom])
		}
		if r.alt_pipes[i][.Image][.Custom] != nil {
			wg.RenderPipelineRelease(r.alt_pipes[i][.Image][.Custom])
		}
		fs_s, ts := _fs_for(.Solid)
		fs_i, ti := _fs_for(.Image)
		r.alt_pipes[i][.Solid][.Custom] = _make_pipe(r, .Custom, fs_s, ts, r.alt_fmt[i])
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
	@location(2) @interpolate(flat) mode: u32,
};

@vertex
fn vs_main(
	@location(0) pos: vec2<f32>,
	@location(1) col: vec4<f32>,
	@location(2) uv: vec2<f32>,
	@location(3) mode: u32,
) -> VSOut {
	var o: VSOut;
	let sx = pos.x * u.p.x * 2.0 - 1.0;
	let sy = 1.0 - pos.y * u.p.y * 2.0;
	o.pos = vec4<f32>(sx, sy * u.p.z, 0.0, 1.0);
	o.col = col;
	o.uv = uv;
	o.mode = mode;
	return o;
}

@group(1) @binding(0) var atlas: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

@fragment
fn fs_ui(in: VSOut) -> @location(0) vec4<f32> {
	let sampled_alpha = textureSample(atlas, samp, in.uv).r;
	if (in.mode == 0u) {
		return vec4<f32>(in.col.rgb * in.col.a, in.col.a);
	}
	let a = sampled_alpha * in.col.a;
	return vec4<f32>(in.col.rgb * a, a);
}

@fragment
fn fs_image(in: VSOut) -> @location(0) vec4<f32> {
	let t = textureSample(atlas, samp, in.uv);
	let a = t.a * in.col.a;
	return vec4<f32>(t.rgb * in.col.rgb * a, a);
}
`

@(private)
_neutral_texture_init :: proc(r: ^Renderer, device: wg.Device, queue: wg.Queue) {
	assert(r != nil && device != nil, "_neutral_texture_init: invalid arguments")
	assert(r.tex_layout != nil && queue != nil, "_neutral_texture_init: invalid resources")
	r.neutral_tex = wg.DeviceCreateTexture(
		device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {1, 1, 1},
			format = .RGBA8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	assert(r.neutral_tex != nil, "_neutral_texture_init: texture creation failed")
	pixel := [4]byte{255, 255, 255, 255}
	wg.QueueWriteTexture(
		queue,
		&{texture = r.neutral_tex},
		raw_data(pixel[:]),
		uint(len(pixel)),
		&{bytesPerRow = 4, rowsPerImage = 1},
		&{1, 1, 1},
	)
	r.neutral_view = wg.TextureCreateView(r.neutral_tex, nil)
	r.neutral_sampler = wg.DeviceCreateSampler(
		device,
		&{
			magFilter = .Nearest,
			minFilter = .Nearest,
			mipmapFilter = .Nearest,
			addressModeU = .ClampToEdge,
			addressModeV = .ClampToEdge,
			addressModeW = .ClampToEdge,
			maxAnisotropy = 1,
		},
	)
	assert(r.neutral_view != nil, "_neutral_texture_init: view creation failed")
	assert(r.neutral_sampler != nil, "_neutral_texture_init: sampler creation failed")
	entries := [2]wg.BindGroupEntry {
		{binding = 0, textureView = r.neutral_view},
		{binding = 1, sampler = r.neutral_sampler},
	}
	r.neutral_bind = wg.DeviceCreateBindGroup(
		device,
		&{layout = r.tex_layout, entryCount = 2, entries = raw_data(entries[:])},
	)
	assert(r.neutral_bind != nil, "_neutral_texture_init: bind creation failed")
}

@(private)
_neutral_texture_shutdown :: proc(r: ^Renderer) {
	assert(r != nil, "_neutral_texture_shutdown: nil renderer")
	assert(r.neutral_tex != nil, "_neutral_texture_shutdown: missing texture")
	if r.neutral_bind != nil do wg.BindGroupRelease(r.neutral_bind)
	if r.neutral_sampler != nil do wg.SamplerRelease(r.neutral_sampler)
	if r.neutral_view != nil do wg.TextureViewRelease(r.neutral_view)
	wg.TextureDestroy(r.neutral_tex)
	wg.TextureRelease(r.neutral_tex)
	r.neutral_bind = nil
	r.neutral_sampler = nil
	r.neutral_view = nil
	r.neutral_tex = nil
}

renderer_init :: proc(r: ^Renderer) {
	assert(r != nil, "renderer_init: nil renderer")
	device, queue, format := g.device, g.queue, g.format
	assert(device != nil && queue != nil, "renderer_init: invalid context")
	shader := wg.DeviceCreateShaderModule(
		device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = BATCH_SHADER,
			},
		},
	)
	r.shader = shader
	_stream_slots_init(r)

	// group(0): projection uniform
	r.ubind_layout = wg.DeviceCreateBindGroupLayout(
		device,
		&{
			entryCount = 1,
			entries = &wg.BindGroupLayoutEntry {
				binding = 0,
				visibility = {.Vertex},
				buffer = {type = .Uniform, minBindingSize = size_of([4]f32)},
			},
		},
	)
	r.ubuf = wg.DeviceCreateBuffer(device, &{usage = {.Uniform, .CopyDst}, size = size_of([4]f32)})
	r.ubind = wg.DeviceCreateBindGroup(
		device,
		&{
			layout = r.ubind_layout,
			entryCount = 1,
			entries = &wg.BindGroupEntry{binding = 0, buffer = r.ubuf, size = size_of([4]f32)},
		},
	)

	// Separate uniform + bind for render-target passes (see struct comment).
	r.rt_ubuf = wg.DeviceCreateBuffer(
		device,
		&{usage = {.Uniform, .CopyDst}, size = size_of([4]f32)},
	)
	r.rt_ubind = wg.DeviceCreateBindGroup(
		device,
		&{
			layout = r.ubind_layout,
			entryCount = 1,
			entries = &wg.BindGroupEntry{binding = 0, buffer = r.rt_ubuf, size = size_of([4]f32)},
		},
	)
	r.cur_u = r.ubind

	// group(1): texture + sampler (used by text + image pipelines)
	tex_entries := [2]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	r.tex_layout = wg.DeviceCreateBindGroupLayout(
		device,
		&{entryCount = 2, entries = raw_data(tex_entries[:])},
	)
	_neutral_texture_init(r, device, queue)

	// Custom blend defaults to premultiplied over-blend until SetBlendFactors.
	r.cust_src = .One
	r.cust_dst = .OneMinusSrcAlpha
	r.cust_op = .Add

	// build every (kind × blend_slot) pipeline once.
	for kind in Pipe_Kind {
		fs, textured := _fs_for(kind)
		for slot in Blend_Slot {
			r.pipes[kind][slot] = _make_pipe(r, slot, fs, textured, format)
		}
	}

	renderer_state_reset(r)
}

renderer_shutdown :: proc(r: ^Renderer) {
	for buffer in r.transient_buffers do wg.BufferRelease(buffer)
	clear(&r.transient_buffers)
	for &buffers in r.retired_buffers {
		for buffer in buffers do wg.BufferRelease(buffer)
		clear(&buffers)
	}
	for &slot in r.stream_slots {
		if slot.uniform_buffer != nil do wg.BufferRelease(slot.uniform_buffer)
		if slot.geometry_buffer != nil do wg.BufferRelease(slot.geometry_buffer)
		delete(slot.geometry_shadow)
		delete(slot.uniform_shadow)
	}
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
	_neutral_texture_shutdown(r)
	if r.ubind_layout != nil do wg.BindGroupLayoutRelease(r.ubind_layout)
	if r.tex_layout != nil do wg.BindGroupLayoutRelease(r.tex_layout)
}

@(private)
renderer_state_reset :: proc(r: ^Renderer) {
	assert(r != nil, "renderer_state_reset: nil renderer")
	assert(r.neutral_bind != nil, "renderer_state_reset: nil neutral bind")
	r.cur_kind = .Solid
	r.cur_bind = r.neutral_bind
	r.cur_blend = .Alpha
}

renderer_frame_begin :: proc(r: ^Renderer) -> bool {
	if !_stream_slot_acquire(r, _submission_completed(&g.submissions)) {
		_stats_stream_slot_exhaustion()
		return false
	}
	retired := &r.retired_buffers[r.active_stream_slot]
	for buffer in retired^ do wg.BufferRelease(buffer)
	clear(retired)
	clear(&r.transient_buffers)
	clear(&r.verts)
	clear(&r.indices)
	renderer_state_reset(r)
	r.cur_u = r.ubind
	r.active_shader = 0
	r.model_xf = AFFINE_IDENTITY
	clear(&r.model_stack)

	// keep projection in sync with the logical window size (p.z = +1: no flip)
	if r.proj_w != g.width || r.proj_h != g.height {
		p := [4]f32{1.0 / f32(max(g.width, 1)), 1.0 / f32(max(g.height, 1)), 1.0, 0.0}
		wg.QueueWriteBuffer(g.queue, r.ubuf, 0, &p, size_of(p))
		r.proj_w, r.proj_h = g.width, g.height
	}
	return true
}

@(private)
_batch_bind :: proc(kind: Pipe_Kind, bind, current, neutral: wg.BindGroup) -> wg.BindGroup {
	assert(neutral != nil, "_batch_bind: nil neutral bind")
	if kind == .Solid && bind == nil && current != nil do return current
	if bind == nil do return neutral
	return bind
}

// batch_set switches the active pipeline/texture, flushing the pending run
// first if the state differs. Routes to the render-target pass when one is
// bound (BeginTextureMode).
//
// Every raylib-shaped draw passes through here, which makes it the one place
// to catch a PascalCase draw aimed at the wrong context while an ergonomic
// Frame is live elsewhere (see _assert_surface_not_routed_elsewhere).
@(private)
batch_set :: proc(r: ^Renderer, kind: Pipe_Kind, bind: wg.BindGroup) {
	assert(r != nil, "batch_set: nil renderer")
	assert(r.neutral_bind != nil, "batch_set: nil neutral bind")
	_assert_surface_not_routed_elsewhere()
	_ensure_active_pass()
	next_bind := _batch_bind(kind, bind, r.cur_bind, r.neutral_bind)
	if kind != r.cur_kind || next_bind != r.cur_bind {
		cause: Flush_Cause = kind != r.cur_kind ? .Pipeline : .Texture
		if _active_pass_begun() do renderer_flush(r, active_pass(), cause)
		r.cur_kind = kind
		r.cur_bind = next_bind
	}
}

@(private)
_batch_reserve :: proc(r: ^Renderer, vertex_count, index_count: int) -> bool {
	assert(r != nil)
	assert(vertex_count > 0)
	assert(index_count > 0)
	if vertex_count > BATCH_MAX_VERTICES || index_count > BATCH_MAX_INDICES do return false
	vertices_fit := len(r.verts) <= BATCH_MAX_VERTICES - vertex_count
	indices_fit := len(r.indices) <= BATCH_MAX_INDICES - index_count
	if vertices_fit && indices_fit do return true
	if !_active_pass_begun() do return false
	renderer_flush(r, active_pass(), .Manual)
	return(
		len(r.verts) <= BATCH_MAX_VERTICES - vertex_count &&
		len(r.indices) <= BATCH_MAX_INDICES - index_count \
	)
}

// push_quad emits two triangles for rect `d` sampling uv rect `s`.
//
// A rectangle survives the model transform as a rectangle only while the
// transform does not mix the axes, so a rotating transform (BeginMode2D with a
// rotation) hands the four corners to push_quad4 instead.
@(private)
push_quad :: proc(
	r: ^Renderer,
	d: Rectangle,
	s: Rectangle,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	if !g.frame.has_frame do return
	u0, v0 := s.x, s.y
	u1, v1 := s.x + s.width, s.y + s.height
	if _affine_rotates(r.model_xf) {
		push_quad4(
			r,
			{d.x, d.y},
			{d.x + d.width, d.y},
			{d.x + d.width, d.y + d.height},
			{d.x, d.y + d.height},
			{u0, v0},
			{u1, v0},
			{u1, v1},
			{u0, v1},
			col,
			mode,
		)
		return
	}
	if !_batch_reserve(r, 4, 6) do return
	p0 := _affine_apply(r.model_xf, {d.x, d.y})
	p1 := _affine_apply(r.model_xf, {d.x + d.width, d.y + d.height})
	x0, y0 := p0.x, p0.y
	x1, y1 := p1.x, p1.y
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{{x0, y0}, col, {u0, v0}, mode},
		Vertex{{x0, y1}, col, {u0, v1}, mode},
		Vertex{{x1, y0}, col, {u1, v0}, mode},
		Vertex{{x1, y1}, col, {u1, v1}, mode},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

@(private)
push_tri :: proc(r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	if !g.frame.has_frame do return
	if !_batch_reserve(r, 3, 3) do return
	pa := _affine_apply(r.model_xf, a)
	pb := _affine_apply(r.model_xf, b)
	pc := _affine_apply(r.model_xf, c)
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{pa, col, {0, 0}, .Solid},
		Vertex{pb, col, {0, 0}, .Solid},
		Vertex{pc, col, {0, 0}, .Solid},
	)
	append(&r.indices, base, base + 1, base + 2)
}

// push_quad4 emits an arbitrary (possibly rotated) quad with per-corner uv.
// Corners must be given in order tl, tr, br, bl.
@(private)
push_quad4 :: proc(
	r: ^Renderer,
	tl, tr, br, bl: [2]f32,
	uv_tl, uv_tr, uv_br, uv_bl: [2]f32,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	if !g.frame.has_frame do return
	if !_batch_reserve(r, 4, 6) do return
	tlo := _affine_apply(r.model_xf, tl)
	tro := _affine_apply(r.model_xf, tr)
	bro := _affine_apply(r.model_xf, br)
	blo := _affine_apply(r.model_xf, bl)
	base := u32(len(r.verts))
	append(
		&r.verts,
		Vertex{tlo, col, uv_tl, mode},
		Vertex{blo, col, uv_bl, mode},
		Vertex{tro, col, uv_tr, mode},
		Vertex{bro, col, uv_br, mode},
	)
	append(&r.indices, base, base + 1, base + 2, base + 2, base + 1, base + 3)
}

// --- model transform (rlgl matrix stack + Camera2D) -------------------------

MatrixModePush :: proc() {
	if len(g.rend.model_stack) >= MODEL_STACK_MAX do return
	append(&g.rend.model_stack, g.rend.model_xf)
}
MatrixModePop :: proc() {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Matrix)
	n := len(g.rend.model_stack)
	if n == 0 {g.rend.model_xf = AFFINE_IDENTITY; return}
	g.rend.model_xf = g.rend.model_stack[n - 1]
	pop(&g.rend.model_stack)
}
MatrixModeTranslate :: proc(x, y: f32) {
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Matrix)
	g.rend.model_xf = _affine_translated(g.rend.model_xf, x, y)
}

renderer_flush :: proc(r: ^Renderer, pass: wg.RenderPassEncoder, cause: Flush_Cause = .Manual) {
	n := len(r.verts)
	if n == 0 do return

	index_count := len(r.indices)
	assert(index_count > 0)
	vertex_bytes := u64(n) * size_of(Vertex)
	index_bytes := u64(index_count) * size_of(u32)
	vertex_buffer, index_buffer: wg.Buffer
	vertex_offset, index_offset: u64
	if STREAMED_RENDERER_ENABLED {
		buffer, uploaded_vertex_offset, uploaded_index_offset, upload_ok :=
			_geometry_upload_indexed(
				r,
				raw_data(r.verts[:]),
				vertex_bytes,
				raw_data(r.indices[:]),
				index_bytes,
			)
		if upload_ok {
			vertex_buffer = buffer
			index_buffer = buffer
			vertex_offset = uploaded_vertex_offset
			index_offset = uploaded_index_offset
		} else {
			vertex_buffer, index_buffer = _geometry_upload_transient(r)
			if vertex_buffer == nil || index_buffer == nil {
				clear(&r.verts)
				clear(&r.indices)
				return
			}
		}
	} else {
		vertex_buffer, index_buffer = _geometry_upload_transient(r)
		if vertex_buffer == nil || index_buffer == nil {
			clear(&r.verts)
			clear(&r.indices)
			return
		}
	}
	_stats_flush(u64(n), vertex_bytes + index_bytes, cause)
	when RENDER_STATS_ENABLED {
		g.stats_current.indices_uploaded += u64(index_count)
	}

	// Custom-shader path: an active shader overrides the pipeline + bind groups
	// for the current draw (fullscreen post-process / custom 2D passes).
	if r.active_shader != 0 {
		if _shader_flush(
			r,
			pass,
			vertex_buffer,
			vertex_offset,
			index_buffer,
			index_offset,
			u32(index_count),
		) {
			clear(&r.verts)
			clear(&r.indices)
			return
		}
	}

	pipe := _pipe_for(r, r.cur_kind, r.cur_blend)
	if pipe == nil {
		clear(&r.verts)
		clear(&r.indices)
		return
	}
	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch()
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(1)
	if r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vertex_buffer, vertex_offset, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(pass, index_buffer, .Uint32, index_offset, index_bytes)
	wg.RenderPassEncoderDrawIndexed(pass, u32(index_count), 1, 0, 0, 0)

	clear(&r.verts)
	clear(&r.indices)
}

@(private)
_geometry_upload_transient :: proc(r: ^Renderer) -> (wg.Buffer, wg.Buffer) {
	assert(r != nil)
	if len(r.transient_buffers) > BATCH_TRANSIENT_BUFFERS_MAX - 2 do return nil, nil
	vertex_buffer := wg.DeviceCreateBufferWithData(g.device, &{usage = {.Vertex}}, r.verts[:])
	if vertex_buffer == nil do return nil, nil
	index_buffer := wg.DeviceCreateBufferWithData(g.device, &{usage = {.Index}}, r.indices[:])
	if index_buffer == nil {
		wg.BufferRelease(vertex_buffer)
		return nil, nil
	}
	append(&r.transient_buffers, vertex_buffer, index_buffer)
	_stats_buffer_created(false)
	_stats_buffer_created(false)
	return vertex_buffer, index_buffer
}

@(private)
_geometry_upload_indexed :: proc(
	r: ^Renderer,
	vertex_data: rawptr,
	vertex_bytes: u64,
	index_data: rawptr,
	index_bytes: u64,
) -> (
	wg.Buffer,
	u64,
	u64,
	bool,
) {
	assert(r != nil)
	assert(vertex_data != nil)
	assert(vertex_bytes > 0)
	assert(index_data != nil)
	assert(index_bytes > 0)
	if r.active_stream_slot < 0 do return nil, 0, 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	vertex_offset, index_offset, ok := _stream_slot_reserve_indexed(
		slot,
		vertex_bytes,
		index_bytes,
		GEOMETRY_STREAM_BYTES,
	)
	if !ok {
		_stats_reservation_failure(false)
		return nil, 0, 0, false
	}

	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.geometry_shadow, slot.geometry_write, GEOMETRY_STREAM_BYTES) {
		slot.geometry_write = vertex_offset
		_stats_reservation_failure(false)
		return nil, 0, 0, false
	}
	mem.copy(raw_data(slot.geometry_shadow[vertex_offset:]), vertex_data, int(vertex_bytes))
	mem.copy(raw_data(slot.geometry_shadow[index_offset:]), index_data, int(index_bytes))
	_stats_stream_copy(platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		g.stats_current.peak_geometry_arena_bytes = max(
			g.stats_current.peak_geometry_arena_bytes,
			slot.geometry_write,
		)
	}
	return slot.geometry_buffer, vertex_offset, index_offset, true
}

@(private)
_stream_slots_init :: proc(r: ^Renderer) {
	assert(r != nil)
	limits, status := wg.DeviceGetLimits(g.device)
	r.uniform_alignment = u64(limits.minUniformBufferOffsetAlignment)
	if status != .Success || r.uniform_alignment == 0 do r.uniform_alignment = 256
	r.active_stream_slot = -1
	for &slot in r.stream_slots {
		slot.geometry_buffer = wg.DeviceCreateBuffer(
			g.device,
			&{usage = {.Vertex, .Index, .CopyDst}, size = GEOMETRY_STREAM_BYTES},
		)
		slot.uniform_buffer = wg.DeviceCreateBuffer(
			g.device,
			&{usage = {.Uniform, .CopyDst}, size = UNIFORM_STREAM_BYTES},
		)
		_stats_buffer_created(false)
		_stats_buffer_created(false)
		assert(slot.geometry_buffer != nil)
		assert(slot.uniform_buffer != nil)
	}
}

@(private)
_stream_shadow_ensure :: proc(shadow: ^[dynamic]byte, required, capacity: u64) -> bool {
	assert(shadow != nil)
	assert(required <= capacity)
	if required <= u64(len(shadow)) do return true
	grown := max(u64(4096), u64(len(shadow)) * 2)
	for grown < required {
		if grown > capacity / 2 {
			grown = capacity
			break
		}
		grown *= 2
	}
	if grown < required || grown > capacity do return false
	resize(shadow, int(grown))
	return u64(len(shadow)) >= required
}

@(private)
_stream_slot_upload :: proc(r: ^Renderer) -> bool {
	assert(r != nil)
	if r.active_stream_slot < 0 do return false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	assert(slot.state == .Recording)
	if slot.geometry_write > 0 {
		started := platform_now()
		wg.QueueWriteBuffer(
			g.queue,
			slot.geometry_buffer,
			0,
			raw_data(slot.geometry_shadow[:slot.geometry_write]),
			uint(slot.geometry_write),
		)
		_stats_stream_write(false, slot.geometry_write, platform_now() - started)
	}
	if slot.uniform_write > 0 {
		started := platform_now()
		wg.QueueWriteBuffer(
			g.queue,
			slot.uniform_buffer,
			0,
			raw_data(slot.uniform_shadow[:slot.uniform_write]),
			uint(slot.uniform_write),
		)
		_stats_stream_write(true, slot.uniform_write, platform_now() - started)
	}
	return true
}

@(private)
_stream_slots_poll :: proc(slots: []Stream_Slot, completed: u64) {
	for &slot in slots {
		if slot.state == .Submitted && completed >= slot.ticket {
			slot.geometry_write = 0
			slot.uniform_write = 0
			slot.ticket = 0
			slot.state = .Free
		}
	}
}

@(private)
_stream_slots_acquire :: proc(slots: []Stream_Slot, completed: u64) -> i32 {
	_stream_slots_poll(slots, completed)
	for &slot, index in slots {
		if slot.state == .Free {
			slot.geometry_write = 0
			slot.uniform_write = 0
			slot.ticket = 0
			slot.state = .Recording
			return i32(index)
		}
	}
	return -1
}

@(private)
_stream_slot_acquire :: proc(r: ^Renderer, completed: u64) -> bool {
	assert(r != nil)
	assert(r.active_stream_slot < 0)
	r.active_stream_slot = _stream_slots_acquire(r.stream_slots[:], completed)
	return r.active_stream_slot >= 0
}

@(private)
_stream_slot_submit :: proc(slot: ^Stream_Slot, ticket: u64) -> bool {
	assert(slot != nil)
	if slot.state != .Recording || ticket == 0 do return false
	slot.ticket = ticket
	slot.state = .Submitted
	return true
}

@(private)
_stream_transients_retire :: proc(r: ^Renderer, slot_index: i32) {
	assert(r != nil)
	assert(slot_index >= 0 && slot_index < len(r.stream_slots))
	append(&r.retired_buffers[slot_index], ..r.transient_buffers[:])
	clear(&r.transient_buffers)
}

@(private)
_stream_slot_submitted :: proc(r: ^Renderer, ticket: u64) -> bool {
	assert(r != nil)
	if r.active_stream_slot < 0 do return false
	assert(r.active_stream_slot < len(r.stream_slots))
	ok := _stream_slot_submit(&r.stream_slots[r.active_stream_slot], ticket)
	if ok {
		_stream_transients_retire(r, r.active_stream_slot)
		r.active_stream_slot = -1
	}
	return ok
}

@(private)
_stream_slot_abandon :: proc(r: ^Renderer) {
	assert(r != nil)
	if r.active_stream_slot < 0 do return
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	assert(slot.state == .Recording)
	slot.geometry_write = 0
	slot.uniform_write = 0
	slot.ticket = 0
	slot.state = .Free
	r.active_stream_slot = -1
}

@(private = "file")
checked_add_u64 :: proc(a, b: u64) -> (sum: u64, ok: bool) {
	if b > max(u64) - a do return 0, false
	return a + b, true
}

@(private = "file")
checked_align_u64 :: proc(value, alignment: u64) -> (aligned: u64, ok: bool) {
	assert(alignment > 0)
	padded := checked_add_u64(value, alignment - 1) or_return
	return padded / alignment * alignment, true
}

@(private)
_stream_slot_reserve_indexed :: proc(
	slot: ^Stream_Slot,
	vertex_bytes, index_bytes, capacity: u64,
) -> (
	vertex, index: u64,
	ok: bool,
) {
	assert(slot != nil)
	assert(slot.state == .Recording)
	assert(vertex_bytes > 0)
	assert(index_bytes > 0)
	write_before := slot.geometry_write
	vertex = checked_align_u64(write_before, GEOMETRY_STREAM_ALIGN) or_return
	vertex_end := checked_add_u64(vertex, vertex_bytes) or_return
	index = checked_align_u64(vertex_end, GEOMETRY_STREAM_ALIGN) or_return
	end := checked_add_u64(index, index_bytes) or_return
	if end > capacity do return 0, 0, false
	slot.geometry_write = end
	assert(slot.geometry_write >= write_before)
	assert(slot.geometry_write <= capacity)
	return vertex, index, true
}

@(private)
_stream_slot_reserve_uniform :: proc(
	slot: ^Stream_Slot,
	size, alignment, capacity: u64,
) -> (
	offset: u64,
	ok: bool,
) {
	assert(slot != nil)
	assert(slot.state == .Recording)
	assert(size > 0)
	assert(alignment > 0)
	write_before := slot.uniform_write
	offset = checked_align_u64(write_before, alignment) or_return
	end := checked_add_u64(offset, size) or_return
	if end > capacity do return 0, false
	slot.uniform_write = end
	assert(slot.uniform_write >= write_before)
	assert(slot.uniform_write <= capacity)
	return offset, true
}

@(private)
_uniform_upload :: proc(r: ^Renderer, data: rawptr, size: u64) -> (u32, bool) {
	assert(r != nil)
	assert(data != nil)
	assert(size > 0)
	if r.active_stream_slot < 0 do return 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	offset, ok := _stream_slot_reserve_uniform(
		slot,
		size,
		r.uniform_alignment,
		UNIFORM_STREAM_BYTES,
	)
	if !ok {
		_stats_reservation_failure(true)
		return 0, false
	}
	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.uniform_shadow, slot.uniform_write, UNIFORM_STREAM_BYTES) {
		slot.uniform_write = offset
		_stats_reservation_failure(true)
		return 0, false
	}
	mem.copy(raw_data(slot.uniform_shadow[offset:]), data, int(size))
	_stats_stream_copy(platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		g.stats_current.peak_uniform_arena_bytes = max(
			g.stats_current.peak_uniform_arena_bytes,
			slot.uniform_write,
		)
	}
	assert(offset <= u64(max(u32)))
	return u32(offset), true
}

@(private)
_active_uniform_buffer :: proc(r: ^Renderer) -> wg.Buffer {
	assert(r != nil)
	if r.active_stream_slot < 0 do return nil
	assert(r.active_stream_slot < len(r.stream_slots))
	return r.stream_slots[r.active_stream_slot].uniform_buffer
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
