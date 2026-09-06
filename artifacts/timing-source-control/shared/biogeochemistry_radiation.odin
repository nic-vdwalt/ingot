package shared

biogeochemistry_light_attenuation :: proc(par, depth_mm, turbidity, organic_carbon, sea_ice: u32) -> u32 {
	if par == 0 do return 0
	ice_transmission := i64(1_000_000) - i64(sea_ice) * 900_000 / i64(CLIMATE_MAX_WATER)
	surface := i64(par) * max(ice_transmission, i64(0)) / 1_000_000
	attenuation := i64(depth_mm) / 2_000 + i64(turbidity) / 20 + i64(organic_carbon) / 80
	transmission := i64(1_000_000_000) / (1_000 + attenuation)
	return u32(clamp(surface * transmission / 1_000_000, i64(0), i64(BIOGEO_MAX_IRRADIANCE)))
}

biogeochemistry_radiation_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "biogeochemistry_radiation_step: nil planet")
	biogeochemistry_radiation_range(planet, 0, PLANET_SIM_CELL_COUNT)
}

biogeochemistry_radiation_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.biogeochemistry
	for index in start ..< end {
		if planet.ocean.mean_depth_mm[index] == 0 {
			state.surface_par[index] = 0
			state.benthic_par[index] = 0
			continue
		}
		par := planet.climate.photosynthetic_radiation[index]
		ice_transmission := i64(1_000_000) - i64(planet.climate.sea_ice[index]) * 900_000 / i64(CLIMATE_MAX_WATER)
		state.surface_par[index] = u32(clamp(i64(par) * ice_transmission / 1_000_000, i64(0), i64(BIOGEO_MAX_IRRADIANCE)))
		state.benthic_par[index] = biogeochemistry_light_attenuation(
			par,
			planet.ocean.mean_depth_mm[index],
			state.turbidity[index],
			state.dissolved_organic_carbon[index],
			planet.climate.sea_ice[index],
		)
	}
}
