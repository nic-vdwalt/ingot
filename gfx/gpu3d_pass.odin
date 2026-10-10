package gfx

import wg "vendor:wgpu"

context_begin_gpu_3d_named :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action,
	name: string,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	assert(ctx != nil, "context_begin_gpu_3d_named: nil context")
	assert(target != nil, "context_begin_gpu_3d: nil target")
	resources := &ctx.resources.gpu_3d
	if resources.active_pass_generation != 0 do return {}, false
	if !ctx.initialized || target.texture.texture.id == 0 || target.texture.depth.id == 0 {
		return {}, false
	}
	color_view, depth_view, resolve_view, sample_count, views_ok := _gpu_3d_target_views(
		ctx,
		target,
	)
	if !views_ok do return {}, false
	owns_stream := !ctx.frame.has_frame
	if owns_stream && !_stream_slot_acquire(&ctx.rend, _submission_completed(&ctx.submissions)) {
		_stats_stream_slot_exhaustion(ctx)
		return {}, false
	}
	identity_offset, identity_ok := _gpu_3d_identity_instances_upload(ctx, &ctx.rend)
	if !identity_ok {
		// Uniform stream exhausted at pass start: operating condition - the
		// reservation failure is counted inside _uniform_upload, and a slot
		// acquired only for this pass must be handed back.
		if owns_stream do _stream_slot_abandon(&ctx.rend)
		return {}, false
	}
	color := wg.RenderPassColorAttachment {
		view          = color_view,
		resolveTarget = resolve_view,
		depthSlice    = wg.DEPTH_SLICE_UNDEFINED,
		loadOp        = load == .Clear ? .Clear : .Load,
		storeOp       = .Store,
		clearValue    = {0, 0, 0, 0},
	}
	depth := wg.RenderPassDepthStencilAttachment {
		view            = depth_view,
		depthLoadOp     = load == .Clear ? .Clear : .Load,
		depthStoreOp    = .Store,
		depthClearValue = 1,
		stencilLoadOp   = .Undefined,
		stencilStoreOp  = .Undefined,
	}
	encoder := _gpu_timing_command_encoder(ctx, name)
	writes := _gpu_timing_pass_writes(&ctx.gpu_timing, name)
	pass := wg.CommandEncoderBeginRenderPass(
		encoder,
		&{
			label = name,
			colorAttachmentCount = 1,
			colorAttachments = &color,
			depthStencilAttachment = &depth,
			timestampWrites = writes.querySet != nil ? &writes : nil,
		},
	)
	_gpu_timing_diagnostic_render_pass(ctx, writes, encoder, pass, color, target, depth)
	resources.next_pass_generation += 1
	if resources.next_pass_generation == 0 do resources.next_pass_generation = 1
	resources.active_pass_generation = resources.next_pass_generation
	_stats_render_pass(ctx)
	result := Gpu_3D_Pass {
		owner                     = ctx,
		epoch                     = ctx.epoch,
		encoder                   = encoder,
		timing                    = {},
		pass_end_query            = writes.endOfPassWriteIndex,
		pass_timed                = writes.querySet != nil,
		pass                      = pass,
		target                    = target,
		light                     = GPU_3D_DEFAULT_LIGHT,
		secondary_light           = GPU_3D_DEFAULT_SECONDARY_LIGHT,
		camera_position           = camera.position,
		time                      = f32(context_time(ctx)),
		generation                = resources.active_pass_generation,
		active                    = true,
		sample_count              = sample_count,
		owns_stream               = owns_stream,
		identity_instances_offset = identity_offset,
	}
	_gpu_3d_set_camera(&result, camera)
	return result, true
}

context_begin_gpu_3d :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	return context_begin_gpu_3d_named(ctx, target, camera, load, "gpu3d")
}

begin_gpu_3d_named :: proc(
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action,
	name: string,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	return context_begin_gpu_3d_named(default_context(), target, camera, load, name)
}

begin_gpu_3d :: proc(
	target: ^Gpu_3D_Target,
	camera: Camera3D,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	return context_begin_gpu_3d(default_context(), target, camera, load)
}

// set_gpu_3d_light overrides the pass light for subsequent draw calls. The
// direction is normalized and intensities clamped to [0, 1] so the shader
// contract (unit direction, bounded factors) always holds.
set_gpu_3d_light :: proc(pass: ^Gpu_3D_Pass, light: Gpu_3D_Light) {
	assert(pass != nil, "set_gpu_3d_light: nil pass")
	normalized, ok := _light_normalize(light)
	assert(ok, "set_gpu_3d_light: degenerate light direction")
	pass.light = normalized
}

