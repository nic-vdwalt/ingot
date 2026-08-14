// ingot:gfx - CPU 2D vertex batcher over WebGPU. Two pipelines share one
// vertex layout (screen-space position, rgba, uv, mode) and one ortho projection
// uniform: `solid` handles flat color and R8 text coverage, while `image`
// handles RGBA textures. Draws accumulate into a CPU run and flush into the
// frame's render pass whenever the pipeline/texture/scissor changes or at
// EndDrawing. Scissor is render-pass state, set directly on the pass between
// flushes.
package gfx

import "core:fmt"
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
	shader:              wg.ShaderModule, // kept alive so Custom pipelines can be rebuilt
	pipes:               [Pipe_Kind][Blend_Slot]wg.RenderPipeline,

	// Lazy batch pipelines for non-swapchain target formats (e.g. the galaxy
	// HDR RGBA16Float render targets). Keyed by colour format.
	alt_fmt:             [4]wg.TextureFormat,
	alt_pipes:           [4][Pipe_Kind][Blend_Slot]wg.RenderPipeline,
	alt_n:               int,
	ubuf:                wg.Buffer,
	ubind:               wg.BindGroup,
	ubind_layout:        wg.BindGroupLayout,
	tex_layout:          wg.BindGroupLayout, // group(1): texture + sampler
	neutral_tex:         wg.Texture,
	neutral_view:        wg.TextureView,
	neutral_sampler:     wg.Sampler,
	neutral_bind:        wg.BindGroup,

	// Alternate group(0) uniform for render-target passes: an RT renders in its
	// own pixel space, so it needs its own ortho projection that must NOT clobber
	// the window projection used by the main pass in the same frame. cur_u is the
	// group(0) bind the next flush uses (r.ubind for the window, r.rt_ubind for
	// the active render target).
	rt_ubuf:             wg.Buffer,
	rt_ubind:            wg.BindGroup,
	cur_u:               wg.BindGroup,

	// current run
	verts:               [dynamic; BATCH_MAX_VERTICES]Vertex,
	indices:             [dynamic; BATCH_MAX_INDICES]u32,
	// High-water marks across the context's lifetime, in elements. Always
	// tracked (two max() per flush) rather than gated behind
	// RENDER_STATS_ENABLED, because these are what justify the capacities
	// above: a bound nobody can measure is a guess. Read via
	// renderer_peak_usage.
	peak_verts:          int,
	peak_indices:        int,
	peak_geometry_bytes: u64,
	peak_uniform_bytes:  u64,
	cur_kind:            Pipe_Kind,
	cur_bind:            wg.BindGroup,
	cur_blend:           Blend_Slot,

	// Active custom shader (BeginShaderMode); 0 = none. When set, Image-kind
	// flushes use the shader's pipeline + uniform/extra-texture bind groups.
	active_shader:       u32,

	// 2D model transform (rlgl matrix stack and BeginMode2D): applied to every
	// emitted vertex so rlgl.PushMatrix/Translatef/PopMatrix shift subsequent
	// draws (the galaxy pane origin transform) and a Camera2D pans, zooms, and
	// rotates the world it wraps.
	model_xf:            Affine,
	model_stack:         [dynamic; MODEL_STACK_MAX]Affine,

	// Custom blend factors (set by rlgl.SetBlendFactors; default = Alpha).
	cust_src:            wg.BlendFactor,
	cust_dst:            wg.BlendFactor,
	cust_op:             wg.BlendOperation,
	stream_slots:        [STREAM_SLOT_COUNT]Stream_Slot,
	active_stream_slot:  i32,
	uniform_alignment:   u64,
	// Per-slot pool sizes actually allocated on this device (limits.odin).
	// Every reservation and shadow bound reads these, never a constant, so a
	// constrained device streams within what its GPU granted.
	geometry_bytes:      u64,
	uniform_bytes:       u64,
	transient_buffers:   [dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	retired_buffers:     [STREAM_SLOT_COUNT][dynamic; BATCH_TRANSIENT_BUFFERS_MAX]wg.Buffer,
	// Bytes that missed the geometry stream this frame and fell back to
	// one-shot buffers. Reset per frame and reported once at frame end so a
	// pathological scene names itself instead of quietly allocating up to
	// BATCH_TRANSIENT_BUFFERS_MAX buffers until the tab dies.
	overflow_bytes:      u64,
	overflow_draws:      u32,
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
		device,
		&{bindGroupLayoutCount = textured ? 2 : 1, bindGroupLayouts = raw_data(layouts[:])},
	)
	if pl == nil do return nil
	pipe := wg.DeviceCreateRenderPipeline(
		device,
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
			r.pipes[kind][slot] = _make_pipe(device, r, slot, fs, textured, format)
		}
	}

	renderer_state_reset(r)
	return true
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

