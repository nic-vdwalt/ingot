package shared

CLIMATE_STANDARD_TEMPERATURE :: i32(288 * PLANET_TEMPERATURE_SCALE)
CLIMATE_STANDARD_PRESSURE :: u32(101_325)
CLIMATE_MAX_WATER :: u32(PLANET_HUMIDITY_SCALE)

Climate_State :: struct {
	surface_revision:         u64,
	temperature:              []i32,
	pressure:                 []u32,
	column_mass:              []u32,
	vapour:                   []u32,
	cloud:                    []u32,
	volcanic_aerosol:         []u32,
	precipitation:            []u32,
	wind_east:                []i32,
	wind_north:               []i32,
	soil_water:               []u32,
	snow:                     []u32,
	sea_ice:                  []u32,
	solar_irradiance:         []u32,
	photosynthetic_radiation: []u32,
	temperature_scratch:      []i32,
	pressure_scratch:         []u32,
	vapour_scratch:           []u32,
	aerosol_scratch:          []u32,
	wind_east_scratch:        []i32,
	wind_north_scratch:       []i32,
	mass_flux_scratch:        []i64,
	temperature_transfer:     []i64,
	vapour_transfer:          []i64,
}

climate_init :: proc(state: ^Climate_State, world: ^World, allocator := context.allocator) {
	assert(state != nil && world != nil, "climate_init: nil input")
	state^ = {}
	state.temperature = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.pressure = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.column_mass = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.vapour = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.cloud = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.volcanic_aerosol = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.precipitation = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_east = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_north = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.soil_water = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.snow = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.sea_ice = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.solar_irradiance = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.photosynthetic_radiation = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.temperature_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.pressure_scratch = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.vapour_scratch = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.aerosol_scratch = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_east_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.wind_north_scratch = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.mass_flux_scratch = make([]i64, len(world.planetary.grid.canonical_edges), allocator)
	state.temperature_transfer = make([]i64, len(world.planetary.grid.scalar_edges), allocator)
	state.vapour_transfer = make([]i64, len(world.planetary.grid.scalar_edges), allocator)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		terrain_index := planet_index(planet_sim_terrain_coord(planet_sim_coord_for_index(index)))
		prior_temperature := i32(world.foundation.temperature[terrain_index])
		state.temperature[index] = (230 + prior_temperature * 100 / 255) * PLANET_TEMPERATURE_SCALE
		state.pressure[index] = CLIMATE_STANDARD_PRESSURE
		state.column_mass[index] = climate_column_mass_from_pressure(
			CLIMATE_STANDARD_PRESSURE,
			world.planetary.physical.gravity_milli_m_s2,
		)
		state.vapour[index] =
			u32(world.foundation.moisture[terrain_index]) * CLIMATE_MAX_WATER / 1020
		state.soil_water[index] =
			u32(world.foundation.moisture[terrain_index]) * CLIMATE_MAX_WATER / 510
	}
}

climate_deinit :: proc(state: ^Climate_State, allocator := context.allocator) {
	assert(state != nil, "climate_deinit: nil state")
	delete(state.vapour_transfer, allocator)
	delete(state.temperature_transfer, allocator)
	delete(state.mass_flux_scratch, allocator)
	delete(state.wind_north_scratch, allocator)
	delete(state.wind_east_scratch, allocator)
	delete(state.aerosol_scratch, allocator)
	delete(state.vapour_scratch, allocator)
	delete(state.pressure_scratch, allocator)
	delete(state.temperature_scratch, allocator)
	delete(state.photosynthetic_radiation, allocator)
	delete(state.solar_irradiance, allocator)
	delete(state.sea_ice, allocator)
	delete(state.snow, allocator)
	delete(state.soil_water, allocator)
	delete(state.wind_north, allocator)
	delete(state.wind_east, allocator)
	delete(state.precipitation, allocator)
	delete(state.volcanic_aerosol, allocator)
	delete(state.cloud, allocator)
	delete(state.vapour, allocator)
	delete(state.column_mass, allocator)
	delete(state.pressure, allocator)
	delete(state.temperature, allocator)
	state^ = {}
}

climate_column_mass_from_pressure :: proc(pressure, gravity_milli: u32) -> u32 {
	assert(gravity_milli > 0, "climate_column_mass_from_pressure: zero gravity")
	return u32(u64(pressure) * 1_000 / u64(gravity_milli))
}

climate_pressure_from_column_mass :: proc(column_mass, gravity_milli: u32) -> u32 {
	assert(gravity_milli > 0, "climate_pressure_from_column_mass: zero gravity")
	return planet_saturating_u32(
		i64(u64(column_mass) * u64(gravity_milli) / 1_000),
		PLANET_MAX_PRESSURE,
	)
}