set_gpu_3d_secondary_light :: proc(pass: ^Gpu_3D_Pass, light: Gpu_3D_Light) {
	assert(pass != nil, "set_gpu_3d_secondary_light: nil pass")
	normalized, ok := _light_normalize(light)
	assert(ok, "set_gpu_3d_secondary_light: degenerate light direction")
	pass.secondary_light = normalized
}

set_gpu_3d_underwater_medium :: proc(
	pass: ^Gpu_3D_Pass,
	absorption_blend, scattering_turbidity: [4]f32,
) {
	assert(pass != nil, "set_gpu_3d_underwater_medium: nil pass")
	pass.underwater_primary = absorption_blend
	pass.underwater_secondary = scattering_turbidity
}

// set_gpu_3d_atmosphere_medium publishes a pass-owned atmosphere medium to
// every subsequent draw through the trailing atmosphere_0..2 uniforms.
// Shaders that do not declare them are unaffected.
set_gpu_3d_atmosphere_medium :: proc(pass: ^Gpu_3D_Pass, params: [3][4]f32) {
	assert(pass != nil, "set_gpu_3d_atmosphere_medium: nil pass")
	for row in params {
		for component in row {
			assert(
				component == component && abs(component) < 1e30,
				"set_gpu_3d_atmosphere_medium: non-finite parameter",
			)
		}
	}
	pass.atmosphere = params
}

set_gpu_3d_clip_plane :: proc(pass: ^Gpu_3D_Pass, plane: [4]f32, enabled: bool) {
	assert(pass != nil, "set_gpu_3d_clip_plane: nil pass")
	if enabled {
		normalized, ok := _camera_vector_normalize(plane.xyz)
		assert(ok, "set_gpu_3d_clip_plane: degenerate plane normal")
		pass.clip_plane = {normalized.x, normalized.y, normalized.z, plane.w}
	} else {
		pass.clip_plane = {}
	}
	pass.clip_enabled = 1 if enabled else 0
}

// _light_normalize is the pure core of set_gpu_3d_light, split out so the
// clamping and normalization contract is headless-testable.
@(private)
_light_normalize :: proc(light: Gpu_3D_Light) -> (Gpu_3D_Light, bool) {
	assert(_f32_is_finite(light.ambient), "_light_normalize: non-finite ambient")
	assert(_f32_is_finite(light.diffuse), "_light_normalize: non-finite diffuse")
	direction, direction_ok := _camera_vector_normalize(light.direction)
	if !direction_ok do return {}, false
	return {
			direction = direction,
			ambient = clamp(light.ambient, 0, 1),
			diffuse = clamp(light.diffuse, 0, 1),
		},
		true
}

context_begin_gpu_3d_pro :: proc(
	ctx: ^Context,
	target: ^Gpu_3D_Target,
	view_projection: Matrix,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	assert(ctx != nil, "context_begin_gpu_3d_pro: nil context")
	assert(target != nil, "context_begin_gpu_3d_pro: nil target")
	assert(view_projection != (Matrix{}), "begin_gpu_3d_pro: zero view-projection")
	camera := Camera3D {
		position   = -CAMERA_WORLD_FORWARD,
		target     = {},
		up         = CAMERA_WORLD_UP,
		fovy       = 60,
		projection = .PERSPECTIVE,
	}
	pass, ok := context_begin_gpu_3d(ctx, target, camera, load)
	if ok do pass.view_projection = view_projection
	return pass, ok
}

begin_gpu_3d_pro :: proc(
	target: ^Gpu_3D_Target,
	view_projection: Matrix,
	load: Gpu_3D_Load_Action = .Clear,
) -> (
	Gpu_3D_Pass,
	bool,
) {
	return context_begin_gpu_3d_pro(default_context(), target, view_projection, load)
}

draw_gpu_mesh :: proc(
	pass: ^Gpu_3D_Pass,
	mesh: Gpu_Mesh,
	transform: Matrix,
	material: Gpu_Material,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	entry := _gpu_3d_mesh(pass.owner.id, &pass.owner.resources.gpu_3d, mesh)
	if entry == nil do return
	// A skipped draw (pool or stream exhaustion) is the documented operating
	// behavior; the failure is counted inside the helper.
	_ = _gpu_3d_draw_indexed(pass, entry, material, transform, pass.identity_instances_offset, 1)
}

