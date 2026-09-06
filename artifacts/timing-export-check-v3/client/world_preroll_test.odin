package main

import "core:testing"
import shared "../shared"

// _world_build runs tick zero on the loader thread and gameplay starts at
// WORLD_PREROLL_TICKS. The world handed to gameplay must be byte-identical
// to a world built the same way and ticked from zero by the sim itself, so
// the (world, tick) sequence is unchanged and only the moment tick zero
// executes has moved.
@(test)
world_preroll_matches_ticking_from_zero :: proc(t: ^testing.T) {
	prerolled := new(shared.World)
	reference := new(shared.World)
	defer free(prerolled)
	defer free(reference)
	testing.expect(t, _world_build(prerolled, shared.TERRAIN_SEED), "prerolled build")
	defer shared.world_deinit(prerolled)
	testing.expect(t, shared.world_init_seed(reference, shared.TERRAIN_SEED), "reference init")
	defer shared.world_deinit(reference)
	_, ok_player := shared.spawn_player(reference, LOCAL_PLAYER)
	testing.expect(t, ok_player)
	_, ok_nodes := shared.world_populate_nodes(reference)
	testing.expect(t, ok_nodes)
	_, ok_gazelles := shared.world_populate_gazelles(reference)
	testing.expect(t, ok_gazelles)
	for tick in u64(0) ..< WORLD_PREROLL_TICKS do shared.sim_tick(reference, tick)
	// Continue both from the preroll tick so the comparison also covers the
	// first gameplay ticks, including a climate-cadence tick.
	for tick in WORLD_PREROLL_TICKS ..< WORLD_PREROLL_TICKS + shared.PLANET_CLIMATE_CADENCE_TICKS {
		shared.sim_tick(prerolled, tick)
		shared.sim_tick(reference, tick)
	}
	size := shared.world_snapshot_size(prerolled)
	testing.expect_value(t, shared.world_snapshot_size(reference), size)
	first := make([]u8, size)
	second := make([]u8, size)
	defer delete(first)
	defer delete(second)
	first_written, ok_first := shared.world_snapshot_write(prerolled, first)
	second_written, ok_second := shared.world_snapshot_write(reference, second)
	testing.expect(t, ok_first && ok_second, "snapshots written")
	testing.expect_value(t, first_written, second_written)
	mismatch := -1
	for byte, index in first[:first_written] {
		if byte != second[index] {
			mismatch = index
			break
		}
	}
	testing.expect_value(t, mismatch, -1)
}

@(test)
world_finalize_starts_gameplay_at_the_preroll_tick :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, world_create(value), "world create")
	defer {
		planetary_prepare_deinit(&value.planetary_prepare)
		shared.world_deinit(&value.world)
	}
	testing.expect_value(t, value.tick, WORLD_PREROLL_TICKS)
	testing.expect_value(t, value.accumulator, f64(0))
	if planetary_prepare_active(&value.planetary_prepare) {
		testing.expect(t, value.planetary_prepare.in_flight)
	}
	planetary_prepare_deinit(&value.planetary_prepare)
	testing.expect(t, !planetary_prepare_active(&value.planetary_prepare))
}
