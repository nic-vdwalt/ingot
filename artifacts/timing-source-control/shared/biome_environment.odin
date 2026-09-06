package shared

import "core:mem"

BIOME_ENVIRONMENT_WINDOW :: u32(30 * 24 * 60 * 60 / (PLANET_SIM_SECONDS_PER_TICK * PLANET_CLIMATE_CADENCE_TICKS))
Biome_Environment_Cell :: struct {
	mean: [5]i32,
	remainder: [5]i32,
	samples: u32,
	dominant, candidate: Biome_Id,
	dwell: u8,
	bucket: u8,
}
Biome_Environment_Header :: struct {
	last_tick: u64,
	revision: u64,
	window: u32,
	initialized: u32,
}
Biome_Environment_State :: struct {
	header: Biome_Environment_Header,
	cells: []Biome_Environment_Cell,
	weights: [][Biome_Id]f32,
}
BIOME_ENVIRONMENT_SNAPSHOT_BYTES :: size_of(Biome_Environment_Header) + PLANET_SIM_CELL_COUNT * size_of(Biome_Environment_Cell)
#assert(BIOME_ENVIRONMENT_SNAPSHOT_BYTES <= 4 * 1024 * 1024)
#assert(PLANET_SIM_CELL_COUNT * size_of([Biome_Id]f32) <= 8 * 1024 * 1024)

biome_environment_mean :: proc(mean, remainder: ^i32, sample: i32, window: u32) {
	numerator := i64(sample) - i64(mean^) + i64(remainder^)
	mean^ += i32(numerator / i64(window))
	remainder^ = i32(numerator % i64(window))
}

biome_environment_scores :: proc(cell: Biome_Environment_Cell) -> (weights: [Biome_Id]f32) {
	temperature := f32(cell.mean[0]) / f32(PLANET_TEMPERATURE_SCALE)
	water := clamp(f32(cell.mean[1]) / f32(PLANET_HUMIDITY_SCALE), 0, 1)
	warm := clamp((temperature - 270) / 30, 0, 1)
	cold := 1 - warm
	frost := clamp(f32(cell.mean[4]) / 10000, 0, 1)
	weights[.Desert] = warm * (1 - water) * (1 - water)
	weights[.Grassland] = (1 - abs(water - 0.45)) * warm * 0.35
	weights[.Savannah] = warm * warm * water * (1 - water)
	weights[.Forest] = water * water * warm * (1 - frost)
	weights[.Wetland] = max(water - 0.8, 0) * warm
	weights[.Taiga] = water * cold * (1 - frost * 0.5)
	weights[.Tundra] = cold * (1 - water) * (1 - frost * 0.5)
	weights[.Snowlands] = cold * frost
	total: f32
	for weight in weights do total += weight
	if total <= 0 {
		weights = {}
		weights[.Grassland] = 1
	} else {
		for &weight in weights do weight /= total
	}
	return
}

biome_environment_hysteresis :: proc(cell: ^Biome_Environment_Cell, weights: [Biome_Id]f32) {
	best := cell.dominant
	for weight, biome in weights {
		if weight > weights[best] do best = biome
	}
	if best == cell.dominant || weights[best] < weights[cell.dominant] + 0.10 {
		cell.candidate = cell.dominant
		cell.dwell = 0
		return
	}
	if cell.candidate != best {
		cell.candidate = best
		cell.dwell = 0
	}
	cell.dwell += 1
	if cell.dwell >= 3 {
		cell.dominant = best
		cell.dwell = 0
	}
}

biome_environment_observation :: proc(world: ^World, index: int) -> [5]i32 {
	climate := &world.planetary.climate
	return {climate.temperature[index], i32(min(climate.soil_water[index], u32(max(i32)))), i32(min(climate.precipitation[index], u32(max(i32)))), i32(min(climate.photosynthetic_radiation[index], u32(max(i32)))), climate.temperature[index] < 273 * PLANET_TEMPERATURE_SCALE ? 10000 : 0}
}

