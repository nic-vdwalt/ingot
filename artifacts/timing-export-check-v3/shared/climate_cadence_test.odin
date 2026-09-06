package shared

import "core:testing"

@(private = "file")
_cadence_serial_reference :: proc(planet: ^Planetary_State) {
	climate_step(planet)
	sea_ice_step(planet)
	biogeochemistry_step(planet)
}

@(private = "file")
_cadence_expect_equal :: proc(t: ^testing.T, first, second: ^Planetary_State) {
	climate_test_expect_state_equal(t, &first.climate, &second.climate)
	for value, index in first.climate.solar_irradiance {
		testing.expect_value(t, value, second.climate.solar_irradiance[index])
	}
	for value, index in first.climate.photosynthetic_radiation {
		testing.expect_value(t, value, second.climate.photosynthetic_radiation[index])
	}
	for value, index in first.climate.snow do testing.expect_value(t, value, second.climate.snow[index])
	for value, index in first.climate.sea_ice {
		testing.expect_value(t, value, second.climate.sea_ice[index])
	}
	for value, index in first.climate.soil_water {
		testing.expect_value(t, value, second.climate.soil_water[index])
	}
	first_fields := biogeochemistry_fields(&first.biogeochemistry)
	second_fields := biogeochemistry_fields(&second.biogeochemistry)
	for field, field_index in first_fields {
		for value, index in field do testing.expect_value(t, value, second_fields[field_index][index])
	}
	for value, index in first.biogeochemistry.surface_par {
		testing.expect_value(t, value, second.biogeochemistry.surface_par[index])
	}
	for value, index in first.biogeochemistry.benthic_par {
		testing.expect_value(t, value, second.biogeochemistry.benthic_par[index])
	}
	for value, index in first.biogeochemistry.bottom_temperature_mk {
		testing.expect_value(t, value, second.biogeochemistry.bottom_temperature_mk[index])
	}
	for value, index in first.biogeochemistry.pathway_energy {
		testing.expect_value(t, value, second.biogeochemistry.pathway_energy[index])
	}
	testing.expect_value(t, first.biogeochemistry.revision, second.biogeochemistry.revision)
	testing.expect_value(t, first.events.count, second.events.count)
	testing.expect_value(t, first.events.dropped, second.events.dropped)
	testing.expect_value(t, first.events.sequence, second.events.sequence)
	for index in 0 ..< int(first.events.count) {
		testing.expect_value(t, first.events.items[index], second.events.items[index])
	}
}

// The fused worker-team cadence job must reproduce the serial climate,
// sea-ice and biogeochemistry steps exactly: every array, the surface and
// biogeochemistry revisions, and the bounded event queue including its
// sequence numbers and dropped count.
@(test)
climate_cadence_step_matches_serial_reference :: proc(t: ^testing.T) {
	parallel := new(World)
	serial := new(World)
	defer free(parallel)
	defer free(serial)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(serial, TERRAIN_SEED))
	defer world_deinit(serial)
	testing.expect(t, parallel.planetary.workers.count > 1, "needs a real worker team")
	for step in 0 ..< 24 {
		// Dynamics between cadence steps keeps the fields moving so the
		// comparison covers rain, snow, evaporation, ice growth and melt.
		for _ in 0 ..< PLANET_CLIMATE_CADENCE_TICKS {
			climate_dynamics_step(&parallel.planetary)
			climate_dynamics_step(&serial.planetary)
		}
		planetary_events_clear(&parallel.planetary.events)
		planetary_events_clear(&serial.planetary.events)
		climate_cadence_step(&parallel.planetary)
		_cadence_serial_reference(&serial.planetary)
		if step % 8 == 7 do _cadence_expect_equal(t, &parallel.planetary, &serial.planetary)
	}
	_cadence_expect_equal(t, &parallel.planetary, &serial.planetary)
}

// Forcing rain in every cell overflows the 256-entry event queue many times
// over across every shard: the replay must drop exactly what the serial
// push sequence drops and keep the same first 256 items.
@(test)
climate_cadence_step_replays_overflowing_precipitation_events :: proc(t: ^testing.T) {
	parallel := new(World)
	serial := new(World)
	defer free(parallel)
	defer free(serial)
	testing.expect(t, world_init_seed(parallel, TERRAIN_SEED))
	defer world_deinit(parallel)
	testing.expect(t, world_init_seed(serial, TERRAIN_SEED))
	defer world_deinit(serial)
	for world in ([]^World{parallel, serial}) {
		for index in 0 ..< PLANET_SIM_CELL_COUNT do world.planetary.climate.cloud[index] = CLIMATE_MAX_WATER
		// A pre-existing event in the queue shifts where the overflow starts.
		_ = planetary_event_push(&world.planetary.events, .Lightning, 7, 1, 1)
	}
	climate_cadence_step(&parallel.planetary)
	_cadence_serial_reference(&serial.planetary)
	testing.expect_value(t, int(parallel.planetary.events.count), PLANET_EVENT_CAPACITY)
	testing.expect(t, parallel.planetary.events.dropped > 0, "overflow must be recorded")
	_cadence_expect_equal(t, &parallel.planetary, &serial.planetary)
}
