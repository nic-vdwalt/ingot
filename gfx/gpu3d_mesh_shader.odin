package gfx

import wg "vendor:wgpu"

context_gpu_mesh_available_slots :: proc(ctx: ^Context) -> int {
	assert(ctx != nil, "context_gpu_mesh_available_slots: nil context")
	if !ctx.initialized do return 0
	count := int(ctx.resources.gpu_3d.mesh_count)
	assert(count >= 0 && count <= GPU_3D_MAX_MESHES, "GPU mesh count out of range")
	return GPU_3D_MAX_MESHES - count
}

gpu_mesh_available_slots :: proc() -> int {
	return context_gpu_mesh_available_slots(default_context())
}

context_create_gpu_mesh :: proc(
	ctx: ^Context,
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
	primitive: Gpu_Primitive = .Triangles,
) -> (
	Gpu_Mesh,
	bool,
) {
	assert(ctx != nil, "context_create_gpu_mesh: nil context")
	if !ctx.initialized || !_gpu_3d_geometry_valid(vertices, indices, primitive) do return {}, false
	resources := &ctx.resources.gpu_3d
	if resources.mesh_count >= GPU_3D_MAX_MESHES {
		_stats_gpu3d_pool_exhaustion(ctx)
		return {}, false
	}
	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(
		ctx,
		raw_data(vertices),
		u64(len(vertices)) * size_of(Gpu_3D_Vertex),
		{.Vertex},
	)
	entry.index_buffer = _gpu_3d_buffer(
		ctx,
		raw_data(indices),
		u64(len(indices)) * size_of(u32),
		{.Index},
	)
	entry.index_count = u32(len(indices))
	entry.vertex_count = u32(len(vertices))
	entry.primitive = primitive
	if entry.vertex_buffer == nil || entry.index_buffer == nil {
		if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
		if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
		free(entry)
		return {}, false
	}
	for &slot, index in resources.meshes {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.entry = entry
		slot.occupied = true
		resources.mesh_count += 1
		_stats_gpu3d_mesh_upload(ctx, entry.vertex_count, entry.index_count)
		return Gpu_Mesh{id = _resource_handle_make_context(ctx.id, index, slot.generation)}, true
	}
	assert(false, "context_create_gpu_mesh: count mismatch")
	return {}, false
}

create_gpu_mesh :: proc(
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
	primitive: Gpu_Primitive = .Triangles,
) -> (
	Gpu_Mesh,
	bool,
) {
	return context_create_gpu_mesh(default_context(), vertices, indices, primitive)
}

// update_gpu_mesh_vertices rewrites an existing mesh's vertex buffer in place,
// keeping its index buffer, primitive, and handle. Deforming geometry - a water
// surface, a cloth, a morphing blend shape - changes positions and normals every
// frame while its topology never moves, so destroying and recreating the mesh
// would release and reallocate a GPU buffer per frame and burn a pool slot's
// generation for nothing.
//
// The vertex count is deliberately fixed at creation: a resize is a different
// mesh, and allowing one here would mean silently reallocating the buffer behind
// a caller that believes it is writing into the geometry it built.
context_update_gpu_mesh_vertices :: proc(
	ctx: ^Context,
	mesh: Gpu_Mesh,
	vertices: []Gpu_3D_Vertex,
) -> bool {
	assert(ctx != nil, "context_update_gpu_mesh_vertices: nil context")
	if !ctx.initialized || len(vertices) == 0 do return false
	entry := _gpu_3d_mesh(ctx.id, &ctx.resources.gpu_3d, mesh)
	if entry == nil do return false
	if u32(len(vertices)) != entry.vertex_count do return false
	assert(entry.vertex_buffer != nil, "update_gpu_mesh_vertices: mesh without a buffer")
	bytes := uint(len(vertices)) * size_of(Gpu_3D_Vertex)
	assert(bytes > 0, "update_gpu_mesh_vertices: empty write")
	wg.QueueWriteBuffer(ctx.queue, entry.vertex_buffer, 0, raw_data(vertices), bytes)
	_stats_gpu3d_mesh_upload(ctx, entry.vertex_count, entry.index_count)
	return true
}

update_gpu_mesh_vertices :: proc(mesh: Gpu_Mesh, vertices: []Gpu_3D_Vertex) -> bool {
	return context_update_gpu_mesh_vertices(default_context(), mesh, vertices)
}

