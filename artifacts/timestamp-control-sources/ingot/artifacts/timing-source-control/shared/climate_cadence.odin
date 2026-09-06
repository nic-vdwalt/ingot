package shared

// climate_cadence_step is the once-per-second planetary bundle (climate
// radiation, thermal pressure, moisture, sea ice, biogeochemical radiation
// and reactions) as one worker-team job. Every pass is per-cell independent
// except three reductions, which are recovered exactly:
//
//   - the post-radiation temperature total (integer sum: every worker sums the
//     shard subtotals in ascending order, so all workers agree on the mean);
//   - the pressure residual, corrected serially by worker 0 in ascending cell
//     order between two barriers, exactly as the serial step does;
//   - precipitation events, which the serial step pushes in ascending cell
//     order into a bounded queue. Each shard records its candidates (at most
//     the queue capacity: once a shard has pushed that many the queue is full
//     and every later candidate is a guaranteed drop) and the caller replays
//     them shard by shard, so item order, sequence numbers and the dropped
//     count match the serial step.
//
// The serial procs (climate_step, sea_ice_step, biogeochemistry_step) remain
// the reference implementation and are compared against this one in tests.

Climate_Rain_Candidate :: struct {
	cell: u32,
	rain: u32,
}

Climate_Cadence_Shard :: struct {
	temperature_total: i64,
	pressure_before:   i64,
	pressure_after:    i64,
	snow_changed:      bool,
	ice_changed:       bool,
	rain_count:        int,
	rain:              [PLANET_EVENT_CAPACITY]Climate_Rain_Candidate,
}

Climate_Cadence_Job :: struct {
	planet:      ^Planetary_State,
	flux_factor: u32,
	shards:      [PLANET_WORKERS_MAX]Climate_Cadence_Shard,
}

climate_cadence_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_cadence_step: nil planet")
	job := Climate_Cadence_Job {
		planet      = planet,
		flux_factor = orbit_flux_factor_ppm(planet.orbit.orbital_phase, planet.physical),
	}
	planet_workers_run(planet.workers, climate_cadence_job_run, &job)
	workers := planet_workers_count(planet.workers)
	// Replay precipitation events in ascending cell order (shards are
	// contiguous ascending ranges, so shard order is cell order).
	for worker in 0 ..< workers {
		shard := &job.shards[worker]
		recorded := min(shard.rain_count, PLANET_EVENT_CAPACITY)
		for candidate in shard.rain[:recorded] {
			_ = planetary_event_push(&planet.events, .Precipitation, candidate.cell, candidate.rain, 1)
		}
		planet.events.dropped += u32(shard.rain_count - recorded)
	}
	snow_changed, ice_changed := false, false
	for worker in 0 ..< workers {
		snow_changed ||= job.shards[worker].snow_changed
		ice_changed ||= job.shards[worker].ice_changed
	}
	if snow_changed do planet.climate.surface_revision += 1
	if ice_changed do planet.climate.surface_revision += 1
	planet.biogeochemistry.revision += 1
}

climate_cadence_job_run :: proc(data: rawptr, worker, workers: int, team: ^Planet_Workers) {
	job := (^Climate_Cadence_Job)(data)
	planet := job.planet
	state := &planet.climate
	shard := &job.shards[worker]
	start, end := planet_worker_range(worker, workers, PLANET_SIM_CELL_COUNT)

	// Phase 1: aerosol decay and radiation.
	for index in start ..< end {
		state.volcanic_aerosol[index] -= state.volcanic_aerosol[index] / 256
	}
	shard.temperature_total = climate_radiation_range(planet, job.flux_factor, start, end)
	planet_workers_sync(team)

	// Phase 2: thermal pressure into scratch against the global mean.
	temperature_total: i64
	for shard_index in 0 ..< workers do temperature_total += job.shards[shard_index].temperature_total
	mean_temperature := temperature_total / i64(PLANET_SIM_CELL_COUNT)
	shard.pressure_before, shard.pressure_after = climate_thermal_pressure_range(
		planet,
		mean_temperature,
		start,
		end,
	)
	planet_workers_sync(team)
	if worker == 0 {
		before, after: i64
		for shard_index in 0 ..< workers {
			before += job.shards[shard_index].pressure_before
			after += job.shards[shard_index].pressure_after
		}
		climate_pressure_scratch_residual_correct(planet, before - after)
		state.pressure, state.pressure_scratch = state.pressure_scratch, state.pressure
	}
	planet_workers_sync(team)

	// Phase 3: column mass, moisture, sea ice, biogeochemical radiation and
	// reactions. All per-cell with no cross-cell reads, so one pass over the
	// shard applies them in the serial per-system order for each cell.
	for index in start ..< end {
		state.column_mass[index] = climate_column_mass_from_pressure(
			state.pressure[index],
			planet.physical.gravity_milli_m_s2,
		)
	}
	shard.snow_changed = climate_moisture_range(planet, shard, start, end)
	shard.ice_changed = sea_ice_range(planet, start, end)
	biogeochemistry_radiation_range(planet, start, end)
	biogeochemistry_reaction_range(planet, start, end)
}

