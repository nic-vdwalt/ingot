package shared

import "core:mem"
import "core:testing"

@(test)
tectonic_steps_are_deterministic_and_bounded :: proc(t: ^testing.T) {
	a := new(World)
	b := new(World)
	defer free(a)
	defer free(b)
	testing.expect(t, world_init_seed(a, 707))
	defer world_deinit(a)
	testing.expect(t, world_init_seed(b, 707))
	defer world_deinit(b)
	for _ in 0 ..< 4 {
		testing.expect(t, tectonics_step(a, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
		testing.expect(t, tectonics_step(b, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
	}
	testing.expect_value(t, a.foundation.lithosphere, b.foundation.lithosphere)
	testing.expect(t, mem.compare(
		mem.slice_to_bytes(a.planetary.tectonics.strain_micro),
		mem.slice_to_bytes(b.planetary.tectonics.strain_micro),
	) == 0)
	testing.expect(t, a.planetary.tectonics.dirty_count <= TECTONIC_DIRTY_TILE_CAPACITY)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		displacement := tectonics_displacement_fixed(&a.planetary.tectonics, index)
		testing.expect(t, displacement >= -TECTONIC_SUBSIDENCE_MAX_FIXED)
		testing.expect(t, displacement <= TECTONIC_UPLIFT_MAX_FIXED + TECTONIC_SEDIMENT_MAX_FIXED)
	}
}

@(test)
tectonic_snapshot_round_trip_preserves_pending_work :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 808))
	defer world_deinit(world)
	testing.expect(t, tectonics_step(world, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
	state := &world.planetary.tectonics
	state.age_remainder_years = 731
	state.elapsed_years += 731
	buffer := make([]u8, tectonics_snapshot_size(state))
	defer delete(buffer)
	written, ok := tectonics_snapshot_write(state, buffer)
	testing.expect(t, ok)
	testing.expect_value(t, written, len(buffer))
	restored: Tectonic_State
	tectonics_init(&restored, &world.foundation)
	defer tectonics_deinit(&restored)
	testing.expect(t, tectonics_snapshot_read(&restored, buffer))
	testing.expect_value(t, restored.epoch, state.epoch)
	testing.expect_value(t, restored.elapsed_years, state.elapsed_years)
	testing.expect_value(t, restored.age_remainder_years, state.age_remainder_years)
	testing.expect_value(t, restored.dirty_count, state.dirty_count)
	testing.expect(t, mem.compare(
		mem.slice_to_bytes(restored.previous_displacement),
		mem.slice_to_bytes(state.previous_displacement),
	) == 0)
}

@(test)
ridges_create_young_oceanic_crust :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 909))
	defer world_deinit(world)
	testing.expect(t, tectonics_step(world, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
	found := false
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state := &world.planetary.tectonics
		if state.boundary[index] != .Ridge || state.crust[index] != .Oceanic do continue
		found = true
		testing.expect(t, state.crust_age_ka[index] > 1)
	}
	testing.expect(t, found)
	testing.expect(t, world.planetary.tectonics.created_volume_m3 > 0)
}
