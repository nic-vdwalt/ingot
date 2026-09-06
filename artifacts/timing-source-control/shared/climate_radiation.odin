package shared

climate_absorbed_solar :: proc(
	incidence: i32,
	flux_factor_ppm: u32,
	solar_flux_milli_w_m2: u32,
	cloud, snow, sea_ice, aerosol: u32,
) -> i64 {
	incoming := i64(incidence) * i64(flux_factor_ppm) / 1_000_000
	incoming = incoming * i64(solar_flux_milli_w_m2) / 1_361_000
	cloud_albedo := i64(cloud) * 250_000 / i64(CLIMATE_MAX_WATER)
	snow_albedo := i64(snow) * 450_000 / i64(CLIMATE_MAX_WATER)
	ice_albedo := i64(sea_ice) * 550_000 / i64(CLIMATE_MAX_WATER)
	albedo := clamp(
		i64(150_000) + cloud_albedo + max(snow_albedo, ice_albedo),
		i64(100_000),
		i64(850_000),
	)
	aerosol_attenuation := i64(1_000_000) - i64(aerosol) * 700_000 / i64(CLIMATE_MAX_WATER)
	return incoming * (1_000_000 - albedo) / 1_000_000 * aerosol_attenuation / 1_000_000
}

climate_radiation_delta :: proc(absorbed: i64, temperature_mk: i32, geothermal_mw_m2: u32) -> i64 {
	outgoing := (i64(temperature_mk) - i64(250 * PLANET_TEMPERATURE_SCALE)) / 180
	return absorbed / 1_000 - outgoing + i64(geothermal_mw_m2) / 4_000
}

climate_downwelling_solar :: proc(
	incidence: i32,
	flux_factor_ppm, solar_flux_milli_w_m2, cloud, aerosol: u32,
) -> u32 {
	incoming := i64(incidence) * i64(flux_factor_ppm) / 1_000_000
	incoming = incoming * i64(solar_flux_milli_w_m2) / 1_000_000
	cloud_attenuation := i64(1_000_000) - i64(cloud) * 650_000 / i64(CLIMATE_MAX_WATER)
	aerosol_attenuation := i64(1_000_000) - i64(aerosol) * 700_000 / i64(CLIMATE_MAX_WATER)
	return u32(clamp(
		incoming * cloud_attenuation / 1_000_000 * aerosol_attenuation / 1_000_000,
		i64(0),
		i64(BIOGEO_MAX_IRRADIANCE),
	))
}

climate_radiation_step :: proc(planet: ^Planetary_State) -> i64 {
	assert(planet != nil, "climate_radiation_step: nil planet")
	flux_factor := orbit_flux_factor_ppm(planet.orbit.orbital_phase, planet.physical)
	return climate_radiation_range(planet, flux_factor, 0, PLANET_SIM_CELL_COUNT)
}
