package gfx

import "core:math"
import wg "vendor:wgpu"

// Fixed pools (Tiger Style: every pool has a static upper bound). Exhaustion
// is an operating condition, not a programmer error: create_sphere_mesh
// returns ok=false and draw_gpu_mesh skips draws once the pipeline pool is
// full — both are counted in renderer_stats().gpu3d_pool_exhaustions.
GPU_3D_MAX_MESHES :: 256
GPU_3D_MAX_PIPELINES :: 8

Gpu_Mesh :: struct {
	id: u32,
}

Gpu_3D_Target :: struct {
	texture: RenderTexture2D,
}

Gpu_Material :: struct {
	color: Color,
}

Gpu_3D_Load_Action :: enum {
	Clear,
	Preserve,
}

Gpu_3D_Pass :: struct {
	owner:           ^Context,
	epoch:           u64,
	encoder:         wg.CommandEncoder,
	pass:            wg.RenderPassEncoder,
	target:          ^Gpu_3D_Target,
	view_projection: Matrix,
	generation:      u64,
	active:          bool,
	owns_stream:     bool,
}

Gpu_3D_Vertex :: struct {
	position: [3]f32,
	normal:   [3]f32,
}

Gpu_3D_Uniforms :: struct {
	view_projection: Matrix,
	model:           Matrix,
	color:           [4]f32,
}

// The dynamic-offset uniform bind group declares minBindingSize =
// size_of(Gpu_3D_Uniforms). The WGSL view of the struct is 144 bytes (two
// mat4x4 + vec4); Odin may append tail padding (matrix alignment is
// target-dependent: 160 on native SIMD, 144 on wasm), and WebGPU permits a
// binding larger than the shader view. Lock the invariants a struct edit
// could silently break: never smaller than the shader view, always 16-byte
// aligned as dynamic offsets require.
#assert(size_of(Gpu_3D_Uniforms) >= 144)
#assert(size_of(Gpu_3D_Uniforms) % 16 == 0)
#assert(size_of(Gpu_3D_Vertex) == 24)

@(private)
Gpu_3D_Mesh_Entry :: struct {
	vertex_buffer: wg.Buffer,
	index_buffer:  wg.Buffer,
	index_count:   u32,
}

@(private)
Gpu_3D_Pipeline_Entry :: struct {
	format:   wg.TextureFormat,
	pipeline: wg.RenderPipeline,
}

@(private)
Gpu_3D_Mesh_Slot :: struct {
	entry:      ^Gpu_3D_Mesh_Entry,
	generation: u32,
	occupied:   bool,
}

Gpu_3D_Resources :: struct {
	meshes:                 [GPU_3D_MAX_MESHES]Gpu_3D_Mesh_Slot,
	mesh_count:             u32,
	pipelines:              [GPU_3D_MAX_PIPELINES]Gpu_3D_Pipeline_Entry,
	pipeline_count:         u32,
	shader:                 wg.ShaderModule,
	layout:                 wg.BindGroupLayout,
	bind:                   [STREAM_SLOT_COUNT]wg.BindGroup,
	next_pass_generation:   u64,
	active_pass_generation: u64,
}

#assert(GPU_3D_MAX_MESHES <= RESOURCE_SLOT_COUNT)

GPU_3D_SHADER :: `
struct Uniforms {
    view_projection: mat4x4<f32>,
    model: mat4x4<f32>,
    color: vec4<f32>,
};
@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) normal: vec3<f32>,
};

@vertex
fn vs_main(@location(0) position: vec3<f32>, @location(1) normal: vec3<f32>) -> VertexOut {
    var out: VertexOut;
    out.position = u.view_projection * u.model * vec4<f32>(position, 1.0);
    out.normal = normalize((u.model * vec4<f32>(normal, 0.0)).xyz);
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    let light = normalize(vec3<f32>(0.4, 0.8, 0.3));
    let diffuse = 0.25 + 0.75 * max(dot(normalize(in.normal), light), 0.0);
    return vec4<f32>(u.color.rgb * diffuse * u.color.a, u.color.a);
}
`