context_destroy_gpu_mesh :: proc(ctx: ^Context, mesh: ^Gpu_Mesh) {
	assert(ctx != nil, "context_destroy_gpu_mesh: nil context")
	assert(mesh != nil)
	slot := _gpu_3d_mesh_slot(ctx.id, &ctx.resources.gpu_3d, mesh^)
	if slot == nil {
		mesh^ = {}
		return
	}
	_gpu_3d_mesh_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(ctx.resources.gpu_3d.mesh_count > 0, "context_destroy_gpu_mesh: count underflow")
	ctx.resources.gpu_3d.mesh_count -= 1
	mesh^ = {}
	assert(mesh.id == 0)
}

destroy_gpu_mesh :: proc(mesh: ^Gpu_Mesh) {
	context_destroy_gpu_mesh(default_context(), mesh)
}

// create_gpu_3d_shader registers a custom WGSL module for use in
// Gpu_Material.shader. The code must declare the same bind groups, vertex
// attributes, and vs_main/fs_main entry points as GPU_3D_SHADER; pipeline
// validation failures surface as skipped draws, not crashes. Pool
// exhaustion is an operating condition: ok=false, counted.
context_create_gpu_3d_shader :: proc(ctx: ^Context, code: string) -> (Gpu_3D_Shader, bool) {
	assert(ctx != nil, "context_create_gpu_3d_shader: nil context")
	if !ctx.initialized || len(code) == 0 do return {}, false
	resources := &ctx.resources.gpu_3d
	if resources.shader_count >= GPU_3D_MAX_SHADERS {
		_stats_gpu3d_pool_exhaustion(ctx)
		return {}, false
	}
	module := wg.DeviceCreateShaderModule(
		ctx.device,
		&{nextInChain = &wg.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = code}},
	)
	if module == nil do return {}, false
	for &slot, index in resources.shaders {
		if slot.occupied do continue
		slot.generation = _resource_generation_next(slot.generation)
		slot.module = module
		slot.occupied = true
		resources.shader_count += 1
		return Gpu_3D_Shader{id = _resource_handle_make_context(ctx.id, index, slot.generation)},
			true
	}
	assert(false, "context_create_gpu_3d_shader: count mismatch")
	return {}, false
}

create_gpu_3d_shader :: proc(code: string) -> (Gpu_3D_Shader, bool) {
	return context_create_gpu_3d_shader(default_context(), code)
}

// destroy_gpu_3d_shader releases a custom shader module and every cached
// pipeline built from it. Zero or stale handles are a no-op; the handle is
// zeroed either way. Must not be called inside an active 3D pass.
context_destroy_gpu_3d_shader :: proc(ctx: ^Context, shader: ^Gpu_3D_Shader) {
	assert(ctx != nil, "context_destroy_gpu_3d_shader: nil context")
	assert(shader != nil, "context_destroy_gpu_3d_shader: nil shader")
	defer shader^ = {}
	if !ctx.initialized || shader.id == 0 do return
	resources := &ctx.resources.gpu_3d
	assert(resources.active_pass_generation == 0, "context_destroy_gpu_3d_shader: active pass")
	slot := _gpu_3d_shader_slot(ctx.id, resources, shader^)
	if slot == nil do return
	// Swap-remove cached pipelines built from this module; the cache is a
	// dense linear-scan array so order does not matter.
	pipeline_index := u32(0)
	for pipeline_index < resources.pipeline_count {
		entry := &resources.pipelines[pipeline_index]
		if entry.shader_id != shader.id {
			pipeline_index += 1
			continue
		}
		if entry.pipeline != nil do wg.RenderPipelineRelease(entry.pipeline)
		resources.pipeline_count -= 1
		entry^ = resources.pipelines[resources.pipeline_count]
		resources.pipelines[resources.pipeline_count] = {}
	}
	wg.ShaderModuleRelease(slot.module)
	slot.module = nil
	slot.occupied = false
	assert(resources.shader_count > 0, "context_destroy_gpu_3d_shader: count underflow")
	resources.shader_count -= 1
}

destroy_gpu_3d_shader :: proc(shader: ^Gpu_3D_Shader) {
	context_destroy_gpu_3d_shader(default_context(), shader)
}

