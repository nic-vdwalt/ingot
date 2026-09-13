#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
gpu_compute_descriptors_reject_invalid_resources :: proc(t: ^testing.T) {
	testing.expect(t, !gpu_buffer_desc_valid({}))
	testing.expect(t, gpu_buffer_desc_valid({size = 16, usage = {.Storage}}))
	testing.expect(t, !gpu_texture_desc_valid({}))
	testing.expect(
		t,
		gpu_texture_desc_valid(
			{
				width = 8,
				height = 8,
				layers = 1,
				mip_count = 1,
				sample_count = 1,
				format = .RGBA16Float,
				usage = {.StorageBinding, .TextureBinding},
			},
		),
	)
	invalid_storage := Gpu_Binding_Desc {
		visibility = {.Compute},
		kind       = .Storage_Texture,
	}
	testing.expect(t, !gpu_binding_desc_valid(invalid_storage))
	invalid_storage.texture_format = .RGBA16Float
	testing.expect(t, gpu_binding_desc_valid(invalid_storage))
	sampled := Gpu_Binding_Desc {
		visibility          = {.Compute},
		kind                = .Sampled_Texture,
		texture_sample_type = .Unfilterable_Float,
	}
	testing.expect(t, gpu_binding_desc_valid(sampled))
}

@(test)
gpu_compute_handles_reject_stale_and_foreign_contexts :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	first.id = 2
	second.id = 3
	slot := &first.resources.compute.buffers[0]
	slot.generation = 1
	slot.occupied = true
	handle := Gpu_Buffer {
		id = _gpu_compute_handle(first.id, 0, slot.generation),
	}
	testing.expect(t, _gpu_buffer_get(first, handle) == nil)
	testing.expect(t, _gpu_buffer_get(second, handle) == nil)
	slot.generation = 2
	testing.expect(t, _gpu_buffer_get(first, handle) == nil)
}

@(test)
gpu_compute_dispatch_bounds_are_explicit :: proc(t: ^testing.T) {
	owner := new(Context)
	defer free(owner)
	owner.epoch = 7
	pass := Gpu_Compute_Pass {
		owner  = owner,
		epoch  = 7,
		active = true,
	}
	testing.expect(t, !compute_pass_dispatch(&pass, 0, 1, 1))
	testing.expect(t, !compute_pass_dispatch(&pass, GPU_COMPUTE_WORKGROUP_LIMIT + 1, 1, 1))
	pass.epoch = 6
	testing.expect(t, !compute_pass_dispatch(&pass, 1, 1, 1))
}

texture_mip_gpu_sample :: proc(t: ^testing.T, owner: ^Context, texture: Texture2D) {
	entry := context_get_texture(owner, texture.id)
	output := wg.DeviceCreateTexture(
		owner.device,
		&{
			size = {4, 1, 1},
			dimension = ._2D,
			format = .RGBA8Unorm,
			mipLevelCount = 1,
			sampleCount = 1,
			usage = {.StorageBinding, .CopySrc},
		},
	)
	defer wg.TextureRelease(output)
	view := wg.TextureCreateView(output, nil)
	defer wg.TextureViewRelease(view)
	source := `
@group(0) @binding(0) var image: texture_2d<f32>;
@group(0) @binding(1) var filtering: sampler;
@group(0) @binding(2) var output: texture_storage_2d<rgba8unorm, write>;
@compute @workgroup_size(1) fn main(@builtin(global_invocation_id) id: vec3<u32>) {
    let lod = array<f32, 4>(0.0, 1.0, 2.0, 1.5);
    textureStore(output, vec2<i32>(i32(id.x), 0),
        textureSampleLevel(image, filtering, vec2<f32>(0.5), lod[id.x]));
}`
	module := wg.DeviceCreateShaderModule(
		owner.device,
		&{nextInChain = &wg.ShaderSourceWGSL{chain = {sType = .ShaderSourceWGSL}, code = source}},
	)
	defer wg.ShaderModuleRelease(module)
	pipeline := wg.DeviceCreateComputePipeline(
		owner.device,
		&{compute = {module = module, entryPoint = "main"}},
	)
	defer wg.ComputePipelineRelease(pipeline)
	layout := wg.ComputePipelineGetBindGroupLayout(pipeline, 0)
	defer wg.BindGroupLayoutRelease(layout)
	entries := [3]wg.BindGroupEntry {
		{binding = 0, textureView = entry.view},
		{binding = 1, sampler = entry.sampler},
		{binding = 2, textureView = view},
	}
	group := wg.DeviceCreateBindGroup(
		owner.device,
		&{layout = layout, entryCount = 3, entries = raw_data(entries[:])},
	)
	defer wg.BindGroupRelease(group)
	encoder := wg.DeviceCreateCommandEncoder(owner.device, nil)
	defer wg.CommandEncoderRelease(encoder)
	pass := wg.CommandEncoderBeginComputePass(encoder, nil)
	wg.ComputePassEncoderSetPipeline(pass, pipeline)
	wg.ComputePassEncoderSetBindGroup(pass, 0, group, nil)
	wg.ComputePassEncoderDispatchWorkgroups(pass, 4, 1, 1)
	wg.ComputePassEncoderEnd(pass)
	wg.ComputePassEncoderRelease(pass)
	command := wg.CommandEncoderFinish(encoder, nil)
	defer wg.CommandBufferRelease(command)
	wg.QueueSubmit(owner.queue, {command})
	staging := _screenshot_copy(owner, output, 4, 1, 256)
	if !testing.expect(t, staging != nil) do return
	defer wg.BufferRelease(staging)
	if !testing.expect(t, _screenshot_map(owner, staging, 256)) do return
	mapped := wg.BufferGetConstMappedRange(staging, 0, 256)
	defer wg.BufferUnmap(staging)
	if !testing.expect(t, mapped != nil) do return
	pixels := mapped
	testing.expect(t, pixels[0] == 255 && pixels[1] == 0 && pixels[2] == 0)
	testing.expect(t, pixels[4] == 0 && pixels[5] == 255 && pixels[6] == 0)
	testing.expect(t, pixels[8] == 0 && pixels[9] == 0 && pixels[10] == 255)
	testing.expect(t, pixels[12] == 0 && pixels[13] >= 127 && pixels[13] <= 128)
	testing.expect(t, pixels[14] >= 127 && pixels[14] <= 128)
}

