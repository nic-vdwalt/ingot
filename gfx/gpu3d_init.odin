package gfx

import wg "vendor:wgpu"

@(private)
_gpu_3d_primitive_topology :: proc(primitive: Gpu_Primitive) -> wg.PrimitiveTopology {
	#partial switch primitive {
	case .Triangles:
		return .TriangleList
	case .Lines:
		return .LineList
	case .Points:
		return .PointList
	}
	return .TriangleList
}

@(private)
_gpu_3d_pipeline_store :: proc(resources: ^Gpu_3D_Resources, entry: Gpu_3D_Pipeline_Entry) {
	assert(resources != nil, "_gpu_3d_pipeline_store: nil resources")
	assert(resources.pipeline_count < GPU_3D_MAX_PIPELINES)
	resources.pipelines[resources.pipeline_count] = entry
	resources.pipeline_count += 1
}

@(private)
_gpu_3d_pipeline :: proc(
	ctx: ^Context,
	format: wg.TextureFormat,
	primitive: Gpu_Primitive,
	style: Gpu_Material_Style,
	sample_count: u32,
	shader_id: u32 = 0,
	shader_module: wg.ShaderModule = nil,
) -> wg.RenderPipeline {
	assert(ctx != nil, "_gpu_3d_pipeline: nil context")
	assert(ctx.initialized, "_gpu_3d_pipeline: uninitialized context")
	assert(sample_count == 1 || sample_count == 4, "_gpu_3d_pipeline: unsupported sample count")
	assert((shader_id == 0) == (shader_module == nil))
	resources := &ctx.resources.gpu_3d
	for entry in resources.pipelines[:resources.pipeline_count] {
		if _gpu_3d_pipeline_matches(entry, format, primitive, style, sample_count, shader_id) {
			return entry.pipeline
		}
	}
	if resources.pipeline_count >= GPU_3D_MAX_PIPELINES {
		_stats_gpu3d_pool_exhaustion(ctx)
		return nil
	}
	_gpu_3d_init_shared(ctx, resources)
	module := resources.shader
	if shader_module != nil do module = shader_module
	attrs := [4]wg.VertexAttribute {
		{format = .Float32x3, offset = 0, shaderLocation = 0},
		{format = .Float32x3, offset = u64(offset_of(Gpu_3D_Vertex, normal)), shaderLocation = 1},
		{format = .Float32, offset = u64(offset_of(Gpu_3D_Vertex, scalar)), shaderLocation = 2},
		{format = .Float32x2, offset = u64(offset_of(Gpu_3D_Vertex, uv)), shaderLocation = 3},
	}
	vertex_layout := wg.VertexBufferLayout {
		arrayStride    = size_of(Gpu_3D_Vertex),
		stepMode       = .Vertex,
		attributeCount = len(attrs),
		attributes     = raw_data(attrs[:]),
	}
	group_layouts := [4]wg.BindGroupLayout {
		resources.layout,
		ctx.rend.tex_layout,
		ctx.rend.tex_layout,
		resources.scene_layout,
	}
	layout := wg.DeviceCreatePipelineLayout(
		ctx.device,
		&{
			bindGroupLayoutCount = len(group_layouts),
			bindGroupLayouts = raw_data(group_layouts[:]),
		},
	)
	policy := _gpu_3d_material_policy(style)
	if primitive != .Triangles do policy.depth_bias = 0
	blend := _blend_for(&ctx.rend, .Alpha)
	target := wg.ColorTargetState {
		format    = format,
		writeMask = wg.ColorWriteMaskFlags_All,
	}
	if policy.blend do target.blend = &blend
	depth := wg.DepthStencilState {
		format            = .Depth24Plus,
		depthWriteEnabled = .True if policy.depth_write else .False,
		depthCompare      = policy.depth_compare,
		stencilReadMask   = 0xff,
		stencilWriteMask  = 0xff,
		depthBias         = policy.depth_bias,
	}
	topology := _gpu_3d_primitive_topology(primitive)
	cull_mode := wg.CullMode.None
	if style == .Silhouette_Outline && primitive == .Triangles do cull_mode = .Front
	pipeline := wg.DeviceCreateRenderPipeline(
		ctx.device,
		&{
			label = "gpu3d",
			layout = layout,
			vertex = {
				module = module,
				entryPoint = "vs_main",
				bufferCount = 1,
				buffers = &vertex_layout,
			},
			primitive = {topology = topology, frontFace = .CCW, cullMode = cull_mode},
			depthStencil = &depth,
			multisample = {count = sample_count, mask = ~u32(0)},
			fragment = &wg.FragmentState {
				module = module,
				entryPoint = "fs_main",
				targetCount = 1,
				targets = &target,
			},
		},
	)
	wg.PipelineLayoutRelease(layout)
	_gpu_3d_pipeline_store(
		resources,
		{format, primitive, style, sample_count, shader_id, pipeline},
	)
	return pipeline
}

