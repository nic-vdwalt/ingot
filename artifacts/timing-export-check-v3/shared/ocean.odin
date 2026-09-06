package shared

OCEAN_MAX_SURFACE_MM :: i32(20_000)
OCEAN_MAX_TRANSPORT :: i32(100_000)

Ocean_State :: struct {
	mean_depth_mm:                []u32,
	bathymetry_revision:          u64,
	surface_mm:                   []i32,
	transport_east:               []i32,
	transport_north:              []i32,
	deep_transport_east:          []i32,
	deep_transport_north:         []i32,
	temperature:                  []i32,
	surface_scratch:              []i32,
	transport_east_scratch:       []i32,
	transport_north_scratch:      []i32,
	deep_transport_east_scratch:  []i32,
	deep_transport_north_scratch: []i32,
}

ocean_init :: proc(state: ^Ocean_State, world: ^World, allocator := context.allocator) {
	assert(state != nil && world != nil, "ocean_init: nil input")
	state^ = {}
	state.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.surface_mm = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.transport_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.transport_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.deep_transport_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.deep_transport_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.temperature = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.surface_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.transport_east_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.transport_north_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.deep_transport_east_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.deep_transport_north_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	sea_level := i32(world.foundation.sea_level)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		terrain := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		ground := terrain_height_fixed_at_coord(world, terrain)
		state.mean_depth_mm[index] =
			u32(max(sea_level - ground, 0)) * u32(PLANET_HEIGHT_SCALE) / u32(HEIGHT_DELTA_SCALE)
		state.temperature[index] = CLIMATE_STANDARD_TEMPERATURE
	}
	state.bathymetry_revision = 1
}

ocean_deinit :: proc(state: ^Ocean_State, allocator := context.allocator) {
	assert(state != nil, "ocean_deinit: nil state")
	delete(state.deep_transport_north_scratch, allocator)
	delete(state.deep_transport_east_scratch, allocator)
	delete(state.transport_north_scratch, allocator)
	delete(state.transport_east_scratch, allocator)
	delete(state.surface_scratch, allocator)
	delete(state.temperature, allocator)
	delete(state.deep_transport_north, allocator)
	delete(state.deep_transport_east, allocator)
	delete(state.transport_north, allocator)
	delete(state.transport_east, allocator)
	delete(state.surface_mm, allocator)
	delete(state.mean_depth_mm, allocator)
	state^ = {}
}

ocean_sync_mean_depth :: proc(state: ^Ocean_State, mean_depth_mm: []u32) -> bool {
	assert(state != nil, "ocean_sync_mean_depth: nil state")
	assert(len(mean_depth_mm) == PLANET_SIM_CELL_COUNT, "ocean_sync_mean_depth: length")
	changed := false
	for value, index in mean_depth_mm {
		if state.mean_depth_mm[index] != value {
			changed = true
			break
		}
	}
	if !changed do return false
	copy(state.mean_depth_mm, mean_depth_mm)
	state.bathymetry_revision += 1
	return true
}

ocean_bathymetry_sync_all :: proc(world: ^World) -> bool {
	assert(world != nil, "ocean_bathymetry_sync_all: nil world")
	changed := false
	sea_level := i32(world.foundation.sea_level)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		terrain := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		ground := terrain_height_fixed_at_coord(world, terrain)
		depth :=
			u32(max(sea_level - ground, 0)) * u32(PLANET_HEIGHT_SCALE) / u32(HEIGHT_DELTA_SCALE)
		if world.planetary.ocean.mean_depth_mm[index] != depth {
			world.planetary.ocean.mean_depth_mm[index] = depth
			changed = true
		}
	}
	if changed {
		world.planetary.ocean.bathymetry_revision += 1
		planetary_mark_mutated(&world.planetary)
	}
	return changed
}

ocean_bathymetry_sync_rect :: proc(world: ^World, center: Planet_Coord, radius: i32) -> bool {
	assert(world != nil, "ocean_bathymetry_sync_rect: nil world")
	changed := false
	sea_level := i32(world.foundation.sea_level)
	coarse_radius := max(radius / i32(PLANET_SIM_TERRAIN_STRIDE) + 2, i32(2))
	center_index := planetary_sample_index(planet_direction(center))
	center_coord := planet_sim_coord_for_index(center_index)
	for offset_v in -coarse_radius ..= coarse_radius {
		for offset_u in -coarse_radius ..= coarse_radius {
			terrain_center := planet_sim_terrain_coord(center_coord)
			terrain := planet_neighbour(
				terrain_center,
				offset_u * i32(PLANET_SIM_TERRAIN_STRIDE),
				offset_v * i32(PLANET_SIM_TERRAIN_STRIDE),
			)
			index := planetary_sample_index(planet_direction(terrain))
			coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
			ground := terrain_height_fixed_at_coord(world, coord)
			depth :=
				u32(max(sea_level - ground, 0)) *
				u32(PLANET_HEIGHT_SCALE) /
				u32(HEIGHT_DELTA_SCALE)
			if world.planetary.ocean.mean_depth_mm[index] != depth {
				world.planetary.ocean.mean_depth_mm[index] = depth
				changed = true
			}
		}
	}
	if changed {
		world.planetary.ocean.bathymetry_revision += 1
		planetary_mark_mutated(&world.planetary)
	}
	return changed
}