create_gpu_3d_target :: proc(width, height: i32) -> (Gpu_3D_Target, bool) {
	if !g.initialized || width <= 0 || height <= 0 do return {}, false
	target := Gpu_3D_Target {
		texture = LoadRenderTextureEx(width, height, g.format, true),
	}
	ok := target.texture.texture.id != 0 && target.texture.depth.id != 0
	return target, ok
}

destroy_gpu_3d_target :: proc(target: ^Gpu_3D_Target) {
	assert(target != nil)
	if target.texture.texture.id != 0 do UnloadRenderTexture(target.texture)
	target^ = {}
	assert(target.texture.texture.id == 0)
}

// _sphere_mesh_geometry generates a UV sphere's vertex/index lists — pure
// CPU, no GPU calls — split out of create_sphere_mesh so headless tests can
// validate counts, bounds, and normals without a device.
@(private)
_sphere_mesh_geometry :: proc(
	radius: f32,
	rings, slices: u32,
	vertices: ^[dynamic]Gpu_3D_Vertex,
	indices: ^[dynamic]u32,
) {
	assert(radius > 0)
	assert(rings >= 2 && slices >= 3)
	for ring: u32 = 0; ring <= rings; ring += 1 {
		v := f32(ring) / f32(rings)
		phi := v * f32(math.PI)
		for slice: u32 = 0; slice <= slices; slice += 1 {
			u := f32(slice) / f32(slices)
			theta := u * f32(math.TAU)
			normal := [3]f32 {
				f32(math.sin(f64(phi))) * f32(math.cos(f64(theta))),
				f32(math.cos(f64(phi))),
				f32(math.sin(f64(phi))) * f32(math.sin(f64(theta))),
			}
			append(vertices, Gpu_3D_Vertex{position = normal * radius, normal = normal})
		}
	}
	row := slices + 1
	for ring: u32 = 0; ring < rings; ring += 1 {
		for slice: u32 = 0; slice < slices; slice += 1 {
			a := ring * row + slice
			b := a + row
			append(indices, a, b, a + 1, a + 1, b, b + 1)
		}
	}
	assert(len(vertices) == int((rings + 1) * (slices + 1)))
	assert(len(indices) == int(rings * slices * 6))
}

create_sphere_mesh :: proc(radius: f32, rings, slices: u32) -> (Gpu_Mesh, bool) {
	assert(radius > 0)
	if !g.initialized || rings < 2 || slices < 3 do return {}, false
	resources := &g.resources.gpu_3d
	if resources.mesh_count >= GPU_3D_MAX_MESHES {
		// Pool full: operating condition — caller gets ok=false (counted).
		_stats_gpu3d_pool_exhaustion()
		return {}, false
	}

	vertices := make([dynamic]Gpu_3D_Vertex, 0, int((rings + 1) * (slices + 1)))
	indices := make([dynamic]u32, 0, int(rings * slices * 6))
	defer delete(vertices)
	defer delete(indices)
	_sphere_mesh_geometry(radius, rings, slices, &vertices, &indices)

	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(
		raw_data(vertices),
		u64(len(vertices)) * size_of(Gpu_3D_Vertex),
		{.Vertex},
	)
	entry.index_buffer = _gpu_3d_buffer(
		raw_data(indices),
		u64(len(indices)) * size_of(u32),
		{.Index},
	)
	entry.index_count = u32(len(indices))
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
		return Gpu_Mesh{id = _resource_handle_make(index, slot.generation)}, true
	}
	assert(false, "create_sphere_mesh: count mismatch")
	return {}, false
}