draw_gpu_mesh_outlined :: proc(
	pass: ^Gpu_3D_Pass,
	mesh, outline_mesh: Gpu_Mesh,
	transform: Matrix,
	material: Gpu_Material,
	outline_color: Color,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	solid_material := material
	solid_material.style = .Opaque
	draw_gpu_mesh(pass, mesh, transform, solid_material)
	draw_gpu_mesh(pass, outline_mesh, transform, {color = outline_color, style = .Opaque_Outline})
}

// draw_gpu_mesh_instanced draws one mesh under many model transforms. Input
// is chunked at GPU_3D_MAX_INSTANCES_PER_DRAW; each chunk is one uniform
// upload plus one indexed draw, which is the batching win over per-mesh
// draw_gpu_mesh calls.
draw_gpu_mesh_instanced :: proc(
	pass: ^Gpu_3D_Pass,
	mesh: Gpu_Mesh,
	transforms: []Matrix,
	material: Gpu_Material,
) {
	if pass == nil || !_gpu_3d_pass_current(&pass.owner.resources.gpu_3d, pass) do return
	// An empty transform list is a valid no-op, not a programmer error.
	if len(transforms) == 0 do return
	entry := _gpu_3d_mesh(pass.owner.id, &pass.owner.resources.gpu_3d, mesh)
	if entry == nil do return
	chunk_count := _gpu_3d_chunk_count(len(transforms))
	assert(chunk_count > 0, "draw_gpu_mesh_instanced: zero chunks for non-empty input")
	for chunk_index in 0 ..< chunk_count {
		start := chunk_index * GPU_3D_MAX_INSTANCES_PER_DRAW
		count := min(len(transforms) - start, GPU_3D_MAX_INSTANCES_PER_DRAW)
		assert(count > 0, "draw_gpu_mesh_instanced: empty chunk")
		assert(start + count <= len(transforms), "draw_gpu_mesh_instanced: chunk out of range")
		instances_offset, upload_ok := _gpu_3d_instance_upload(
			pass.owner,
			&pass.owner.rend,
			transforms[start:start + count],
		)
		if !upload_ok {
			// Uniform stream exhausted mid-batch: stop rather than draw with
			// stale instance data - counted inside _uniform_upload.
			return
		}
		// The chunk transforms carry the full model matrix, so the shared
		// uniform model slot is identity for instanced draws.
		if !_gpu_3d_draw_indexed(pass, entry, material, 1, instances_offset, u32(count)) do return
		_stats_gpu3d_instanced_draw(pass.owner)
	}
}

// _gpu_3d_chunk_count is the pure chunking rule for instanced draws, split
// out so the boundary arithmetic is headless-testable.
@(private)
_gpu_3d_chunk_count :: proc(transform_count: int) -> int {
	assert(transform_count >= 0, "_gpu_3d_chunk_count: negative count")
	count := (transform_count + GPU_3D_MAX_INSTANCES_PER_DRAW - 1) / GPU_3D_MAX_INSTANCES_PER_DRAW
	assert(
		count * GPU_3D_MAX_INSTANCES_PER_DRAW >= transform_count,
		"_gpu_3d_chunk_count: chunks too few",
	)
	return count
}

// _gpu_3d_instance_upload copies one chunk of instance transforms into the
// uniform stream. The full block size is reserved even for partial chunks
// because the bind group layout's minBindingSize covers the whole array.
@(private)
_gpu_3d_instance_upload :: proc(ctx: ^Context, r: ^Renderer, transforms: []Matrix) -> (u32, bool) {
	assert(ctx != nil, "_gpu_3d_instance_upload: nil context")
	assert(r == &ctx.rend, "_gpu_3d_instance_upload: foreign renderer")
	assert(len(transforms) > 0, "_gpu_3d_instance_upload: empty chunk")
	assert(
		len(transforms) <= GPU_3D_MAX_INSTANCES_PER_DRAW,
		"_gpu_3d_instance_upload: chunk exceeds GPU_3D_MAX_INSTANCES_PER_DRAW",
	)
	block: Gpu_3D_Instance_Uniforms
	copy(block.transforms[:len(transforms)], transforms)
	return _uniform_upload(ctx, r, &block, size_of(Gpu_3D_Instance_Uniforms))
}

