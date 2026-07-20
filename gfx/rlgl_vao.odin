// ingot:gfx — raw rlgl vertex-array / instanced-draw backing over WebGPU. The
// galaxy's 2D bubble/node/star fields and 3D starfields are drawn as GPU
// instanced quads through the low-level rlgl API (LoadVertexArray, per-vertex
// and per-instance attributes via SetVertexAttribute(+Divisor), then
// DrawVertexArrayInstanced). This records a real VAO (buffers + attribute
// layout) and issues an instanced draw with the shader bound by EnableShader.
//
// The custom shaders used here (glow2d/node2d/star2d/...) declare their uniform
// block as `struct U { ... }; @group(0) @binding(0) var<uniform> u: U;` and take
// vertex attributes at the @location indices matching SetVertexAttribute. No
// textures are sampled (the fields are procedural), so only group(0) is bound.
package gfx

import wg "vendor:wgpu"

@(private)
Vao_Attr :: struct {
	location:   u32,
	comps:      u32,
	offset:     u32,
	stride:     u32,
	buffer_idx: int,
	divisor:    u32,
}

@(private)
Vao_Buffer :: struct {
	id:  u32, // global VBO id
	buf: wg.Buffer,
}

@(private)
Vao_PipeCache :: struct {
	shader_id: u32,
	format:    wg.TextureFormat,
	blend:     Blend_Slot,
	pipe:      wg.RenderPipeline,
}

@(private)
Vao :: struct {
	buffers:    [dynamic]Vao_Buffer,
	attrs:      [dynamic]Vao_Attr,
	cur_buffer: int,
	caches:     [dynamic]Vao_PipeCache,
}

@(private) g_vaos: [dynamic]^Vao
@(private) g_vbos: [dynamic]wg.Buffer // global VBO registry (id = index+1)
@(private) g_cur_vao: int             // bound VAO id (0 = none)
@(private) g_inst_shader: u32         // shader bound via EnableShader

@(private)
_vao_get :: proc(id: int) -> ^Vao {
	if id <= 0 || id > len(g_vaos) do return nil
	return g_vaos[id - 1]
}

// --- VAO / VBO lifecycle ----------------------------------------------------

RlLoadVertexArray :: proc() -> u32 {
	v := new(Vao)
	append(&g_vaos, v)
	return u32(len(g_vaos))
}

RlEnableVertexArray :: proc(id: u32) -> bool {
	if _vao_get(int(id)) == nil do return false
	g_cur_vao = int(id)
	return true
}

RlDisableVertexArray :: proc() { g_cur_vao = 0 }

RlUnloadVertexArray :: proc(id: u32) {
	v := _vao_get(int(id))
	if v == nil do return
	for c in v.caches {
		if c.pipe != nil do wg.RenderPipelineRelease(c.pipe)
	}
	delete(v.buffers)
	delete(v.attrs)
	delete(v.caches)
	free(v)
	g_vaos[id - 1] = nil
	if g_cur_vao == int(id) do g_cur_vao = 0
}

RlLoadVertexBuffer :: proc(data: rawptr, size: i32, dynamic_buf: bool) -> u32 {
	usage: wg.BufferUsageFlags = {.Vertex, .CopyDst}
	buf := wg.DeviceCreateBuffer(g.device, &{usage = usage, size = u64(max(size, 4))})
	if data != nil && size > 0 {
		wg.QueueWriteBuffer(g.queue, buf, 0, data, uint(size))
	}
	append(&g_vbos, buf)
	id := u32(len(g_vbos))
	// link into the currently-bound VAO
	if v := _vao_get(g_cur_vao); v != nil {
		append(&v.buffers, Vao_Buffer{id = id, buf = buf})
		v.cur_buffer = len(v.buffers) - 1
	}
	return id
}