destroy_gpu_mesh :: proc(mesh: ^Gpu_Mesh) {
	assert(mesh != nil)
	slot := _gpu_3d_mesh_slot(&g.resources.gpu_3d, mesh^)
	if slot == nil {
		mesh^ = {}
		return
	}
	_gpu_3d_mesh_entry_destroy(slot.entry)
	slot.entry = nil
	slot.occupied = false
	assert(g.resources.gpu_3d.mesh_count > 0, "destroy_gpu_mesh: count underflow")
	g.resources.gpu_3d.mesh_count -= 1
	mesh^ = {}
	assert(mesh.id == 0)
}

begin_gpu_3d :: proc(
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	assert(target != nil)
	resources := &g.resources.gpu_3d
	if resources.active_pass_generation != 0 do return {}, false
	if !g.initialized || target.texture.texture.id == 0 || target.texture.depth.id == 0 {
		return {}, false
	}
	color_view := _texture_view(target.texture.texture.id)
	depth_view := _texture_view(target.texture.depth.id)
	if color_view == nil || depth_view == nil do return {}, false
	owns_stream := !g.frame.has_frame
	if owns_stream && !_stream_slot_acquire(&g.rend, _submission_completed(&g.submissions)) {
		_stats_stream_slot_exhaustion()
		return {}, false
	}

	color := wg.RenderPassColorAttachment {
		view       = color_view,
		depthSlice = wg.DEPTH_SLICE_UNDEFINED,
		loadOp     = load == .Clear ? .Clear : .Load,
		storeOp    = .Store,
		clearValue = {0, 0, 0, 0},
	}
	depth := wg.RenderPassDepthStencilAttachment {
		view            = depth_view,
		depthLoadOp     = load == .Clear ? .Clear : .Load,
		depthStoreOp    = .Store,
		depthClearValue = 1,
		stencilLoadOp   = .Undefined,
		stencilStoreOp  = .Undefined,
	}
	encoder := wg.DeviceCreateCommandEncoder(g.device, nil)
	pass := wg.CommandEncoderBeginRenderPass(
		encoder,
		&{colorAttachmentCount = 1, colorAttachments = &color, depthStencilAttachment = &depth},
	)
	resources.next_pass_generation += 1
	if resources.next_pass_generation == 0 do resources.next_pass_generation = 1
	resources.active_pass_generation = resources.next_pass_generation
	_stats_render_pass()
	result := Gpu_3D_Pass {
		owner       = default_context(),
		epoch       = g.epoch,
		encoder     = encoder,
		pass        = pass,
		target      = target,
		generation  = resources.active_pass_generation,
		active      = true,
		owns_stream = owns_stream,
	}
	_gpu_3d_set_camera(&result, camera)
	return result, true
}

draw_gpu_mesh :: proc(
	pass: ^Gpu_3D_Pass,
	mesh: Gpu_Mesh,
	transform: Matrix,
	material: Gpu_Material,
) {
	if !_gpu_3d_pass_current(&g.resources.gpu_3d, pass) do return
	entry := _gpu_3d_mesh(mesh)
	if entry == nil do return
	target_entry := get_texture(pass.target.texture.texture.id)
	if target_entry == nil do return
	pipeline := _gpu_3d_pipeline(target_entry.wgformat)
	if pipeline == nil do return

	uniforms := Gpu_3D_Uniforms {
		view_projection = pass.view_projection,
		model           = transform,
		color           = col_f(material.color),
	}
	offset, ok := _uniform_upload(&g.rend, &uniforms, size_of(uniforms))
	if !ok || g.rend.active_stream_slot < 0 do return
	wg.RenderPassEncoderSetPipeline(pass.pass, pipeline)
	wg.RenderPassEncoderSetBindGroup(
		pass.pass,
		0,
		g.resources.gpu_3d.bind[g.rend.active_stream_slot],
		{offset},
	)
	wg.RenderPassEncoderSetVertexBuffer(pass.pass, 0, entry.vertex_buffer, 0, wg.WHOLE_SIZE)
	wg.RenderPassEncoderSetIndexBuffer(pass.pass, entry.index_buffer, .Uint32, 0, wg.WHOLE_SIZE)
	wg.RenderPassEncoderDrawIndexed(pass.pass, entry.index_count, 1, 0, 0, 0)
	_stats_pipeline_switch()
	_stats_bind_group_switches(1)
}