// _gpu_3d_identity_instances_upload reserves the shared per-pass instance
// block. Every slot is identity so a hypothetical out-of-range instance
// index would render untransformed instead of collapsing geometry through a
// zero matrix.
@(private)
_gpu_3d_identity_instances_upload :: proc(ctx: ^Context, r: ^Renderer) -> (u32, bool) {
	assert(ctx != nil, "_gpu_3d_identity_instances_upload: nil context")
	assert(r == &ctx.rend, "_gpu_3d_identity_instances_upload: foreign renderer")
	resources := &ctx.resources.gpu_3d
	if !resources.identity_block_ready {
		for index in 0 ..< GPU_3D_MAX_INSTANCES_PER_DRAW {
			resources.identity_block.transforms[index] = 1
		}
		resources.identity_block_ready = true
	}
	assert(
		resources.identity_block.transforms[0] == Matrix(1),
		"_gpu_3d_identity_instances_upload: corrupted identity block",
	)
	return _uniform_upload(ctx, r, &resources.identity_block, size_of(Gpu_3D_Instance_Uniforms))
}

// _gpu_3d_texture_bind resolves one material texture to a bind group. Stale
// or destroyed handles are an operating condition (a consumer may destroy a
// texture between frames), so the caller-provided neutral binding is used.
@(private)
_gpu_3d_texture_bind :: proc(
	ctx: ^Context,
	texture: Texture2D,
	fallback: wg.BindGroup,
) -> (
	wg.BindGroup,
	bool,
) {
	assert(ctx != nil, "_gpu_3d_texture_bind: nil context")
	assert(ctx.initialized, "_gpu_3d_texture_bind: uninitialized context")
	assert(fallback != nil, "_gpu_3d_texture_bind: missing fallback texture")
	if texture.id != 0 {
		slot := _texture_slot_context(ctx.id, &ctx.resources.textures, texture.id)
		if slot != nil && slot.entry != nil && slot.entry.bind != nil {
			return slot.entry.bind, true
		}
	}
	return fallback, false
}

@(private)
_gpu_3d_material_binds :: proc(
	pass: ^Gpu_3D_Pass,
	material: Gpu_Material,
) -> (
	wg.BindGroup,
	bool,
	wg.BindGroup,
	bool,
	wg.BindGroup,
	bool,
) {
	assert(pass != nil && pass.owner != nil, "_gpu_3d_material_binds: nil pass")
	resources := &pass.owner.resources.gpu_3d
	texture_bind, textured := _gpu_3d_texture_bind(
		pass.owner,
		material.texture,
		pass.owner.rend.neutral_bind,
	)
	normal_bind, normal_mapped := _gpu_3d_texture_bind(
		pass.owner,
		material.normal_texture,
		resources.neutral_normal_bind,
	)
	roughness_bind, roughness_mapped := _gpu_3d_texture_bind(
		pass.owner,
		material.roughness_ao_texture,
		pass.owner.rend.neutral_bind,
	)
	return texture_bind, textured, normal_bind, normal_mapped, roughness_bind, roughness_mapped
}

// _gpu_3d_format_filterable reports whether a texture format may bind to a
// Float (filterable) texture slot sampled with a Filtering sampler. 32-bit
// float formats need the optional float32-filterable feature, which the
// device never requests; depth and integer formats never qualify.
@(private)
_gpu_3d_format_filterable :: proc(format: wg.TextureFormat) -> bool {
	#partial switch format {
	case .R32Float, .RG32Float, .RGBA32Float:
		return false
	}
	return _gpu_3d_format_float_sampleable(format)
}

// _gpu_3d_format_float_sampleable reports whether a format may bind to an
// UnfilterableFloat texture slot (any float or normalized colour format).
@(private)
_gpu_3d_format_float_sampleable :: proc(format: wg.TextureFormat) -> bool {
	#partial switch format {
	case .Undefined,
	     .Stencil8,
	     .Depth16Unorm,
	     .Depth24Plus,
	     .Depth24PlusStencil8,
	     .Depth32Float,
	     .Depth32FloatStencil8,
	     .R8Uint,
	     .R8Sint,
	     .R16Uint,
	     .R16Sint,
	     .RG8Uint,
	     .RG8Sint,
	     .R32Uint,
	     .R32Sint,
	     .RG16Uint,
	     .RG16Sint,
	     .RGBA8Uint,
	     .RGBA8Sint,
	     .RG32Uint,
	     .RG32Sint,
	     .RGBA16Uint,
	     .RGBA16Sint,
	     .RGBA32Uint,
	     .RGBA32Sint,
	     .RGB10A2Uint:
		return false
	}
	return true
}

