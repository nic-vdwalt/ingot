package gfx

import wg "vendor:wgpu"

GPU_COMPUTE_RESOURCE_MAX :: 128
GPU_COMPUTE_WORKGROUP_LIMIT :: u32(65_535)

Gpu_Compute_Pass :: struct {
	owner:  ^Context,
	epoch:  u64,
	pass:   wg.ComputePassEncoder,
	active: bool,
}

@(private)
Gpu_Buffer_Slot :: struct {
	value:      wg.Buffer,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_Sampler_Slot :: struct {
	value:      wg.Sampler,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_Layout_Slot :: struct {
	value:      wg.BindGroupLayout,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_Group_Slot :: struct {
	value:      wg.BindGroup,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_Module_Slot :: struct {
	value:      wg.ShaderModule,
	generation: u32,
	occupied:   bool,
}

@(private)
Gpu_Pipeline_Slot :: struct {
	value:      wg.ComputePipeline,
	generation: u32,
	occupied:   bool,
}

Gpu_Compute_Resources :: struct {
	buffers:    [GPU_COMPUTE_RESOURCE_MAX]Gpu_Buffer_Slot,
	samplers:   [GPU_COMPUTE_RESOURCE_MAX]Gpu_Sampler_Slot,
	layouts:    [GPU_COMPUTE_RESOURCE_MAX]Gpu_Layout_Slot,
	groups:     [GPU_COMPUTE_RESOURCE_MAX]Gpu_Group_Slot,
	modules:    [GPU_COMPUTE_RESOURCE_MAX]Gpu_Module_Slot,
	pipelines:  [GPU_COMPUTE_RESOURCE_MAX]Gpu_Pipeline_Slot,
	buffer_n:   u32,
	sampler_n:  u32,
	layout_n:   u32,
	group_n:    u32,
	module_n:   u32,
	pipeline_n: u32,
}

@(private)
_gpu_compute_handle :: proc(context_id: u32, index: int, generation: u32) -> u32 {
	assert(index >= 0 && index < GPU_COMPUTE_RESOURCE_MAX)
	return _resource_handle_make_context(context_id, index, generation)
}

@(private)
_gpu_compute_slot :: proc(context_id, id: u32, capacity: int) -> (int, u32, bool) {
	if id == 0 do return 0, 0, false
	handle_context := (id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	if handle_context != context_id do return 0, 0, false
	return _resource_handle_decode(id, capacity)
}

@(private)
_gpu_buffer_get :: proc(ctx: ^Context, handle: Gpu_Buffer) -> wg.Buffer {
	assert(ctx != nil, "_gpu_buffer_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.buffers))
	if !ok do return nil
	slot := &ctx.resources.compute.buffers[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

@(private)
_gpu_sampler_get :: proc(ctx: ^Context, handle: Gpu_Sampler) -> wg.Sampler {
	assert(ctx != nil, "_gpu_sampler_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.samplers))
	if !ok do return nil
	slot := &ctx.resources.compute.samplers[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

@(private)
_gpu_layout_get :: proc(ctx: ^Context, handle: Gpu_Bind_Group_Layout) -> wg.BindGroupLayout {
	assert(ctx != nil, "_gpu_layout_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.layouts))
	if !ok do return nil
	slot := &ctx.resources.compute.layouts[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

@(private)
_gpu_group_get :: proc(ctx: ^Context, handle: Gpu_Bind_Group) -> wg.BindGroup {
	assert(ctx != nil, "_gpu_group_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.groups))
	if !ok do return nil
	slot := &ctx.resources.compute.groups[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

@(private)
_gpu_module_get :: proc(ctx: ^Context, handle: Gpu_Shader_Module) -> wg.ShaderModule {
	assert(ctx != nil, "_gpu_module_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.modules))
	if !ok do return nil
	slot := &ctx.resources.compute.modules[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

@(private)
_gpu_pipeline_get :: proc(ctx: ^Context, handle: Gpu_Compute_Pipeline) -> wg.ComputePipeline {
	assert(ctx != nil, "_gpu_pipeline_get: nil context")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.pipelines))
	if !ok do return nil
	slot := &ctx.resources.compute.pipelines[index]
	if !slot.occupied || slot.generation != generation do return nil
	return slot.value
}

context_create_gpu_buffer :: proc(ctx: ^Context, desc: Gpu_Buffer_Desc) -> Gpu_Buffer {
	assert(ctx != nil, "context_create_gpu_buffer: nil context")
	if !ctx.initialized || !gpu_buffer_desc_valid(desc) do return {}
	resources := &ctx.resources.compute
	if resources.buffer_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.buffers {
		if slot.occupied do continue
		value := wg.DeviceCreateBuffer(ctx.device, &{size = desc.size, usage = desc.usage})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.buffer_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	assert(false, "context_create_gpu_buffer: count mismatch")
	return {}
}

create_gpu_buffer :: proc(desc: Gpu_Buffer_Desc) -> Gpu_Buffer {
	return context_create_gpu_buffer(default_context(), desc)
}

context_write_gpu_buffer :: proc(ctx: ^Context, buffer: Gpu_Buffer, offset: u64, data: []u8) -> bool {
	assert(ctx != nil, "context_write_gpu_buffer: nil context")
	value := _gpu_buffer_get(ctx, buffer)
	if value == nil || len(data) == 0 do return false
	if offset > max(u64) - u64(len(data)) do return false
	wg.QueueWriteBuffer(ctx.queue, value, offset, raw_data(data), uint(len(data)))
	return true
}

write_gpu_buffer :: proc(buffer: Gpu_Buffer, offset: u64, data: []u8) -> bool {
	return context_write_gpu_buffer(default_context(), buffer, offset, data)
}

context_destroy_gpu_buffer :: proc(ctx: ^Context, handle: ^Gpu_Buffer) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_buffer: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.buffers))
	if !ok do return
	slot := &ctx.resources.compute.buffers[index]
	if !slot.occupied || slot.generation != generation do return
	wg.BufferRelease(slot.value)
	slot.value = nil
	slot.occupied = false
	ctx.resources.compute.buffer_n -= 1
	handle^ = {}
}

destroy_gpu_buffer :: proc(handle: ^Gpu_Buffer) {
	context_destroy_gpu_buffer(default_context(), handle)
}

context_create_gpu_texture :: proc(ctx: ^Context, desc: Gpu_Texture_Desc) -> Gpu_Texture {
	assert(ctx != nil, "context_create_gpu_texture: nil context")
	if !ctx.initialized || !gpu_texture_desc_valid(desc) do return {}
	if desc.layers != 1 || desc.sample_count != 1 do return {}
	entry := new(Tex_Entry)
	entry.width = i32(desc.width)
	entry.height = i32(desc.height)
	entry.wgformat = desc.format
	entry.sample_count = desc.sample_count
	entry.mip_count = desc.mip_count
	entry.usage = desc.usage
	entry.tex = wg.DeviceCreateTexture(ctx.device, &{
		usage = desc.usage,
		dimension = ._2D,
		size = {desc.width, desc.height, desc.layers},
		format = desc.format,
		mipLevelCount = desc.mip_count,
		sampleCount = desc.sample_count,
	})
	if entry.tex == nil {
		free(entry)
		return {}
	}
	entry.view = wg.TextureCreateView(entry.tex, nil)
	if entry.view == nil {
		wg.TextureRelease(entry.tex)
		free(entry)
		return {}
	}
	if .TextureBinding in desc.usage do _tex_build_bind(ctx, entry)
	id := _texture_register_context(ctx.id, &ctx.resources.textures, entry)
	if id == 0 {
		_texture_entry_destroy(ctx, entry)
		return {}
	}
	return {id = id}
}

create_gpu_texture :: proc(desc: Gpu_Texture_Desc) -> Gpu_Texture {
	return context_create_gpu_texture(default_context(), desc)
}

gpu_texture_as_texture_2d :: proc(handle: Gpu_Texture) -> Texture2D {
	entry := context_get_texture(default_context(), handle.id)
	if entry == nil do return {}
	return {
		id = handle.id,
		width = entry.width,
		height = entry.height,
		mipmaps = i32(entry.mip_count),
		format = .UNCOMPRESSED_R16G16B16A16,
	}
}

context_destroy_gpu_texture :: proc(ctx: ^Context, handle: ^Gpu_Texture) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_texture: invalid argument")
	slot := _texture_slot_context(ctx.id, &ctx.resources.textures, handle.id)
	if slot == nil do return
	_texture_entry_destroy(ctx, slot.entry)
	slot.entry = nil
	slot.occupied = false
	ctx.resources.textures.count -= 1
	handle^ = {}
}

destroy_gpu_texture :: proc(handle: ^Gpu_Texture) {
	context_destroy_gpu_texture(default_context(), handle)
}

context_create_gpu_sampler :: proc(ctx: ^Context, kind: Gpu_Sampler_Kind) -> Gpu_Sampler {
	assert(ctx != nil, "context_create_gpu_sampler: nil context")
	if !ctx.initialized do return {}
	resources := &ctx.resources.compute
	if resources.sampler_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.samplers {
		if slot.occupied do continue
		filter: wg.FilterMode = .Linear if kind == .Filtering else .Nearest
		value := wg.DeviceCreateSampler(ctx.device, &{
			magFilter = filter,
			minFilter = filter,
			mipmapFilter = .Nearest,
			addressModeU = .Repeat,
			addressModeV = .Repeat,
			addressModeW = .Repeat,
			compare = .Undefined,
			maxAnisotropy = 1,
		})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.sampler_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	return {}
}

create_gpu_sampler :: proc(kind: Gpu_Sampler_Kind) -> Gpu_Sampler {
	return context_create_gpu_sampler(default_context(), kind)
}

context_create_gpu_shader_module :: proc(ctx: ^Context, source: string) -> Gpu_Shader_Module {
	assert(ctx != nil, "context_create_gpu_shader_module: nil context")
	if !ctx.initialized || len(source) == 0 || len(source) > SHADER_SOURCE_BYTES_MAX do return {}
	resources := &ctx.resources.compute
	if resources.module_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.modules {
		if slot.occupied do continue
		value := wg.DeviceCreateShaderModule(ctx.device, &{
			nextInChain = &wg.ShaderSourceWGSL{
				chain = {sType = .ShaderSourceWGSL},
				code = source,
			},
		})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.module_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	return {}
}

create_gpu_shader_module :: proc(source: string) -> Gpu_Shader_Module {
	return context_create_gpu_shader_module(default_context(), source)
}

@(private)
_gpu_stage_flags :: proc(stages: bit_set[Gpu_Shader_Stage]) -> wg.ShaderStageFlags {
	result: wg.ShaderStageFlags
	if .Vertex in stages do result += {.Vertex}
	if .Fragment in stages do result += {.Fragment}
	if .Compute in stages do result += {.Compute}
	return result
}

context_create_gpu_bind_group_layout :: proc(
	ctx: ^Context,
	descs: []Gpu_Binding_Desc,
) -> Gpu_Bind_Group_Layout {
	assert(ctx != nil, "context_create_gpu_bind_group_layout: nil context")
	if !ctx.initialized || len(descs) == 0 || len(descs) > 16 do return {}
	entries: [16]wg.BindGroupLayoutEntry
	for desc, index in descs {
		if !gpu_binding_desc_valid(desc) do return {}
		entry := &entries[index]
		entry.binding = desc.binding
		entry.visibility = _gpu_stage_flags(desc.visibility)
		switch desc.kind {
		case .Uniform_Buffer:
			entry.buffer = {type = .Uniform, minBindingSize = desc.minimum_size}
		case .Read_Only_Storage_Buffer:
			entry.buffer = {type = .ReadOnlyStorage, minBindingSize = desc.minimum_size}
		case .Storage_Buffer:
			entry.buffer = {type = .Storage, minBindingSize = desc.minimum_size}
		case .Sampled_Texture:
			entry.texture = {sampleType = .Float, viewDimension = ._2D}
		case .Depth_Texture:
			entry.texture = {sampleType = .Depth, viewDimension = ._2D}
		case .Storage_Texture:
			access: wg.StorageTextureAccess = .WriteOnly
			if desc.storage_access == .Read_Only do access = .ReadOnly
			if desc.storage_access == .Read_Write do access = .ReadWrite
			entry.storageTexture = {
				access = access,
				format = desc.texture_format,
				viewDimension = ._2D,
			}
		case .Sampler:
			type: wg.SamplerBindingType = .Filtering
			if desc.sampler_kind == .Non_Filtering do type = .NonFiltering
			entry.sampler = {type = type}
		case .Comparison_Sampler:
			entry.sampler = {type = .Comparison}
		}
	}
	resources := &ctx.resources.compute
	if resources.layout_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.layouts {
		if slot.occupied do continue
		value := wg.DeviceCreateBindGroupLayout(ctx.device, &{
			entryCount = uint(len(descs)),
			entries = raw_data(entries[:len(descs)]),
		})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.layout_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	return {}
}

create_gpu_bind_group_layout :: proc(descs: []Gpu_Binding_Desc) -> Gpu_Bind_Group_Layout {
	return context_create_gpu_bind_group_layout(default_context(), descs)
}

context_create_gpu_bind_group :: proc(
	ctx: ^Context,
	layout: Gpu_Bind_Group_Layout,
	bindings: []Gpu_Bind_Entry,
) -> Gpu_Bind_Group {
	assert(ctx != nil, "context_create_gpu_bind_group: nil context")
	layout_value := _gpu_layout_get(ctx, layout)
	if layout_value == nil || len(bindings) == 0 || len(bindings) > 16 do return {}
	entries: [16]wg.BindGroupEntry
	for binding, index in bindings {
		entry := &entries[index]
		entry.binding = binding.binding
		if binding.buffer.id != 0 {
			entry.buffer = _gpu_buffer_get(ctx, binding.buffer)
			entry.offset = binding.offset
			entry.size = binding.size
			if entry.buffer == nil do return {}
		} else if binding.texture.id != 0 {
			texture := context_get_texture(ctx, binding.texture.id)
			if texture == nil do return {}
			entry.textureView = texture.view
		} else if binding.sampler.id != 0 {
			entry.sampler = _gpu_sampler_get(ctx, binding.sampler)
			if entry.sampler == nil do return {}
		} else {
			return {}
		}
	}
	resources := &ctx.resources.compute
	if resources.group_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.groups {
		if slot.occupied do continue
		value := wg.DeviceCreateBindGroup(ctx.device, &{
			layout = layout_value,
			entryCount = uint(len(bindings)),
			entries = raw_data(entries[:len(bindings)]),
		})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.group_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	return {}
}

create_gpu_bind_group :: proc(
	layout: Gpu_Bind_Group_Layout,
	bindings: []Gpu_Bind_Entry,
) -> Gpu_Bind_Group {
	return context_create_gpu_bind_group(default_context(), layout, bindings)
}

context_create_gpu_compute_pipeline :: proc(
	ctx: ^Context,
	module: Gpu_Shader_Module,
	layout: Gpu_Bind_Group_Layout,
	entry_point := "cs_main",
) -> Gpu_Compute_Pipeline {
	assert(ctx != nil, "context_create_gpu_compute_pipeline: nil context")
	module_value := _gpu_module_get(ctx, module)
	layout_value := _gpu_layout_get(ctx, layout)
	if module_value == nil || layout_value == nil || len(entry_point) == 0 do return {}
	layouts := [1]wg.BindGroupLayout{layout_value}
	pipeline_layout := wg.DeviceCreatePipelineLayout(ctx.device, &{
		bindGroupLayoutCount = 1,
		bindGroupLayouts = raw_data(layouts[:]),
	})
	if pipeline_layout == nil do return {}
	defer wg.PipelineLayoutRelease(pipeline_layout)
	resources := &ctx.resources.compute
	if resources.pipeline_n >= GPU_COMPUTE_RESOURCE_MAX do return {}
	for &slot, index in resources.pipelines {
		if slot.occupied do continue
		value := wg.DeviceCreateComputePipeline(ctx.device, &{
			layout = pipeline_layout,
			compute = {module = module_value, entryPoint = entry_point},
		})
		if value == nil do return {}
		slot.generation = _resource_generation_next(slot.generation)
		slot.value = value
		slot.occupied = true
		resources.pipeline_n += 1
		return {id = _gpu_compute_handle(ctx.id, index, slot.generation)}
	}
	return {}
}

create_gpu_compute_pipeline :: proc(
	module: Gpu_Shader_Module,
	layout: Gpu_Bind_Group_Layout,
	entry_point := "cs_main",
) -> Gpu_Compute_Pipeline {
	return context_create_gpu_compute_pipeline(default_context(), module, layout, entry_point)
}

context_begin_gpu_compute_pass :: proc(commands: ^Gpu_Command_List) -> (Gpu_Compute_Pass, bool) {
	assert(commands != nil, "context_begin_gpu_compute_pass: nil commands")
	if !commands.active || commands.owner == nil do return {}, false
	if commands.epoch != commands.owner.epoch do return {}, false
	pass := wg.CommandEncoderBeginComputePass(commands.encoder, nil)
	if pass == nil do return {}, false
	return {owner = commands.owner, epoch = commands.epoch, pass = pass, active = true}, true
}

begin_gpu_compute_pass :: proc(commands: ^Gpu_Command_List) -> (Gpu_Compute_Pass, bool) {
	return context_begin_gpu_compute_pass(commands)
}

compute_pass_set_pipeline :: proc(pass: ^Gpu_Compute_Pass, pipeline: Gpu_Compute_Pipeline) -> bool {
	assert(pass != nil, "compute_pass_set_pipeline: nil pass")
	if !pass.active || pass.owner == nil || pass.epoch != pass.owner.epoch do return false
	value := _gpu_pipeline_get(pass.owner, pipeline)
	if value == nil do return false
	wg.ComputePassEncoderSetPipeline(pass.pass, value)
	return true
}

compute_pass_set_bind_group :: proc(pass: ^Gpu_Compute_Pass, index: u32, group: Gpu_Bind_Group) -> bool {
	assert(pass != nil, "compute_pass_set_bind_group: nil pass")
	if !pass.active || pass.owner == nil || pass.epoch != pass.owner.epoch do return false
	value := _gpu_group_get(pass.owner, group)
	if value == nil do return false
	wg.ComputePassEncoderSetBindGroup(pass.pass, index, value)
	return true
}

compute_pass_dispatch :: proc(pass: ^Gpu_Compute_Pass, x, y, z: u32) -> bool {
	assert(pass != nil, "compute_pass_dispatch: nil pass")
	if !pass.active || pass.owner == nil || pass.epoch != pass.owner.epoch do return false
	if x == 0 || y == 0 || z == 0 do return false
	if max(x, max(y, z)) > GPU_COMPUTE_WORKGROUP_LIMIT do return false
	wg.ComputePassEncoderDispatchWorkgroups(pass.pass, x, y, z)
	return true
}

end_gpu_compute_pass :: proc(pass: ^Gpu_Compute_Pass) -> bool {
	assert(pass != nil, "end_gpu_compute_pass: nil pass")
	if !pass.active || pass.pass == nil do return false
	wg.ComputePassEncoderEnd(pass.pass)
	wg.ComputePassEncoderRelease(pass.pass)
	pass^ = {}
	return true
}

context_destroy_gpu_sampler :: proc(ctx: ^Context, handle: ^Gpu_Sampler) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_sampler: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.samplers))
	if !ok do return
	slot := &ctx.resources.compute.samplers[index]
	if !slot.occupied || slot.generation != generation do return
	wg.SamplerRelease(slot.value)
	slot^ = {generation = slot.generation}
	ctx.resources.compute.sampler_n -= 1
	handle^ = {}
}

destroy_gpu_sampler :: proc(handle: ^Gpu_Sampler) {
	context_destroy_gpu_sampler(default_context(), handle)
}

context_destroy_gpu_bind_group :: proc(ctx: ^Context, handle: ^Gpu_Bind_Group) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_bind_group: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.groups))
	if !ok do return
	slot := &ctx.resources.compute.groups[index]
	if !slot.occupied || slot.generation != generation do return
	wg.BindGroupRelease(slot.value)
	slot^ = {generation = slot.generation}
	ctx.resources.compute.group_n -= 1
	handle^ = {}
}

destroy_gpu_bind_group :: proc(handle: ^Gpu_Bind_Group) {
	context_destroy_gpu_bind_group(default_context(), handle)
}

context_destroy_gpu_bind_group_layout :: proc(ctx: ^Context, handle: ^Gpu_Bind_Group_Layout) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_bind_group_layout: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.layouts))
	if !ok do return
	slot := &ctx.resources.compute.layouts[index]
	if !slot.occupied || slot.generation != generation do return
	wg.BindGroupLayoutRelease(slot.value)
	slot^ = {generation = slot.generation}
	ctx.resources.compute.layout_n -= 1
	handle^ = {}
}

destroy_gpu_bind_group_layout :: proc(handle: ^Gpu_Bind_Group_Layout) {
	context_destroy_gpu_bind_group_layout(default_context(), handle)
}

context_destroy_gpu_shader_module :: proc(ctx: ^Context, handle: ^Gpu_Shader_Module) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_shader_module: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.modules))
	if !ok do return
	slot := &ctx.resources.compute.modules[index]
	if !slot.occupied || slot.generation != generation do return
	wg.ShaderModuleRelease(slot.value)
	slot^ = {generation = slot.generation}
	ctx.resources.compute.module_n -= 1
	handle^ = {}
}

destroy_gpu_shader_module :: proc(handle: ^Gpu_Shader_Module) {
	context_destroy_gpu_shader_module(default_context(), handle)
}

context_destroy_gpu_compute_pipeline :: proc(ctx: ^Context, handle: ^Gpu_Compute_Pipeline) {
	assert(ctx != nil && handle != nil, "context_destroy_gpu_compute_pipeline: invalid argument")
	index, generation, ok := _gpu_compute_slot(ctx.id, handle.id, len(ctx.resources.compute.pipelines))
	if !ok do return
	slot := &ctx.resources.compute.pipelines[index]
	if !slot.occupied || slot.generation != generation do return
	wg.ComputePipelineRelease(slot.value)
	slot^ = {generation = slot.generation}
	ctx.resources.compute.pipeline_n -= 1
	handle^ = {}
}

destroy_gpu_compute_pipeline :: proc(handle: ^Gpu_Compute_Pipeline) {
	context_destroy_gpu_compute_pipeline(default_context(), handle)
}

@(private)
_gpu_compute_resources_destroy :: proc(resources: ^Gpu_Compute_Resources) {
	assert(resources != nil, "_gpu_compute_resources_destroy: nil resources")
	for &slot in resources.groups do if slot.occupied do wg.BindGroupRelease(slot.value)
	for &slot in resources.pipelines do if slot.occupied do wg.ComputePipelineRelease(slot.value)
	for &slot in resources.layouts do if slot.occupied do wg.BindGroupLayoutRelease(slot.value)
	for &slot in resources.modules do if slot.occupied do wg.ShaderModuleRelease(slot.value)
	for &slot in resources.samplers do if slot.occupied do wg.SamplerRelease(slot.value)
	for &slot in resources.buffers do if slot.occupied do wg.BufferRelease(slot.value)
	resources^ = {}
}