// _gpu_3d_shader_resolve maps a material's shader handle to the module used
// for pipeline creation. Zero or stale handles fall back to the built-in
// shader (nil module, id 0) - an operating condition matching the texture
// fallback policy.
@(private)
_gpu_3d_shader_slot :: proc(
	context_id: u32,
	resources: ^Gpu_3D_Resources,
	shader: Gpu_3D_Shader,
) -> ^Gpu_3D_Shader_Slot {
	assert(context_id != 0, "_gpu_3d_shader_slot: zero context id")
	assert(resources != nil, "_gpu_3d_shader_slot: nil resources")
	handle_context := (shader.id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(shader.id, len(resources.shaders))
	if !ok do return nil
	assert(index >= 0 && index < len(resources.shaders), "_gpu_3d_shader_slot: invalid index")
	slot := &resources.shaders[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_gpu_3d_shader_resolve :: proc(
	context_id: u32,
	resources: ^Gpu_3D_Resources,
	shader: Gpu_3D_Shader,
) -> (
	wg.ShaderModule,
	u32,
) {
	assert(resources != nil, "_gpu_3d_shader_resolve: nil resources")
	if shader.id == 0 do return nil, 0
	slot := _gpu_3d_shader_slot(context_id, resources, shader)
	if slot == nil do return nil, 0
	return slot.module, shader.id
}

@(private)
_gpu_3d_mesh_slot :: proc(
	context_id: u32,
	resources: ^Gpu_3D_Resources,
	mesh: Gpu_Mesh,
) -> ^Gpu_3D_Mesh_Slot {
	assert(context_id != 0, "_gpu_3d_mesh_slot: zero context id")
	assert(resources != nil, "_gpu_3d_mesh_slot: nil resources")
	handle_context := (mesh.id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return nil
	index, generation, ok := _resource_handle_decode(mesh.id, len(resources.meshes))
	if !ok do return nil
	assert(
		index >= 0 && index < len(resources.meshes),
		"_gpu_3d_mesh_slot: decoded index out of range",
	)
	slot := &resources.meshes[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_gpu_3d_mesh :: proc(
	context_id: u32,
	resources: ^Gpu_3D_Resources,
	mesh: Gpu_Mesh,
) -> ^Gpu_3D_Mesh_Entry {
	assert(resources != nil, "_gpu_3d_mesh: nil resources")
	slot := _gpu_3d_mesh_slot(context_id, resources, mesh)
	if slot == nil do return nil
	return slot.entry
}

@(private)
_gpu_3d_mesh_entry_destroy :: proc(entry: ^Gpu_3D_Mesh_Entry) {
	assert(entry != nil, "_gpu_3d_mesh_entry_destroy: nil entry")
	if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
	if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
	free(entry)
}

@(private)
_gpu_3d_geometry_valid :: proc(
	vertices: []Gpu_3D_Vertex,
	indices: []u32,
	primitive: Gpu_Primitive,
) -> bool {
	if len(vertices) == 0 || len(indices) == 0 do return false
	if len(vertices) > GPU_3D_MAX_VERTICES || len(indices) > GPU_3D_MAX_INDICES do return false
	bytes := u64(len(vertices)) * size_of(Gpu_3D_Vertex) + u64(len(indices)) * size_of(u32)
	if bytes > GPU_3D_MAX_MESH_BYTES do return false
	#partial switch primitive {
	case .Triangles:
		if len(indices) % 3 != 0 do return false
	case .Lines:
		if len(indices) % 2 != 0 do return false
	case .Points:
	}
	for index in indices {
		if int(index) >= len(vertices) do return false
	}
	return true
}

@(private)
_gpu_3d_buffer :: proc(
	ctx: ^Context,
	data: rawptr,
	size: u64,
	usage: wg.BufferUsageFlags,
) -> wg.Buffer {
	assert(ctx != nil, "_gpu_3d_buffer: nil context")
	assert(data != nil)
	assert(size > 0)
	buffer := wg.DeviceCreateBuffer(ctx.device, &{usage = usage | {.CopyDst}, size = size})
	if buffer == nil do return nil
	wg.QueueWriteBuffer(ctx.queue, buffer, 0, data, uint(size))
	_stats_buffer_created(ctx, false)
	return buffer
}