// _gpu_3d_scene_view resolves a material texture to a single-sample view for
// a group-3 slot. Stale handles, multisampled textures and formats the slot
// cannot accept fall back to the neutral view (operating condition).
@(private)
_gpu_3d_scene_view :: proc(
	ctx: ^Context,
	texture: Texture2D,
	fallback: wg.TextureView,
	filterable: bool,
) -> (
	wg.TextureView,
	wg.Sampler,
	bool,
) {
	if texture.id == 0 do return fallback, nil, false
	slot := _texture_slot_context(ctx.id, &ctx.resources.textures, texture.id)
	if slot == nil || slot.entry == nil || slot.entry.view == nil do return fallback, nil, false
	entry := slot.entry
	if entry.sample_count > 1 do return fallback, nil, false
	if .TextureBinding not_in entry.usage && entry.usage != {} do return fallback, nil, false
	allowed := _gpu_3d_format_float_sampleable(entry.wgformat)
	if filterable do allowed = _gpu_3d_format_filterable(entry.wgformat)
	if !allowed do return fallback, nil, false
	return entry.view, entry.sampler, true
}

// _gpu_3d_scene_sampled_view resolves a filterable material texture together
// with its sampler; any unusable handle falls back to the neutral pair.
@(private)
_gpu_3d_scene_sampled_view :: proc(
	ctx: ^Context,
	texture: Texture2D,
) -> (
	wg.TextureView,
	wg.Sampler,
) {
	assert(ctx != nil, "_gpu_3d_scene_sampled_view: nil context")
	neutral_view := ctx.rend.neutral_view
	view, sampler, ok := _gpu_3d_scene_view(ctx, texture, neutral_view, true)
	if !ok || sampler == nil do return neutral_view, ctx.rend.neutral_sampler
	return view, sampler
}

@(private)
_gpu_3d_scene_bind :: proc(pass: ^Gpu_3D_Pass, material: Gpu_Material) -> (wg.BindGroup, bool) {
	assert(pass != nil && pass.owner != nil, "_gpu_3d_scene_bind: nil pass")
	resources := &pass.owner.resources.gpu_3d
	key := Gpu_3D_Scene_Bind_Key {
		roughness_texture = material.roughness_ao_texture.id,
		color_texture     = material.scene_color_texture.id,
		depth_texture     = material.scene_depth_texture.id,
		extra_0           = material.extra_texture_0.id,
		extra_1           = material.extra_texture_1.id,
		extra_data_0      = material.extra_data_texture.id,
		extra_data_1      = material.extra_data_texture_1.id,
		extra_data_2      = material.extra_data_texture_2.id,
	}
	for index in 0 ..< pass.scene_bind_count {
		entry := &pass.scene_binds[index]
		if entry.key == key do return entry.bind, true
	}
	neutral_view := pass.owner.rend.neutral_view
	roughness_view, roughness_sampler := _gpu_3d_scene_sampled_view(
		pass.owner,
		material.roughness_ao_texture,
	)
	color_view, color_sampler := _gpu_3d_scene_sampled_view(
		pass.owner,
		material.scene_color_texture,
	)
	extra_0_view, _, _ := _gpu_3d_scene_view(
		pass.owner,
		material.extra_texture_0,
		neutral_view,
		true,
	)
	extra_1_view, _, _ := _gpu_3d_scene_view(
		pass.owner,
		material.extra_texture_1,
		neutral_view,
		true,
	)
	data_0_view, _, _ := _gpu_3d_scene_view(
		pass.owner,
		material.extra_data_texture,
		resources.neutral_data_view,
		false,
	)
	data_1_view, _, _ := _gpu_3d_scene_view(
		pass.owner,
		material.extra_data_texture_1,
		resources.neutral_data_view,
		false,
	)
	data_2_view, _, _ := _gpu_3d_scene_view(
		pass.owner,
		material.extra_data_texture_2,
		resources.neutral_data_view,
		false,
	)
	depth_view := resources.neutral_depth_view
	if material.scene_depth_texture.id != 0 {
		slot := _texture_slot_context(
			pass.owner.id,
			&pass.owner.resources.textures,
			material.scene_depth_texture.id,
		)
		if slot != nil && slot.entry != nil do depth_view = slot.entry.view
	}
	entries := [GPU_3D_SCENE_BINDING_COUNT]wg.BindGroupEntry {
		{binding = 0, textureView = roughness_view},
		{binding = 1, sampler = roughness_sampler},
		{binding = 2, textureView = color_view},
		{binding = 3, sampler = color_sampler},
		{binding = 4, textureView = depth_view},
		{binding = 5, textureView = extra_0_view},
		{binding = 6, textureView = extra_1_view},
		{binding = 7, sampler = resources.extra_sampler},
		{binding = 8, textureView = data_0_view},
		{binding = 9, textureView = data_1_view},
		{binding = 10, textureView = data_2_view},
	}
	bind := wg.DeviceCreateBindGroup(
		pass.owner.device,
		&{
			layout = resources.scene_layout,
			entryCount = len(entries),
			entries = raw_data(entries[:]),
		},
	)
	if bind == nil do return nil, false
	_stats_gpu3d_scene_bind_creation(pass.owner)
	if pass.scene_bind_count < GPU_3D_SCENE_BINDS_PER_PASS {
		pass.scene_binds[pass.scene_bind_count] = {
			key  = key,
			bind = bind,
		}
		pass.scene_bind_count += 1
		return bind, true
	}
	return bind, false
}

