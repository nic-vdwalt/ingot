#+build !js
package gfx

import "core:testing"

@(test)
resource_handle_round_trip_and_wrap :: proc(t: ^testing.T) {
	handle := _resource_handle_make(RESOURCE_SLOT_COUNT - 1, 7)
	index, generation, ok := _resource_handle_decode(handle, RESOURCE_SLOT_COUNT)
	testing.expect(t, ok)
	testing.expect_value(t, index, RESOURCE_SLOT_COUNT - 1)
	testing.expect_value(t, generation, u32(7))
	testing.expect_value(t, _resource_generation_next(RESOURCE_GENERATION_MASK), u32(1))
}

@(test)
resource_handle_rejects_invalid_values :: proc(t: ^testing.T) {
	_, _, zero_ok := _resource_handle_decode(0, RESOURCE_SLOT_COUNT)
	testing.expect(t, !zero_ok)
	handle := _resource_handle_make(MAX_ATLASES, 1)
	_, _, range_ok := _resource_handle_decode(handle, MAX_ATLASES)
	testing.expect(t, !range_ok)
}

@(test)
texture_pool_reuses_slots_without_aliasing :: proc(t: ^testing.T) {
	resources: Texture_Resources
	first_entry, second_entry: Tex_Entry
	first := _texture_register(&resources, &first_entry)
	first_slot := _texture_slot(&resources, first)
	testing.expect(t, first_slot != nil)
	first_slot.entry = nil
	first_slot.occupied = false
	resources.count -= 1
	second := _texture_register(&resources, &second_entry)
	testing.expect(t, first != second)
	testing.expect(t, _texture_slot(&resources, first) == nil)
	testing.expect(t, _texture_slot(&resources, second).entry == &second_entry)
}

@(test)
atlas_and_shader_pools_reject_stale_handles :: proc(t: ^testing.T) {
	atlases: Atlas_Resources
	atlas_entry: Atlas
	old_atlas := _atlas_register(&atlases, &atlas_entry)
	atlas_slot := _atlas_slot(&atlases, old_atlas)
	atlas_slot.occupied = false
	atlases.count -= 1
	new_atlas := _atlas_register(&atlases, &atlas_entry)
	testing.expect(t, old_atlas != new_atlas)
	testing.expect(t, _atlas_slot(&atlases, old_atlas) == nil)

	shaders: Shader_Resources
	shader_entry: Shader_Entry
	old_shader := _shader_register(&shaders, &shader_entry)
	shader_slot := _shader_slot(&shaders, old_shader)
	shader_slot.occupied = false
	shaders.count -= 1
	new_shader := _shader_register(&shaders, &shader_entry)
	testing.expect(t, old_shader != new_shader)
	testing.expect(t, _shader_slot(&shaders, old_shader) == nil)
}

@(test)
vao_pool_rejects_reused_slot_handle :: proc(t: ^testing.T) {
	resources: Rlgl_Resources
	entry: Vao
	slot := &resources.vaos[0]
	slot.generation = _resource_generation_next(slot.generation)
	slot.entry = &entry
	slot.occupied = true
	old_id := _resource_handle_make(0, slot.generation)
	testing.expect(t, _vao_slot(&resources, old_id) == slot)
	slot.generation = _resource_generation_next(slot.generation)
	new_id := _resource_handle_make(0, slot.generation)
	testing.expect(t, old_id != new_id)
	testing.expect(t, _vao_slot(&resources, old_id) == nil)
	testing.expect(t, _vao_slot(&resources, new_id) == slot)
}

@(test)
gpu_3d_pass_rejects_stale_generation :: proc(t: ^testing.T) {
	resources: Gpu_3D_Resources
	resources.active_pass_generation = 12
	current := Gpu_3D_Pass {
		owner      = default_context(),
		epoch      = context_epoch(default_context()),
		generation = 12,
		active     = true,
	}
	stale := Gpu_3D_Pass {
		owner      = default_context(),
		epoch      = context_epoch(default_context()),
		generation = 11,
		active     = true,
	}
	testing.expect(t, _gpu_3d_pass_current(&resources, &current))
	testing.expect(t, !_gpu_3d_pass_current(&resources, &stale))
	testing.expect(t, !_gpu_3d_pass_current(&resources, nil))
}

@(test)
submission_reservation_is_nonzero_and_rollback_is_atomic :: proc(t: ^testing.T) {
	tracker: Submission_Tracker
	_submission_init(&tracker, default_context())
	first := _submission_reserve(&tracker)
	second := _submission_reserve(&tracker)
	testing.expect(t, first != 0)
	testing.expect(t, second > first)
	testing.expect_value(t, tracker.count, u32(2))
	testing.expect(t, !_submission_rollback(&tracker, first))
	testing.expect(t, _submission_rollback(&tracker, second))
	testing.expect_value(t, tracker.count, u32(1))
	testing.expect(t, _submission_find(&tracker, first) != nil)
	testing.expect(t, _submission_find(&tracker, second) == nil)
}

@(test)
submission_reservation_stops_at_fixed_capacity :: proc(t: ^testing.T) {
	tracker: Submission_Tracker
	_submission_init(&tracker, default_context())
	for _ in 0 ..< MAX_IN_FLIGHT_SUBMISSIONS {
		testing.expect(t, _submission_reserve(&tracker) != 0)
	}
	testing.expect_value(t, tracker.count, u32(MAX_IN_FLIGHT_SUBMISSIONS))
	testing.expect_value(t, _submission_reserve(&tracker), u64(0))
	testing.expect_value(t, tracker.count, u32(MAX_IN_FLIGHT_SUBMISSIONS))
}