@(test)
texture_mip_gpu_roundtrip :: proc(t: ^testing.T) {
	gfx_shared_test_lock()
	defer gfx_shared_test_unlock()
	owner := new(Context)
	defer free(owner)
	owner.id = 2
	owner.instance = wg.CreateInstance()
	defer wg.InstanceRelease(owner.instance)
	adapter: Adapter_Res
	wg.InstanceRequestAdapter(
		owner.instance,
		nil,
		{mode = .AllowProcessEvents, callback = _on_adapter, userdata1 = &adapter},
	)
	for _ in 0 ..< 100000 {
		if adapter.done do break
		wg.InstanceProcessEvents(owner.instance)
	}
	if !testing.expect(t, adapter.done && adapter.adapter != nil) do return
	owner.adapter = adapter.adapter
	defer wg.AdapterRelease(owner.adapter)
	device: Device_Res
	wg.AdapterRequestDevice(
		owner.adapter,
		nil,
		{mode = .AllowProcessEvents, callback = _on_device, userdata1 = &device},
	)
	for _ in 0 ..< 100000 {
		if device.done do break
		wg.InstanceProcessEvents(owner.instance)
	}
	if !testing.expect(t, device.done && device.device != nil) do return
	owner.device = device.device
	defer wg.DeviceRelease(owner.device)
	owner.queue = wg.DeviceGetQueue(owner.device)
	defer wg.QueueRelease(owner.queue)
	owner.initialized = true
	layout_entries := [2]wg.BindGroupLayoutEntry {
		{
			binding = 0,
			visibility = {.Fragment},
			texture = {sampleType = .Float, viewDimension = ._2D},
		},
		{binding = 1, visibility = {.Fragment}, sampler = {type = .Filtering}},
	}
	owner.rend.tex_layout = wg.DeviceCreateBindGroupLayout(
		owner.device,
		&{entryCount = 2, entries = raw_data(layout_entries[:])},
	)
	defer wg.BindGroupLayoutRelease(owner.rend.tex_layout)
	red: [64]u8
	green: [16]u8
	blue := [4]u8{0, 0, 255, 255}
	for index in 0 ..< 16 {red[index * 4] = 255; red[index * 4 + 3] = 255}
	for index in 0 ..< 4 {green[index * 4 + 1] = 255; green[index * 4 + 3] = 255}
	levels := [3]Texture_Mip_Data {
		{4, 4, &red, 64, .UNCOMPRESSED_R8G8B8A8},
		{2, 2, &green, 16, .UNCOMPRESSED_R8G8B8A8},
		{1, 1, &blue, 4, .UNCOMPRESSED_R8G8B8A8},
	}
	texture := context_load_texture_mips_checked(owner, levels[:], {.TRILINEAR, 1})
	if !testing.expect(t, texture.id != 0) do return
	defer context_unload_texture(owner, texture)
	texture_mip_gpu_sample(t, owner, texture)
	testing.expect(t, context_set_texture_sampling_checked(owner, texture, {.TRILINEAR, 4}))
	texture_mip_gpu_sample(t, owner, texture)
	levels[2].byte_count = 3
	testing.expect(t, !context_update_texture_mips_checked(owner, texture, levels[:]))
	texture_mip_gpu_sample(t, owner, texture)
	levels[2].byte_count = 4
	entry := context_get_texture(owner, texture.id)
	entry.usage -= {.CopyDst}
	testing.expect(t, !context_update_texture_mips_checked(owner, texture, levels[:]))
	entry.usage += {.CopyDst}
	entry.wgformat = .RGBA16Float
	testing.expect(t, !context_update_texture_mips_checked(owner, texture, levels[:]))
	entry.wgformat = .RGBA8Unorm
	entry.sample_count = 4
	testing.expect(t, !context_update_texture_mips_checked(owner, texture, levels[:]))
	entry.sample_count = 1
	owner.id = 3
	testing.expect(t, !context_update_texture_mips_checked(owner, texture, levels[:]))
	owner.id = 2
	for &slot in owner.resources.textures.slots do slot.occupied = true
	owner.resources.textures.count = MAX_TEXTURES
	failed := context_load_texture_mips_checked(owner, levels[:], {.TRILINEAR, 4})
	testing.expect(t, failed.id == 0)
	for &slot in owner.resources.textures.slots do slot.occupied = slot.entry != nil
	testing.expect(t, owner.resources.textures.count == MAX_TEXTURES)
	owner.resources.textures.count = 1
}

