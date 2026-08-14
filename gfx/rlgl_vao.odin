// ingot:gfx - raw rlgl vertex-array / instanced-draw backing over WebGPU. The
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

RLGL_MAX_VAOS :: 256
RLGL_MAX_VBOS :: 1024
RLGL_MAX_BUFFERS_PER_VAO :: 16
RLGL_MAX_ATTRIBUTES_PER_VAO :: 32
RLGL_MAX_PIPELINES_PER_VAO :: 32

#assert(RLGL_MAX_VAOS <= RESOURCE_SLOT_COUNT)
#assert(RLGL_MAX_VBOS <= RESOURCE_SLOT_COUNT)

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
	id:   u32, // global VBO id
	buf:  wg.Buffer,
	size: u64,
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

@(private)
Vao_Slot :: struct {
	entry:      ^Vao,
	generation: u32,
	occupied:   bool,
}

@(private)
Vbo_Slot :: struct {
	buffer:     wg.Buffer,
	generation: u32,
	occupied:   bool,
}

Rlgl_Resources :: struct {
	vaos:        [RLGL_MAX_VAOS]Vao_Slot,
	vbos:        [RLGL_MAX_VBOS]Vbo_Slot,
	vao_count:   u32,
	vbo_count:   u32,
	current_vao: u32,
	inst_shader: u32,
}