climate_cover_bucket :: proc(value: u32) -> u32 {
	return value / 10_000
}

// climate_step is the serial reference for the climate part of
// climate_cadence_step: the same range procs over the whole grid, in order.
climate_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_step: nil planet")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		planet.climate.volcanic_aerosol[index] -= planet.climate.volcanic_aerosol[index] / 256
	}
	temperature_total := climate_radiation_step(planet)
	climate_thermal_pressure_step(planet, temperature_total)
	climate_moisture_step(planet)
}

climate_thermal_pressure_step :: proc(planet: ^Planetary_State, temperature_total: i64) {
	assert(planet != nil, "climate_thermal_pressure_step: nil planet")
	state := &planet.climate
	mean_temperature := temperature_total / i64(PLANET_SIM_CELL_COUNT)
	total_before, total_after := climate_thermal_pressure_range(
		planet,
		mean_temperature,
		0,
		PLANET_SIM_CELL_COUNT,
	)
	climate_pressure_scratch_residual_correct(planet, total_before - total_after)
	state.pressure, state.pressure_scratch = state.pressure_scratch, state.pressure
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state.column_mass[index] = climate_column_mass_from_pressure(
			state.pressure[index],
			planet.physical.gravity_milli_m_s2,
		)
	}
}

climate_wind_range :: proc(planet: ^Planetary_State, start, end: int) {
	assert(planet != nil, "climate_wind_range: nil planet")
	state := &planet.climate
	climate_wind_range_buffers(
		planet,
		start,
		end,
		state.wind_east,
		state.wind_north,
		state.wind_east_scratch,
		state.wind_north_scratch,
	)
}

// climate_wind_range_buffers reads the wind from `east`/`north` and writes
// the next substep's wind to `out_east`/`out_north`; the job alternates the
// two buffer pairs by substep parity instead of swapping shared slices.
climate_wind_range_buffers :: proc(
	planet: ^Planetary_State,
	start, end: int,
	wind_east, wind_north: []i32,
	out_east, out_north: []i32,
) {
	assert(planet != nil, "climate_wind_range_buffers: nil planet")
	assert(start >= 0 && start <= end && end <= PLANET_SIM_CELL_COUNT, "climate_wind_range: range")
	state := &planet.climate
	for index in start ..< end {
		west := int(planet.grid.neighbours[index][0])
		east := int(planet.grid.neighbours[index][1])
		south := int(planet.grid.neighbours[index][2])
		north := int(planet.grid.neighbours[index][3])
		pressure_gradient_east := i64(state.pressure[west]) - i64(state.pressure[east])
		pressure_gradient_north := i64(state.pressure[south]) - i64(state.pressure[north])
		coriolis := i64(planet.grid.coriolis_nano[index])
		old_east := i64(wind_east[index])
		old_north := i64(wind_north[index])
		drag := i64(126) if planet.ocean.mean_depth_mm[index] > 0 else i64(122)
		out_east[index] = planet_saturating_i32(
			(old_east * drag + pressure_gradient_east + old_north * coriolis / 1_000_000_000) /
			128,
			-PLANET_WIND_MAX,
			PLANET_WIND_MAX,
		)
		out_north[index] = planet_saturating_i32(
			(old_north * drag + pressure_gradient_north - old_east * coriolis / 1_000_000_000) /
			128,
			-PLANET_WIND_MAX,
			PLANET_WIND_MAX,
		)
	}
}

Climate_Wind_Job :: struct {
	planet: ^Planetary_State,
}

climate_wind_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Climate_Wind_Job)(data)
	start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)
	climate_wind_range(job.planet, start, end)
}

climate_wind_substep :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_wind_substep: nil planet")
	job := Climate_Wind_Job{planet = planet}
	planet_workers_run(planet.workers, climate_wind_job_run, &job)
	state := &planet.climate
	state.wind_east, state.wind_east_scratch = state.wind_east_scratch, state.wind_east
	state.wind_north, state.wind_north_scratch = state.wind_north_scratch, state.wind_north
}

climate_mass_transport_substep :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_mass_transport_substep: nil planet")
	climate_mass_transport_edge_range(planet, 0, len(planet.grid.canonical_edges))
	climate_mass_transport_cell_range(planet, 0, PLANET_SIM_CELL_COUNT)
}

climate_mass_transport_edge_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.climate
	climate_mass_transport_edge_range_buffers(planet, start, end, state.wind_east, state.wind_north)
}