@(test)
texture_mip_chains_validate_every_level :: proc(t: ^testing.T) {
	pixel: u8
	for size in ([][2]i32{{1, 1}, {1, 8}, {7, 5}, {1056, 1056}}) {
		levels: [TEXTURE_MIP_LEVEL_MAX]Texture_Mip_Data
		width, height := size[0], size[1]
		count: u32
		for index in 0 ..< TEXTURE_MIP_LEVEL_MAX {
			levels[index] = {
				width,
				height,
				&pixel,
				u64(width) * u64(height) * 4,
				.UNCOMPRESSED_R8G8B8A8,
			}
			count += 1
			if width == 1 && height == 1 do break
			width, height = max(width / 2, 1), max(height / 2, 1)
		}
		chain := levels[:count]
		testing.expect(t, texture_mip_chain_valid(chain, count))
		testing.expect(t, !texture_mip_chain_valid(chain, count + 1))
		for &level in chain {
			original := level
			level.byte_count -= 1
			testing.expect(t, !texture_mip_chain_valid(chain, count))
			level = original
			level.width += 1
			testing.expect(t, !texture_mip_chain_valid(chain, count))
			level = original
			level.pixels = nil
			testing.expect(t, !texture_mip_chain_valid(chain, count))
			level = original
			level.format = .UNCOMPRESSED_R8G8B8
			testing.expect(t, !texture_mip_chain_valid(chain, count))
			level = original
		}
		if count < TEXTURE_MIP_LEVEL_MAX {
			levels[count] = levels[count - 1]
			testing.expect(t, !texture_mip_chain_valid(levels[:count + 1], count + 1))
		}
	}
	testing.expect(t, !texture_mip_chain_valid(nil, 0))
}

@(test)
texture_sampling_is_explicit_and_bounded :: proc(t: ^testing.T) {
	for anisotropy in ([]u16{1, 2, 4, 8, 16}) {
		desc, valid := texture_sampling_descriptor({.TRILINEAR, anisotropy}, 5)
		testing.expect(t, valid)
		testing.expect(t, desc.maxAnisotropy == anisotropy)
		testing.expect(t, desc.mipmapFilter == .Linear)
		testing.expect(t, desc.minFilter == .Linear && desc.magFilter == .Linear)
		testing.expect(t, desc.lodMaxClamp == 4)
	}
	for sampling in ([]Texture_Sampling {
			{.POINT, 4},
			{.BILINEAR, 2},
			{.TRILINEAR, 0},
			{.TRILINEAR, 3},
			{.TRILINEAR, 32},
		}) {
		_, valid := texture_sampling_descriptor(sampling, 5)
		testing.expect(t, !valid)
	}
	_, valid := texture_sampling_descriptor({.TRILINEAR, 4}, 0)
	testing.expect(t, !valid)
	_, valid = texture_sampling_descriptor({.TRILINEAR, 4}, TEXTURE_MIP_LEVEL_MAX + 1)
	testing.expect(t, !valid)
	owner := new(Context)
	defer free(owner)
	owner.id = 2
	testing.expect(t, !context_update_texture_mips_checked(owner, {}, nil))
	testing.expect(t, !context_set_texture_sampling_checked(owner, {}, {.TRILINEAR, 4}))
	testing.expect(t, context_load_texture_mips_checked(owner, nil, {.TRILINEAR, 4}).id == 0)
}

@(test)
gpu_compute_resource_bound_fits_handle_capacity :: proc(t: ^testing.T) {
	testing.expect(t, GPU_COMPUTE_RESOURCE_MAX > 0)
	testing.expect(t, GPU_COMPUTE_RESOURCE_MAX <= RESOURCE_SLOT_COUNT)
	testing.expect(t, GPU_COMPUTE_WORKGROUP_LIMIT == 65_535)
	_ = wg.TextureFormat.RGBA16Float
}