@(private)
_gpu_3d_uniforms :: proc(
	pass: ^Gpu_3D_Pass,
	material: Gpu_Material,
	transform: Matrix,
	textured: bool,
	normal_mapped: bool,
	roughness_ao_mapped: bool,
) -> Gpu_3D_Uniforms {
	assert(pass != nil, "_gpu_3d_uniforms: nil pass")
	color_high := material.color_high
	if color_high == (Color{}) do color_high = material.color
	light := pass.light
	secondary_light := pass.secondary_light
	return {
		view_projection = pass.view_projection,
		model = transform,
		color = col_f(material.color),
		color_high = col_f(color_high),
		light_direction = {light.direction.x, light.direction.y, light.direction.z, 0},
		light_params = {light.ambient, light.diffuse, material.depth_nudge, pass.time},
		camera_position = {
			pass.camera_position.x,
			pass.camera_position.y,
			pass.camera_position.z,
			0,
		},
		custom_params = material.custom_params,
		custom_params_2 = material.custom_params_2,
		custom_params_3 = material.custom_params_3,
		custom_params_4 = material.custom_params_4,
		use_scalar = u32(1) if material.use_scalar else 0,
		use_texture = u32(1) if textured else 0,
		use_normal = u32(1) if normal_mapped else 0,
		use_roughness_ao = u32(1) if roughness_ao_mapped else 0,
		custom_params_5 = pass.underwater_primary,
		custom_params_6 = pass.underwater_secondary,
		custom_params_7 = material.custom_params_7,
		custom_params_8 = material.custom_params_8,
		custom_params_9 = material.custom_params_9,
		custom_params_10 = material.custom_params_10,
		custom_params_11 = material.custom_params_11,
		custom_params_12 = material.custom_params_12,
		custom_params_13 = material.custom_params_13,
		custom_params_14 = material.custom_params_14,
		custom_params_15 = material.custom_params_15,
		custom_params_16 = material.custom_params_16,
		custom_params_17 = material.custom_params_17,
		custom_params_18 = material.custom_params_18,
		custom_params_19 = material.custom_params_19,
		clip_plane = pass.clip_plane,
		clip_enabled = pass.clip_enabled,
		secondary_light_direction = {
			secondary_light.direction.x,
			secondary_light.direction.y,
			secondary_light.direction.z,
			0,
		},
		secondary_light_params = {secondary_light.ambient, secondary_light.diffuse, 0, 0},
		custom_params_20 = material.custom_params_20,
		custom_params_21 = material.custom_params_21,
		custom_params_22 = material.custom_params_22,
		custom_params_23 = material.custom_params_23,
		custom_params_24 = material.custom_params_24,
		custom_params_25 = material.custom_params_25,
		custom_params_26 = material.custom_params_26,
		custom_params_27 = material.custom_params_27,
		custom_params_28 = material.custom_params_28,
		custom_params_29 = material.custom_params_29,
		custom_params_30 = material.custom_params_30,
		custom_params_31 = material.custom_params_31,
		atmosphere_0 = pass.atmosphere[0],
		atmosphere_1 = pass.atmosphere[1],
		atmosphere_2 = pass.atmosphere[2],
	}
}