climate_radiation_range :: proc(
	planet: ^Planetary_State,
	flux_factor: u32,
	start, end: int,
) -> i64 {
	temperature_total: i64
	for index in start ..< end {
		incidence := orbit_solar_incidence(
			planet.grid.latitude_microdegrees[index],
			planet.grid.longitude_phase[index],
			planet.orbit,
			planet.physical,
		)
		absorbed := climate_absorbed_solar(
			incidence,
			flux_factor,
			planet.physical.solar_flux_milli_w_m2,
			planet.climate.cloud[index],
			planet.climate.snow[index],
			planet.climate.sea_ice[index],
			planet.climate.volcanic_aerosol[index],
		)
		planet.climate.solar_irradiance[index] = climate_downwelling_solar(
			incidence,
			flux_factor,
			planet.physical.solar_flux_milli_w_m2,
			planet.climate.cloud[index],
			planet.climate.volcanic_aerosol[index],
		)
		planet.climate.photosynthetic_radiation[index] =
			planet.climate.solar_irradiance[index] * 43 / 100
		temperature := i64(planet.climate.temperature[index])
		delta := climate_radiation_delta(
			absorbed,
			planet.climate.temperature[index],
			planet.geology.heat_flux_mw_m2[index],
		)
		planet.climate.temperature[index] = planet_saturating_i32(
			temperature + delta,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
		temperature_total += i64(planet.climate.temperature[index])
	}
	return temperature_total
}

climate_thermal_pressure_range :: proc(
	planet: ^Planetary_State,
	mean_temperature: i64,
	start, end: int,
) -> (
	total_before, total_after: i64,
) {
	state := &planet.climate
	for index in start ..< end {
		pressure := i64(state.pressure[index])
		total_before += pressure
		thermal_anomaly := clamp(
			(mean_temperature - i64(state.temperature[index])) / 20,
			i64(-PLANET_PRESSURE_ANOMALY_MAX_PA),
			i64(PLANET_PRESSURE_ANOMALY_MAX_PA),
		)
		target := i64(CLIMATE_STANDARD_PRESSURE) + thermal_anomaly
		updated := clamp((pressure * 31 + target) / 32, i64(1), i64(PLANET_MAX_PRESSURE))
		state.pressure_scratch[index] = u32(updated)
		total_after += updated
	}
	return
}

// climate_pressure_scratch_residual_correct spreads the conserved-mass
// residual one pascal per cell in ascending order over pressure_scratch.
climate_pressure_scratch_residual_correct :: proc(planet: ^Planetary_State, residual: i64) {
	state := &planet.climate
	step := i64(1) if residual > 0 else i64(-1)
	remaining := abs(residual)
	for index := 0; index < PLANET_SIM_CELL_COUNT && remaining > 0; index += 1 {
		updated := i64(state.pressure_scratch[index]) + step
		if updated > 0 && updated <= i64(PLANET_MAX_PRESSURE) {
			state.pressure_scratch[index] = u32(updated)
			remaining -= 1
		}
	}
}

climate_moisture_range :: proc(
	planet: ^Planetary_State,
	shard: ^Climate_Cadence_Shard,
	start, end: int,
) -> (
	cover_changed: bool,
) {
	state := &planet.climate
	for index in start ..< end {
		old_snow_bucket := climate_cover_bucket(state.snow[index])
		saturation := climate_saturation_humidity(state.temperature[index])
		if state.vapour[index] > saturation {
			condensed := (state.vapour[index] - saturation) / 2
			state.vapour[index] -= condensed
			state.cloud[index] = min(state.cloud[index] + condensed, CLIMATE_MAX_WATER)
			state.temperature[index] = planet_saturating_i32(
				i64(state.temperature[index]) + i64(condensed) / 200,
				PLANET_MIN_TEMPERATURE,
				PLANET_MAX_TEMPERATURE,
			)
		}
		state.precipitation[index] = 0
		if state.cloud[index] > 120_000 {
			rain := min((state.cloud[index] - 120_000) / 3, u32(20_000))
			state.cloud[index] -= rain
			state.precipitation[index] = rain
			if state.temperature[index] < 273 * PLANET_TEMPERATURE_SCALE {
				state.snow[index] = min(state.snow[index] + rain, CLIMATE_MAX_WATER)
			} else {
				state.soil_water[index] = min(state.soil_water[index] + rain, CLIMATE_MAX_WATER)
			}
			if shard.rain_count < PLANET_EVENT_CAPACITY {
				shard.rain[shard.rain_count] = {cell = u32(index), rain = rain}
			}
			shard.rain_count += 1
		}
		if planet.ocean.mean_depth_mm[index] > 0 && state.vapour[index] < saturation {
			evaporation := min((saturation - state.vapour[index]) / 64, u32(2_000))
			state.vapour[index] += evaporation
		}
		if state.temperature[index] > 275 * PLANET_TEMPERATURE_SCALE && state.snow[index] > 0 {
			melt := min(state.snow[index], u32(2_000))
			state.snow[index] -= melt
			state.soil_water[index] = min(state.soil_water[index] + melt, CLIMATE_MAX_WATER)
		}
		if planet.ocean.mean_depth_mm[index] == 0 {
			state.soil_water[index] = climate_land_drying(state.soil_water[index], state.temperature[index], state.photosynthetic_radiation[index])
		}
		if climate_cover_bucket(state.snow[index]) != old_snow_bucket do cover_changed = true
	}
	return
}

sea_ice_range :: proc(planet: ^Planetary_State, start, end: int) -> (cover_changed: bool) {
	for index in start ..< end {
		old_bucket := climate_cover_bucket(planet.climate.sea_ice[index])
		planet.climate.sea_ice[index] = sea_ice_update(
			planet.climate.sea_ice[index],
			planet.ocean.temperature[index],
			planet.climate.temperature[index],
			planet.ocean.mean_depth_mm[index],
		)
		if climate_cover_bucket(planet.climate.sea_ice[index]) != old_bucket do cover_changed = true
	}
	return
}
