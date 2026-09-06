package shared

PLANET_SIM_SECONDS_PER_TICK :: u64(300)
PLANET_TEMPERATURE_SCALE :: i32(1000)
PLANET_HUMIDITY_SCALE :: u32(1_000_000)
PLANET_HEIGHT_SCALE :: i32(1000)
PLANET_VELOCITY_SCALE :: i32(100)
PLANET_VECTOR_SCALE :: i32(1_000_000)
PLANET_ENERGY_SCALE :: u64(1000)
PLANET_WAVE_VARIANCE_SCALE :: u64(1_000_000)
PLANET_PRESSURE_ANOMALY_MAX_PA :: i32(20_000)
PLANET_WIND_MAX :: i32(20_000)
PLANET_MIN_TEMPERATURE :: i32(150 * PLANET_TEMPERATURE_SCALE)
PLANET_MAX_TEMPERATURE :: i32(400 * PLANET_TEMPERATURE_SCALE)
PLANET_MAX_PRESSURE :: u32(200_000)
PLANET_MAX_SUBSTEPS :: u32(8)

Planet_Physical_Parameters :: struct {
	radius_m:                  u64,
	gravity_milli_m_s2:        u32,
	rotation_period_s:         u32,
	obliquity_microradians:    i32,
	orbital_period_s:          u32,
	orbital_eccentricity_ppm:  u32,
	solar_flux_milli_w_m2:     u32,
	surface_pressure_pa:       u32,
	atmospheric_mass_kg:       u64,
	dry_gas_constant_milli:    u32,
	water_gas_constant_milli:  u32,
	ocean_density_milli_kg_m3: u32,
	mantle_heat_tw_milli:      u32,
	radiogenic_heat_tw_milli:  u32,
	primordial_heat_tw_milli:  u32,
	time_scale:                u32,
}

planet_physical_earthlike :: proc() -> Planet_Physical_Parameters {
	return {
		radius_m = 6_371_000,
		gravity_milli_m_s2 = 9_807,
		rotation_period_s = 86_164,
		obliquity_microradians = 409_105,
		orbital_period_s = 31_556_952,
		orbital_eccentricity_ppm = 16_708,
		solar_flux_milli_w_m2 = 1_361_000,
		surface_pressure_pa = 101_325,
		atmospheric_mass_kg = 5_148_000_000_000_000_000,
		dry_gas_constant_milli = 287_050,
		water_gas_constant_milli = 461_500,
		ocean_density_milli_kg_m3 = 1_025_000,
		mantle_heat_tw_milli = 47_000,
		radiogenic_heat_tw_milli = 23_000,
		primordial_heat_tw_milli = 24_000,
		time_scale = 1,
	}
}

planet_saturating_i32 :: proc(value: i64, minimum, maximum: i32) -> i32 {
	assert(minimum <= maximum, "planet_saturating_i32: invalid range")
	return i32(clamp(value, i64(minimum), i64(maximum)))
}

planet_saturating_u32 :: proc(value: i64, maximum: u32) -> u32 {
	assert(maximum > 0, "planet_saturating_u32: zero maximum")
	return u32(clamp(value, i64(0), i64(maximum)))
}

planet_mul_div_i64 :: proc(value, multiplier, divisor: i64) -> i64 {
	assert(divisor != 0, "planet_mul_div_i64: zero divisor")
	return value * multiplier / divisor
}

planet_vector_normalize :: proc(east, north: i64) -> (i32, i32) {
	magnitude := integer_sqrt(u64(east * east + north * north))
	if magnitude == 0 do return 0, 0
	return i32(east * i64(PLANET_VECTOR_SCALE) / i64(magnitude)),
	       i32(north * i64(PLANET_VECTOR_SCALE) / i64(magnitude))
}

planet_render_height_from_mm :: proc(value: i32) -> f32 {
	return f32(value) / f32(PLANET_HEIGHT_SCALE)
}
