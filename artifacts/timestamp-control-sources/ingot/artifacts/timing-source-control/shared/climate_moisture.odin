package shared

climate_land_drying :: proc(water: u32, temperature: i32, light: u32) -> u32 {
	warmth := u32(clamp((temperature - 253 * PLANET_TEMPERATURE_SCALE) / PLANET_TEMPERATURE_SCALE, 0, 80))
	demand := warmth * 4 + min(light / 10_000, u32(100))
	return water - min(water, demand)
}

climate_saturation_humidity :: proc(temperature_millikelvin: i32) -> u32 {
	celsius :=
		(temperature_millikelvin - 273 * PLANET_TEMPERATURE_SCALE) / PLANET_TEMPERATURE_SCALE
	return u32(clamp(i64(40_000 + celsius * 6_000), i64(10_000), i64(CLIMATE_MAX_WATER)))
}

// climate_moisture_step is the serial reference for the moisture phase of
// climate_cadence_step: it pushes precipitation events directly, in cell
// order, which the parallel step must reproduce through its shard replay.
climate_moisture_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "climate_moisture_step: nil planet")
	cover_changed := false
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		old_snow_bucket := climate_cover_bucket(planet.climate.snow[index])
		state := &planet.climate
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
			_ = planetary_event_push(&planet.events, .Precipitation, u32(index), rain, 1)
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
	if cover_changed do planet.climate.surface_revision += 1
}