renderer_frame_begin :: proc(ctx: ^Context, r: ^Renderer) -> bool {
	assert(ctx != nil, "renderer_frame_begin: nil context")
	assert(r == &ctx.rend, "renderer_frame_begin: foreign renderer")
	if !_stream_slot_acquire(r, _submission_completed(&ctx.submissions)) {
		_stats_stream_slot_exhaustion(ctx)
		return false
	}
	retired := &r.retired_buffers[r.active_stream_slot]
	for buffer in retired^ do wg.BufferRelease(buffer)
	clear(retired)
	clear(&r.transient_buffers)
	clear(&r.verts)
	clear(&r.indices)
	r.overflow_bytes = 0
	r.overflow_draws = 0
	renderer_state_reset(r)
	r.cur_u = r.ubind
	r.active_shader = 0
	r.model_xf = AFFINE_IDENTITY
	clear(&r.model_stack)
	return true
}

@(private)
renderer_window_projection_refresh :: proc(r: ^Renderer, queue: wg.Queue, width, height: i32) {
	assert(r != nil, "renderer_window_projection_refresh: nil renderer")
	assert(queue != nil, "renderer_window_projection_refresh: nil queue")
	projection := _window_projection(width, height)
	wg.QueueWriteBuffer(queue, r.ubuf, 0, &projection, size_of(projection))
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
@(private)
batch_set :: proc(ctx: ^Context, r: ^Renderer, kind: Pipe_Kind, bind: wg.BindGroup) {
	assert(ctx != nil, "batch_set: nil context")
	assert(r == &ctx.rend, "batch_set: foreign renderer")
	assert(r.neutral_bind != nil, "batch_set: nil neutral bind")
	context_ensure_active_pass(ctx)
	next_bind := _batch_bind(kind, bind, r.cur_bind, r.neutral_bind)
	if kind != r.cur_kind || next_bind != r.cur_bind {
		cause: Flush_Cause = kind != r.cur_kind ? .Pipeline : .Texture
		if context_active_pass_begun(ctx) {
			renderer_flush(ctx, r, context_active_pass(ctx), cause)
		}
		r.cur_kind = kind
		r.cur_bind = next_bind
	}
}

@(private)
_batch_reserve :: proc(ctx: ^Context, r: ^Renderer, vertex_count, index_count: int) -> bool {
	assert(ctx != nil, "_batch_reserve: nil context")
	assert(r == &ctx.rend, "_batch_reserve: foreign renderer")
	assert(vertex_count > 0)
	assert(index_count > 0)
	if vertex_count > BATCH_MAX_VERTICES || index_count > BATCH_MAX_INDICES do return false
	vertices_fit := len(r.verts) <= BATCH_MAX_VERTICES - vertex_count
	indices_fit := len(r.indices) <= BATCH_MAX_INDICES - index_count
	if vertices_fit && indices_fit do return true
	if !context_active_pass_begun(ctx) do return false
	renderer_flush(ctx, r, context_active_pass(ctx), .Manual)
	return(
		len(r.verts) <= BATCH_MAX_VERTICES - vertex_count &&
		len(r.indices) <= BATCH_MAX_INDICES - index_count \
	)
}

// push_quad emits two triangles for rect `d` sampling uv rect `s`.
//
// The push_* procedures are the frame-guarded entry points; the _emit_*
// procedures below them do the geometry. Splitting the two keeps the model
// transform testable against a bare Renderer, with no shared frame state for
// concurrent tests to race on.
@(private)
push_quad :: proc(
	ctx: ^Context,
	r: ^Renderer,
	d: Rectangle,
	s: Rectangle,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "push_quad: nil context")
	assert(r == &ctx.rend, "push_quad: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_quad(ctx, r, d, s, col, mode)
}

// _emit_quad transforms and appends a rectangle.
//
// A rectangle survives the model transform as a rectangle only while the
// transform does not mix the axes, so a rotating transform (BeginMode2D with a
// rotation) hands the four corners to the general quad path instead.
@(private)
_emit_quad :: proc(
	ctx: ^Context,
	r: ^Renderer,
	d: Rectangle,
	s: Rectangle,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "_emit_quad: nil context")
	assert(r == &ctx.rend, "_emit_quad: foreign renderer")
	u0, v0 := s.x, s.y
	u1, v1 := s.x + s.width, s.y + s.height
	if _affine_rotates(r.model_xf) {
		_emit_quad4(
			ctx,
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
	if !_batch_reserve(ctx, r, 4, 6) do return
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
push_tri :: proc(ctx: ^Context, r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	assert(ctx != nil, "push_tri: nil context")
	assert(r == &ctx.rend, "push_tri: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_tri(ctx, r, a, b, c, col)
}

@(private)
_emit_tri :: proc(ctx: ^Context, r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	assert(ctx != nil, "_emit_tri: nil context")
	assert(r == &ctx.rend, "_emit_tri: foreign renderer")
	if !_batch_reserve(ctx, r, 3, 3) do return
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
	ctx: ^Context,
	r: ^Renderer,
	tl, tr, br, bl: [2]f32,
	uv_tl, uv_tr, uv_br, uv_bl: [2]f32,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "push_quad4: nil context")
	assert(r == &ctx.rend, "push_quad4: foreign renderer")
	if !ctx.frame.has_frame do return
	_emit_quad4(ctx, r, tl, tr, br, bl, uv_tl, uv_tr, uv_br, uv_bl, col, mode)
}

@(private)
_emit_quad4 :: proc(
	ctx: ^Context,
	r: ^Renderer,
	tl, tr, br, bl: [2]f32,
	uv_tl, uv_tr, uv_br, uv_bl: [2]f32,
	col: [4]f32,
	mode: Vertex_Mode = .Solid,
) {
	assert(ctx != nil, "_emit_quad4: nil context")
	assert(r == &ctx.rend, "_emit_quad4: foreign renderer")
	if !_batch_reserve(ctx, r, 4, 6) do return
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

context_matrix_mode_push :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_matrix_mode_push: nil context")
	r := &ctx.rend
	if len(r.model_stack) >= MODEL_STACK_MAX do return
	append(&r.model_stack, r.model_xf)
}

context_matrix_mode_pop :: proc(ctx: ^Context) {
	assert(ctx != nil, "context_matrix_mode_pop: nil context")
	r := &ctx.rend
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, r, context_active_pass(ctx), .Matrix)
	}
	n := len(r.model_stack)
	if n == 0 {r.model_xf = AFFINE_IDENTITY; return}
	r.model_xf = r.model_stack[n - 1]
	pop(&r.model_stack)
}

context_matrix_mode_translate :: proc(ctx: ^Context, x, y: f32) {
	assert(ctx != nil, "context_matrix_mode_translate: nil context")
	r := &ctx.rend
	if context_active_pass_begun(ctx) {
		renderer_flush(ctx, r, context_active_pass(ctx), .Matrix)
	}
	r.model_xf = _affine_translated(r.model_xf, x, y)
}

MatrixModePush :: proc() {
	context_matrix_mode_push(default_context())
}
MatrixModePop :: proc() {
	context_matrix_mode_pop(default_context())
}
MatrixModeTranslate :: proc(x, y: f32) {
	context_matrix_mode_translate(default_context(), x, y)
}

// _batch_record_peak folds one flush's batch size into the renderer's
// high-water marks. Split out from renderer_flush so it can be tested without
// a live GPU pass: renderer_flush needs a real RenderPassEncoder, which would
// leave the only measurement that justifies BATCH_MAX_VERTICES unverified.
@(private)
_batch_record_peak :: proc(r: ^Renderer, vertex_count, index_count: int) {
	assert(r != nil, "_batch_record_peak: nil renderer")
	assert(vertex_count >= 0 && index_count >= 0, "_batch_record_peak: negative count")
	r.peak_verts = max(r.peak_verts, vertex_count)
	r.peak_indices = max(r.peak_indices, index_count)
	assert(r.peak_verts >= vertex_count, "_batch_record_peak: peak below sample")
}

@(private)
_stream_record_peak :: proc(r: ^Renderer, geometry_bytes, uniform_bytes: u64) {
	assert(r != nil, "_stream_record_peak: nil renderer")
	assert(geometry_bytes <= r.geometry_bytes, "_stream_record_peak: geometry exceeds capacity")
	assert(uniform_bytes <= r.uniform_bytes, "_stream_record_peak: uniform exceeds capacity")
	r.peak_geometry_bytes = max(r.peak_geometry_bytes, geometry_bytes)
	r.peak_uniform_bytes = max(r.peak_uniform_bytes, uniform_bytes)
	assert(r.peak_geometry_bytes <= r.geometry_bytes)
	assert(r.peak_uniform_bytes <= r.uniform_bytes)
}

renderer_flush :: proc(
	ctx: ^Context,
	r: ^Renderer,
	pass: wg.RenderPassEncoder,
	cause: Flush_Cause = .Manual,
) {
	assert(ctx != nil, "renderer_flush: nil context")
	assert(r == &ctx.rend, "renderer_flush: foreign renderer")
	n := len(r.verts)
	if n == 0 do return

	index_count := len(r.indices)
	assert(index_count > 0)
	// Record before the buffers are cleared below: this is the whole batch
	// that accumulated since the last flush, which is exactly the quantity
	// BATCH_MAX_VERTICES has to cover.
	_batch_record_peak(r, n, index_count)
	vertex_bytes := u64(n) * size_of(Vertex)
	index_bytes := u64(index_count) * size_of(u32)
	vertex_buffer, index_buffer: wg.Buffer
	vertex_offset, index_offset: u64
	if STREAMED_RENDERER_ENABLED {
		buffer, uploaded_vertex_offset, uploaded_index_offset, upload_ok :=
			_geometry_upload_indexed(
				ctx,
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
			vertex_buffer, index_buffer = _geometry_upload_transient(ctx, r)
			if vertex_buffer == nil || index_buffer == nil {
				clear(&r.verts)
				clear(&r.indices)
				return
			}
		}
	} else {
		vertex_buffer, index_buffer = _geometry_upload_transient(ctx, r)
		if vertex_buffer == nil || index_buffer == nil {
			clear(&r.verts)
			clear(&r.indices)
			return
		}
	}
	_stats_flush(ctx, u64(n), vertex_bytes + index_bytes, cause)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.indices_uploaded += u64(index_count)
	}

	// Custom-shader path: an active shader overrides the pipeline + bind groups
	// for the current draw (fullscreen post-process / custom 2D passes).
	if r.active_shader != 0 {
		if _shader_flush(
			ctx,
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

	pipe := _pipe_for(ctx, r, r.cur_kind, r.cur_blend)
	if pipe == nil {
		clear(&r.verts)
		clear(&r.indices)
		return
	}
	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch(ctx)
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.cur_u != nil ? r.cur_u : r.ubind)
	_stats_bind_group_switches(ctx, 1)
	if r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
		_stats_bind_group_switches(ctx, 1)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vertex_buffer, vertex_offset, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(pass, index_buffer, .Uint32, index_offset, index_bytes)
	wg.RenderPassEncoderDrawIndexed(pass, u32(index_count), 1, 0, 0, 0)

	clear(&r.verts)
	clear(&r.indices)
}

// _geometry_upload_transient is the fallback path when indexed streaming has
// no room: it creates one-shot vertex and index buffers that live until the
// owning stream slot is reused.
//
// The device is passed in rather than read from the active-context global, so
// this leaf stays pure and its caller owns the context lookup (the same shape
// as _neutral_texture_init).
// GEOMETRY_OVERFLOW_REPORTS_MAX bounds how many overflow frames are reported.
// A scene that overflows usually overflows every frame, and an unbounded log
// would itself become the performance problem (and would flood the on-page
// crash panel on web, hiding the first occurrence).
GEOMETRY_OVERFLOW_REPORTS_MAX :: 4

@(private)
g_overflow_reports: u32

// _renderer_report_overflow logs, at most GEOMETRY_OVERFLOW_REPORTS_MAX times,
// that this frame's geometry did not fit the stream and fell back to one-shot
// buffers. Silence here was a cliff: the fallback quietly allocates up to
// BATCH_TRANSIENT_BUFFERS_MAX buffers per frame, which on a memory-constrained
// device (a phone) ends as a killed tab with no diagnostic at all.
@(private)
_renderer_report_overflow :: proc(r: ^Renderer) {
	assert(r != nil, "_renderer_report_overflow: nil renderer")
	if r.overflow_draws == 0 do return
	if g_overflow_reports >= GEOMETRY_OVERFLOW_REPORTS_MAX do return
	g_overflow_reports += 1
	final := g_overflow_reports == GEOMETRY_OVERFLOW_REPORTS_MAX
	fmt.eprintfln(
		"gfx: geometry stream overflow - %d draw(s), %d KiB spilled (stream %d KiB)%s",
		r.overflow_draws,
		r.overflow_bytes / 1024,
		r.geometry_bytes / 1024,
		" [further reports suppressed]" if final else "",
	)
}

@(private)
_geometry_upload_transient :: proc(ctx: ^Context, r: ^Renderer) -> (wg.Buffer, wg.Buffer) {
	assert(ctx != nil, "_geometry_upload_transient: nil context")
	assert(r == &ctx.rend, "_geometry_upload_transient: foreign renderer")
	// Record the overflow before attempting the allocation: a scene reaching
	// this path at all is the signal worth reporting, whether or not the
	// fallback itself succeeds.
	r.overflow_bytes += u64(len(r.verts)) * size_of(Vertex) + u64(len(r.indices)) * size_of(u32)
	r.overflow_draws += 1
	// Two buffers are appended below, so stop one pair short of the cap.
	if len(r.transient_buffers) > BATCH_TRANSIENT_BUFFERS_MAX - 2 do return nil, nil
	vertex_buffer := wg.DeviceCreateBufferWithData(ctx.device, &{usage = {.Vertex}}, r.verts[:])
	if vertex_buffer == nil do return nil, nil
	index_buffer := wg.DeviceCreateBufferWithData(ctx.device, &{usage = {.Index}}, r.indices[:])
	if index_buffer == nil {
		wg.BufferRelease(vertex_buffer)
		return nil, nil
	}
	append(&r.transient_buffers, vertex_buffer, index_buffer)
	assert(len(r.transient_buffers) <= BATCH_TRANSIENT_BUFFERS_MAX)
	_stats_buffer_created(ctx, false)
	_stats_buffer_created(ctx, false)
	return vertex_buffer, index_buffer
}

@(private)
_geometry_upload_indexed :: proc(
	ctx: ^Context,
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
	assert(ctx != nil)
	assert(r == &ctx.rend)
	assert(vertex_data != nil)
	assert(vertex_bytes > 0)
	assert(index_data != nil)
	assert(index_bytes > 0)
	if r.active_stream_slot < 0 do return nil, 0, 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	write_before := slot.geometry_write
	vertex_offset, index_offset, ok := _stream_slot_reserve_indexed(
		slot,
		vertex_bytes,
		index_bytes,
		r.geometry_bytes,
	)
	if !ok {
		_stats_reservation_failure(ctx, false)
		return nil, 0, 0, false
	}

	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.geometry_shadow, slot.geometry_write, r.geometry_bytes) {
		slot.geometry_write = write_before
		_stats_reservation_failure(ctx, false)
		return nil, 0, 0, false
	}
	mem.copy(raw_data(slot.geometry_shadow[vertex_offset:]), vertex_data, int(vertex_bytes))
	mem.copy(raw_data(slot.geometry_shadow[index_offset:]), index_data, int(index_bytes))
	_stream_record_peak(r, slot.geometry_write, r.peak_uniform_bytes)
	_stats_stream_copy(ctx, platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.peak_geometry_arena_bytes = max(
			ctx.stats_current.peak_geometry_arena_bytes,
			slot.geometry_write,
		)
	}
	return slot.geometry_buffer, vertex_offset, index_offset, true
}

