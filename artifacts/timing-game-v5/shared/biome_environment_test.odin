package shared

import "core:testing"
import "core:mem"

@(test)
biome_environment_remainders_and_drying :: proc(t: ^testing.T) {
	mean, remainder: i32
	for _ in 0 ..< 16 do biome_environment_mean(&mean, &remainder, 1, 16)
	testing.expect(t, mean == 1 && remainder == 0)
	for _ in 0 ..< 16 do biome_environment_mean(&mean, &remainder, 0, 16)
	testing.expect(t, mean == 0 && remainder == 0)
	testing.expect(t, climate_land_drying(0, 300000, 1000000) == 0)
	testing.expect(t, climate_land_drying(10, 300000, 1000000) == 0)
	testing.expect(t, climate_land_drying(10000, 300000, 1000000) < climate_land_drying(10000, 260000, 0))
}

@(test)
biome_environment_normalized_hysteresis :: proc(t: ^testing.T) {
	cell := Biome_Environment_Cell{dominant = .Grassland, candidate = .Grassland}
	weights: [Biome_Id]f32
	weights[.Grassland], weights[.Forest] = 0.46, 0.54
	for _ in 0 ..< 8 do biome_environment_hysteresis(&cell, weights)
	testing.expect(t, cell.dominant == .Grassland && cell.dwell == 0)
	weights[.Grassland], weights[.Forest] = 0.4, 0.6
	biome_environment_hysteresis(&cell, weights)
	biome_environment_hysteresis(&cell, weights)
	testing.expect(t, cell.dominant == .Grassland && cell.dwell == 2)
	biome_environment_hysteresis(&cell, weights)
	testing.expect(t, cell.dominant == .Forest && cell.dwell == 0)
	for temperature in 230 ..< 331 {
		cell.mean[0] = i32(temperature) * PLANET_TEMPERATURE_SCALE
		weights = biome_environment_scores(cell)
		total: f32
		for weight in weights {
			testing.expect(t, weight >= 0 && weight <= 1)
			total += weight
		}
		testing.expect(t, abs(total - 1) < 0.00001)
	}
}

@(test)
biome_environment_sustained_change :: proc(t: ^testing.T) {
	cell := Biome_Environment_Cell{dominant = .Forest, candidate = .Forest}
	cell.mean = {300000, i32(PLANET_HUMIDITY_SCALE), 100, 1000000, 0}
	initial := biome_environment_scores(cell)
	biome_environment_mean(&cell.mean[1], &cell.remainder[1], 0, BIOME_ENVIRONMENT_WINDOW)
	biome_environment_hysteresis(&cell, biome_environment_scores(cell))
	testing.expect(t, cell.dominant == .Forest)
	for _ in 0 ..< int(BIOME_ENVIRONMENT_WINDOW) * 5 {
		biome_environment_mean(&cell.mean[1], &cell.remainder[1], 0, BIOME_ENVIRONMENT_WINDOW)
		biome_environment_hysteresis(&cell, biome_environment_scores(cell))
	}
	final_weights := biome_environment_scores(cell)
	testing.expect(t, cell.dominant == .Desert)
	testing.expect(t, final_weights[.Desert] > initial[.Desert])
	testing.expect(t, final_weights[.Forest] < initial[.Forest])
	water := u32(10000)
	for _ in 0 ..< 10 do water = climate_land_drying(water + 1000, 300000, 1000000)
	testing.expect(t, water > 10000)
}

@(test)
biome_environment_history_snapshot_continuation :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	biome_environment_step(world, 4)
	state := &world.biome_environment
	bytes := make([]u8, BIOME_ENVIRONMENT_SNAPSHOT_BYTES)
	defer delete(bytes)
	testing.expect(t, biome_environment_snapshot_write(state, bytes))
	samples := state.cells[0].samples
	biome_environment_step(world, 4)
	testing.expect(t, state.cells[0].samples == samples)
	biome_environment_step(world, 8)
	expected := make([]u8, BIOME_ENVIRONMENT_SNAPSHOT_BYTES)
	defer delete(expected)
	testing.expect(t, biome_environment_snapshot_write(state, expected))
	testing.expect(t, biome_environment_snapshot_read(world, bytes))
	biome_environment_step(world, 8)
	actual := make([]u8, BIOME_ENVIRONMENT_SNAPSHOT_BYTES)
	defer delete(actual)
	testing.expect(t, biome_environment_snapshot_write(state, actual))
	testing.expect(t, mem.compare(expected, actual) == 0)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		if coord.u != 0 && coord.v != 0 && coord.u != PLANET_SIM_FACE_CELLS - 1 && coord.v != PLANET_SIM_FACE_CELLS - 1 do continue
		weights := biome_environment_at_coord(world, planet_sim_terrain_coord(coord))
		total: f32
		contributors := 0
		for weight in weights {
			total += weight
			if weight > 0 do contributors += 1
		}
		testing.expect(t, abs(total - 1) < 0.00001 && contributors <= 4)
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coarse := planet_sim_coord_for_index(index)
		if coarse.u != 0 && coarse.v != 0 && coarse.u != PLANET_SIM_FACE_CELLS - 1 && coarse.v != PLANET_SIM_FACE_CELLS - 1 do continue
		coord := planet_sim_terrain_coord(coarse)
		if coarse.u == 0 do coord.u = 0
		if coarse.v == 0 do coord.v = 0
		if coarse.u == PLANET_SIM_FACE_CELLS - 1 do coord.u = PLANET_FACE_CELLS
		if coarse.v == PLANET_SIM_FACE_CELLS - 1 do coord.v = PLANET_FACE_CELLS
		weights := biome_environment_at_coord(world, coord)
		total: f32
		for weight in weights do total += weight
		testing.expect(t, abs(total - 1) < 0.00001)
	}
	bytes[16] = 0
	bytes[17] = 0
	testing.expect(t, !biome_environment_snapshot_read(world, bytes))
}