ocean_transport_divergence :: proc(
	planet: ^Planetary_State,
	index: int,
	transport_east, transport_north: []i32,
) -> i64 {
	assert(planet != nil, "ocean_transport_divergence: nil planet")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "ocean_transport_divergence: index")
	assert(len(transport_east) == PLANET_SIM_CELL_COUNT, "ocean_transport_divergence: east length")
	assert(
		len(transport_north) == PLANET_SIM_CELL_COUNT,
		"ocean_transport_divergence: north length",
	)
	divergence: i64
	for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
		neighbour := int(planet.grid.neighbours[index][edge_index])
		east, north := planet_sim_rotate_neighbour_to_local(
			&planet.grid,
			index,
			edge_index,
			transport_east[neighbour],
			transport_north[neighbour],
		)
		flux :=
			(east * i64(planet.grid.edge_east[index][edge_index]) +
				north * i64(planet.grid.edge_north[index][edge_index])) /
			i64(PLANET_VECTOR_SCALE)
		divergence -= flux
	}
	return divergence
}

ocean_neighbour_current_means :: proc(
	planet: ^Planetary_State,
	index: int,
) -> (
	i64,
	i64,
	i64,
	i64,
) {
	surface_east_total, surface_north_total: i64
	deep_east_total, deep_north_total: i64
	for edge_index in 0 ..< PLANET_SIM_EDGE_COUNT {
		neighbour := int(planet.grid.neighbours[index][edge_index])
		surface_east, surface_north := planet_sim_rotate_neighbour_to_local(
			&planet.grid,
			index,
			edge_index,
			planet.ocean.transport_east[neighbour],
			planet.ocean.transport_north[neighbour],
		)
		deep_east, deep_north := planet_sim_rotate_neighbour_to_local(
			&planet.grid,
			index,
			edge_index,
			planet.ocean.deep_transport_east[neighbour],
			planet.ocean.deep_transport_north[neighbour],
		)
		surface_east_total += surface_east
		surface_north_total += surface_north
		deep_east_total += deep_east
		deep_north_total += deep_north
	}
	return surface_east_total / PLANET_SIM_EDGE_COUNT,
		surface_north_total / PLANET_SIM_EDGE_COUNT,
		deep_east_total / PLANET_SIM_EDGE_COUNT,
		deep_north_total / PLANET_SIM_EDGE_COUNT
}

ocean_column_transport :: proc(state: ^Ocean_State, index: int) -> (i64, i64) {
	assert(state != nil, "ocean_column_transport: nil state")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "ocean_column_transport: index")
	deep_weight := i64(
		clamp((i64(state.mean_depth_mm[index]) - 20_000) * 1_000 / 180_000, i64(0), i64(1_000)),
	)
	surface_weight := i64(1_000) - deep_weight
	east :=
		(i64(state.transport_east[index]) * surface_weight +
			i64(state.deep_transport_east[index]) * deep_weight) /
		1_000
	north :=
		(i64(state.transport_north[index]) * surface_weight +
			i64(state.deep_transport_north[index]) * deep_weight) /
		1_000
	return east, north
}

ocean_geothermal_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "ocean_geothermal_step: nil planet")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		heat := planet.geology.heat_flux_mw_m2[index] / 20_000
		planet.ocean.temperature[index] = planet_saturating_i32(
			i64(planet.ocean.temperature[index]) + i64(heat),
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
	}
}

Ocean_Update_Job :: struct {
	planet:    ^Planetary_State,
	ephemeris: Orbit_Ephemeris,
	surface:   bool,
}