climate_mass_transport_edge_range_buffers :: proc(
	planet: ^Planetary_State,
	start, end: int,
	wind_east, wind_north: []i32,
) {
	state := &planet.climate
	for edge, edge_index in planet.grid.canonical_edges[start:end] {
		index := int(edge.index)
		edge_wind :=
			(i64(wind_east[index]) * i64(edge.edge_east) +
				i64(wind_north[index]) * i64(edge.edge_north)) /
			i64(PLANET_VECTOR_SCALE)
		state.mass_flux_scratch[start + edge_index] = clamp(edge_wind / 256, i64(-64), i64(64))
	}
}

climate_mass_transport_cell_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.climate
	maximum_mass := climate_column_mass_from_pressure(
		PLANET_MAX_PRESSURE,
		planet.physical.gravity_milli_m_s2,
	)
	for index in start ..< end {
		flux: i64
		for incident_index in 0 ..< int(planet.grid.incident_edge_count[index]) {
			incident := planet.grid.incident_edges[index][incident_index]
			flux += state.mass_flux_scratch[incident.edge] * i64(incident.sign)
		}
		state.column_mass[index] = planet_saturating_u32(
			i64(state.column_mass[index]) + flux,
			maximum_mass,
		)
		state.pressure[index] = climate_pressure_from_column_mass(
			state.column_mass[index],
			planet.physical.gravity_milli_m_s2,
		)
	}
}

climate_scalar_transfer_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.climate
	climate_scalar_transfer_range_buffers(planet, start, end, state.temperature, state.vapour)
}

climate_scalar_transfer_range_buffers :: proc(
	planet: ^Planetary_State,
	start, end: int,
	temperature: []i32,
	vapour: []u32,
) {
	state := &planet.climate
	for edge, edge_index in planet.grid.scalar_edges[start:end] {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		state.temperature_transfer[start + edge_index] =
			(i64(temperature[neighbour]) - i64(temperature[index])) / 2_048
		state.vapour_transfer[start + edge_index] =
			(i64(vapour[neighbour]) - i64(vapour[index])) / 2_048
	}
}

climate_scalar_apply_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.climate
	climate_scalar_apply_range_buffers(
		planet,
		start,
		end,
		state.temperature,
		state.vapour,
		state.temperature_scratch,
		state.vapour_scratch,
	)
}

climate_scalar_apply_range_buffers :: proc(
	planet: ^Planetary_State,
	start, end: int,
	temperature: []i32,
	vapour: []u32,
	out_temperature: []i32,
	out_vapour: []u32,
) {
	state := &planet.climate
	for index in start ..< end {
		next_temperature := i64(temperature[index])
		next_vapour := i64(vapour[index])
		for incident_index in 0 ..< int(planet.grid.scalar_incident_count[index]) {
			incident := planet.grid.scalar_incident_edges[index][incident_index]
			next_temperature += state.temperature_transfer[incident.edge] * i64(incident.sign)
			next_vapour += state.vapour_transfer[incident.edge] * i64(incident.sign)
		}
		out_temperature[index] = planet_saturating_i32(
			next_temperature,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
		out_vapour[index] = planet_saturating_u32(next_vapour, CLIMATE_MAX_WATER)
	}
}

climate_temperature_transport :: proc(planet: ^Planetary_State) {
	state := &planet.climate
	copy(state.temperature_scratch, state.temperature)
	for edge in planet.grid.scalar_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		transfer := (i64(state.temperature[neighbour]) - i64(state.temperature[index])) / 2_048
		state.temperature_scratch[index] = planet_saturating_i32(
			i64(state.temperature_scratch[index]) + transfer,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
		state.temperature_scratch[neighbour] = planet_saturating_i32(
			i64(state.temperature_scratch[neighbour]) - transfer,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
	}
}

climate_vapour_transport :: proc(planet: ^Planetary_State) {
	state := &planet.climate
	copy(state.vapour_scratch, state.vapour)
	for edge in planet.grid.scalar_edges {
		index := int(edge.index)
		neighbour := int(edge.neighbour)
		transfer := (i64(state.vapour[neighbour]) - i64(state.vapour[index])) / 2_048
		state.vapour_scratch[index] = planet_saturating_u32(
			i64(state.vapour_scratch[index]) + transfer,
			CLIMATE_MAX_WATER,
		)
		state.vapour_scratch[neighbour] = planet_saturating_u32(
			i64(state.vapour_scratch[neighbour]) - transfer,
			CLIMATE_MAX_WATER,
		)
	}
}

// climate_scalar_transport_substep is the standalone (one-substep) form of
// the scalar phase of the dynamics job: parallel per-edge transfers, then a
// per-cell gather, then the buffer swap.
climate_scalar_transport_substep :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_scalar_transport_substep: nil planet")
	job := Climate_Wind_Job{planet = planet}
	planet_workers_run(planet.workers, climate_scalar_transport_job_run, &job)
	state := &planet.climate
	state.temperature, state.temperature_scratch = state.temperature_scratch, state.temperature
	state.vapour, state.vapour_scratch = state.vapour_scratch, state.vapour
}

climate_scalar_transport_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Climate_Wind_Job)(data)
	scalar_start, scalar_end := planet_worker_range(worker, workers, len(job.planet.grid.scalar_edges))
	climate_scalar_transfer_range(job.planet, scalar_start, scalar_end)
	planet_workers_sync(team)
	start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)
	climate_scalar_apply_range(job.planet, start, end)
}