@(private)
_vao_slot :: proc(context_id: u32, resources: ^Rlgl_Resources, id: u32) -> ^Vao_Slot {
	assert(context_id != 0, "_vao_slot: zero context id")
	assert(resources != nil, "_vao_slot: nil resources")
	handle_context := (id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(id, len(resources.vaos))
	if !ok do return nil
	slot := &resources.vaos[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
context_vao_get :: proc(ctx: ^Context, id: u32) -> ^Vao {
	assert(ctx != nil, "context_vao_get: nil context")
	slot := _vao_slot(ctx.id, &ctx.resources.rlgl, id)
	if slot == nil do return nil
	return slot.entry
}

@(private)
_vbo_slot :: proc(context_id: u32, resources: ^Rlgl_Resources, id: u32) -> ^Vbo_Slot {
	assert(context_id != 0, "_vbo_slot: zero context id")
	assert(resources != nil, "_vbo_slot: nil resources")
	handle_context := (id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(id, len(resources.vbos))
	if !ok do return nil
	slot := &resources.vbos[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_vao_invalidate_caches :: proc(v: ^Vao) {
	assert(v != nil)
	assert(len(v.caches) >= 0)
	for c in v.caches {
		if c.pipe != nil do wg.RenderPipelineRelease(c.pipe)
	}
	clear(&v.caches)
	assert(len(v.caches) == 0)
}

// --- VAO / VBO lifecycle ----------------------------------------------------

ContextRlLoadVertexArray :: proc(ctx: ^Context) -> u32 {
	assert(ctx != nil, "ContextRlLoadVertexArray: nil context")
	resources := &ctx.resources.rlgl
	if resources.vao_count >= RLGL_MAX_VAOS do return 0
	for &slot, index in resources.vaos {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = new(Vao)
		slot.occupied = true
		resources.vao_count += 1
		return _resource_handle_make_context(ctx.id, index, slot.generation)
	}
	assert(false, "ContextRlLoadVertexArray: count mismatch")
	return 0
}

RlLoadVertexArray :: proc() -> u32 {
	return ContextRlLoadVertexArray(default_context())
}

ContextRlEnableVertexArray :: proc(ctx: ^Context, id: u32) -> bool {
	assert(ctx != nil, "ContextRlEnableVertexArray: nil context")
	if context_vao_get(ctx, id) == nil do return false
	ctx.resources.rlgl.current_vao = id
	return true
}

RlEnableVertexArray :: proc(id: u32) -> bool {
	return ContextRlEnableVertexArray(default_context(), id)
}

ContextRlDisableVertexArray :: proc(ctx: ^Context) {
	assert(ctx != nil, "ContextRlDisableVertexArray: nil context")
	ctx.resources.rlgl.current_vao = 0
}

RlDisableVertexArray :: proc() {
	ContextRlDisableVertexArray(default_context())
}

@(private)
_vao_entry_destroy :: proc(entry: ^Vao) {
	assert(entry != nil, "_vao_entry_destroy: nil entry")
	_vao_invalidate_caches(entry)
	delete(entry.buffers)
	delete(entry.attrs)
	delete(entry.caches)
	free(entry)
}

ContextRlUnloadVertexArray :: proc(ctx: ^Context, id: u32) {
	assert(ctx != nil, "ContextRlUnloadVertexArray: nil context")
	resources := &ctx.resources.rlgl
	slot := _vao_slot(ctx.id, resources, id)
	if slot == nil do return
	_vao_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(resources.vao_count > 0, "ContextRlUnloadVertexArray: count underflow")
	resources.vao_count -= 1
	if resources.current_vao == id do resources.current_vao = 0
}

RlUnloadVertexArray :: proc(id: u32) {
	ContextRlUnloadVertexArray(default_context(), id)
}

ContextRlLoadVertexBuffer :: proc(
	ctx: ^Context,
	data: rawptr,
	size: i32,
	dynamic_buf: bool,
) -> u32 {
	assert(ctx != nil, "ContextRlLoadVertexBuffer: nil context")
	if ctx.device == nil || size <= 0 do return 0
	resources := &ctx.resources.rlgl
	if resources.vbo_count >= RLGL_MAX_VBOS do return 0
	assert(size > 0)
	buffer_size := u64(size)
	usage: wg.BufferUsageFlags = {.Vertex, .CopyDst}
	buffer := wg.DeviceCreateBuffer(ctx.device, &{usage = usage, size = buffer_size})
	if buffer == nil do return 0
	if data != nil do wg.QueueWriteBuffer(ctx.queue, buffer, 0, data, uint(size))
	id: u32
	for &slot, index in resources.vbos {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.buffer = buffer
		slot.occupied = true
		resources.vbo_count += 1
		id = _resource_handle_make_context(ctx.id, index, slot.generation)
		break
	}
	assert(id > 0, "ContextRlLoadVertexBuffer: count mismatch")
	if v := context_vao_get(ctx, resources.current_vao);
	   v != nil && len(v.buffers) < RLGL_MAX_BUFFERS_PER_VAO {
		_vao_invalidate_caches(v)
		append(&v.buffers, Vao_Buffer{id = id, buf = buffer, size = buffer_size})
		v.cur_buffer = len(v.buffers) - 1
		assert(v.cur_buffer >= 0)
	}
	return id
}

RlLoadVertexBuffer :: proc(data: rawptr, size: i32, dynamic_buf: bool) -> u32 {
	return ContextRlLoadVertexBuffer(default_context(), data, size, dynamic_buf)
}

ContextRlUpdateVertexBuffer :: proc(
	ctx: ^Context,
	bufferId: u32,
	data: rawptr,
	dataSize: i32,
	offset: i32,
) {
	assert(ctx != nil, "ContextRlUpdateVertexBuffer: nil context")
	slot := _vbo_slot(ctx.id, &ctx.resources.rlgl, bufferId)
	if slot == nil || data == nil || dataSize <= 0 || offset < 0 do return
	wg.QueueWriteBuffer(ctx.queue, slot.buffer, u64(offset), data, uint(dataSize))
}

RlUpdateVertexBuffer :: proc(bufferId: u32, data: rawptr, dataSize: i32, offset: i32) {
	ContextRlUpdateVertexBuffer(default_context(), bufferId, data, dataSize, offset)
}

ContextRlUnloadVertexBuffer :: proc(ctx: ^Context, vboId: u32) {
	assert(ctx != nil, "ContextRlUnloadVertexBuffer: nil context")
	resources := &ctx.resources.rlgl
	slot := _vbo_slot(ctx.id, resources, vboId)
	if slot == nil do return
	wg.BufferRelease(slot.buffer)
	slot.buffer = nil
	slot.occupied = false
	assert(resources.vbo_count > 0, "RlUnloadVertexBuffer: count underflow")
	resources.vbo_count -= 1
	// Detach this buffer from every VAO that references it. Without this the
	// stale Vao_Buffer slot (and its attributes) would linger; a subsequent
	// LoadVertexBuffer + re-setup would append duplicate shaderLocations and
	// wgpu would reject the resulting pipeline (an uncaptured validation error
	// that aborts the process).
	for vao_slot in resources.vaos {
		if !vao_slot.occupied do continue
		v := vao_slot.entry
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

		_vao_invalidate_caches(v)
	}
}

RlUnloadVertexBuffer :: proc(vboId: u32) {
	ContextRlUnloadVertexBuffer(default_context(), vboId)
}

// --- attribute recording ----------------------------------------------------

ContextRlSetVertexAttribute :: proc(
	ctx: ^Context,
	index: u32,
	compSize: i32,
	type: i32,
	normalized: bool,
	stride: i32,
	offset: i32,
) {
	assert(ctx != nil, "ContextRlSetVertexAttribute: nil context")
	v := context_vao_get(ctx, ctx.resources.rlgl.current_vao)
	if v == nil || v.cur_buffer < 0 || v.cur_buffer >= len(v.buffers) do return
	if compSize < 1 || compSize > 4 || stride <= 0 || offset < 0 do return
	if offset + compSize * size_of(f32) > stride do return
	assert(v.buffers[v.cur_buffer].buf != nil)
	attr := Vao_Attr {
		location   = index,
		comps      = u32(compSize),
		offset     = u32(offset),
		stride     = u32(stride),
		buffer_idx = v.cur_buffer,
		divisor    = 0,
	}
	_vao_invalidate_caches(v)
	for &a in v.attrs {
		if a.location == index {
			a = attr
			return
		}
	}
	if len(v.attrs) >= RLGL_MAX_ATTRIBUTES_PER_VAO do return
	append(&v.attrs, attr)
	assert(len(v.attrs) > 0)
}

RlSetVertexAttribute :: proc(
	index: u32,
	compSize: i32,
	type: i32,
	normalized: bool,
	stride: i32,
	offset: i32,
) {
	ContextRlSetVertexAttribute(
		default_context(),
		index,
		compSize,
		type,
		normalized,
		stride,
		offset,
	)
}

ContextRlSetVertexAttributeDivisor :: proc(ctx: ^Context, index: u32, divisor: i32) {
	assert(ctx != nil, "ContextRlSetVertexAttributeDivisor: nil context")
	v := context_vao_get(ctx, ctx.resources.rlgl.current_vao)
	if v == nil || divisor < 0 do return
	assert(divisor >= 0)
	for &a in v.attrs {
		if a.location == index {
			if a.divisor != u32(divisor) do _vao_invalidate_caches(v)
			a.divisor = u32(divisor)
			return
		}
	}
}

RlSetVertexAttributeDivisor :: proc(index: u32, divisor: i32) {
	ContextRlSetVertexAttributeDivisor(default_context(), index, divisor)
}

RlEnableVertexAttribute :: proc(index: u32) {}

// --- shader binding ---------------------------------------------------------

ContextRlEnableInstShader :: proc(ctx: ^Context, id: u32) {
	assert(ctx != nil, "ContextRlEnableInstShader: nil context")
	ctx.resources.rlgl.inst_shader = id
}

RlEnableInstShader :: proc(id: u32) {
	ContextRlEnableInstShader(default_context(), id)
}

ContextRlDisableInstShader :: proc(ctx: ^Context) {
	assert(ctx != nil, "ContextRlDisableInstShader: nil context")
	ctx.resources.rlgl.inst_shader = 0
}

RlDisableInstShader :: proc() {
	ContextRlDisableInstShader(default_context())
}

// --- instanced draw ---------------------------------------------------------

@(private)
_vf_for_comps :: proc(comps: u32) -> wg.VertexFormat {
	switch comps {
	case 1:
		return .Float32
	case 2:
		return .Float32x2
	case 3:
		return .Float32x3
	case 4:
		return .Float32x4
	}
	return .Float32x2
}

@(private)
_vao_layout_valid :: proc(v: ^Vao) -> bool {
	if v == nil || len(v.buffers) == 0 || len(v.attrs) == 0 do return false
	assert(len(v.buffers) > 0)
	assert(len(v.attrs) > 0)
	assert(len(v.buffers) <= RLGL_MAX_BUFFERS_PER_VAO)
	seen: [32]bool
	strides: [RLGL_MAX_BUFFERS_PER_VAO]u32
	for b in v.buffers {
		if b.id == 0 || b.buf == nil || b.size == 0 do return false
	}
	for a in v.attrs {
		if a.location >= u32(len(seen)) || seen[a.location] do return false
		if a.buffer_idx < 0 || a.buffer_idx >= len(v.buffers) do return false
		if a.comps < 1 || a.comps > 4 || a.stride == 0 || a.stride % 4 != 0 do return false
		if a.offset % 4 != 0 || a.offset + a.comps * 4 > a.stride do return false
		if strides[a.buffer_idx] != 0 && strides[a.buffer_idx] != a.stride do return false
		strides[a.buffer_idx] = a.stride
		seen[a.location] = true
	}
	for stride in strides[:len(v.buffers)] {
		if stride == 0 do return false
	}
	return true
}

// _vao_pipeline builds (and caches) the instanced pipeline for the given VAO
// layout + shader + current target format + blend.
@(private)
_vao_pipeline :: proc(
	ctx: ^Context,
	v: ^Vao,
	se: ^Shader_Entry,
	format: wg.TextureFormat,
	blend: Blend_Slot,
) -> wg.RenderPipeline {
	assert(ctx != nil, "_vao_pipeline: nil context")
	if v == nil || se == nil || !_vao_layout_valid(v) do return nil
	assert(len(v.buffers) > 0)
	assert(len(v.attrs) > 0)
	for cache in v.caches {
		if cache.shader_id == ctx.resources.rlgl.inst_shader &&
		   cache.format == format &&
		   cache.blend == blend {
			return cache.pipe
		}
	}
	if len(v.caches) >= RLGL_MAX_PIPELINES_PER_VAO do return nil
	nbuf := len(v.buffers)
	ensure(nbuf <= RLGL_MAX_BUFFERS_PER_VAO)
	attr_store: [RLGL_MAX_BUFFERS_PER_VAO][RLGL_MAX_ATTRIBUTES_PER_VAO]wg.VertexAttribute
	attr_counts: [RLGL_MAX_BUFFERS_PER_VAO]u32
	strides: [RLGL_MAX_BUFFERS_PER_VAO]u32
	stepmodes: [RLGL_MAX_BUFFERS_PER_VAO]wg.VertexStepMode
	layouts: [RLGL_MAX_BUFFERS_PER_VAO]wg.VertexBufferLayout
	for i in 0 ..< nbuf {stepmodes[i] = .Vertex}
	for a in v.attrs {
		attribute_index := attr_counts[a.buffer_idx]
		ensure(attribute_index < RLGL_MAX_ATTRIBUTES_PER_VAO)
		attr_store[a.buffer_idx][attribute_index] = {
			format         = _vf_for_comps(a.comps),
			offset         = u64(a.offset),
			shaderLocation = a.location,
		}
		attr_counts[a.buffer_idx] += 1
		strides[a.buffer_idx] = a.stride
		if a.divisor > 0 do stepmodes[a.buffer_idx] = .Instance
	}
	for i in 0 ..< nbuf {
		if strides[i] == 0 || attr_counts[i] == 0 do return nil
		layouts[i] = {
			arrayStride    = u64(strides[i]),
			stepMode       = stepmodes[i],
			attributeCount = uint(attr_counts[i]),
			attributes     = raw_data(attr_store[i][:attr_counts[i]]),
		}
	}

	bl := _blend_for(&ctx.rend, blend)
	target := wg.ColorTargetState {
		format    = format,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	if _format_blendable(format) do target.blend = &bl
	gl := [1]wg.BindGroupLayout{se.u_layout}
	pl := wg.DeviceCreatePipelineLayout(
		ctx.device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = raw_data(gl[:])},
	)
	pipe := wg.DeviceCreateRenderPipeline(
		ctx.device,
		&{
			layout = pl,
			vertex = {
				module = se.module,
				entryPoint = "vs_main",
				bufferCount = uint(nbuf),
				buffers = raw_data(layouts[:nbuf]),
			},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .None},
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &wg.FragmentState {
				module = se.module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(pl)
	append(
		&v.caches,
		Vao_PipeCache {
			shader_id = ctx.resources.rlgl.inst_shader,
			format = format,
			blend = blend,
			pipe = pipe,
		},
	)
	return pipe
}

ContextRlDrawVertexArrayInstanced :: proc(ctx: ^Context, offset, count, instances: i32) {
	assert(ctx != nil, "ContextRlDrawVertexArrayInstanced: nil context")
	if instances <= 0 || count <= 0 || offset < 0 do return
	v := context_vao_get(ctx, ctx.resources.rlgl.current_vao)
	se := context_shader_get(ctx, ctx.resources.rlgl.inst_shader)
	if v == nil || se == nil || !_vao_layout_valid(v) do return
	if !ctx.frame.has_frame || ctx.frame.scissor_empty do return
	assert(len(v.buffers) > 0)
	assert(len(v.attrs) > 0)
	context_ensure_active_pass(ctx)
	if !context_active_pass_begun(ctx) do return
	renderer_flush(ctx, &ctx.rend, context_active_pass(ctx))

	pass := context_active_pass(ctx)
	pipe := _vao_pipeline(ctx, v, se, _cur_target_format(ctx), ctx.rend.cur_blend)
	if pipe == nil do return

	u_offset, ok := _uniform_upload(ctx, &ctx.rend, raw_data(se.ushadow), u64(len(se.ushadow)))
	if !ok || ctx.rend.active_stream_slot < 0 do return
	wg.RenderPassEncoderSetPipeline(pass, pipe)
	_stats_pipeline_switch(ctx)
	wg.RenderPassEncoderSetBindGroup(pass, 0, se.u_bind[ctx.rend.active_stream_slot], {u_offset})
	_stats_bind_group_switches(ctx, 1)
	for b, i in v.buffers {
		if b.buf == nil || b.size == 0 do return
		wg.RenderPassEncoderSetVertexBuffer(pass, u32(i), b.buf, 0, b.size)
	}
	wg.RenderPassEncoderDraw(pass, u32(count), u32(instances), u32(offset), 0)
}

RlDrawVertexArrayInstanced :: proc(offset, count, instances: i32) {
	ContextRlDrawVertexArrayInstanced(default_context(), offset, count, instances)
}

RlDrawVertexArrayElementsInstanced :: proc(offset, count: i32, buffer: rawptr, instances: i32) {
	// Galaxy uses the non-indexed instanced path; indexed instancing is not yet
	// wired. No-op keeps the API total.
}

@(private)
_rlgl_resources_destroy :: proc(resources: ^Rlgl_Resources) {
	assert(resources != nil, "_rlgl_resources_destroy: nil resources")
	for &slot in resources.vaos {
		if slot.occupied do _vao_entry_destroy(slot.entry)
	}
	for slot in resources.vbos {
		if slot.occupied && slot.buffer != nil do wg.BufferRelease(slot.buffer)
	}
	resources^ = {}
}