@(private)
_gpu_3d_init_neutral_normal :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_init_neutral_normal: nil context")
	assert(resources != nil, "_gpu_3d_init_neutral_normal: nil resources")
	resources.neutral_normal_tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {1, 1, 1},
			format = .RGBA8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	neutral_normal := [4]byte{128, 128, 255, 255}
	wg.QueueWriteTexture(
		ctx.queue,
		&{texture = resources.neutral_normal_tex},
		raw_data(neutral_normal[:]),
		uint(len(neutral_normal)),
		&{bytesPerRow = 4, rowsPerImage = 1},
		&{1, 1, 1},
	)
	resources.neutral_normal_view = wg.TextureCreateView(resources.neutral_normal_tex, nil)
	resources.neutral_normal_sampler = wg.DeviceCreateSampler(
		ctx.device,
		&{
			magFilter = .Linear,
			minFilter = .Linear,
			mipmapFilter = .Nearest,
			addressModeU = .Repeat,
			addressModeV = .Repeat,
			addressModeW = .ClampToEdge,
			maxAnisotropy = 1,
		},
	)
	entries := [2]wg.BindGroupEntry {
		{binding = 0, textureView = resources.neutral_normal_view},
		{binding = 1, sampler = resources.neutral_normal_sampler},
	}
	resources.neutral_normal_bind = wg.DeviceCreateBindGroup(
		ctx.device,
		&{layout = ctx.rend.tex_layout, entryCount = len(entries), entries = raw_data(entries[:])},
	)
}

@(private)
_gpu_3d_init_shared :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_init_shared: nil context")
	assert(resources != nil, "_gpu_3d_init_shared: nil resources")
	// Renderer init precedes any 3D pass, so the shared 2D texture layout
	// must already exist - a nil here is a programmer error in init order.
	assert(ctx.rend.tex_layout != nil, "_gpu_3d_init_shared: missing renderer texture layout")
	if resources.shader != nil do return
	resources.shader = wg.DeviceCreateShaderModule(
		ctx.device,
		&{
			nextInChain = &wg.ShaderSourceWGSL {
				chain = {sType = .ShaderSourceWGSL},
				code = GPU_3D_SHADER,
			},
		},
	)
	layout_entries := [2]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = size_of(Gpu_3D_Uniforms),
			},
		},
		{
			binding = 1,
			visibility = {.Vertex},
			buffer = {
				type = .Uniform,
				hasDynamicOffset = true,
				minBindingSize = size_of(Gpu_3D_Instance_Uniforms),
			},
		},
	}
	resources.layout = wg.DeviceCreateBindGroupLayout(
		ctx.device,
		&{entryCount = 2, entries = raw_data(layout_entries[:])},
	)
	_gpu_3d_init_neutral_normal(ctx, resources)
	_gpu_3d_init_neutral_scene(ctx, resources)
	for &bind, index in resources.bind {
		bind_entries := [2]wg.BindGroupEntry {
			{
				binding = 0,
				buffer = ctx.rend.stream_slots[index].uniform_buffer,
				size = size_of(Gpu_3D_Uniforms),
			},
			{
				binding = 1,
				buffer = ctx.rend.stream_slots[index].uniform_buffer,
				size = size_of(Gpu_3D_Instance_Uniforms),
			},
		}
		bind = wg.DeviceCreateBindGroup(
			ctx.device,
			&{layout = resources.layout, entryCount = 2, entries = raw_data(bind_entries[:])},
		)
	}
	assert(resources.shader != nil)
	assert(resources.layout != nil)
	assert(resources.neutral_normal_tex != nil)
	assert(resources.neutral_normal_view != nil)
	assert(resources.neutral_normal_sampler != nil)
	assert(resources.neutral_normal_bind != nil)
}