// Halving 16 MiB down to the 1 MiB floor takes four steps, so eight attempts
// is generous headroom while still bounding the retry statically (Tiger Style:
// put a limit on everything). A budget that needed more halvings than this
// would already be below the floor the caller asserts.
STREAM_BUFFER_ATTEMPTS_MAX :: 8

// _stream_buffer_create allocates one stream buffer, halving the request until
// the device accepts it or the floor is reached. A phone can refuse a
// desktop-sized buffer even when the reported limits allow it (limits describe
// the API ceiling, not free VRAM), and the previous code asserted on the nil
// return - an Odin panic, which on web traps the wasm module and kills the
// requestAnimationFrame loop for good. Degrading beats dying.
//
// Returns a nil buffer when even the floor-sized allocation fails, which the
// caller treats as an operating error rather than a programmer error.
@(private)
_stream_buffer_create :: proc(
	device: wg.Device,
	usage: wg.BufferUsageFlags,
	requested, minimum: u64,
) -> (
	wg.Buffer,
	u64,
) {
	assert(device != nil, "_stream_buffer_create: nil device")
	assert(minimum > 0, "_stream_buffer_create: zero floor")
	assert(requested >= minimum, "_stream_buffer_create: request below floor")
	size := requested
	for _ in 0 ..< STREAM_BUFFER_ATTEMPTS_MAX {
		buffer := wg.DeviceCreateBuffer(device, &{usage = usage, size = size})
		if buffer != nil {
			assert(size >= minimum, "_stream_buffer_create: allocated below floor")
			return buffer, size
		}
		if size <= minimum do return nil, 0
		size = max(size / 2, minimum)
	}
	// Exhausting the bound means the floor was never reached, which only a
	// mis-sized budget constant could cause.
	assert(size <= minimum, "_stream_buffer_create: retries exhausted above floor")
	return nil, 0
}

