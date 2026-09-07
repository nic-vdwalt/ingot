package main

import "core:mem"
import "core:testing"
import shared "../shared"

@(private = "file")
_expect_worlds_identical :: proc(t: ^testing.T, first, second: ^shared.World) {
	size := shared.world_snapshot_size(first)
	testing.expect_value(t, shared.world_snapshot_size(second), size)
	first_bytes := make([]u8, size)
	second_bytes := make([]u8, size)
	defer delete(first_bytes)
	defer delete(second_bytes)
	_, ok_first := shared.world_snapshot_write(first, first_bytes)
	_, ok_second := shared.world_snapshot_write(second, second_bytes)
	testing.expect(t, ok_first && ok_second, "snapshots written")
	testing.expect(t, mem.compare(first_bytes, second_bytes) == 0, "world snapshots differ")
}

// Ticking through sim_update with the asynchronous planetary preparation
// must produce the same world as ticking the reference synchronously, and
// the prepared stage must actually be what gets committed.
@(test)
async_planetary_preparation_matches_synchronous_ticks :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, world_create(value), "world create")
	defer {
		planetary_prepare_deinit(&value.planetary_prepare)
		shared.world_deinit(&value.world)
	}
	reference := new(shared.World)
	defer free(reference)
	testing.expect(t, _world_build(reference, shared.TERRAIN_SEED), "reference build")
	defer shared.world_deinit(reference)
	when ODIN_OS != .JS {
		testing.expect(t, planetary_prepare_active(&value.planetary_prepare), "prepare worker running")
	}
	ticks := u64(shared.PLANET_CLIMATE_CADENCE_TICKS * 4)
	for _ in 0 ..< ticks {
		start_tick := value.tick
		sim_update(value, f32(shared.TICK_DURATION_SECONDS))
		testing.expect_value(t, value.tick, start_tick + 1)
		shared.sim_tick(reference, start_tick)
	}
	_expect_worlds_identical(t, &value.world, reference)
	when ODIN_OS != .JS {
		testing.expect_value(t, value.planetary_prepare.commits, ticks)
		testing.expect_value(t, value.planetary_prepare.fallbacks, u64(0))
	}
}

// An edit to the live planetary state after a preparation started must
// invalidate it: the tick falls back to the synchronous path and the world
// still matches a reference that saw the same edit before the same tick.
@(test)
async_planetary_preparation_falls_back_after_a_mutation :: proc(t: ^testing.T) {
	when ODIN_OS == .JS do return
	value := new(Client_State)
	defer free(value)
	testing.expect(t, world_create(value), "world create")
	defer {
		planetary_prepare_deinit(&value.planetary_prepare)
		shared.world_deinit(&value.world)
	}
	reference := new(shared.World)
	defer free(reference)
	testing.expect(t, _world_build(reference, shared.TERRAIN_SEED), "reference build")
	defer shared.world_deinit(reference)
	sim_update(value, f32(shared.TICK_DURATION_SECONDS))
	shared.sim_tick(reference, WORLD_PREROLL_TICKS)
	// The next tick is being prepared now; edit the bathymetry underneath it
	// through the same path terraforming uses.
	for world in ([]^shared.World{&value.world, reference}) {
		for index in 0 ..< 256 do world.planetary.ocean.mean_depth_mm[index] += 5_000
		world.planetary.ocean.bathymetry_revision += 1
		shared.planetary_mark_mutated(&world.planetary)
	}
	sim_update(value, f32(shared.TICK_DURATION_SECONDS))
	shared.sim_tick(reference, WORLD_PREROLL_TICKS + 1)
	testing.expect_value(t, value.planetary_prepare.fallbacks, u64(1))
	testing.expect_value(t, value.planetary_prepare.commits, u64(1))
	// Subsequent ticks prepare from the mutated state and commit again.
	sim_update(value, f32(shared.TICK_DURATION_SECONDS))
	shared.sim_tick(reference, WORLD_PREROLL_TICKS + 2)
	testing.expect_value(t, value.planetary_prepare.commits, u64(2))
	_expect_worlds_identical(t, &value.world, reference)
}