biome_environment_physical_mask :: proc(world: ^World, coord: Planet_Coord) -> (biome: Biome_Id, masked: bool) {
	index := planet_index(coord)
	if world.waterfield.depths[index] > 0 {
		return world.foundation.continentalness[index] < 128 ? .Ocean : .Lake, true
	}
	landform := i32(world.foundation.landform_height[index]) + i32(world.foundation.tectonic_delta[index])
	left := planet_index(planet_neighbour(coord, -1, 0))
	right := planet_index(planet_neighbour(coord, 1, 0))
	down := planet_index(planet_neighbour(coord, 0, -1))
	up := planet_index(planet_neighbour(coord, 0, 1))
	rise_u := abs(i32(world.foundation.landform_height[right]) + i32(world.foundation.tectonic_delta[right]) - i32(world.foundation.landform_height[left]) - i32(world.foundation.tectonic_delta[left]))
	rise_v := abs(i32(world.foundation.landform_height[up]) + i32(world.foundation.tectonic_delta[up]) - i32(world.foundation.landform_height[down]) - i32(world.foundation.tectonic_delta[down]))
	if landform > i32(world.foundation.snow_level) && max(rise_u, rise_v) >= i32(HEIGHT_DELTA_SCALE) do return .Mountain, true
	return .Grassland, false
}

biome_environment_rebuild :: proc(world: ^World, advance: bool = false) {
	state := &world.biome_environment
	for &cell, index in state.cells {
		previous_dominant := cell.dominant
		weights := biome_environment_scores(cell)
		coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		if biome, masked := biome_environment_physical_mask(world, coord); masked {
			weights = {}
			weights[biome] = 1
			cell.dominant, cell.candidate, cell.dwell = biome, biome, 0
		} else if advance {
			biome_environment_hysteresis(&cell, weights)
		}
		state.weights[index] = weights
		bucket := u8(clamp(weights[cell.dominant] * 15, 0, 15))
		if bucket != cell.bucket || cell.dominant != previous_dominant {
			cell.bucket = bucket
			state.header.revision += 1
		}
	}
}

biome_environment_init :: proc(world: ^World, allocator := context.allocator) {
	state := &world.biome_environment
	state.header.window = BIOME_ENVIRONMENT_WINDOW
	state.cells = make([]Biome_Environment_Cell, PLANET_SIM_CELL_COUNT, allocator)
	state.weights = make([][Biome_Id]f32, PLANET_SIM_CELL_COUNT, allocator)
	for &cell, index in state.cells {
		cell.mean = biome_environment_observation(world, index)
		cell.samples = 1
		cell.dominant = world.foundation.primary_biome[planet_index(planet_sim_terrain_coord(planet_sim_coord_for_index(index)))]
		cell.candidate = cell.dominant
	}
	biome_environment_rebuild(world)
}

biome_environment_deinit :: proc(state: ^Biome_Environment_State, allocator := context.allocator) {
	delete(state.cells, allocator)
	delete(state.weights, allocator)
	state^ = {}
}

biome_environment_step :: proc(world: ^World, tick: u64) {
	state := &world.biome_environment
	if len(state.cells) == 0 || tick % PLANET_CLIMATE_CADENCE_TICKS != 0 do return
	if state.header.initialized != 0 && tick <= state.header.last_tick do return
	state.header.last_tick, state.header.initialized = tick, 1
	for &cell, index in state.cells {
		observation := biome_environment_observation(world, index)
		for sample, channel in observation do biome_environment_mean(&cell.mean[channel], &cell.remainder[channel], sample, state.header.window)
		cell.samples = min(cell.samples, max(u32) - 1) + 1
	}
	biome_environment_rebuild(world, true)
}