// _gpu_3d_draw_indexed encodes one indexed draw: uniforms, both bind groups,
// buffers, and stats. Shared by plain and instanced draws so the two paths
// cannot drift.
@(private)
_gpu_3d_draw_indexed :: proc(
	pass: ^Gpu_3D_Pass,
	entry: ^Gpu_3D_Mesh_Entry,
	material: Gpu_Material,
	transform: Matrix,
	instances_offset: u32,
	instance_count: u32,
) -> bool {
	assert(pass != nil, "_gpu_3d_draw_indexed: nil pass")
	assert(entry != nil, "_gpu_3d_draw_indexed: nil mesh entry")
	assert(instance_count >= 1, "_gpu_3d_draw_indexed: zero instances")
	assert(
		instance_count <= GPU_3D_MAX_INSTANCES_PER_DRAW,
		"_gpu_3d_draw_indexed: instance count exceeds GPU_3D_MAX_INSTANCES_PER_DRAW",
	)
	target_slot := _texture_slot_context(
		pass.owner.id,
		&pass.owner.resources.textures,
		pass.target.texture.texture.id,
	)
	if target_slot == nil || target_slot.entry == nil do return false
	shader_module, shader_id := _gpu_3d_shader_resolve(
		pass.owner.id,
		&pass.owner.resources.gpu_3d,
		material.shader,
	)
	pipeline := _gpu_3d_pipeline(
		pass.owner,
		target_slot.entry.wgformat,
		entry.primitive,
		material.style,
		pass.sample_count,
		shader_id,
		shader_module,
	)
	if pipeline == nil do return false
	texture_bind, textured, normal_bind, normal_mapped, _, roughness_ao_mapped :=
		_gpu_3d_material_binds(pass, material)
	scene_bind, scene_bind_cached := _gpu_3d_scene_bind(pass, material)
	if scene_bind == nil do return false
	uniforms := _gpu_3d_uniforms(
		pass,
		material,
		transform,
		textured,
		normal_mapped,
		roughness_ao_mapped,
	)
	offset, ok := _uniform_upload(pass.owner, &pass.owner.rend, &uniforms, size_of(uniforms))
	if !ok || pass.owner.rend.active_stream_slot < 0 do return false
	wg.RenderPassEncoderSetPipeline(pass.pass, pipeline)
	// Dynamic offsets follow binding order: shared uniforms then instances.
	offsets := [2]u32{offset, instances_offset}
	wg.RenderPassEncoderSetBindGroup(
		pass.pass,
		0,
		pass.owner.resources.gpu_3d.bind[pass.owner.rend.active_stream_slot],
		offsets[:],
	)
	wg.RenderPassEncoderSetBindGroup(pass.pass, 1, texture_bind)
	wg.RenderPassEncoderSetBindGroup(pass.pass, 2, normal_bind)
	wg.RenderPassEncoderSetBindGroup(pass.pass, 3, scene_bind)
	vertex_bytes := u64(entry.vertex_count) * size_of(Gpu_3D_Vertex)
	index_bytes := u64(entry.index_count) * size_of(u32)
	wg.RenderPassEncoderSetVertexBuffer(pass.pass, 0, entry.vertex_buffer, 0, vertex_bytes)
	wg.RenderPassEncoderSetIndexBuffer(pass.pass, entry.index_buffer, .Uint32, 0, index_bytes)
	wg.RenderPassEncoderDrawIndexed(pass.pass, entry.index_count, instance_count, 0, 0, 0)
	when GPU_TIMING_DIAGNOSTICS {
		_gpu_timing_diagnostic_draw(
			&pass.owner.gpu_timing.diagnostics[0],
			pass.pass,
			{
				path = .Gpu_3D,
				known = true,
				indexed = true,
				count = entry.index_count,
				instances = instance_count,
				shader_id = shader_id,
				pipeline_kind = u32(entry.primitive),
				pipeline_style = u32(material.style),
				scissor = {0, 0, u32(target_slot.entry.width), u32(target_slot.entry.height)},
			},
		)
	}
	_stats_gpu3d_draw(
		pass.owner,
		entry.vertex_count * instance_count,
		entry.index_count * instance_count,
	)
	_stats_pipeline_switch(pass.owner)
	_stats_bind_group_switches(pass.owner, 4)
	if !scene_bind_cached do wg.BindGroupRelease(scene_bind)
	return true
}

@(private)
_gpu_3d_should_upload_stream :: proc(allow_submit: bool) -> bool {
	return allow_submit
}