@(private)
_gpu_3d_init_scene_layout :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_init_scene_layout: nil context")
	assert(resources != nil, "_gpu_3d_init_scene_layout: nil resources")
	scene_layout_entries := [GPU_3D_SCENE_BINDING_COUNT]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Vertex, .Fragment}, sampler = {type = .Filtering}},
		{
			binding = 2,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 3, visibility = {.Vertex, .Fragment}, sampler = {type = .Filtering}},
		{
			binding = 4,
			visibility = {.Fragment},
			texture = {sampleType = .Depth, viewDimension = ._2D},
		},
		{
			binding = 5,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{
			binding = 6,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 7, visibility = {.Vertex, .Fragment}, sampler = {type = .Filtering}},
		{
			binding = 8,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D},
		},
		{
			binding = 9,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D},
		},
		{
			binding = 10,
			visibility = {.Vertex, .Fragment},
			texture = {sampleType = .UnfilterableFloat, viewDimension = ._2D},
		},
	}
	resources.scene_layout = wg.DeviceCreateBindGroupLayout(
		ctx.device,
		&{entryCount = len(scene_layout_entries), entries = raw_data(scene_layout_entries[:])},
	)
	assert(resources.scene_layout != nil)
}

@(private)
_gpu_3d_init_neutral_scene :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_init_neutral_scene: nil context")
	assert(resources != nil, "_gpu_3d_init_neutral_scene: nil resources")
	_gpu_3d_init_scene_layout(ctx, resources)
	resources.neutral_depth_tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.RenderAttachment, .TextureBinding},
			dimension = ._2D,
			size = {1, 1, 1},
			format = .Depth24Plus,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	resources.neutral_depth_view = wg.TextureCreateView(resources.neutral_depth_tex, nil)
	resources.neutral_data_tex = wg.DeviceCreateTexture(
		ctx.device,
		&{
			usage = {.TextureBinding, .CopyDst},
			dimension = ._2D,
			size = {1, 1, 1},
			format = .RGBA32Float,
			mipLevelCount = 1,
			sampleCount = 1,
		},
	)
	neutral_data := [4]f32{}
	wg.QueueWriteTexture(
		ctx.queue,
		&{texture = resources.neutral_data_tex},
		raw_data(neutral_data[:]),
		uint(size_of(neutral_data)),
		&{bytesPerRow = size_of(neutral_data), rowsPerImage = 1},
		&{1, 1, 1},
	)
	resources.neutral_data_view = wg.TextureCreateView(resources.neutral_data_tex, nil)
	resources.extra_sampler = wg.DeviceCreateSampler(
		ctx.device,
		&{
			magFilter = .Linear,
			minFilter = .Linear,
			mipmapFilter = .Linear,
			addressModeU = .Repeat,
			addressModeV = .Repeat,
			addressModeW = .ClampToEdge,
			maxAnisotropy = 1,
		},
	)
	neutral_scene_entries := [GPU_3D_SCENE_BINDING_COUNT]wg.BindGroupEntry {
		{binding = 0, textureView = ctx.rend.neutral_view},
		{binding = 1, sampler = ctx.rend.neutral_sampler},
		{binding = 2, textureView = ctx.rend.neutral_view},
		{binding = 3, sampler = ctx.rend.neutral_sampler},
		{binding = 4, textureView = resources.neutral_depth_view},
		{binding = 5, textureView = ctx.rend.neutral_view},
		{binding = 6, textureView = ctx.rend.neutral_view},
		{binding = 7, sampler = resources.extra_sampler},
		{binding = 8, textureView = resources.neutral_data_view},
		{binding = 9, textureView = resources.neutral_data_view},
		{binding = 10, textureView = resources.neutral_data_view},
	}
	resources.neutral_scene_bind = wg.DeviceCreateBindGroup(
		ctx.device,
		&{
			layout = resources.scene_layout,
			entryCount = len(neutral_scene_entries),
			entries = raw_data(neutral_scene_entries[:]),
		},
	)
	assert(resources.scene_layout != nil)
	assert(resources.neutral_depth_tex != nil)
	assert(resources.neutral_depth_view != nil)
	assert(resources.neutral_data_tex != nil)
	assert(resources.neutral_data_view != nil)
	assert(resources.extra_sampler != nil)
	assert(resources.neutral_scene_bind != nil)
}