RlUpdateVertexBuffer :: proc(bufferId: u32, data: rawptr, dataSize: i32, offset: i32) {
	if bufferId == 0 || int(bufferId) > len(g_vbos) do return
	buf := g_vbos[bufferId - 1]
	if buf == nil || data == nil || dataSize <= 0 do return
	wg.QueueWriteBuffer(g.queue, buf, u64(offset), data, uint(dataSize))
}

RlUnloadVertexBuffer :: proc(vboId: u32) {
	if vboId == 0 || int(vboId) > len(g_vbos) do return
	buf := g_vbos[vboId - 1]
	if buf != nil {
		wg.BufferRelease(buf)
		g_vbos[vboId - 1] = nil
	}
	// Detach this buffer from every VAO that references it. Without this the
	// stale Vao_Buffer slot (and its attributes) would linger; a subsequent
	// LoadVertexBuffer + re-setup would append duplicate shaderLocations and
	// wgpu would reject the resulting pipeline (an uncaptured validation error
	// that aborts the process).
	for v in g_vaos {
		if v == nil do continue
		k := -1
		for b, i in v.buffers {
			if b.id == vboId {
				k = i
				break
			}
		}
		if k < 0 do continue

		ordered_remove(&v.buffers, k)

		// Drop attributes bound to the removed buffer; reindex those after it.
		for i := len(v.attrs) - 1; i >= 0; i -= 1 {
			if v.attrs[i].buffer_idx == k {
				ordered_remove(&v.attrs, i)
			} else if v.attrs[i].buffer_idx > k {
				v.attrs[i].buffer_idx -= 1
			}
		}

		if v.cur_buffer > k {
			v.cur_buffer -= 1
		} else if v.cur_buffer == k {
			v.cur_buffer = len(v.buffers) - 1
		}

		// The buffer set changed, so any cached pipelines are stale.
		for c in v.caches {
			if c.pipe != nil do wg.RenderPipelineRelease(c.pipe)
		}
		clear(&v.caches)
	}
}

// --- attribute recording ----------------------------------------------------

RlSetVertexAttribute :: proc(index: u32, compSize: i32, type: i32, normalized: bool, stride: i32, offset: i32) {
	v := _vao_get(g_cur_vao)
	if v == nil do return
	attr := Vao_Attr{
		location   = index,
		comps      = u32(clamp(compSize, 1, 4)),
		offset     = u32(offset),
		stride     = u32(stride),
		buffer_idx = v.cur_buffer,
		divisor    = 0,
	}
	// Overwrite an existing attribute at the same shaderLocation instead of
	// appending (matches glVertexAttribPointer semantics). Appending would let
	// a re-setup path register the same location twice, producing an invalid
	// wgpu vertex layout.
	for &a in v.attrs {
		if a.location == index {
			a = attr
			return
		}
	}
	append(&v.attrs, attr)
}

RlSetVertexAttributeDivisor :: proc(index: u32, divisor: i32) {
	v := _vao_get(g_cur_vao)
	if v == nil do return
	for &a in v.attrs {
		if a.location == index do a.divisor = u32(divisor)
	}
}

RlEnableVertexAttribute :: proc(index: u32) {}

// --- shader binding ---------------------------------------------------------

RlEnableInstShader :: proc(id: u32) { g_inst_shader = id }
RlDisableInstShader :: proc() { g_inst_shader = 0 }

// --- instanced draw ---------------------------------------------------------

@(private)
_vf_for_comps :: proc(comps: u32) -> wg.VertexFormat {
	switch comps {
	case 1: return .Float32
	case 2: return .Float32x2
	case 3: return .Float32x3
	case 4: return .Float32x4
	}
	return .Float32x2
}

