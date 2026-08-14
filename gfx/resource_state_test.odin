#+build !js
package gfx

import "core:testing"
import wg "vendor:wgpu"

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
texture_handles_reject_cross_context_lookup :: proc(t: ^testing.T) {
	first, second: Texture_Resources
	first_entry, second_entry: Tex_Entry
	first_id := _texture_register_context(2, &first, &first_entry)
	second_id := _texture_register_context(3, &second, &second_entry)
	testing.expect(t, first_id != second_id)
	testing.expect(t, _texture_slot_context(2, &first, first_id) != nil)
	testing.expect(t, _texture_slot_context(3, &second, second_id) != nil)
	testing.expect(t, _texture_slot_context(3, &second, first_id) == nil)
	testing.expect(t, _texture_slot_context(2, &first, second_id) == nil)
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

@(test)
retire_bound_covers_every_destroyable_resource :: proc(t: ^testing.T) {
	// The bound must stay the physical maximum (one retirement per texture
	// slot plus one per atlas), otherwise a consumer that legitimately
	// recycles a large tile cache in one frame trips the assert.
	#assert(MAX_RETIRED_PER_FRAME == RESOURCE_SLOT_COUNT + MAX_ATLASES)
	#assert(MAX_RETIRED_PER_FRAME == 1280)
	testing.expect(t, MAX_RETIRED_PER_FRAME >= MAX_TEXTURES)
}

@(test)
texture_pool_reports_exhaustion_instead_of_asserting :: proc(t: ^testing.T) {
	// A full pool is an operating condition: registration returns 0 so the
	// loader can hand back an invalid Texture2D for the caller to handle.
	resources: Texture_Resources
	entries := make([]Tex_Entry, MAX_TEXTURES)
	defer delete(entries)
	for i in 0 ..< MAX_TEXTURES {
		testing.expect(t, _texture_register(&resources, &entries[i]) != 0)
	}
	testing.expect_value(t, int(resources.count), MAX_TEXTURES)
	overflow: Tex_Entry
	testing.expect_value(t, _texture_register(&resources, &overflow), u32(0))
	testing.expect_value(t, int(resources.count), MAX_TEXTURES)
}

@(test)
shader_pool_reports_exhaustion_instead_of_asserting :: proc(t: ^testing.T) {
	resources: Shader_Resources
	entries := make([]Shader_Entry, MAX_SHADERS)
	defer delete(entries)
	for index in 0 ..< MAX_SHADERS {
		testing.expect(t, _shader_register(&resources, &entries[index]) != 0)
	}
	testing.expect_value(t, int(resources.count), MAX_SHADERS)
	overflow: Shader_Entry
	testing.expect_value(t, _shader_register(&resources, &overflow), u32(0))
	testing.expect_value(t, int(resources.count), MAX_SHADERS)
}

@(test)
texture_slot_accounting_is_observable :: proc(t: ^testing.T) {
	// Consumers size their caches off these accessors, so the used count must
	// track registration exactly and IsTextureValid must reject a zero handle.
	testing.expect(t, !IsTextureValid(Texture2D{}))

	before := TextureSlotsUsed()
	entry: Tex_Entry
	id := _texture_register_context(g.id, &g.resources.textures, &entry)
	testing.expect(t, id != 0)
	testing.expect_value(t, TextureSlotsUsed(), before + 1)
	testing.expect(t, IsTextureValid(Texture2D{id = id}))

	// Release the slot by hand: UnloadTexture would retire all-nil GPU
	// handles, which is itself an asserted double-unload.
	slot := _texture_slot_context(g.id, &g.resources.textures, id)
	testing.expect(t, slot != nil)
	slot.entry = nil
	slot.occupied = false
	g.resources.textures.count -= 1
	testing.expect_value(t, TextureSlotsUsed(), before)
	testing.expect(t, !IsTextureValid(Texture2D{id = id}))
}

// --- default context identity -----------------------------------------------
//
// default_context_storage is deliberately left without a static initialiser:
// Context is ~11 MB, and any initialiser - even a single field - moves the
// whole struct from .bss to .data, which the wasm target then emits verbatim
// as 11 MB of zeros (see the note in context.odin, and
// scripts/check_wasm_bloat.py). The id is assigned by an @(init) procedure
// instead.
//
// That trade rests on an ordering the language does not specify. Odin's
// init_procedures_cmp sorts @(init) by package import order, then filename,
// then source offset. Across packages that is safe - import cycles are a
// compile error, so anything reaching gfx sorts after it. Within gfx it is
// not: the tiebreak is the filename, and context.odin does not sort first, so
// a second @(init) in an earlier-named file would read an unassigned id.
//
// The tests below cannot observe that. They run after every @(init), so they
// pin the outcome, not the ordering that produced it - an @(init) reading the
// id too early would still find these green. The ordering itself is enforced
// statically by scripts/check_init_order.py, which fails the build if any
// @(init) other than _default_context_init appears in gfx, and dynamically by
// the assertions in context_id and _texture_slot_context.

@(test)
default_context_has_its_reserved_id :: proc(t: ^testing.T) {
	// @(init) runs before the test runner, so observing the id here is the
	// same observation any caller makes after startup - but not the same as
	// one made from another @(init). See the note above.
	testing.expect_value(t, default_context().id, DEFAULT_CONTEXT_ID)
	testing.expect_value(t, context_id(default_context()), DEFAULT_CONTEXT_ID)
	// A zero id means "unassigned" throughout the resource handle code, so
	// the default context must never present as one.
	testing.expect(t, default_context().id != 0)
}

@(test)
unassigned_context_ids_still_read_as_zero :: proc(t: ^testing.T) {
	// context_id's assertion is deliberately narrow: it fires only for the
	// default context. A context that has not opened a window has no id yet -
	// _context_assign_id runs at window creation - and reading zero from one
	// is the documented contract, not a fault. A blanket "non-nil implies
	// non-zero" assertion here would abort on every pre-init context.
	testing.expect_value(t, context_id(nil), u32(0))

	// Heap-allocated: Context is ~11 MB, past a safe stack frame.
	fresh := new(Context)
	defer free(fresh)
	testing.expect_value(t, fresh.id, u32(0))
	testing.expect_value(t, context_id(fresh), u32(0))
}

@(test)
no_resource_handle_can_carry_a_zero_context :: proc(t: ^testing.T) {
	// This is why a zero context id has to abort rather than return nil:
	// _resource_handle_make_context refuses to mint a handle for context 0, so
	// no live handle can ever carry one. A lookup with zero therefore cannot
	// match anything, and would report an unassigned context as an ordinary
	// stale handle - the two are indistinguishable at the call site.
	resources: Texture_Resources
	entry: Tex_Entry
	id := _texture_register_context(DEFAULT_CONTEXT_ID, &resources, &entry)
	testing.expect(t, id != 0)

	raw_id := id & ~TEX_ID_BASE
	handle_context := (raw_id >> RESOURCE_SLOT_BITS) & RESOURCE_CONTEXT_MASK
	testing.expect(t, handle_context != 0)
	testing.expect_value(t, handle_context, DEFAULT_CONTEXT_ID)
}

@(test)
texture_lookup_rejects_an_unassigned_context_id :: proc(t: ^testing.T) {
	// The oracle itself, rather than the reasoning behind it: looking up with
	// an unassigned context id aborts instead of silently missing. Without
	// this the guard in _texture_slot_context could be deleted and every other
	// test would stay green.
	testing.expect_assert_message(t, "_texture_slot_context: unassigned context id")

	resources: Texture_Resources
	entry: Tex_Entry
	id := _texture_register_context(DEFAULT_CONTEXT_ID, &resources, &entry)
	_ = _texture_slot_context(0, &resources, id)

	// Only reached if the assertion did not fire. expect_assert_message merely
	// tolerates an abort, it does not require one, so a test that ends at the
	// call above passes just as happily with the assertion deleted. fail_now
	// is what makes this test an oracle rather than a description.
	testing.fail_now(t, "_texture_slot_context accepted an unassigned context id")
}

@(test)
assigned_context_ids_never_collide_with_the_default :: proc(t: ^testing.T) {
	// _context_assign_id hands out ids from CONTEXT_ID_FIRST. If that ever
	// started at or below the reserved id, two contexts would share an id and
	// their resource handles would alias.
	testing.expect(t, CONTEXT_ID_FIRST > DEFAULT_CONTEXT_ID)

	saved := context_id_next
	defer context_id_next = saved
	context_id_next = CONTEXT_ID_FIRST

	// Heap-allocated: Context is ~11 MB, past a safe stack frame.
	first := new(Context)
	defer free(first)
	testing.expect(t, _context_assign_id(first))
	testing.expect_value(t, first.id, CONTEXT_ID_FIRST)
	testing.expect(t, first.id != DEFAULT_CONTEXT_ID)

	second := new(Context)
	defer free(second)
	testing.expect(t, _context_assign_id(second))
	testing.expect(t, second.id != first.id)
	testing.expect(t, second.id != DEFAULT_CONTEXT_ID)

	// Assignment is idempotent: a context that already has an id keeps it.
	previous := first.id
	testing.expect(t, _context_assign_id(first))
	testing.expect_value(t, first.id, previous)
}

@(test)
frame_owner_and_availability_are_context_bound :: proc(t: ^testing.T) {
	first := new(Context)
	defer free(first)
	second := new(Context)
	defer free(second)
	first.epoch = 17
	second.epoch = 29
	frame := Frame {
		owner     = first,
		epoch     = first.epoch,
		open      = true,
		available = true,
	}
	testing.expect(t, frame_owner(&frame) == first)
	testing.expect(t, frame_owner(&frame) != second)
	testing.expect(t, frame_available(&frame))
	frame.open = false
	testing.expect(t, !frame_available(&frame))
	testing.expect(t, !frame_available(nil))
}

@(test)
context_renderer_statistics_are_isolated :: proc(t: ^testing.T) {
	first := new(Context)
	defer free(first)
	second := new(Context)
	defer free(second)
	first.stats_latest.flush_count = 11
	second.stats_latest.flush_count = 23
	testing.expect_value(t, context_renderer_stats(first).flush_count, u32(11))
	testing.expect_value(t, context_renderer_stats(second).flush_count, u32(23))
	context_renderer_stats_reset(first)
	when RENDER_STATS_ENABLED {
		testing.expect_value(t, context_renderer_stats(first).flush_count, u64(0))
	}
	testing.expect_value(t, context_renderer_stats(second).flush_count, u32(23))
}

@(test)
texture_retirement_is_context_bound :: proc(t: ^testing.T) {
	first := new(Context)
	defer free(first)
	defer delete(first.resources.retire)
	second := new(Context)
	defer free(second)
	defer delete(second.resources.retire)
	first.frame.has_frame = true
	second.frame.has_frame = true
	first_view := transmute(wg.TextureView)(uintptr(1))
	second_view := transmute(wg.TextureView)(uintptr(2))
	_retire_texture(first, nil, nil, first_view, nil)
	testing.expect_value(t, len(first.resources.retire), 1)
	testing.expect_value(t, len(second.resources.retire), 0)
	_retire_texture(second, nil, nil, second_view, nil)
	testing.expect_value(t, len(first.resources.retire), 1)
	testing.expect_value(t, len(second.resources.retire), 1)
}