// _stream_slots_init allocates the per-slot geometry and uniform pools. The
// device and budget are passed in rather than read from the active-context
// global so this stays a pure leaf its caller can test (the same shape as
// _geometry_upload_transient). Returns false when even the floor-sized pools
// cannot be allocated, leaving the caller to decide the context's fate.
@(private)
_stream_slots_init :: proc(
	ctx: ^Context,
	r: ^Renderer,
	device: wg.Device,
	budget: Gpu_Budget,
) -> bool {
	assert(ctx != nil, "_stream_slots_init: nil context")
	assert(r == &ctx.rend, "_stream_slots_init: foreign renderer")
	assert(device != nil, "_stream_slots_init: nil device")
	assert(budget.geometry_stream_bytes > 0, "_stream_slots_init: empty geometry budget")
	assert(budget.uniform_stream_bytes > 0, "_stream_slots_init: empty uniform budget")
	limits, status := wg.DeviceGetLimits(device)
	r.uniform_alignment = u64(limits.minUniformBufferOffsetAlignment)
	if status != .Success || r.uniform_alignment == 0 do r.uniform_alignment = 256
	r.active_stream_slot = -1
	r.geometry_bytes = budget.geometry_stream_bytes
	r.uniform_bytes = budget.uniform_stream_bytes
	for &slot in r.stream_slots {
		geometry, geometry_size := _stream_buffer_create(
			device,
			{.Vertex, .Index, .CopyDst},
			r.geometry_bytes,
			GPU_BUDGET_GEOMETRY_BYTES_MINIMUM,
		)
		uniform, uniform_size := _stream_buffer_create(
			device,
			{.Uniform, .CopyDst},
			r.uniform_bytes,
			GPU_BUDGET_UNIFORM_BYTES_MINIMUM,
		)
		if geometry == nil || uniform == nil {
			// Below the floor the engine cannot draw at all. Report it and
			// let the caller close the context rather than aborting the
			// process (a panic here traps the wasm module for good).
			if geometry != nil do wg.BufferRelease(geometry)
			if uniform != nil do wg.BufferRelease(uniform)
			fmt.eprintln("gfx: GPU stream buffer allocation failed; device out of memory")
			return false
		}
		_stats_buffer_created(ctx, false)
		_stats_buffer_created(ctx, false)
		slot.geometry_buffer = geometry
		slot.uniform_buffer = uniform
		// Every slot shares one reservation bound, so a slot that had to
		// shrink pulls the whole renderer down with it.
		r.geometry_bytes = min(r.geometry_bytes, geometry_size)
		r.uniform_bytes = min(r.uniform_bytes, uniform_size)
	}
	if r.geometry_bytes != budget.geometry_stream_bytes ||
	   r.uniform_bytes != budget.uniform_stream_bytes {
		fmt.eprintfln(
			"gfx: stream pools reduced to geometry=%d KiB uniform=%d KiB after allocation failure",
			r.geometry_bytes / 1024,
			r.uniform_bytes / 1024,
		)
	}
	assert(r.geometry_bytes >= GPU_BUDGET_GEOMETRY_BYTES_MINIMUM)
	assert(r.uniform_bytes >= GPU_BUDGET_UNIFORM_BYTES_MINIMUM)
	return true
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
_stream_slot_upload :: proc(ctx: ^Context, r: ^Renderer) -> bool {
	assert(ctx != nil, "_stream_slot_upload: nil context")
	assert(r == &ctx.rend, "_stream_slot_upload: foreign renderer")
	if r.active_stream_slot < 0 do return false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	assert(slot.state == .Recording)
	assert(slot.geometry_uploaded <= slot.geometry_write)
	assert(slot.uniform_uploaded <= slot.uniform_write)
	if slot.geometry_write > slot.geometry_uploaded {
		started := platform_now()
		start := slot.geometry_uploaded
		byte_count := slot.geometry_write - start
		wg.QueueWriteBuffer(
			ctx.queue,
			slot.geometry_buffer,
			start,
			raw_data(slot.geometry_shadow[start:slot.geometry_write]),
			uint(byte_count),
		)
		slot.geometry_uploaded = slot.geometry_write
		_stats_stream_write(ctx, false, byte_count, platform_now() - started)
	}
	if slot.uniform_write > slot.uniform_uploaded {
		started := platform_now()
		start := slot.uniform_uploaded
		byte_count := slot.uniform_write - start
		wg.QueueWriteBuffer(
			ctx.queue,
			slot.uniform_buffer,
			start,
			raw_data(slot.uniform_shadow[start:slot.uniform_write]),
			uint(byte_count),
		)
		slot.uniform_uploaded = slot.uniform_write
		_stats_stream_write(ctx, true, byte_count, platform_now() - started)
	}
	return true
}

@(private)
_stream_slots_poll :: proc(slots: []Stream_Slot, completed: u64) {
	for &slot in slots {
		if slot.state == .Submitted && completed >= slot.ticket {
			slot.geometry_write = 0
			slot.geometry_uploaded = 0
			slot.uniform_write = 0
			slot.uniform_uploaded = 0
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
			slot.geometry_uploaded = 0
			slot.uniform_write = 0
			slot.uniform_uploaded = 0
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
	slot.geometry_uploaded = 0
	slot.uniform_write = 0
	slot.uniform_uploaded = 0
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
_uniform_upload :: proc(ctx: ^Context, r: ^Renderer, data: rawptr, size: u64) -> (u32, bool) {
	assert(ctx != nil)
	assert(r == &ctx.rend)
	assert(data != nil)
	assert(size > 0)
	if r.active_stream_slot < 0 do return 0, false
	assert(r.active_stream_slot < len(r.stream_slots))
	slot := &r.stream_slots[r.active_stream_slot]
	offset, ok := _stream_slot_reserve_uniform(slot, size, r.uniform_alignment, r.uniform_bytes)
	if !ok {
		_stats_reservation_failure(ctx, true)
		return 0, false
	}
	copy_started := platform_now()
	if !_stream_shadow_ensure(&slot.uniform_shadow, slot.uniform_write, r.uniform_bytes) {
		slot.uniform_write = offset
		_stats_reservation_failure(ctx, true)
		return 0, false
	}
	mem.copy(raw_data(slot.uniform_shadow[offset:]), data, int(size))
	_stream_record_peak(r, r.peak_geometry_bytes, slot.uniform_write)
	_stats_stream_copy(ctx, platform_now() - copy_started)
	when RENDER_STATS_ENABLED {
		ctx.stats_current.peak_uniform_arena_bytes = max(
			ctx.stats_current.peak_uniform_arena_bytes,
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

SetCustomBlend :: proc(src, dst: BlendFactorRL, op: BlendOpRL) {
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
