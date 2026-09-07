package shared

import "core:testing"

@(test)
geomorphology_flow_is_bounded_and_downhill :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 1010))
	defer world_deinit(world)
	testing.expect(t, geomorphology_resolve_flow(world, &world.planetary.geomorphology))
	state := &world.planetary.geomorphology
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		target := int(state.flow_to[index])
		testing.expect(t, target >= 0 && target < PLANET_SIM_CELL_COUNT)
		if target == index do continue
		testing.expect(t, geomorphology_height_fixed(world, target) <= geomorphology_height_fixed(world, index))
	}
}

@(test)
geomorphology_replay_is_deterministic :: proc(t: ^testing.T) {
	a := new(World)
	b := new(World)
	defer free(a)
	defer free(b)
	testing.expect(t, world_init_seed(a, 1111))
	defer world_deinit(a)
	testing.expect(t, world_init_seed(b, 1111))
	defer world_deinit(b)
	for _ in 0 ..< 3 {
		testing.expect(t, geomorphology_step(a, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
		testing.expect(t, geomorphology_step(b, TECTONIC_TIMELAPSE_YEARS_PER_STEP))
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		testing.expect_value(t, a.planetary.geomorphology.flow_to[index], b.planetary.geomorphology.flow_to[index])
		testing.expect_value(t, a.planetary.geomorphology.sediment_load[index], b.planetary.geomorphology.sediment_load[index])
		testing.expect(t, abs(a.planetary.geomorphology.erosional_delta[index]) <= GEOMORPHOLOGY_EROSION_MAX_FIXED)
	}
}