@(private)
_gpu_3d_resources_destroy :: proc(ctx: ^Context, resources: ^Gpu_3D_Resources) {
	assert(ctx != nil, "_gpu_3d_resources_destroy: nil context")
	assert(resources != nil, "_gpu_3d_resources_destroy: nil resources")
	assert(resources.active_pass_generation == 0, "_gpu_3d_resources_destroy: active pass")
	compat := &resources.compat
	if compat.target.texture.texture.id != 0 do _gpu_3d_target_destroy(ctx, &compat.target)
	compat^ = {}
	for &slot in resources.meshes {
		if slot.occupied do _gpu_3d_mesh_entry_destroy(slot.entry)
	}
	for index in 0 ..< resources.pipeline_count {
		if resources.pipelines[index].pipeline != nil {
			wg.RenderPipelineRelease(resources.pipelines[index].pipeline)
		}
	}
	for &slot in resources.shaders {
		if slot.occupied && slot.module != nil do wg.ShaderModuleRelease(slot.module)
	}
	for bind in resources.bind {
		if bind != nil do wg.BindGroupRelease(bind)
	}
	if resources.neutral_normal_bind != nil do wg.BindGroupRelease(resources.neutral_normal_bind)
	if resources.neutral_normal_sampler != nil do wg.SamplerRelease(resources.neutral_normal_sampler)
	if resources.neutral_normal_view != nil do wg.TextureViewRelease(resources.neutral_normal_view)
	if resources.neutral_normal_tex != nil {
		wg.TextureDestroy(resources.neutral_normal_tex)
		wg.TextureRelease(resources.neutral_normal_tex)
	}
	if resources.neutral_scene_bind != nil do wg.BindGroupRelease(resources.neutral_scene_bind)
	if resources.neutral_depth_view != nil do wg.TextureViewRelease(resources.neutral_depth_view)
	if resources.neutral_depth_tex != nil {
		wg.TextureDestroy(resources.neutral_depth_tex)
		wg.TextureRelease(resources.neutral_depth_tex)
	}
	if resources.extra_sampler != nil do wg.SamplerRelease(resources.extra_sampler)
	if resources.neutral_data_view != nil do wg.TextureViewRelease(resources.neutral_data_view)
	if resources.neutral_data_tex != nil {
		wg.TextureDestroy(resources.neutral_data_tex)
		wg.TextureRelease(resources.neutral_data_tex)
	}
	if resources.scene_layout != nil do wg.BindGroupLayoutRelease(resources.scene_layout)
	if resources.layout != nil do wg.BindGroupLayoutRelease(resources.layout)
	if resources.shader != nil do wg.ShaderModuleRelease(resources.shader)
	resources^ = {}
}