// _vao_pipeline builds (and caches) the instanced pipeline for the given VAO
// layout + shader + current target format + blend.
@(private)
_vao_pipeline :: proc(v: ^Vao, se: ^Shader_Entry, format: wg.TextureFormat, blend: Blend_Slot) -> wg.RenderPipeline {
	for c in v.caches {
		if c.shader_id == g_inst_shader && c.format == format && c.blend == blend do return c.pipe
	}
	// build one VertexBufferLayout per VAO buffer, grouping its attributes.
	nbuf := len(v.buffers)
	if nbuf == 0 do return nil
	// per-buffer attribute storage (kept alive through pipeline creation)
	attr_store := make([][dynamic]wg.VertexAttribute, nbuf, context.temp_allocator)
	strides := make([]u32, nbuf, context.temp_allocator)
	stepmodes := make([]wg.VertexStepMode, nbuf, context.temp_allocator)
	for i in 0 ..< nbuf { stepmodes[i] = .Vertex }
	for a in v.attrs {
		if a.buffer_idx < 0 || a.buffer_idx >= nbuf do continue
		append(&attr_store[a.buffer_idx], wg.VertexAttribute{
			format = _vf_for_comps(a.comps), offset = u64(a.offset), shaderLocation = a.location,
		})
		strides[a.buffer_idx] = a.stride
		if a.divisor > 0 do stepmodes[a.buffer_idx] = .Instance
	}
	layouts := make([]wg.VertexBufferLayout, nbuf, context.temp_allocator)
	for i in 0 ..< nbuf {
		layouts[i] = {
			arrayStride = u64(strides[i]),
			stepMode = stepmodes[i],
			attributeCount = uint(len(attr_store[i])),
			attributes = raw_data(attr_store[i][:]),
		}
	}

	bl := _blend_for(&g.rend, blend)
	target := wg.ColorTargetState{format = format, blend = &bl, writeMask = wg.ColorWriteMaskFlags_All}
	gl := [1]wg.BindGroupLayout{se.u_layout}
	pl := wg.DeviceCreatePipelineLayout(g.device, &{
		bindGroupLayoutCount = 1, bindGroupLayouts = raw_data(gl[:]),
	})
	pipe := wg.DeviceCreateRenderPipeline(g.device, &{
		layout = pl,
		vertex = {module = se.module, entryPoint = "vs_main", bufferCount = uint(nbuf), buffers = raw_data(layouts)},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
		multisample = {count = 1, mask = ~u32(0)},
		fragment = &wg.FragmentState{module = se.module, entryPoint = "fs_main", targetCount = 1, targets = &target},
	})
	append(&v.caches, Vao_PipeCache{shader_id = g_inst_shader, format = format, blend = blend, pipe = pipe})
	return pipe
}

RlDrawVertexArrayInstanced :: proc(offset, count, instances: i32) {
	if instances <= 0 || count <= 0 do return
	v := _vao_get(g_cur_vao)
	se := _shader_get(g_inst_shader)
	if v == nil || se == nil do return
	if !g.frame.has_frame do return
	_ensure_active_pass()
	if !_active_pass_begun() do return
	// order any pending batch geometry before the raw instanced draw
	renderer_flush(&g.rend, active_pass())

	pass := active_pass()
	pipe := _vao_pipeline(v, se, _cur_target_format(), g.rend.cur_blend)
	if pipe == nil do return

	if len(se.ushadow) > 0 {
		wg.QueueWriteBuffer(g.queue, se.ubuf, 0, raw_data(se.ushadow), uint(len(se.ushadow)))
	}
	wg.RenderPassEncoderSetPipeline(pass, pipe)
	wg.RenderPassEncoderSetBindGroup(pass, 0, se.ubind)
	for b, i in v.buffers {
		if b.buf != nil {
			wg.RenderPassEncoderSetVertexBuffer(pass, u32(i), b.buf, 0, wg.WHOLE_SIZE)
		}
	}
	wg.RenderPassEncoderDraw(pass, u32(count), u32(instances), u32(offset), 0)
}

RlDrawVertexArrayElementsInstanced :: proc(offset, count: i32, buffer: rawptr, instances: i32) {
	// Galaxy uses the non-indexed instanced path; indexed instancing is not yet
	// wired. No-op keeps the API total.
}
