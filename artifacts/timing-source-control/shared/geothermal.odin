package shared

geothermal_heat_flux :: proc(crust_age_ka: u32, boundary: Plate_Boundary) -> u32 {
	age := max(u64(crust_age_ka), u64(1))
	flux := u64(4_000_000) / max(integer_sqrt(age), u64(1))
	if boundary == .Ridge do flux += 400
	if boundary == .Subduction do flux += 150
	return u32(clamp(flux, u64(35), u64(200_000)))
}

geothermal_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "geothermal_step: nil planet")
	geology := &planet.geology
	if geology.radiogenic_tw_milli > 1 do geology.radiogenic_tw_milli -= 1
	if geology.primordial_tw_milli > 1 do geology.primordial_tw_milli -= 1
	cooling := i64(geology.radiogenic_tw_milli + geology.primordial_tw_milli) / 10_000
	geology.mantle_temperature_mk = planet_saturating_i32(
		i64(geology.mantle_temperature_mk) - cooling,
		800 * PLANET_TEMPERATURE_SCALE,
		2_500 * PLANET_TEMPERATURE_SCALE,
	)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if geology.boundary[index] == .Ridge {
			geology.crust_age_ka[index] = 1
		} else if geology.crust_age_ka[index] < max(u32) {
			geology.crust_age_ka[index] += 1
		}
		geology.heat_flux_mw_m2[index] = geothermal_heat_flux(
			geology.crust_age_ka[index],
			geology.boundary[index],
		)
	}
}