end_gpu_3d :: proc(pass: ^Gpu_3D_Pass) {
	if !_gpu_3d_pass_current(&g.resources.gpu_3d, pass) do return
	wg.RenderPassEncoderEnd(pass.pass)
	wg.RenderPassEncoderRelease(pass.pass)
	retirement := u64(0)
	if pass.owns_stream do retirement = _submission_reserve(&g.submissions)
	cmd := wg.CommandEncoderFinish(pass.encoder, nil)
	if (!pass.owns_stream || retirement != 0) && cmd != nil {
		wg.QueueSubmit(g.queue, {cmd})
		_stats_queue_submission()
		if pass.owns_stream {
			assert(_submission_commit(&g.submissions, retirement))
			if !_stream_slot_submitted(&g.rend, retirement) do _stats_stream_retirement_failure()
		}
	} else if pass.owns_stream {
		if retirement != 0 do assert(_submission_rollback(&g.submissions, retirement))
		_stream_slot_abandon(&g.rend)
		_stats_stream_retirement_failure()
	}
	if cmd != nil do wg.CommandBufferRelease(cmd)
	wg.CommandEncoderRelease(pass.encoder)
	g.resources.gpu_3d.active_pass_generation = 0
	pass^ = {}
}

@(private)
_gpu_3d_set_camera :: proc(pass: ^Gpu_3D_Pass, camera: Camera3D) {
	assert(pass != nil)
	width := pass.target.texture.texture.width
	height := pass.target.texture.texture.height
	assert(width > 0 && height > 0)
	_, _, pass.view_projection = _camera_matrices(camera, width, height)
}