biome_environment_at_coord :: proc(world: ^World, coord: Planet_Coord) -> (weights: [Biome_Id]f32) {
	if biome, masked := biome_environment_physical_mask(world, coord); masked {
		weights[biome] = 1
		return
	}
	if len(world.biome_environment.weights) == 0 {
		weights[world.foundation.primary_biome[planet_index(coord)]] = 1
		return
	}
	stride := i32(PLANET_SIM_TERRAIN_STRIDE)
	center := planet_sim_terrain_coord(planet_sim_coord_for_index(planetary_sample_index(planet_direction(coord))))
	_, local_u, local_v := planet_locate(planet_direction(coord))
	delta_u, delta_v := local_u - f32(center.u), local_v - f32(center.v)
	step_u := delta_u < 0 ? -stride : stride
	step_v := delta_v < 0 ? -stride : stride
	blend_u := clamp(f32(abs(delta_u)) / f32(stride), 0, 1)
	blend_v := clamp(f32(abs(delta_v)) / f32(stride), 0, 1)
	for corner in 0 ..< 4 {
		offset_u := corner % 2 == 0 ? 0 : step_u
		offset_v := corner / 2 == 0 ? 0 : step_v
		contribution := (corner % 2 == 0 ? 1 - blend_u : blend_u) * (corner / 2 == 0 ? 1 - blend_v : blend_v)
		sample := planet_neighbour(center, offset_u, offset_v)
		for weight, biome in world.biome_environment.weights[planetary_sample_index(planet_direction(sample))] {
			weights[biome] += weight * contribution
		}
	}
	weights[.Ocean], weights[.Lake] = 0, 0
	retained: [Biome_Id]f32
	for _ in 0 ..< 4 {
		best := Biome_Id.Grassland
		for weight, biome in weights do if weight > weights[best] do best = biome
		if weights[best] <= 0 do break
		retained[best] = weights[best]
		weights[best] = 0
	}
	total: f32
	for weight in retained do total += weight
	if total <= 0 {
		retained[.Grassland] = 1
	} else {
		for &weight in retained do weight /= total
	}
	return retained
}

biome_environment_snapshot_write :: proc(state: ^Biome_Environment_State, buffer: []u8) -> bool {
	if len(buffer) < BIOME_ENVIRONMENT_SNAPSHOT_BYTES || len(state.cells) != PLANET_SIM_CELL_COUNT do return false
	copy(buffer, mem.ptr_to_bytes(&state.header))
	copy(buffer[size_of(state.header):], mem.slice_to_bytes(state.cells))
	return true
}

biome_environment_snapshot_read :: proc(world: ^World, buffer: []u8) -> bool {
	if len(buffer) != BIOME_ENVIRONMENT_SNAPSHOT_BYTES do return false
	header: Biome_Environment_Header
	copy(mem.ptr_to_bytes(&header), buffer)
	if header.window != BIOME_ENVIRONMENT_WINDOW || header.initialized > 1 do return false
	cells := make([]Biome_Environment_Cell, PLANET_SIM_CELL_COUNT)
	defer delete(cells)
	copy(mem.slice_to_bytes(cells), buffer[size_of(header):])
	for cell in cells {
		if u8(cell.dominant) > u8(Biome_Id.Mountain) || u8(cell.candidate) > u8(Biome_Id.Mountain) || cell.dwell > 2 || cell.bucket > 15 || cell.samples == 0 do return false
		for remainder in cell.remainder do if abs(i64(remainder)) >= i64(header.window) do return false
		for mean in cell.mean do if mean < 0 do return false
		if cell.mean[4] > 10000 do return false
	}
	state := &world.biome_environment
	if len(state.cells) != PLANET_SIM_CELL_COUNT do return false
	state.header = header
	copy(state.cells, cells)
	for cell, index in state.cells {
		state.weights[index] = biome_environment_scores(cell)
		coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		if biome, masked := biome_environment_physical_mask(world, coord); masked {
			state.weights[index] = {}
			state.weights[index][biome] = 1
		}
	}
	return true
}
