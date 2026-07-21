package gfx

import "core:math"
import wg "vendor:wgpu"

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
	encoder:    wg.CommandEncoder,
	pass:       wg.RenderPassEncoder,
	target:      ^Gpu_3D_Target,
	generation:  u64,
	active:      bool,
	owns_stream: bool,
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

@(private) gpu_3d_meshes: [GPU_3D_MAX_MESHES]^Gpu_3D_Mesh_Entry
@(private) gpu_3d_mesh_count: u32
@(private) gpu_3d_pipelines: [GPU_3D_MAX_PIPELINES]Gpu_3D_Pipeline_Entry
@(private) gpu_3d_pipeline_count: u32
@(private) gpu_3d_shader: wg.ShaderModule
@(private) gpu_3d_layout: wg.BindGroupLayout
@(private) gpu_3d_bind: [STREAM_SLOT_COUNT]wg.BindGroup
@(private) gpu_3d_generation: u64

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
	target := Gpu_3D_Target{
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

create_sphere_mesh :: proc(radius: f32, rings, slices: u32) -> (Gpu_Mesh, bool) {
	assert(radius > 0)
	if !g.initialized || rings < 2 || slices < 3 do return {}, false
	if gpu_3d_mesh_count >= GPU_3D_MAX_MESHES do return {}, false

	vertices := make([dynamic]Gpu_3D_Vertex, 0, int((rings + 1) * (slices + 1)))
	indices := make([dynamic]u32, 0, int(rings * slices * 6))
	defer delete(vertices)
	defer delete(indices)
	for ring: u32 = 0; ring <= rings; ring += 1 {
		v := f32(ring) / f32(rings)
		phi := v * f32(math.PI)
		for slice: u32 = 0; slice <= slices; slice += 1 {
			u := f32(slice) / f32(slices)
			theta := u * f32(math.TAU)
			normal := [3]f32{
				f32(math.sin(f64(phi))) * f32(math.cos(f64(theta))),
				f32(math.cos(f64(phi))),
				f32(math.sin(f64(phi))) * f32(math.sin(f64(theta))),
			}
			append(&vertices, Gpu_3D_Vertex{position = normal * radius, normal = normal})
		}
	}
	row := slices + 1
	for ring: u32 = 0; ring < rings; ring += 1 {
		for slice: u32 = 0; slice < slices; slice += 1 {
			a := ring * row + slice
			b := a + row
			append(&indices, a, b, a + 1, a + 1, b, b + 1)
		}
	}

	entry := new(Gpu_3D_Mesh_Entry)
	entry.vertex_buffer = _gpu_3d_buffer(raw_data(vertices), u64(len(vertices)) * size_of(Gpu_3D_Vertex), {.Vertex})
	entry.index_buffer = _gpu_3d_buffer(raw_data(indices), u64(len(indices)) * size_of(u32), {.Index})
	entry.index_count = u32(len(indices))
	if entry.vertex_buffer == nil || entry.index_buffer == nil {
		if entry.vertex_buffer != nil do wg.BufferRelease(entry.vertex_buffer)
		if entry.index_buffer != nil do wg.BufferRelease(entry.index_buffer)
		free(entry)
		return {}, false
	}
	gpu_3d_meshes[gpu_3d_mesh_count] = entry
	gpu_3d_mesh_count += 1
	return Gpu_Mesh{id = gpu_3d_mesh_count}, true
}

destroy_gpu_mesh :: proc(mesh: ^Gpu_Mesh) {
	assert(mesh != nil)
	entry := _gpu_3d_mesh(mesh^)
	if entry == nil do return
	wg.BufferRelease(entry.vertex_buffer)
	wg.BufferRelease(entry.index_buffer)
	free(entry)
	gpu_3d_meshes[mesh.id - 1] = nil
	mesh^ = {}
	assert(mesh.id == 0)
}

begin_gpu_3d :: proc(
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action = .Clear,
) -> (Gpu_3D_Pass, bool) {
	assert(target != nil)
	if !g.initialized || target.texture.texture.id == 0 || target.texture.depth.id == 0 do return {}, false
	color_view := _texture_view(target.texture.texture.id)
	depth_view := _texture_view(target.texture.depth.id)
	if color_view == nil || depth_view == nil do return {}, false
	owns_stream := !g.frame.has_frame
	if owns_stream && !_stream_slot_acquire(&g.rend, _submission_completed(&g.submissions)) {
		_stats_stream_slot_exhaustion()
		return {}, false
	}

	color := wg.RenderPassColorAttachment{
		view = color_view,
		depthSlice = wg.DEPTH_SLICE_UNDEFINED,
		loadOp = load == .Clear ? .Clear : .Load,
		storeOp = .Store,
		clearValue = {0, 0, 0, 0},
	}
	depth := wg.RenderPassDepthStencilAttachment{
		view = depth_view,
		depthLoadOp = load == .Clear ? .Clear : .Load,
		depthStoreOp = .Store,
		depthClearValue = 1,
		stencilLoadOp = .Undefined,
		stencilStoreOp = .Undefined,
	}
	encoder := wg.DeviceCreateCommandEncoder(g.device, nil)
	pass := wg.CommandEncoderBeginRenderPass(encoder, &{
		colorAttachmentCount = 1,
		colorAttachments = &color,
		depthStencilAttachment = &depth,
	})
	gpu_3d_generation += 1
	_stats_render_pass()
	result := Gpu_3D_Pass{
		encoder = encoder,
		pass = pass,
		target = target,
		generation = gpu_3d_generation,
		active = true,
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
	assert(pass != nil)
	assert(pass.active)
	entry := _gpu_3d_mesh(mesh)
	if entry == nil do return
	target_entry := get_texture(pass.target.texture.texture.id)
	if target_entry == nil do return
	pipeline := _gpu_3d_pipeline(target_entry.wgformat)
	if pipeline == nil do return

	uniforms := Gpu_3D_Uniforms{
		view_projection = cam3d_vp,
		model = transform,
		color = col_f(material.color),
	}
	offset, ok := _uniform_upload(&g.rend, &uniforms, size_of(uniforms))
	if !ok || g.rend.active_stream_slot < 0 do return
	wg.RenderPassEncoderSetPipeline(pass.pass, pipeline)
	wg.RenderPassEncoderSetBindGroup(pass.pass, 0, gpu_3d_bind[g.rend.active_stream_slot], {offset})
	wg.RenderPassEncoderSetVertexBuffer(pass.pass, 0, entry.vertex_buffer, 0, wg.WHOLE_SIZE)
	wg.RenderPassEncoderSetIndexBuffer(pass.pass, entry.index_buffer, .Uint32, 0, wg.WHOLE_SIZE)
	wg.RenderPassEncoderDrawIndexed(pass.pass, entry.index_count, 1, 0, 0, 0)
	_stats_pipeline_switch()
	_stats_bind_group_switches(1)
}

end_gpu_3d :: proc(pass: ^Gpu_3D_Pass) {
	assert(pass != nil)
	assert(pass.active)
	wg.RenderPassEncoderEnd(pass.pass)
	wg.RenderPassEncoderRelease(pass.pass)
	cmd := wg.CommandEncoderFinish(pass.encoder, nil)
	wg.QueueSubmit(g.queue, {cmd})
	_stats_queue_submission()
	if pass.owns_stream {
		retirement := _submission_track(&g.submissions)
		if !_stream_slot_submitted(&g.rend, retirement) do _stats_stream_retirement_failure()
	}
	wg.CommandBufferRelease(cmd)
	wg.CommandEncoderRelease(pass.encoder)
	pass.active = false
	assert(!pass.active)
}

@(private)
_gpu_3d_set_camera :: proc(pass: ^Gpu_3D_Pass, camera: Camera3D) {
	assert(pass != nil)
	width := pass.target.texture.texture.width
	height := pass.target.texture.texture.height
	old_width, old_height := g.width, g.height
	g.width, g.height = width, height
	cam3d_vp = _vp_from(camera)
	g.width, g.height = old_width, old_height
	assert(width > 0 && height > 0)
}

@(private)
_gpu_3d_mesh :: proc(mesh: Gpu_Mesh) -> ^Gpu_3D_Mesh_Entry {
	if mesh.id == 0 || mesh.id > gpu_3d_mesh_count do return nil
	return gpu_3d_meshes[mesh.id - 1]
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
	for index in 0 ..< gpu_3d_pipeline_count {
		if gpu_3d_pipelines[index].format == format do return gpu_3d_pipelines[index].pipeline
	}
	if gpu_3d_pipeline_count >= GPU_3D_MAX_PIPELINES do return nil
	_gpu_3d_init_shared()
	attrs := [2]wg.VertexAttribute{
		{format = .Float32x3, offset = 0, shaderLocation = 0},
		{format = .Float32x3, offset = u64(offset_of(Gpu_3D_Vertex, normal)), shaderLocation = 1},
	}
	vertex_layout := wg.VertexBufferLayout{
		arrayStride = size_of(Gpu_3D_Vertex),
		stepMode = .Vertex,
		attributeCount = len(attrs),
		attributes = raw_data(attrs[:]),
	}
	layout := wg.DeviceCreatePipelineLayout(g.device, &{
		bindGroupLayoutCount = 1,
		bindGroupLayouts = &gpu_3d_layout,
	})
	blend := _blend_for(&g.rend, .Alpha)
	target := wg.ColorTargetState{format = format, blend = &blend, writeMask = wg.ColorWriteMaskFlags_All}
	depth := wg.DepthStencilState{
		format = .Depth24Plus,
		depthWriteEnabled = .True,
		depthCompare = .Less,
		stencilReadMask = 0xff,
		stencilWriteMask = 0xff,
	}
	pipeline := wg.DeviceCreateRenderPipeline(g.device, &{
		layout = layout,
		vertex = {
			module = gpu_3d_shader,
			entryPoint = "vs_main",
			bufferCount = 1,
			buffers = &vertex_layout,
		},
		primitive = {topology = .TriangleList, frontFace = .CCW, cullMode = .Back},
		depthStencil = &depth,
		multisample = {count = 1, mask = ~u32(0)},
		fragment = &wg.FragmentState{
			module = gpu_3d_shader,
			entryPoint = "fs_main",
			targetCount = 1,
			targets = &target,
		},
	})
	wg.PipelineLayoutRelease(layout)
	index := gpu_3d_pipeline_count
	gpu_3d_pipelines[index] = {format = format, pipeline = pipeline}
	gpu_3d_pipeline_count += 1
	return pipeline
}

@(private)
_gpu_3d_init_shared :: proc() {
	if gpu_3d_shader != nil do return
	gpu_3d_shader = wg.DeviceCreateShaderModule(g.device, &{
		nextInChain = &wg.ShaderSourceWGSL{
			chain = {sType = .ShaderSourceWGSL},
			code = GPU_3D_SHADER,
		},
	})
	gpu_3d_layout = wg.DeviceCreateBindGroupLayout(g.device, &{
		entryCount = 1,
		entries = &wg.BindGroupLayoutEntry{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = size_of(Gpu_3D_Uniforms),
			},
		},
	})
	for &bind, index in gpu_3d_bind {
		bind = wg.DeviceCreateBindGroup(g.device, &{
			layout = gpu_3d_layout,
			entryCount = 1,
			entries = &wg.BindGroupEntry{
				binding = 0,
				buffer = g.rend.stream_slots[index].uniform_buffer,
				size = size_of(Gpu_3D_Uniforms),
			},
		})
	}
	assert(gpu_3d_shader != nil)
	assert(gpu_3d_layout != nil)
}