@(private)
_gpu_3d_mesh_slot :: proc(resources: ^Gpu_3D_Resources, mesh: Gpu_Mesh) -> ^Gpu_3D_Mesh_Slot {
	assert(resources != nil, "_gpu_3d_mesh_slot: nil resources")
	index, generation, ok := _resource_handle_decode(mesh.id, len(resources.meshes))
	if !ok do return nil
	slot := &resources.meshes[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot
}

@(private)
_gpu_3d_mesh :: proc(mesh: Gpu_Mesh) -> ^Gpu_3D_Mesh_Entry {
	slot := _gpu_3d_mesh_slot(&g.resources.gpu_3d, mesh)
	if slot == nil do return nil
	return slot.entry
}

@(private)
_gpu_3d_pass_current :: proc(resources: ^Gpu_3D_Resources, pass: ^Gpu_3D_Pass) -> bool {
	if resources == nil || pass == nil || !pass.active || pass.generation == 0 do return false
	if pass.owner != default_context() || pass.epoch != g.epoch do return false
	return pass.generation == resources.active_pass_generation
}

@(private)
_gpu_3d_mesh_entry_destroy :: proc(entry: ^Gpu_3D_Mesh_Entry) {
	assert(entry != nil, "_gpu_3d_mesh_entry_destroy: nil entry")
	if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
	if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
	free(entry)
}

@(private)
_gpu_3d_buffer :: proc(data: rawptr, size: u64, usage: wg.BufferUsageFlags) -> wg.Buffer {
	assert(data != nil)
	assert(size > 0)
	buffer := wg.DeviceCreateBuffer(g.device, &{usage = usage | {.CopyDst}, size = size})
	if buffer == nil do return nil
	wg.QueueWriteBuffer(g.queue, buffer, 0, data, uint(size))
	_stats_buffer_created(false)
	return buffer
}

@(private)
_gpu_3d_pipeline :: proc(format: wg.TextureFormat) -> wg.RenderPipeline {
	resources := &g.resources.gpu_3d
	for index in 0 ..< resources.pipeline_count {
		if resources.pipelines[index].format == format do return resources.pipelines[index].pipeline
	}
	if resources.pipeline_count >= GPU_3D_MAX_PIPELINES {
		// Pool full: draws to targets in unseen formats are skipped from now
		// on (bounded pool, never grows) — operating condition, counted.
		_stats_gpu3d_pool_exhaustion()
		return nil
	}
	_gpu_3d_init_shared(resources)
	attrs := [2]wg.VertexAttribute {
		{format = .Float32x3, offset = 0, shaderLocation = 0},
		{format = .Float32x3, offset = u64(offset_of(Gpu_3D_Vertex, normal)), shaderLocation = 1},
	}
	vertex_layout := wg.VertexBufferLayout {
		arrayStride    = size_of(Gpu_3D_Vertex),
		stepMode       = .Vertex,
		attributeCount = len(attrs),
		attributes     = raw_data(attrs[:]),
	}
	layout := wg.DeviceCreatePipelineLayout(
		g.device,
		&{bindGroupLayoutCount = 1, bindGroupLayouts = &resources.layout},
	)
	blend := _blend_for(&g.rend, .Alpha)
	target := wg.ColorTargetState {
		format    = format,
		blend     = &blend,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	depth := wg.DepthStencilState {
		format            = .Depth24Plus,
		depthWriteEnabled = .True,
		depthCompare      = .Less,
		stencilReadMask   = 0xff,
		stencilWriteMask  = 0xff,
	}
	pipeline := wg.DeviceCreateRenderPipeline(
		g.device,
		&{
			layout = layout,
			vertex = {
				module = resources.shader,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &vertex_layout,
			},
			primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .Back},
			depthStencil = &depth,
			multisample = {count = 1, mask = ~u32(0)},
			fragment = &wg.FragmentState {
				module = resources.shader,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(layout)
	index := resources.pipeline_count
	resources.pipelines[index] = {
		format   = format,
		pipeline = pipeline,
	}
	resources.pipeline_count += 1
	return pipeline
}

@(private)
_gpu_3d_init_shared :: proc(resources: ^Gpu_3D_Resources) {
	assert(resources != nil, "_gpu_3d_init_shared: nil resources")
	if resources.shader != nil do return
	resources.shader = wg.DeviceCreateShaderModule(
		g.device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = GPU_3D_SHADER,
			},
		},
	)
	resources.layout = wg.DeviceCreateBindGroupLayout(
		g.device,
		&{
			entryCount = 1,
			entries = &wg.BindGroupLayoutEntry {
				binding = 0,
				visibility = {.Vertex, .Fragment},
				buffer = {
					type = .Uniform,
					hasDynamicOffset = true,
					minBindingSize = size_of(Gpu_3D_Uniforms),
				},
			},
		},
	)
	for &bind, index in resources.bind {
		bind = wg.DeviceCreateBindGroup(
			g.device,
			&{
				layout = resources.layout,
				entryCount = 1,
				entries = &wg.BindGroupEntry {
					binding = 0,
					buffer = g.rend.stream_slots[index].uniform_buffer,
					size = size_of(Gpu_3D_Uniforms),
				},
			},
		)
	}
	assert(resources.shader != nil)
	assert(resources.layout != nil)
}

@(private)
_gpu_3d_resources_destroy :: proc(resources: ^Gpu_3D_Resources) {
	assert(resources != nil, "_gpu_3d_resources_destroy: nil resources")
	assert(resources.active_pass_generation == 0, "_gpu_3d_resources_destroy: active pass")
	for &slot in resources.meshes {
		if slot.occupied do _gpu_3d_mesh_entry_destroy(slot.entry)
	}
	for index in 0 ..< resources.pipeline_count {
		if resources.pipelines[index].pipeline != nil {
			wg.RenderPipelineRelease(resources.pipelines[index].pipeline)
		}
	}
	for bind in resources.bind {
		if bind != nil do wg.BindGroupRelease(bind)
	}
	if resources.layout != nil do wg.BindGroupLayoutRelease(resources.layout)
	if resources.shader != nil do wg.ShaderModuleRelease(resources.shader)
	resources^ = {}
}
