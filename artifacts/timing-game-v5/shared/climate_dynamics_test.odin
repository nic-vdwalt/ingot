package shared

import "core:testing"

climate_test_expect_state_equal :: proc(t: ^testing.T, first, second: ^Climate_State) {
	testing.expect_value(t, first.surface_revision, second.surface_revision)
	for value, index in first.temperature do testing.expect_value(t, value, second.temperature[index])
	for value, index in first.pressure do testing.expect_value(t, value, second.pressure[index])
	for value, index in first.column_mass do testing.expect_value(t, value, second.column_mass[index])
	for value, index in first.vapour do testing.expect_value(t, value, second.vapour[index])
	for value, index in first.cloud do testing.expect_value(t, value, second.cloud[index])
	for value, index in first.volcanic_aerosol do testing.expect_value(t, value, second.volcanic_aerosol[index])
	for value, index in first.precipitation do testing.expect_value(t, value, second.precipitation[index])
	for value, index in first.wind_east do testing.expect_value(t, value, second.wind_east[index])
	for value, index in first.wind_north do testing.expect_value(t, value, second.wind_north[index])
	for value, index in first.soil_water do testing.expect_value(t, value, second.soil_water[index])
	for value, index in first.snow do testing.expect_value(t, value, second.snow[index])
	for value, index in first.sea_ice do testing.expect_value(t, value, second.sea_ice[index])
	for value, index in first.solar_irradiance do testing.expect_value(t, value, second.solar_irradiance[index])
	for value, index in first.photosynthetic_radiation {
		testing.expect_value(t, value, second.photosynthetic_radiation[index])
	}
	for value, index in first.temperature_scratch {
		testing.expect_value(t, value, second.temperature_scratch[index])
	}
	for value, index in first.pressure_scratch do testing.expect_value(t, value, second.pressure_scratch[index])
	for value, index in first.vapour_scratch do testing.expect_value(t, value, second.vapour_scratch[index])
	for value, index in first.aerosol_scratch do testing.expect_value(t, value, second.aerosol_scratch[index])
	for value, index in first.wind_east_scratch {
		testing.expect_value(t, value, second.wind_east_scratch[index])
	}
	for value, index in first.wind_north_scratch {
		testing.expect_value(t, value, second.wind_north_scratch[index])
	}
	for value, index in first.mass_flux_scratch {
		testing.expect_value(t, value, second.mass_flux_scratch[index])
	}
}

climate_dynamics_step_serial_reference :: proc(planet: ^Planetary_State) {
	for _ in 0 ..< PLANET_MAX_SUBSTEPS {
		climate_wind_range(planet, 0, PLANET_SIM_CELL_COUNT)
		state := &planet.climate
		state.wind_east, state.wind_east_scratch = state.wind_east_scratch, state.wind_east
		state.wind_north, state.wind_north_scratch = state.wind_north_scratch, state.wind_north
		climate_mass_transport_substep(planet)
		climate_temperature_transport(planet)
		climate_vapour_transport(planet)
		state.temperature, state.temperature_scratch = state.temperature_scratch, state.temperature
		state.vapour, state.vapour_scratch = state.vapour_scratch, state.vapour
	}
	climate_pressure_residual_correct(planet)
}

@(test)
climate_parallel_dynamics_matches_serial_reference :: proc(t: ^testing.T) {
	parallel := new(World)
	serial := new(World)
	defer free(parallel)
	defer free(serial)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(serial, TERRAIN_SEED))
	defer world_deinit(serial)
	for _ in 0 ..< 64 {
		climate_dynamics_step(&parallel.planetary)
		climate_dynamics_step_serial_reference(&serial.planetary)
	}
	climate_test_expect_state_equal(t, &parallel.planetary.climate, &serial.planetary.climate)
}

@(test)
climate_parallel_dynamics_is_deterministic :: proc(t: ^testing.T) {
	first := new(World)
	second := new(World)
	defer free(first)
	defer free(second)
	testing.expect(t, world_init_seed(first, TERRAIN_SEED))
	defer world_deinit(first)
	testing.expect(t, world_init_seed(second, TERRAIN_SEED))
	defer world_deinit(second)
	for _ in 0 ..< 4 {
		climate_dynamics_step(&first.planetary)
		climate_dynamics_step(&second.planetary)
	}
	climate_test_expect_state_equal(t, &first.planetary.climate, &second.planetary.climate)
}

@(test)
climate_wind_ranges_match_full_substep :: proc(t: ^testing.T) {
	parallel := new(World)
	serial := new(World)
	defer free(parallel)
	defer free(serial)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(serial, TERRAIN_SEED))
	defer world_deinit(serial)
	climate_wind_substep(&parallel.planetary)
	climate_wind_range(&serial.planetary, 0, PLANET_SIM_CELL_COUNT)
	serial.planetary.climate.wind_east, serial.planetary.climate.wind_east_scratch =
		serial.planetary.climate.wind_east_scratch, serial.planetary.climate.wind_east
	serial.planetary.climate.wind_north, serial.planetary.climate.wind_north_scratch =
		serial.planetary.climate.wind_north_scratch, serial.planetary.climate.wind_north
	for value, index in parallel.planetary.climate.wind_east {
		testing.expect_value(t, value, serial.planetary.climate.wind_east[index])
	}
	for value, index in parallel.planetary.climate.wind_north {
		testing.expect_value(t, value, serial.planetary.climate.wind_north[index])
	}
}