@(private)
_gpu_3d_pass_submit :: proc(pass: ^Gpu_3D_Pass) {
	ctx := pass.owner
	_gpu_timing_encoder_end(ctx, pass.encoder, pass.timing)
	retirement := u64(0)
	if pass.owns_stream do retirement = _submission_reserve(&ctx.submissions)
	allow_submit := !pass.owns_stream || retirement != 0
	upload_elapsed := f64(0)
	uploaded := _gpu_3d_should_upload_stream(allow_submit)
	if uploaded {
		upload_started := platform_now()
		slot_uploaded := _stream_slot_upload(ctx, &ctx.rend)
		assert(slot_uploaded, "_gpu_3d_pass_submit: stream upload failed")
		upload_elapsed = platform_now() - upload_started
	}
	cmd, encode_elapsed, submit_elapsed := _stats_finish_submit(ctx, pass.encoder, allow_submit)
	_stats_submission_call(
		ctx,
		.Intermediate,
		upload_elapsed,
		encode_elapsed,
		submit_elapsed,
		uploaded,
		cmd != nil,
		allow_submit && cmd != nil,
	)
	if allow_submit && cmd != nil {
		_stats_queue_submission(ctx)
		if pass.owns_stream {
			committed := _submission_commit(&ctx.submissions, retirement)
			assert(committed, "_gpu_3d_pass_submit: submission commit failed")
			if !_stream_slot_submitted(&ctx.rend, retirement) {
				_stats_stream_retirement_failure(ctx)
			}
		}
	} else if pass.owns_stream {
		if retirement != 0 {
			rolled_back := _submission_rollback(&ctx.submissions, retirement)
			assert(rolled_back, "_gpu_3d_pass_submit: submission rollback failed")
		}
		_stream_slot_abandon(&ctx.rend)
		_stats_stream_retirement_failure(ctx)
	}
	_stats_context_cpu_times(ctx, 0, 0, encode_elapsed, submit_elapsed, 0)
	if cmd != nil do wg.CommandBufferRelease(cmd)
	wg.CommandEncoderRelease(pass.encoder)
	for index in 0 ..< pass.scene_bind_count {
		if pass.scene_binds[index].bind != nil do wg.BindGroupRelease(pass.scene_binds[index].bind)
	}
	ctx.resources.gpu_3d.active_pass_generation = 0
	pass^ = {}
}

end_gpu_3d :: proc(pass: ^Gpu_3D_Pass) {
	if pass == nil || pass.owner == nil do return
	ctx := pass.owner
	if !_gpu_3d_pass_current(&ctx.resources.gpu_3d, pass) do return
	wg.RenderPassEncoderEnd(pass.pass)
	wg.RenderPassEncoderRelease(pass.pass)
	_gpu_3d_pass_submit(pass)
}

end_gpu_3d_and_copy_target_named :: proc(
	pass: ^Gpu_3D_Pass,
	destination: ^Gpu_3D_Target,
	name: string,
) -> bool {
	if pass == nil || pass.owner == nil do return false
	ctx := pass.owner
	if !_gpu_3d_pass_current(&ctx.resources.gpu_3d, pass) do return false
	copy, ok := _gpu_3d_target_copy_prepare(ctx, pass.target, destination)
	if !ok do return false
	wg.RenderPassEncoderEnd(pass.pass)
	wg.RenderPassEncoderRelease(pass.pass)
	timing := _gpu_timing_encoder_begin(ctx, pass.encoder, name)
	// An encoder-level timestamp is not ordered after the render pass on tiled
	// GPUs (Metal samples it at an encoder boundary that can begin while the
	// pass still executes), so the copy would otherwise report the whole pass
	// again. Measure it from the pass's own end-of-pass timestamp instead.
	if pass.pass_timed do _gpu_timing_span_anchor(&ctx.gpu_timing, timing, pass.pass_end_query)
	_gpu_3d_target_copy_encode(pass.encoder, copy)
	_gpu_timing_encoder_end(ctx, pass.encoder, timing)
	_gpu_3d_pass_submit(pass)
	return true
}

end_gpu_3d_and_copy_target :: proc(pass: ^Gpu_3D_Pass, destination: ^Gpu_3D_Target) -> bool {
	return end_gpu_3d_and_copy_target_named(pass, destination, "gpu3d-copy")
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
_gpu_3d_pass_current :: proc(resources: ^Gpu_3D_Resources, pass: ^Gpu_3D_Pass) -> bool {
	if resources == nil || pass == nil || pass.owner == nil do return false
	if resources != &pass.owner.resources.gpu_3d do return false
	if !pass.active || pass.generation == 0 do return false
	if pass.epoch != pass.owner.epoch do return false
	return pass.generation == resources.active_pass_generation
}
