package shared

import "core:testing"

@(test)
solar_absorption_responds_to_flux_and_cryosphere_albedo :: proc(t: ^testing.T) {
	clear := climate_absorbed_solar(800_000, 1_000_000, 1_361_000, 0, 0, 0, 0)
	bright := climate_absorbed_solar(800_000, 1_000_000, 1_361_000, 0, CLIMATE_MAX_WATER, 0, 0)
	high_flux := climate_absorbed_solar(800_000, 1_000_000, 1_500_000, 0, 0, 0, 0)
	testing.expect(t, clear > bright)
	testing.expect(t, high_flux > clear)
	aerosol := climate_absorbed_solar(
		800_000,
		1_000_000,
		1_361_000,
		0,
		0,
		0,
		CLIMATE_MAX_WATER,
	)
	testing.expect(t, clear > aerosol)
}

@(test)
radiation_delta_warms_cold_ground_and_cools_hot_ground :: proc(t: ^testing.T) {
	cold := climate_radiation_delta(500_000, 240 * PLANET_TEMPERATURE_SCALE, 0)
	hot := climate_radiation_delta(0, 320 * PLANET_TEMPERATURE_SCALE, 0)
	testing.expect(t, cold > 0)
	testing.expect(t, hot < 0)
}

@(test)
radiation_delta_balances_earthlike_sunlight_near_habitable_temperature :: proc(t: ^testing.T) {
	absorbed := climate_absorbed_solar(250_000, 1_000_000, 1_361_000, 0, 0, 0, 0)
	testing.expect(t, climate_radiation_delta(absorbed, 288 * PLANET_TEMPERATURE_SCALE, 0) > 0)
	testing.expect(t, climate_radiation_delta(absorbed, 300 * PLANET_TEMPERATURE_SCALE, 0) < 0)
}

@(test)
radiation_delta_converts_geothermal_milliwatts_to_watts :: proc(t: ^testing.T) {
	baseline := 250 * PLANET_TEMPERATURE_SCALE
	testing.expect_value(t, climate_radiation_delta(0, baseline, 4_000), i64(1))
	testing.expect_value(t, climate_radiation_delta(0, baseline, 200_000), i64(50))
	testing.expect(t, climate_radiation_delta(0, PLANET_MAX_TEMPERATURE, 200_000) < 0)
}

@(test)
modest_pressure_gradient_bootstraps_wind :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	index := 0
	west := int(world.planetary.grid.neighbours[index][0])
	east := int(world.planetary.grid.neighbours[index][1])
	world.planetary.climate.pressure[west] = CLIMATE_STANDARD_PRESSURE + 128
	world.planetary.climate.pressure[east] = CLIMATE_STANDARD_PRESSURE - 128
	climate_wind_substep(&world.planetary)
	testing.expect(t, world.planetary.climate.wind_east[index] > 0)
}

@(test)
obliquity_controls_seasonal_hemisphere_contrast :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	orbit := Orbit_State {
		orbital_phase = ORBIT_PHASE_SCALE / 4,
	}
	tilted_north := orbit_solar_incidence(60_000_000, 0, orbit, physical)
	physical.obliquity_microradians = 0
	untilted_north := orbit_solar_incidence(60_000_000, 0, orbit, physical)
	testing.expect(t, tilted_north > untilted_north)
}

@(test)
downwelling_solar_is_zero_at_night_and_cloud_attenuated :: proc(t: ^testing.T) {
	testing.expect_value(t, climate_downwelling_solar(0, 1_000_000, 1_361_000, 0, 0), u32(0))
	clear := climate_downwelling_solar(1_000_000, 1_000_000, 1_361_000, 0, 0)
	cloudy := climate_downwelling_solar(1_000_000, 1_000_000, 1_361_000, CLIMATE_MAX_WATER, 0)
	testing.expect(t, clear > cloudy)
}

@(test)
climate_radiation_returns_the_written_temperature_total :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	returned := climate_radiation_step(&world.planetary)
	measured: i64
	for temperature in world.planetary.climate.temperature do measured += i64(temperature)
	testing.expect_value(t, returned, measured)
}
