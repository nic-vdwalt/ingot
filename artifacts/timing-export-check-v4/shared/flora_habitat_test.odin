package shared

import "core:testing"

@(test)
flora_recruitment_requires_local_viable_propagules :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.flora_ecology
	for &cell in state.cells do cell = {bare_ground = FLORA_COVER_SCALE, nutrients = 100000}
	index := 0
	for candidate in 0 ..< PLANET_SIM_CELL_COUNT {
		if world.planetary.ocean.mean_depth_mm[candidate] == 0 {
			index = candidate
			break
		}
	}
	for &lineage in state.lineages[:state.lineage_count] {
		lineage.temperature_optimum = 128
		lineage.moisture_optimum = 128
		lineage.temperature_tolerance = 100
		lineage.moisture_tolerance = 100
	}
	world.planetary.climate.temperature[index] = 280000
	world.planetary.climate.soil_water[index] = PLANET_HUMIDITY_SCALE / 2
	world.planetary.climate.photosynthetic_radiation[index] = 1000000
	world.planetary.climate.snow[index] = 0
	world.biome_environment.cells[index].mean = {280000, i32(PLANET_HUMIDITY_SCALE / 2), 0, 1000000, 0}
	terrain_index := planet_index(planet_sim_terrain_coord(planet_sim_coord_for_index(index)))
	world.foundation.slope[terrain_index] = 0
	state.cells[index].succession_steps = max(u32)
	flora_ecology_step_state(state, world)
	testing.expect(t, state.cells[index].bare_ground == FLORA_COVER_SCALE)
	state.cells[index].founder_reserve[Flora_Growth_Form.Tree] = 4000
	flora_ecology_step_state(state, world)
	testing.expect(t, state.cells[index].bare_ground < FLORA_COVER_SCALE)
	testing.expect(t, state.cells[index].founder_reserve[Flora_Growth_Form.Tree] == 3000)
	buffer := make([]u8, flora_ecology_snapshot_size(state))
	defer delete(buffer)
	_, saved := flora_ecology_snapshot_write(state, buffer)
	testing.expect(t, saved)
	state.cells[index].founder_reserve[Flora_Growth_Form.Tree] = 0
	testing.expect(t, flora_ecology_snapshot_read(state, buffer))
	testing.expect(t, state.cells[index].founder_reserve[Flora_Growth_Form.Tree] == 3000)
	flora_disturb_cell(world, index, 2000)
	testing.expect(t, state.cells[index].disturbance == 2000 && state.cells[index].succession_steps == 0)
	habitat := flora_habitat_at_cell(world, index)
	environment := ecology_environment_at_cell(world, index)
	testing.expect(t, habitat.par == environment.surface_par && habitat.nutrients == environment.soil_nutrients)
	lineage := _flora_founder(world.foundation.seed, .Tree)
	lineage.temperature_optimum = 0
	lineage.temperature_tolerance = 1
	testing.expect(t, flora_establishment_score(&lineage, habitat, &state.cells[index]) == 0)
	flora_ecology_sterilize(state)
	flora_ecology_step_state(state, world)
	testing.expect(t, state.cells[index].bare_ground == FLORA_COVER_SCALE)
	for reserve in state.cells[index].founder_reserve do testing.expect(t, reserve == 0)
}

@(test)
flora_habitat_selects_traits_not_growth_form_timers :: proc(t: ^testing.T) {
	wet := _flora_founder(42, .Tree)
	dry := wet
	wet.moisture_optimum, wet.moisture_tolerance = 210, 40
	dry.moisture_optimum, dry.moisture_tolerance = 50, 40
	cell := Flora_Cell{nutrients = 100000, bare_ground = FLORA_COVER_SCALE}
	habitat := Flora_Habitat{land = true, temperature = wet.temperature_optimum, mean_temperature = wet.temperature_optimum, moisture = 210, mean_moisture = 210, light = 1000, mean_light = 1000}
	testing.expect(t, flora_establishment_score(&wet, habitat, &cell) > flora_establishment_score(&dry, habitat, &cell))
	habitat.moisture, habitat.mean_moisture = 50, 50
	testing.expect(t, flora_establishment_score(&dry, habitat, &cell) > flora_establishment_score(&wet, habitat, &cell))
	cell.succession_steps = max(u32)
	testing.expect(t, flora_establishment_score(&wet, habitat, &cell) == 0)
	habitat.snow = 1000
	testing.expect(t, flora_establishment_score(&dry, habitat, &cell) == 0)
	habitat.snow, habitat.slope = 0, 1000
	testing.expect(t, flora_establishment_score(&dry, habitat, &cell) == 0)
}