// climate_dynamics_job_run is the complete eight-substep dynamics pass as one
// worker sees it. Every phase writes only its own cell or edge range, and
// the wind and scalar fields double-buffer by substep parity (substep s
// reads buffer s%2 and writes buffer (s+1)%2), so no worker ever swaps a
// shared slice and only three barriers per substep remain:
//
//   wind(s)                       writes W[(s+1)%2]  from W[s%2], pressure
//   --- barrier: mass edges read every cell's new wind
//   mass edges(s)                 writes flux         from W[(s+1)%2]
//   --- barrier: cell gather reads every edge's flux
//   mass cells(s) + transfers(s)  writes pressure, column mass, T/V transfers
//   --- barrier: scalar apply reads every edge's transfer
//   scalar apply(s)               writes T/V[(s+1)%2] from T/V[s%2]
//
// The next substep's wind reads pressure (written two barriers earlier) and
// W[(s+1)%2] (written three barriers earlier), and its transfers read
// T/V[(s+1)%2] behind two more barriers, so no fourth barrier is needed.
// PLANET_MAX_SUBSTEPS is even, so the final state lands back in the primary
// buffers. Results are byte-identical to the serial reference for any
// worker count because every write is to a range-owned slot and the
// per-cell gathers sum in a fixed incident-edge order.
#assert(PLANET_MAX_SUBSTEPS % 2 == 0)

climate_dynamics_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Climate_Wind_Job)(data)
	planet := job.planet
	state := &planet.climate
	start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)
	edge_start, edge_end := planet_worker_range(worker, workers, len(planet.grid.canonical_edges))
	scalar_start, scalar_end := planet_worker_range(worker, workers, len(planet.grid.scalar_edges))
	wind_east := [2][]i32{state.wind_east, state.wind_east_scratch}
	wind_north := [2][]i32{state.wind_north, state.wind_north_scratch}
	temperature := [2][]i32{state.temperature, state.temperature_scratch}
	vapour := [2][]u32{state.vapour, state.vapour_scratch}
	for substep in 0 ..< PLANET_MAX_SUBSTEPS {
		current := substep % 2
		next := 1 - current
		climate_wind_range_buffers(
			planet,
			start,
			end,
			wind_east[current],
			wind_north[current],
			wind_east[next],
			wind_north[next],
		)
		planet_workers_sync(team)
		climate_mass_transport_edge_range_buffers(
			planet,
			edge_start,
			edge_end,
			wind_east[next],
			wind_north[next],
		)
		planet_workers_sync(team)
		climate_mass_transport_cell_range(planet, start, end)
		climate_scalar_transfer_range_buffers(
			planet,
			scalar_start,
			scalar_end,
			temperature[current],
			vapour[current],
		)
		planet_workers_sync(team)
		climate_scalar_apply_range_buffers(
			planet,
			start,
			end,
			temperature[current],
			vapour[current],
			temperature[next],
			vapour[next],
		)
	}
}

climate_pressure_residual_correct :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_pressure_residual_correct: nil planet")
	state := &planet.climate
	pressure_total: u64
	for pressure in state.pressure do pressure_total += u64(pressure)
	target_total := u64(CLIMATE_STANDARD_PRESSURE) * u64(PLANET_SIM_CELL_COUNT)
	if pressure_total == target_total do return
	increase := pressure_total < target_total
	remaining := abs(i64(target_total) - i64(pressure_total))
	for index := 0; index < PLANET_SIM_CELL_COUNT && remaining > 0; index += 1 {
		pressure := i64(state.pressure[index])
		updated := pressure + (i64(1) if increase else i64(-1))
		if updated > 0 && updated <= i64(PLANET_MAX_PRESSURE) {
			state.pressure[index] = u32(updated)
			state.column_mass[index] = climate_column_mass_from_pressure(
				state.pressure[index],
				planet.physical.gravity_milli_m_s2,
			)
			remaining -= 1
		}
	}
}

climate_dynamics_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_dynamics_step: nil planet")
	job := Climate_Wind_Job{planet = planet}
	planet_workers_run(planet.workers, climate_dynamics_job_run, &job)
	climate_pressure_residual_correct(planet)
}
