package shared

import "base:runtime"
import "core:mem"
import "core:testing"

@(private = "file")
Slice_List :: struct {
	headers: [dynamic]runtime.Raw_Slice,
	sizes:   [dynamic]int,
}

@(private = "file")
_collect_visit :: proc(slice: ^runtime.Raw_Slice, elem_size, elem_align: int, data: rawptr) {
	list := (^Slice_List)(data)
	append(&list.headers, slice^)
	append(&list.sizes, elem_size)
}

// _expect_planetary_equal compares every simulated slice byte for byte and
// the scalar remainder through the persisted snapshot.
@(private = "file")
_expect_planetary_equal :: proc(t: ^testing.T, first, second: ^Planetary_State) {
	first_list, second_list: Slice_List
	defer delete(first_list.headers)
	defer delete(first_list.sizes)
	defer delete(second_list.headers)
	defer delete(second_list.sizes)
	planetary_shadow_walk(first, _collect_visit, &first_list)
	planetary_shadow_walk(second, _collect_visit, &second_list)
	testing.expect_value(t, len(first_list.headers), len(second_list.headers))
	testing.expect(t, len(first_list.headers) > 50, "walk should find the state arrays")
	for header, index in first_list.headers {
		other := second_list.headers[index]
		testing.expect_value(t, header.len, other.len)
		testing.expect(t, header.data != other.data || header.len == 0, "slices must not alias")
		bytes := header.len * first_list.sizes[index]
		if bytes == 0 do continue
		equal := mem.compare_byte_ptrs((^byte)(header.data), (^byte)(other.data), bytes) == 0
		testing.expectf(t, equal, "slice %d (%d bytes) differs", index, bytes)
	}
	size := planetary_snapshot_size(first)
	testing.expect_value(t, planetary_snapshot_size(second), size)
	first_bytes := make([]u8, size)
	second_bytes := make([]u8, size)
	defer delete(first_bytes)
	defer delete(second_bytes)
	_, ok_first := planetary_snapshot_write(first, first_bytes)
	_, ok_second := planetary_snapshot_write(second, second_bytes)
	testing.expect(t, ok_first && ok_second)
	testing.expect(t, mem.compare(first_bytes, second_bytes) == 0, "snapshots differ")
	testing.expect_value(t, first.events.count, second.events.count)
	testing.expect_value(t, first.events.dropped, second.events.dropped)
	testing.expect(t, first.diagnostics_accum == second.diagnostics_accum, "diagnostic accumulations differ")
	testing.expect_value(t, first.mutation_revision, second.mutation_revision)
}

@(test)
planetary_shadow_copies_every_simulated_slice_without_aliasing :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, TERRAIN_SEED))
	defer world_deinit(world)
	shadow := new(Planetary_State)
	defer free(shadow)
	planetary_shadow_init(shadow, &world.planetary)
	defer planetary_shadow_deinit(shadow)
	testing.expect(t, shadow.workers == world.planetary.workers, "team is shared")
	testing.expect(t, !shadow.workers_owned && world.planetary.workers_owned, "ownership stays live")
	testing.expect(t, raw_data(shadow.grid.neighbours) == raw_data(world.planetary.grid.neighbours), "grid is shared")
	_expect_planetary_equal(t, shadow, &world.planetary)
	// Advance the live world; the shadow must be stale until copied again.
	world_planetary_step(world, 1)
	testing.expect(t, shadow.orbit != world.planetary.orbit, "shadow is independent")
	planetary_shadow_copy(shadow, &world.planetary)
	_expect_planetary_equal(t, shadow, &world.planetary)
}

// Preparing the simulated planetary stage on a shadow and committing it
// through sim_tick_prepared must leave the world byte-identical to plain
// sim_tick, across every cadence class including the geology tick.
@(test)
planetary_prepared_ticks_match_synchronous_ticks :: proc(t: ^testing.T) {
	synchronous := new(World)
	prepared := new(World)
	defer free(synchronous)
	defer free(prepared)
	testing.expect(t, world_init_seed(synchronous, TERRAIN_SEED))
	defer world_deinit(synchronous)
	testing.expect(t, world_init_seed(prepared, TERRAIN_SEED))
	defer world_deinit(prepared)
	shadow := new(Planetary_State)
	scratch := new(Planetary_State)
	defer free(shadow)
	defer free(scratch)
	planetary_shadow_init(shadow, &prepared.planetary)
	defer planetary_shadow_deinit(shadow)
	ticks := [?]u64{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 1_151, 1_152, 1_153, 1_154, 1_156}
	for tick in ticks {
		sim_tick(synchronous, tick)
		// Prepare (what the worker thread does) then commit (render thread).
		planetary_shadow_copy(shadow, &prepared.planetary)
		planetary_step_simulated(shadow, tick)
		sim_tick_prepared(prepared, tick, shadow, scratch)
	}
	_expect_planetary_equal(t, &synchronous.planetary, &prepared.planetary)
	testing.expect(t, prepared.planetary.workers_owned, "live keeps team ownership after swaps")
	testing.expect(t, !shadow.workers_owned, "shadow never owns the team")
	size := world_snapshot_size(synchronous)
	first := make([]u8, size)
	second := make([]u8, size)
	defer delete(first)
	defer delete(second)
	_, ok_first := world_snapshot_write(synchronous, first)
	_, ok_second := world_snapshot_write(prepared, second)
	testing.expect(t, ok_first && ok_second)
	testing.expect(t, mem.compare(first, second) == 0, "world snapshots differ")
}
