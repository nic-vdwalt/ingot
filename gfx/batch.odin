// ingot:gfx - CPU 2D vertex batcher over WebGPU. Two pipelines share one
// vertex layout (screen-space position, rgba, uv, mode) and one ortho projection
// uniform: `solid` handles flat color and R8 text coverage, while `image`
// handles RGBA textures. Draws accumulate into a CPU run and flush into the
// frame's render pass whenever the pipeline/texture/scissor changes or at
// EndDrawing. Scissor is render-pass state, set directly on the pass between
// flushes.
package gfx

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

// Gpu_Vertex is the layout the 2D batch uploads. Vertex stays the CPU-side
// authoring form; flush packs into this, colour as RGBA8 read by Unorm8x4, so
// WGSL still sees vec4<f32>. 24 bytes instead of 36 cuts per-frame uploads,
// which is what iOS WebKit's GPU process runs out of.
Gpu_Vertex :: struct {
	pos:  [2]f32,
	uv:   [2]f32,
	col:  u32,
	mode: Vertex_Mode,
}
#assert(size_of(Gpu_Vertex) == 24)

// _pack_color is lossless for every producer: all batch colours come from an
// 8-bit Color through col_f.
@(private)
_pack_color :: #force_inline proc "contextless" (c: [4]f32) -> u32 {
	r := u32(clamp(c[0], 0, 1) * 255 + 0.5)
	g := u32(clamp(c[1], 0, 1) * 255 + 0.5)
	b := u32(clamp(c[2], 0, 1) * 255 + 0.5)
	a := u32(clamp(c[3], 0, 1) * 255 + 0.5)
	return r | g << 8 | b << 16 | a << 24
}

@(private)
_pack_vertex :: #force_inline proc "contextless" (v: Vertex) -> Gpu_Vertex {
	return {pos = v.pos, uv = v.uv, col = _pack_color(v.col), mode = v.mode}
}

