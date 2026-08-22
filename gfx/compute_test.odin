#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

@(test)
gpu_compute_descriptors_reject_invalid_resources :: proc(t: ^testing.T) {
	testing.expect(t, !gpu_buffer_desc_valid({}))
	testing.expect(t, gpu_buffer_desc_valid({size = 16, usage = {.Storage}}))
	testing.expect(t, !gpu_texture_desc_valid({}))
	testing.expect(t, gpu_texture_desc_valid({
		width = 8,
		height = 8,
		layers = 1,
		mip_count = 1,
		sample_count = 1,
		format = .RGBA16Float,
		usage = {.StorageBinding, .TextureBinding},
	}))
	invalid_storage := Gpu_Binding_Desc {
		visibility = {.Compute},
		kind = .Storage_Texture,
	}
	testing.expect(t, !gpu_binding_desc_valid(invalid_storage))
	invalid_storage.texture_format = .RGBA16Float
	testing.expect(t, gpu_binding_desc_valid(invalid_storage))
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
	handle := Gpu_Buffer{id = _gpu_compute_handle(first.id, 0, slot.generation)}
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
	pass := Gpu_Compute_Pass{owner = owner, epoch = 7, active = true}
	testing.expect(t, !compute_pass_dispatch(&pass, 0, 1, 1))
	testing.expect(t, !compute_pass_dispatch(&pass, GPU_COMPUTE_WORKGROUP_LIMIT + 1, 1, 1))
	pass.epoch = 6
	testing.expect(t, !compute_pass_dispatch(&pass, 1, 1, 1))
}

@(test)
gpu_compute_resource_bound_fits_handle_capacity :: proc(t: ^testing.T) {
	testing.expect(t, GPU_COMPUTE_RESOURCE_MAX > 0)
	testing.expect(t, GPU_COMPUTE_RESOURCE_MAX <= RESOURCE_SLOT_COUNT)
	testing.expect(t, GPU_COMPUTE_WORKGROUP_LIMIT == 65_535)
	_ = wg.TextureFormat.RGBA16Float
}
