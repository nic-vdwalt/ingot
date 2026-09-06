package shared

import "core:testing"

@(test)
tectonic_genesis_ocean_fraction_matches_target :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 707))
	defer world_deinit(world)
	wet, total := f64(0), f64(0)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		area := planet_sim_cell_solid_angle(coord)
		total += area
		if world.foundation.base_height[planet_index(planet_sim_terrain_coord(coord))] <= world.foundation.sea_level do wet += area
	}
	testing.expect(t, abs(wet / total - 0.71) < 0.02)
}

@(test)
tectonic_genesis_continents_are_independent_of_plates :: proc(t: ^testing.T) {
	for seed in u64(1) ..= 32 {
		lithosphere: Lithosphere
		lithosphere_generate(&lithosphere, seed)
		seen: [LITHOSPHERE_PLATE_COUNT][2]bool
		for index in 0 ..< 2_048 {
			direction := _lithosphere_hash_direction(seed ~ 891, u64(index))
			sample := lithosphere_sample(&lithosphere, direction)
			seen[sample.plate_id][int(sample.crust)] = true
		}
		mixed := 0
		for kinds in seen {
			if kinds[0] && kinds[1] do mixed += 1
		}
		testing.expect(t, mixed >= 2)
	}
}
