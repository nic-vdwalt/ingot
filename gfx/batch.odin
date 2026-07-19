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

Renderer :: struct {
	solid_pipe: wg.RenderPipeline,
	text_pipe:  wg.RenderPipeline,
	image_pipe: wg.RenderPipeline,

	ubuf:         wg.Buffer,
	ubind:        wg.BindGroup,
	ubind_layout: wg.BindGroupLayout,
	tex_layout:   wg.BindGroupLayout, // group(1): texture + sampler

	// current run
	verts:    [dynamic]Vertex,
	cur_kind: Pipe_Kind,
	cur_bind: wg.BindGroup,

	// transient per-frame vertex buffers (released at next frame begin)
	frame_buffers: [dynamic]wg.Buffer,

	proj_w, proj_h: i32,
}

BATCH_SHADER := `
struct Uniforms { inv: vec2<f32> };
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VSOut {
	@builtin(position) pos: vec4<f32>,
	@location(0) col: vec4<f32>,
	@location(1) uv: vec2<f32>,
};

@vertex
fn vs_main(@location(0) pos: vec2<f32>, @location(1) col: vec4<f32>, @location(2) uv: vec2<f32>) -> VSOut {
	var o: VSOut;
	let ndc = vec2<f32>(pos.x * u.inv.x * 2.0 - 1.0, 1.0 - pos.y * u.inv.y * 2.0);
	o.pos = vec4<f32>(ndc, 0.0, 1.0);
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
	defer wg.ShaderModuleRelease(shader)

	// group(0): projection uniform
	r.ubind_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 1,
		entries = &wg.BindGroupLayoutEntry{
			binding = 0,
			visibility = {.Vertex},
			buffer = {type = .Uniform, minBindingSize = size_of([2]f32)},
		},
	})
	r.ubuf = wg.DeviceCreateBuffer(g.device, &{usage = {.Uniform, .CopyDst}, size = size_of([2]f32)})
	r.ubind = wg.DeviceCreateBindGroup(g.device, &{
		layout = r.ubind_layout,
		entryCount = 1,
		entries = &wg.BindGroupEntry{binding = 0, buffer = r.ubuf, size = size_of([2]f32)},
	})

	// group(1): texture + sampler (used by text + image pipelines)
	tex_entries := [2]wg.BindGroupLayoutEntry{
		{binding = 0, visibility = {.Fragment}, texture = {sampleType = .Float, viewDimension = ._2D}},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	r.tex_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 2, entries = raw_data(tex_entries[:]),
	})

	attrs := [3]wg.VertexAttribute{
		{format = .Float32x2, offset = 0, shaderLocation = 0},
		{format = .Float32x4, offset = u64(offset_of(Vertex, col)), shaderLocation = 1},
		{format = .Float32x2, offset = u64(offset_of(Vertex, uv)), shaderLocation = 2},
	}
	vbl := wg.VertexBufferLayout{
		arrayStride = size_of(Vertex), stepMode = .Vertex,
		attributeCount = 3, attributes = raw_data(attrs[:]),
	}
	// premultiplied-alpha blending (shaders output premultiplied rgb)
	blend := wg.BlendState{
		color = {srcFactor = .One, dstFactor = .OneMinusSrcAlpha, operation = .Add},
		alpha = {srcFactor = .One, dstFactor = .OneMinusSrcAlpha, operation = .Add},
	}
	target := wg.ColorTargetState{format = g.format, blend = &blend, writeMask = wg.ColorWriteMaskFlags_All}

	make_pipe :: proc(r: ^Renderer, shader: wg.ShaderModule, vbl: ^wg.VertexBufferLayout, target: ^wg.ColorTargetState, fs: string, textured: bool) -> wg.RenderPipeline {
		layouts := [2]wg.BindGroupLayout{r.ubind_layout, r.tex_layout}
		pl := wg.DeviceCreatePipelineLayout(g.device, &{
			bindGroupLayoutCount = textured ? 2 : 1,
			bindGroupLayouts = raw_data(layouts[:]),
		})
		return wg.DeviceCreateRenderPipeline(g.device, &{
			layout = pl,
			vertex = {module = shader, entryPoint = "vs_main", bufferCount = 1, buffers = vbl},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &wg.FragmentState{module = shader, entryPoint = fs, targetCount = 1, targets = target},
		})
	}

	r.solid_pipe = make_pipe(r, shader, &vbl, &target, "fs_solid", false)
	r.text_pipe  = make_pipe(r, shader, &vbl, &target, "fs_text", true)
	r.image_pipe = make_pipe(r, shader, &vbl, &target, "fs_image", true)

	r.cur_kind = .Solid
}

renderer_shutdown :: proc(r: ^Renderer) {
	for b in r.frame_buffers do wg.BufferRelease(b)
	delete(r.frame_buffers)
	delete(r.verts)
	if r.solid_pipe != nil do wg.RenderPipelineRelease(r.solid_pipe)
	if r.text_pipe != nil do wg.RenderPipelineRelease(r.text_pipe)
	if r.image_pipe != nil do wg.RenderPipelineRelease(r.image_pipe)
	if r.ubind != nil do wg.BindGroupRelease(r.ubind)
	if r.ubuf != nil do wg.BufferRelease(r.ubuf)
	if r.ubind_layout != nil do wg.BindGroupLayoutRelease(r.ubind_layout)
	if r.tex_layout != nil do wg.BindGroupLayoutRelease(r.tex_layout)
}

renderer_frame_begin :: proc(r: ^Renderer) {
	// release previous frame's transient vertex buffers
	for b in r.frame_buffers do wg.BufferRelease(b)
	clear(&r.frame_buffers)
	clear(&r.verts)
	r.cur_kind = .Solid
	r.cur_bind = nil

	// keep projection in sync with the logical window size
	if r.proj_w != g.width || r.proj_h != g.height {
		inv := [2]f32{1.0 / f32(max(g.width, 1)), 1.0 / f32(max(g.height, 1))}
		wg.QueueWriteBuffer(g.queue, r.ubuf, 0, &inv, size_of(inv))
		r.proj_w, r.proj_h = g.width, g.height
	}
}

// batch_set switches the active pipeline/texture, flushing the pending run
// first if the state differs.
@(private)
batch_set :: proc(r: ^Renderer, kind: Pipe_Kind, bind: wg.BindGroup) {
	_ensure_pass()
	if kind != r.cur_kind || bind != r.cur_bind {
		if g.frame.pass_begun do renderer_flush(r, g.frame.pass)
		r.cur_kind = kind
		r.cur_bind = bind
	}
}

// push_quad emits two triangles for rect `d` sampling uv rect `s`.
@(private)
push_quad :: proc(r: ^Renderer, d: Rectangle, s: Rectangle, col: [4]f32) {
	if !g.frame.has_frame || g.frame.tex_mode do return
	x0, y0 := d.x, d.y
	x1, y1 := d.x + d.width, d.y + d.height
	u0, v0 := s.x, s.y
	u1, v1 := s.x + s.width, s.y + s.height
	append(&r.verts,
		Vertex{{x0, y0}, col, {u0, v0}},
		Vertex{{x0, y1}, col, {u0, v1}},
		Vertex{{x1, y0}, col, {u1, v0}},
		Vertex{{x1, y0}, col, {u1, v0}},
		Vertex{{x0, y1}, col, {u0, v1}},
		Vertex{{x1, y1}, col, {u1, v1}},
	)
}

@(private)
push_tri :: proc(r: ^Renderer, a, b, c: [2]f32, col: [4]f32) {
	if !g.frame.has_frame || g.frame.tex_mode do return
	append(&r.verts,
		Vertex{a, col, {0, 0}},
		Vertex{b, col, {0, 0}},
		Vertex{c, col, {0, 0}},
	)
}

// push_quad4 emits an arbitrary (possibly rotated) quad with per-corner uv.
// Corners must be given in order tl, tr, br, bl.
@(private)
push_quad4 :: proc(r: ^Renderer, tl, tr, br, bl: [2]f32, uv_tl, uv_tr, uv_br, uv_bl: [2]f32, col: [4]f32) {
	if !g.frame.has_frame || g.frame.tex_mode do return
	append(&r.verts,
		Vertex{tl, col, uv_tl},
		Vertex{bl, col, uv_bl},
		Vertex{tr, col, uv_tr},
		Vertex{tr, col, uv_tr},
		Vertex{bl, col, uv_bl},
		Vertex{br, col, uv_br},
	)
}

renderer_flush :: proc(r: ^Renderer, pass: wg.RenderPassEncoder) {
	n := len(r.verts)
	if n == 0 do return

	vbuf := wg.DeviceCreateBufferWithData(g.device, &{usage = {.Vertex}}, r.verts[:])
	append(&r.frame_buffers, vbuf)

	switch r.cur_kind {
	case .Solid:
		wg.RenderPassEncoderSetPipeline(pass, r.solid_pipe)
	case .Text:
		wg.RenderPassEncoderSetPipeline(pass, r.text_pipe)
	case .Image:
		wg.RenderPassEncoderSetPipeline(pass, r.image_pipe)
	}
	wg.RenderPassEncoderSetBindGroup(pass, 0, r.ubind)
	if r.cur_kind != .Solid && r.cur_bind != nil {
		wg.RenderPassEncoderSetBindGroup(pass, 1, r.cur_bind)
	}
	wg.RenderPassEncoderSetVertexBuffer(pass, 0, vbuf, 0, u64(n * size_of(Vertex)))
	wg.RenderPassEncoderDraw(pass, u32(n), 1, 0, 0)

	clear(&r.verts)
}

// col_f converts an 8-bit Color to normalized rgba for the vertex stream.
@(private)
col_f :: proc(c: Color) -> [4]f32 {
	return {f32(c.r) / 255.0, f32(c.g) / 255.0, f32(c.b) / 255.0, f32(c.a) / 255.0}
}