ocean_current_update_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.ocean
	for index in start ..< end {
		if state.mean_depth_mm[index] == 0 {
			state.surface_scratch[index] = 0
			state.transport_east_scratch[index] = 0
			state.transport_north_scratch[index] = 0
			state.deep_transport_east_scratch[index] = 0
			state.deep_transport_north_scratch[index] = 0
			continue
		}
		west := int(planet.grid.neighbours[index][0])
		east := int(planet.grid.neighbours[index][1])
		south := int(planet.grid.neighbours[index][2])
		north := int(planet.grid.neighbours[index][3])
		gradient_east := i64(state.surface_mm[west]) - i64(state.surface_mm[east])
		gradient_north := i64(state.surface_mm[south]) - i64(state.surface_mm[north])
		temperature_gradient_east := i64(state.temperature[west]) - i64(state.temperature[east])
		temperature_gradient_north := i64(state.temperature[south]) - i64(state.temperature[north])
		wind_east := i64(planet.climate.wind_east[index])
		wind_north := i64(planet.climate.wind_north[index])
		coriolis := i64(planet.grid.coriolis_nano[index])
		surface_east := i64(state.transport_east[index])
		surface_north := i64(state.transport_north[index])
		deep_east := i64(state.deep_transport_east[index])
		deep_north := i64(state.deep_transport_north[index])
		surface_mean_east, surface_mean_north, deep_mean_east, deep_mean_north :=
			ocean_neighbour_current_means(planet, index)
		state.transport_east_scratch[index] = planet_saturating_i32(
			(surface_east * 56 +
				surface_mean_east * 6 +
				gradient_east / 4 +
				wind_east / 20 +
				surface_north * coriolis / 1_000_000_000) /
			64,
			-OCEAN_MAX_TRANSPORT,
			OCEAN_MAX_TRANSPORT,
		)
		state.transport_north_scratch[index] = planet_saturating_i32(
			(surface_north * 56 +
				surface_mean_north * 6 +
				gradient_north / 4 +
				wind_north / 20 -
				surface_east * coriolis / 1_000_000_000) /
			64,
			-OCEAN_MAX_TRANSPORT,
			OCEAN_MAX_TRANSPORT,
		)
		state.deep_transport_east_scratch[index] = planet_saturating_i32(
			(deep_east * 60 +
				deep_mean_east * 3 -
				surface_east / 8 +
				temperature_gradient_east / 64 +
				deep_north * coriolis / 1_000_000_000) /
			64,
			-OCEAN_MAX_TRANSPORT,
			OCEAN_MAX_TRANSPORT,
		)
		state.deep_transport_north_scratch[index] = planet_saturating_i32(
			(deep_north * 60 +
				deep_mean_north * 3 -
				surface_north / 8 +
				temperature_gradient_north / 64 -
				deep_east * coriolis / 1_000_000_000) /
			64,
			-OCEAN_MAX_TRANSPORT,
			OCEAN_MAX_TRANSPORT,
		)
		state.temperature[index] = planet_saturating_i32(
			(i64(state.temperature[index]) * 255 + i64(planet.climate.temperature[index])) / 256,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
	}
}

ocean_surface_update_range :: proc(
	planet: ^Planetary_State,
	ephemeris: Orbit_Ephemeris,
	start, end: int,
) {
	state := &planet.ocean
	for index in start ..< end {
		if state.mean_depth_mm[index] == 0 do continue
		tide := tide_equilibrium_mm(planet.physical, ephemeris.moon, planet.grid.directions[index])
		divergence := ocean_transport_divergence(
			planet,
			index,
			state.transport_east,
			state.transport_north,
		)
		state.surface_scratch[index] = planet_saturating_i32(
			(i64(state.surface_mm[index]) * 63 + i64(tide) + divergence / 16) / 64,
			-OCEAN_MAX_SURFACE_MM,
			OCEAN_MAX_SURFACE_MM,
		)
	}
}

ocean_update_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Ocean_Update_Job)(data)
	start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)
	if job.surface {
		ocean_surface_update_range(job.planet, job.ephemeris, start, end)
	} else {
		ocean_current_update_range(job.planet, start, end)
	}
}

// ocean_update_parallel runs one of the two ocean phases across the
// persistent worker team. Each cell writes only its own scratch slot, so
// the partition does not affect the result.
ocean_update_parallel :: proc(
	planet: ^Planetary_State,
	ephemeris: Orbit_Ephemeris,
	surface: bool,
) {
	job := Ocean_Update_Job {
		planet    = planet,
		ephemeris = ephemeris,
		surface   = surface,
	}
	planet_workers_run(planet.workers, ocean_update_job_run, &job)
}

ocean_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "ocean_step: nil planet")
	state := &planet.ocean
	copy(state.surface_scratch, state.surface_mm)
	ephemeris := orbit_ephemeris(planet.orbit, planet.physical)
	ocean_update_parallel(planet, ephemeris, false)
	state.transport_east, state.transport_east_scratch =
		state.transport_east_scratch, state.transport_east
	state.transport_north, state.transport_north_scratch =
		state.transport_north_scratch, state.transport_north
	state.deep_transport_east, state.deep_transport_east_scratch =
		state.deep_transport_east_scratch, state.deep_transport_east
	state.deep_transport_north, state.deep_transport_north_scratch =
		state.deep_transport_north_scratch, state.deep_transport_north
	ocean_update_parallel(planet, ephemeris, true)
	state.surface_mm, state.surface_scratch = state.surface_scratch, state.surface_mm
}