// _gpu_vertex_attributes is the single source of the batch vertex layout for
// every pipeline that consumes batch geometry, built-in or custom shader.
_gpu_vertex_attributes :: proc "contextless" () -> [4]wg.VertexAttribute {
	return {
		{format = .Float32x2, offset = u64(offset_of(Gpu_Vertex, pos)), shaderLocation = 0},
		{format = .Unorm8x4, offset = u64(offset_of(Gpu_Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Gpu_Vertex, uv)), shaderLocation = 2},
		{format = .Uint32, offset = u64(offset_of(Gpu_Vertex, mode)), shaderLocation = 3},
	}
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

// GPU_BUDGET_* in limits.odin are the desktop targets these default to. The
// live sizes are negotiated per-device and stored on the Renderer, because a
// mobile GPU cannot afford STREAM_SLOT_COUNT pairs of 16 MiB buffers.
GEOMETRY_STREAM_ALIGN :: u64(4)
STREAM_SLOT_COUNT :: 3

// Batch capacity: the CPU-side run accumulated between flushes. These are
// inline arrays in Renderer, which is inside the static `g` Context, so the
// full 10.5 MiB is resident for the whole session.
//
// Measured with the gallery smoke run (scripts/smoke-gallery.sh), which walks
// every section including the 1000-button stress grid:
//
//   viewport            vertices    indices   % of cap
//   phone  780x1688       26,964     31,374      10.3%
//   laptop 1100x760       15,680     18,228       6.0%
//   4K     3840x2160     107,968    125,880      41.2%
//
// The vertex count tracks visible widget count, so it scales with framebuffer
// area: 4K already reaches 41%, and a 5K/6K display would approach the cap.
// These defaults are therefore NOT oversized for desktop and are deliberately
// left alone - an earlier plan proposed cutting them to 32,768 on the
// strength of the laptop measurement alone, which would have overflowed every
// large display.
//
// They are #config so a target with a known-small framebuffer can reclaim the
// memory. A web build capped at devicePixelRatio 2 (see web/ingot_web.js)
// cannot exceed a tablet-sized framebuffer, so halving these there is safe;
// overflow degrades through _geometry_upload_transient rather than corrupting,
// and now logs (_renderer_report_overflow).
BATCH_MAX_VERTICES :: #config(INGOT_BATCH_MAX_VERTICES, 262_144)
BATCH_MAX_INDICES :: #config(INGOT_BATCH_MAX_INDICES, 393_216)

// A batch below the measured 4K peak would spill to one-shot buffers during
// ordinary use on a large display.
#assert(BATCH_MAX_VERTICES >= 131_072)
// Indices run about 1.5x vertices (a quad is 4 vertices, 6 indices).
#assert(BATCH_MAX_INDICES >= BATCH_MAX_VERTICES)

BATCH_TRANSIENT_BUFFERS_MAX :: 4096
MODEL_STACK_MAX :: 64
STREAMED_RENDERER_ENABLED :: #config(INGOT_STREAMED_RENDERER, true)

Stream_Slot_State :: enum {
	Free,
	Recording,
	Submitted,
}

Stream_Slot :: struct {
	geometry_buffer:   wg.Buffer,
	uniform_buffer:    wg.Buffer,
	geometry_shadow:   [dynamic]byte,
	uniform_shadow:    [dynamic]byte,
	geometry_write:    u64,
	geometry_uploaded: u64,
	uniform_write:     u64,
	uniform_uploaded:  u64,
	ticket:            u64,
	state:             Stream_Slot_State,
}

Renderer :: struct {
	shader:                wg.ShaderModule, // kept alive so Custom pipelines can be rebuilt
	pipes:                 [Pipe_Kind][Blend_Slot]wg.RenderPipeline,

	// Lazy batch pipelines for non-swapchain target formats (e.g. the galaxy
	// HDR RGBA16Float render targets). Keyed by colour format.
	alt_fmt:               [4]wg.TextureFormat,
	alt_pipes:             [4][Pipe_Kind][Blend_Slot]wg.RenderPipeline,
	alt_n:                 int,
	ubuf:                  wg.Buffer,
	diagnostic_projection: [4 when GPU_TIMING_DIAGNOSTICS else 0]f32,
	diagnostic_pipelines:  [GPU_TIMING_BATCH_PIPELINE_SLOTS]Gpu_Timing_Batch_Pipeline,
	ubind:                 wg.BindGroup,
	ubind_layout:          wg.BindGroupLayout,
	tex_layout:            wg.BindGroupLayout, // group(1): texture + sampler
	neutral_tex:           wg.Texture,
	neutral_view:          wg.TextureView,
	neutral_sampler:       wg.Sampler,
	neutral_bind:          wg.BindGroup,

	// Alternate group(0) uniform for render-target passes: an RT renders in its
	// own pixel space, so it needs its own ortho projection that must NOT clobber
	// the window projection used by the main pass in the same frame. cur_u is the
	// group(0) bind the next flush uses (r.ubind for the window, r.rt_ubind for
	// the active render target).
	rt_ubuf:               wg.Buffer,
	rt_ubind:              wg.BindGroup,
	cur_u:                 wg.BindGroup,

	// current run
	verts:                 [dynamic; BATCH_MAX_VERTICES]Vertex,
	indices:               [dynamic; BATCH_MAX_INDICES]u32,
	// High-water marks across the context's lifetime, in elements. Always
	// tracked (two max() per flush) rather than gated behind
	// RENDER_STATS_ENABLED, because these are what justify the capacities
	// above: a bound nobody can measure is a guess. Read via
	// renderer_peak_usage.
	peak_verts:            int,
	peak_indices:          int,
	peak_geometry_bytes:   u64,
	peak_uniform_bytes:    u64,
	cur_kind:              Pipe_Kind,
	cur_bind:              wg.BindGroup,
	cur_blend:             Blend_Slot,

	// Active custom shader (BeginShaderMode); 0 = none. When set, Image-kind
	// flushes use the shader's pipeline + uniform/extra-texture bind groups.
	active_shader:         u32,

	// 2D model transform (rlgl matrix stack and BeginMode2D): applied to every
	// emitted vertex so rlgl.PushMatrix/Translatef/PopMatrix shift subsequent
	// draws (the galaxy pane origin transform) and a Camera2D pans, zooms, and
	// rotates the world it wraps.
	model_xf:              Affine,
	model_stack:           [dynamic; MODEL_STACK_MAX]Affine,

	// Custom blend factors (set by rlgl.SetBlendFactors; default = Alpha).
	cust_src:              wg.BlendFactor,
	cust_dst:              wg.BlendFactor,
	cust_op:               wg.BlendOperation,
	stream_slots:          [STREAM_SLOT_COUNT]Stream_Slot,
	active_stream_slot:    i32,
	uniform_alignment:     u64,
	// Per-slot pool sizes actually allocated on this device (limits.odin).
	// Every reservation and shadow bound reads these, never a constant, so a
	// constrained device streams within what its GPU granted.
	geometry_bytes:        u64,
	uniform_bytes:         u64,
	transient_buffers:     [dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	retired_buffers:       [STREAM_SLOT_COUNT][dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	// Bytes that missed the geometry stream this frame and fell back to
	// one-shot buffers. Reset per frame and reported once at frame end so a
	// pathological scene names itself instead of quietly allocating up to
	// BATCH_TRANSIENT_BUFFERS_MAX buffers until the tab dies.
	overflow_bytes:        u64,
	overflow_draws:        u32,
	// Lifetime count of overflow reports already printed for this renderer.
	// Never reset per frame (like peak_*) so the report cap is per context,
	// not per process.
	overflow_reports:      u32,
}

@(private)
_window_projection :: proc(width, height: i32) -> [4]f32 {
	assert(width > 0 && height > 0, "_window_projection: invalid logical size")
	return {1.0 / f32(width), 1.0 / f32(height), 1.0, 0.0}
}

@(private)
_window_projection_ndc :: proc(point: [2]f32, projection: [4]f32) -> [2]f32 {
	return {point.x * projection.x * 2.0 - 1.0, 1.0 - point.y * projection.y * 2.0}
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

// renderer_init builds the pipelines and stream pools. Returns false when the
// device cannot supply even floor-sized stream buffers, so the caller can
// close the context instead of running with an unusable renderer.
@(private = "package")
renderer_init :: proc(ctx: ^Context, r: ^Renderer) -> bool {
	assert(ctx != nil, "renderer_init: nil context")
	assert(r == &ctx.rend, "renderer_init: foreign renderer")
	device, queue, format := ctx.device, ctx.queue, ctx.format
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
	if !_stream_slots_init(ctx, r, device, gpu_budget_context(ctx)) do return false

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
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Vertex, .Fragment}, sampler = {type = .Filtering}},
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

	// build every (kind × blend_slot) pipeline once. The retained descriptors
	// are cleared first so a re-initialised window records its own swapchain
	// set rather than keeping a previous window's format.
	when GPU_TIMING_DIAGNOSTICS {
		r.diagnostic_pipelines = {}
	}
	for kind in Pipe_Kind {
		fs, textured := _fs_for(kind)
		for slot in Blend_Slot {
			r.pipes[kind][slot] = _make_pipe(device, r, slot, fs, textured, format)
		}
	}

	renderer_state_reset(r)
	return true
}

@(private = "package")
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
