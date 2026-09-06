package shared

SEA_ICE_WAVE_TRANSMISSION_SCALE :: u64(1_000)
SEA_ICE_WAVE_MIN_TRANSMISSION_MILLI :: u64(100)

sea_ice_wave_transmission_milli :: proc(cover: u32) -> u64 {
	coverage := min(cover, u32(CLIMATE_MAX_WATER))
	loss := u64(coverage) *
		(SEA_ICE_WAVE_TRANSMISSION_SCALE - SEA_ICE_WAVE_MIN_TRANSMISSION_MILLI) /
		u64(CLIMATE_MAX_WATER)
	return SEA_ICE_WAVE_TRANSMISSION_SCALE - loss
}

sea_ice_damp_wave_variance :: proc(variance: u64, cover: u32) -> u64 {
	return variance * sea_ice_wave_transmission_milli(cover) /
		SEA_ICE_WAVE_TRANSMISSION_SCALE
}

sea_ice_update :: proc(current: u32, ocean_temperature, air_temperature: i32, ocean_depth_mm: u32) -> u32 {
	if ocean_depth_mm == 0 do return 0
	if ocean_temperature < 272 * PLANET_TEMPERATURE_SCALE && air_temperature < 273 * PLANET_TEMPERATURE_SCALE {
		return min(current + 2_000, CLIMATE_MAX_WATER)
	}
	if ocean_temperature > 274 * PLANET_TEMPERATURE_SCALE || air_temperature > 276 * PLANET_TEMPERATURE_SCALE {
		return current - min(current, u32(3_000))
	}
	return current
}

sea_ice_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "sea_ice_step: nil planet")
	if sea_ice_range(planet, 0, PLANET_SIM_CELL_COUNT) do planet.climate.surface_revision += 1
}
