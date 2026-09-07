package shared

import "core:testing"

@(test)
tide_scales_with_inverse_cube_distance :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	ephemeris := Orbital_Body_Ephemeris {
		body = {mass_teratonnes = 73_420_000_000},
		distance_km = 400_000,
		planet_fixed_direction = {1, 0, 0},
	}
	far := abs(tide_equilibrium_mm(physical, ephemeris, {1, 0, 0}))
	ephemeris.distance_km = 200_000
	near := abs(tide_equilibrium_mm(physical, ephemeris, {1, 0, 0}))
	testing.expect(t, near > far)
}

@(test)
tide_uses_three_dimensional_planet_fixed_direction :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	ephemeris := Orbital_Body_Ephemeris {
		body = {mass_teratonnes = 73_420_000_000},
		distance_km = 384_400,
		planet_fixed_direction = {0, 0, 1},
	}
	aligned := tide_equilibrium_mm(physical, ephemeris, {0, 0, 1})
	antipodal := tide_equilibrium_mm(physical, ephemeris, {0, 0, -1})
	quadrature := tide_equilibrium_mm(physical, ephemeris, {1, 0, 0})
	testing.expect(t, aligned > 0)
	testing.expect_value(t, aligned, antipodal)
	testing.expect(t, quadrature < 0)
	testing.expect(t, aligned >= abs(quadrature))
}

@(test)
wave_energy_grows_under_wind_and_is_depth_limited :: proc(t: ^testing.T) {
	planet: Planetary_State
	planet_sim_grid_init(&planet.grid, planet_physical_earthlike())
	defer planet_sim_grid_deinit(&planet.grid)
	planet.ocean.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_east = make([]i32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_north = make([]i32, PLANET_SIM_CELL_COUNT)
	waves_init(&planet.waves)
	defer waves_deinit(&planet.waves)
	defer delete(planet.climate.wind_north)
	defer delete(planet.climate.wind_east)
	defer delete(planet.ocean.mean_depth_mm)
	for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 1_000
	planet.climate.wind_east[0] = 2_000
	waves_step(&planet)
	first_height := planet.waves.height_mm[0]
	testing.expect(t, planet.waves.wind_sea_variance[0] > 0)
	testing.expect(t, first_height > 0)
	planet.climate.wind_east[0] = 4_000
	waves_step(&planet)
	testing.expect(t, planet.waves.height_mm[0] >= first_height)
	testing.expect(t, planet.waves.height_mm[0] <= WAVE_MAX_HEIGHT_MM)
}

@(test)
calm_deep_water_has_no_unforced_swell :: proc(t: ^testing.T) {
	planet: Planetary_State
	planet.physical = planet_physical_earthlike()
	planet_sim_grid_init(&planet.grid, planet.physical)
	defer planet_sim_grid_deinit(&planet.grid)
	planet.ocean.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_east = make([]i32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_north = make([]i32, PLANET_SIM_CELL_COUNT)
	waves_init(&planet.waves)
	defer waves_deinit(&planet.waves)
	defer delete(planet.climate.wind_north)
	defer delete(planet.climate.wind_east)
	defer delete(planet.ocean.mean_depth_mm)
	planet.ocean.mean_depth_mm[0] = 50_000
	waves_step(&planet)
	testing.expect_value(t, planet.waves.packet_count, u16(0))
	testing.expect_value(t, planet.waves.swell_variance[0], u64(0))
}

@(test)
finite_depth_dispersion_slows_and_shoals_toward_shore :: proc(t: ^testing.T) {
	deep_phase, deep_group := wave_dispersion_speed_mm_s(9_810, 50_000, 8_000)
	shallow_phase, shallow_group := wave_dispersion_speed_mm_s(9_810, 1_000, 8_000)
	testing.expect(t, deep_phase > shallow_phase)
	testing.expect(t, deep_group > shallow_group)
	testing.expect(t, shallow_phase > 0 && shallow_group > 0)
}

@(test)
nine_second_swell_has_physical_phase_and_group_travel :: proc(t: ^testing.T) {
	phase, group := wave_dispersion_speed_mm_s(9_810, 500_000, 9_625)
	testing.expect(t, phase >= 15_020 && phase <= 15_035)
	testing.expect(t, group >= 7_510 && group <= 7_520)
	testing.expect(t, u64(group) * 600 >= 4_506_000 && u64(group) * 600 <= 4_512_000)
}

@(private = "file")
_wave_test_planet_init :: proc(planet: ^Planetary_State) {
	planet.physical = planet_physical_earthlike()
	planet_sim_grid_init(&planet.grid, planet.physical)
	planet.ocean.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_east = make([]i32, PLANET_SIM_CELL_COUNT)
	planet.climate.wind_north = make([]i32, PLANET_SIM_CELL_COUNT)
	waves_init(&planet.waves)
}

@(private = "file")
_wave_test_planet_deinit :: proc(planet: ^Planetary_State) {
	waves_deinit(&planet.waves)
	delete(planet.climate.wind_north)
	delete(planet.climate.wind_east)
	delete(planet.ocean.mean_depth_mm)
	planet_sim_grid_deinit(&planet.grid)
}

@(private = "file")
_wave_test_cell :: proc(u, v: i32) -> int {
	return planet_sim_index({.Pos_X, u, v})
}

@(private = "file")
_wave_test_distance_mm :: proc(planet: ^Planetary_State, from, to: int) -> u64 {
	angle := wave_angle_between(planet.waves.cell_direction[from], planet.waves.cell_direction[to])
	return u64(f64(angle) * f64(planet.physical.radius_m) * 1_000)
}

@(private = "file")
_wave_test_ring :: proc(planet: ^Planetary_State, source: int, radius_mm: u64, action: u64) {
	planet.waves.packets[0] = {
		active           = true,
		id               = 1,
		source_id        = 1,
		source_cell      = u32(source),
		period_ms        = 8_000,
		action           = action,
		radius_mm        = radius_mm,
		band_mm          = wave_ring_band_mm(planet, u32(source), 8_000),
		group_speed_mm_s = 1,
	}
	planet.waves.packet_count = 1
}

@(private = "file")
_wave_test_outward_alignment :: proc(planet: ^Planetary_State, source, cell: int) -> f32 {
	state := &planet.waves
	cell_direction := state.cell_direction[cell]
	source_direction := state.cell_direction[source]
	dot :=
		cell_direction.x * source_direction.x +
		cell_direction.y * source_direction.y +
		cell_direction.z * source_direction.z
	outward, ok := wave_normalize(cell_direction * dot - source_direction)
	if !ok do return 0
	east := f32(state.swell_direction_east[cell]) / f32(WAVE_DIRECTION_SCALE)
	north := f32(state.swell_direction_north[cell]) / f32(WAVE_DIRECTION_SCALE)
	direction := state.cell_east[cell] * east + state.cell_north[cell] * north
	return outward.x * direction.x + outward.y * direction.y + outward.z * direction.z
}

@(test)
storm_packet_emission_is_local_and_arrival_is_delayed :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	center := PLANET_SIM_FACE_CELLS + 1
	planet.ocean.mean_depth_mm[center] = 500_000
	for neighbour in planet.grid.neighbours[center] do planet.ocean.mean_depth_mm[neighbour] = 500_000
	planet.climate.wind_east[center] = 12 * PLANET_VELOCITY_SCALE
	planet.waves.wind_sea_variance[center] = 4_000_000
	planet.waves.wind_sea_period_ms[center] = 9_625
	for _ in 0 ..< 12 {
		waves_detect_storm_sources(planet)
		waves_emit_swell_packets(planet)
	}
	testing.expect(t, planet.waves.packet_count > 0)
	packet := &planet.waves.packets[0]
	testing.expect_value(t, packet.source_cell, u32(center))
	testing.expect_value(t, packet.radius_mm, u64(0))
	wave_packet_advance(planet, packet, 600)
	testing.expect(t, packet.active)
	testing.expect(t, packet.radius_mm >= 4_506_000 && packet.radius_mm <= 4_512_000)
	waves_rasterize_packets(planet)
	testing.expect(t, planet.waves.swell_variance[center] > 0)
	testing.expect_value(t, planet.waves.swell_variance[PLANET_SIM_CELL_COUNT - 1], u64(0))
}

@(test)
storm_source_rejects_shallow_and_coast_adjacent_maxima :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	center := PLANET_SIM_FACE_CELLS + 1
	planet.climate.wind_east[center] = 12 * PLANET_VELOCITY_SCALE
	planet.ocean.mean_depth_mm[center] = 20_000
	waves_detect_storm_sources(planet)
	testing.expect_value(t, planet.waves.source_count, u16(0))
	planet.ocean.mean_depth_mm[center] = 500_000
	waves_detect_storm_sources(planet)
	testing.expect_value(t, planet.waves.source_count, u16(0))
	for neighbour in planet.grid.neighbours[center] do planet.ocean.mean_depth_mm[neighbour] = 500_000
	waves_detect_storm_sources(planet)
	testing.expect_value(t, planet.waves.source_count, u16(1))
}

@(test)
storm_emission_creates_one_ring :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	center := PLANET_SIM_FACE_CELLS + 1
	planet.ocean.mean_depth_mm[center] = 500_000
	planet.waves.sources[0] = {
		active               = true,
		id                   = 1,
		cell                 = u32(center),
		direction_east       = WAVE_DIRECTION_SCALE,
		period_ms            = 8_000,
		accumulated_variance = 8_000,
		age_s                = WAVE_PACKET_EMISSION_INTERVAL_S,
		emission_elapsed_s   = WAVE_PACKET_EMISSION_INTERVAL_S,
	}
	planet.waves.source_count = 1
	waves_emit_swell_packets(planet)
	testing.expect_value(t, planet.waves.packet_count, u16(1))
	packet := planet.waves.packets[0]
	testing.expect(t, packet.active)
	testing.expect_value(t, packet.action, u64(8_000))
	testing.expect_value(t, packet.radius_mm, u64(0))
	testing.expect_value(t, packet.blocked_sectors, u64(0))
	testing.expect_value(t, packet.source_cell, u32(center))
	testing.expect_value(t, packet.band_mm, wave_cell_span_mm(planet, u32(center)))
	testing.expect(t, packet.band_mm > 50_000_000)
	testing.expect(t, packet.group_speed_mm_s > 0)
	testing.expect_value(t, planet.waves.sources[0].accumulated_variance, u64(4_000))
}

@(test)
ring_rasterises_a_circular_band_in_every_direction :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
	waves_derive_bathymetry(planet)
	source := _wave_test_cell(48, 48)
	east := _wave_test_cell(53, 48)
	west := _wave_test_cell(43, 48)
	north := _wave_test_cell(48, 53)
	south := _wave_test_cell(48, 43)
	far_east := _wave_test_cell(57, 48)
	_wave_test_ring(planet, source, _wave_test_distance_mm(planet, source, east), 1_000_000)
	waves_rasterize_packets(planet)
	state := &planet.waves
	testing.expect(t, state.swell_variance[east] > 0)
	testing.expect(t, state.swell_variance[west] > 0)
	testing.expect(t, state.swell_variance[north] > 0)
	testing.expect(t, state.swell_variance[south] > 0)
	testing.expect_value(t, state.swell_variance[source], u64(0))
	testing.expect_value(t, state.swell_variance[far_east], u64(0))
	testing.expect_value(t, state.swell_period_ms[east], u32(8_000))
	for cell in ([]int{east, west, north, south}) {
		testing.expect(t, _wave_test_outward_alignment(planet, source, cell) > 0.9)
	}
}

@(test)
ring_action_spreads_geometrically :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
	waves_derive_bathymetry(planet)
	source := _wave_test_cell(48, 48)
	near := _wave_test_cell(53, 48)
	far := _wave_test_cell(58, 48)
	action := u64(1_000_000)
	_wave_test_ring(planet, source, _wave_test_distance_mm(planet, source, near), action)
	waves_rasterize_packets(planet)
	near_total: u64
	for variance in planet.waves.swell_variance do near_total += variance
	near_peak := planet.waves.swell_variance[near]
	testing.expect(t, near_total >= action * 95 / 100 && near_total <= action * 105 / 100)
	_wave_test_ring(planet, source, _wave_test_distance_mm(planet, source, far), action)
	waves_rasterize_packets(planet)
	far_total: u64
	for variance in planet.waves.swell_variance do far_total += variance
	far_peak := planet.waves.swell_variance[far]
	testing.expect(t, far_total >= action * 95 / 100 && far_total <= action * 105 / 100)
	testing.expect(t, far_peak > 0 && far_peak < near_peak)
}

@(test)
land_shadows_ring_sectors :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
	for v in 0 ..< PLANET_SIM_FACE_CELLS do planet.ocean.mean_depth_mm[_wave_test_cell(51, i32(v))] = 0
	waves_derive_bathymetry(planet)
	source := _wave_test_cell(48, 48)
	shore := _wave_test_cell(50, 48)
	wall := _wave_test_cell(51, 48)
	behind := _wave_test_cell(55, 48)
	open := _wave_test_cell(41, 48)
	_wave_test_ring(planet, source, 0, 4_000_000)
	packet := &planet.waves.packets[0]
	shore_mm := _wave_test_distance_mm(planet, source, shore)
	wall_mm := _wave_test_distance_mm(planet, source, wall)
	behind_mm := _wave_test_distance_mm(planet, source, behind)
	packet.group_speed_mm_s = u32(shore_mm)
	wave_packet_advance(planet, packet, 1)
	testing.expect_value(t, packet.blocked_sectors, u64(0))
	packet.group_speed_mm_s = u32(wall_mm - shore_mm)
	wave_packet_advance(planet, packet, 1)
	testing.expect(t, packet.blocked_sectors != 0)
	testing.expect(t, packet.blocked_sectors != WAVE_RING_ALL_SECTORS)
	testing.expect(t, planet.waves.breaking[shore] > 0)
	testing.expect_value(t, planet.waves.breaker_type[shore], Wave_Breaker_Type.Surging)
	packet.group_speed_mm_s = u32(behind_mm - wall_mm)
	wave_packet_advance(planet, packet, 1)
	testing.expect(t, packet.active)
	waves_rasterize_packets(planet)
	testing.expect_value(t, planet.waves.swell_variance[behind], u64(0))
	testing.expect(t, planet.waves.swell_variance[open] > 0)
}

@(test)
ring_retires_after_the_far_hemisphere :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	for index in 0 ..< PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
	source := _wave_test_cell(48, 48)
	_wave_test_ring(planet, source, planet.physical.radius_m * 1_000 * 4, 4_000_000)
	packet := &planet.waves.packets[0]
	wave_packet_advance(planet, packet, 1)
	testing.expect(t, !packet.active)
	testing.expect_value(t, planet.waves.packet_count, u16(0))
}

@(test)
travelled_packet_does_not_absorb_new_source_emission :: proc(t: ^testing.T) {
	state: Wave_State
	state.packets[0] = {
		active      = true,
		source_id   = 7,
		source_cell = 12,
		period_ms   = 8_000,
		action      = 10,
		radius_mm   = 10_000,
		band_mm     = 1_000,
	}
	slot := wave_packet_allocate(&state, 7, 12, 8_000)
	testing.expect(t, slot != 0)
	testing.expect_value(t, state.merged_packets, u32(0))
	testing.expect_value(t, state.packets[0].action, u64(10))
}

@(test)
compatible_source_packet_merges_before_using_free_slot :: proc(t: ^testing.T) {
	state := new(Wave_State)
	defer free(state)
	state.packets[0] = {
		active      = true,
		source_id   = 7,
		source_cell = 12,
		period_ms   = 8_000,
		action      = 10,
		band_mm     = 1_000,
	}
	slot := wave_packet_allocate(state, 7, 12, 8_000)
	testing.expect_value(t, slot, 0)
	testing.expect_value(t, state.merged_packets, u32(1))
}

@(test)
full_packet_table_evicts_the_thinnest_ring :: proc(t: ^testing.T) {
	state := new(Wave_State)
	defer free(state)
	for &packet, index in state.packets {
		packet = {
			active      = true,
			id          = u32(index + 1),
			source_id   = u32(index + 1),
			source_cell = u32(index),
			period_ms   = 8_000,
			action      = 1_000,
			radius_mm   = 1_000,
			band_mm     = 1_000,
		}
	}
	state.packets[5].radius_mm = 1_000_000
	slot := wave_packet_allocate(state, 999, 999, 8_000)
	testing.expect_value(t, slot, 5)
	testing.expect_value(t, state.dropped_packets, u32(1))
}

@(test)
uniform_deep_water_never_breaks_a_cell :: proc(t: ^testing.T) {
	planet := new(Planetary_State)
	defer free(planet)
	_wave_test_planet_init(planet)
	defer _wave_test_planet_deinit(planet)
	center := PLANET_SIM_FACE_CELLS + 1
	planet.ocean.mean_depth_mm[center] = 500_000
	limited, breaking, breaker_type := wave_cell_break_limit(planet, center, 2_325_625, 9_625)
	testing.expect_value(t, limited, u64(2_325_625))
	testing.expect_value(t, breaking, u32(0))
	testing.expect_value(t, breaker_type, Wave_Breaker_Type.None)
	planet.ocean.mean_depth_mm[center] = 2_000
	shallow, shallow_breaking, shallow_type := wave_cell_break_limit(
		planet,
		center,
		2_325_625,
		9_625,
	)
	testing.expect(t, shallow < 2_325_625)
	testing.expect(t, shallow_breaking > 0)
	testing.expect(t, shallow_type != .None)
}

@(test)
sea_ice_uses_ocean_temperature_and_melt_hysteresis :: proc(t: ^testing.T) {
	frozen := sea_ice_update(
		0,
		270 * PLANET_TEMPERATURE_SCALE,
		270 * PLANET_TEMPERATURE_SCALE,
		1_000,
	)
	testing.expect(t, frozen > 0)
	testing.expect_value(
		t,
		sea_ice_update(
			frozen,
			273 * PLANET_TEMPERATURE_SCALE,
			274 * PLANET_TEMPERATURE_SCALE,
			1_000,
		),
		frozen,
	)
	testing.expect(
		t,
		sea_ice_update(
			frozen,
			275 * PLANET_TEMPERATURE_SCALE,
			277 * PLANET_TEMPERATURE_SCALE,
			1_000,
		) <
		frozen,
	)
	testing.expect_value(
		t,
		sea_ice_update(frozen, 270 * PLANET_TEMPERATURE_SCALE, 270 * PLANET_TEMPERATURE_SCALE, 0),
		u32(0),
	)
}

@(test)
sea_ice_wave_damping_is_monotonic_and_bounded :: proc(t: ^testing.T) {
	variance := u64(1_000_000)
	open := sea_ice_damp_wave_variance(variance, 0)
	partial := sea_ice_damp_wave_variance(variance, CLIMATE_MAX_WATER / 2)
	covered := sea_ice_damp_wave_variance(variance, CLIMATE_MAX_WATER)
	testing.expect_value(t, open, variance)
	testing.expect(t, open > partial)
	testing.expect(t, partial > covered)
	testing.expect_value(t, covered, u64(100_000))
}

@(test)
ocean_depth_sync_increments_revision_only_on_change :: proc(t: ^testing.T) {
	state: Ocean_State
	state.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
	defer delete(state.mean_depth_mm)
	depths := make([]u32, PLANET_SIM_CELL_COUNT)
	defer delete(depths)
	testing.expect(t, !ocean_sync_mean_depth(&state, depths))
	depths[0] = 25_000
	testing.expect(t, ocean_sync_mean_depth(&state, depths))
	testing.expect_value(t, state.bathymetry_revision, u64(1))
	testing.expect(t, !ocean_sync_mean_depth(&state, depths))
}

@(test)
ocean_column_transport_shifts_from_surface_to_deep_current_with_depth :: proc(t: ^testing.T) {
	state: Ocean_State
	state.mean_depth_mm = make([]u32, PLANET_SIM_CELL_COUNT)
	state.transport_east = make([]i32, PLANET_SIM_CELL_COUNT)
	state.transport_north = make([]i32, PLANET_SIM_CELL_COUNT)
	state.deep_transport_east = make([]i32, PLANET_SIM_CELL_COUNT)
	state.deep_transport_north = make([]i32, PLANET_SIM_CELL_COUNT)
	defer delete(state.deep_transport_north)
	defer delete(state.deep_transport_east)
	defer delete(state.transport_north)
	defer delete(state.transport_east)
	defer delete(state.mean_depth_mm)
	state.transport_east[0] = 1_000
	state.deep_transport_east[0] = -500
	state.mean_depth_mm[0] = 10_000
	shallow_east, _ := ocean_column_transport(&state, 0)
	state.mean_depth_mm[0] = 200_000
	deep_east, _ := ocean_column_transport(&state, 0)
	testing.expect_value(t, shallow_east, i64(1_000))
	testing.expect_value(t, deep_east, i64(-500))
}

@(test)
ocean_surface_wind_drives_deep_return_and_dry_cells_stay_still :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	wet := -1
	dry := -1
	for depth, index in world.planetary.ocean.mean_depth_mm {
		if wet < 0 && depth >= 200_000 {
			interior := true
			for neighbour in world.planetary.grid.neighbours[index] do interior = interior && world.planetary.ocean.mean_depth_mm[neighbour] > 0
			if interior do wet = index
		}
		if dry < 0 && depth == 0 do dry = index
		if wet >= 0 && dry >= 0 do break
	}
	if wet < 0 {
		wet = 0
		world.planetary.ocean.mean_depth_mm[wet] = 200_000
	}
	if dry < 0 || dry == wet {
		dry = 1
		world.planetary.ocean.mean_depth_mm[dry] = 0
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		world.planetary.ocean.transport_east[index] = 0
		world.planetary.ocean.transport_north[index] = 0
		world.planetary.ocean.deep_transport_east[index] = 0
		world.planetary.ocean.deep_transport_north[index] = 0
		world.planetary.ocean.temperature[index] = 280 * PLANET_TEMPERATURE_SCALE
		world.planetary.climate.wind_east[index] = 0
		world.planetary.climate.wind_north[index] = 0
		if world.planetary.ocean.mean_depth_mm[index] > 0 {
			world.planetary.climate.wind_east[index] = PLANET_WIND_MAX
			world.planetary.ocean.transport_east[index] = OCEAN_MAX_TRANSPORT / 2
		}
	}
	for _ in 0 ..< 128 do ocean_step(&world.planetary)
	surface := world.planetary.ocean.transport_east[wet]
	deep := world.planetary.ocean.deep_transport_east[wet]
	testing.expect(t, surface > 0)
	testing.expect(t, deep < 0)
	testing.expect(t, abs(surface) <= OCEAN_MAX_TRANSPORT)
	testing.expect(t, abs(deep) <= OCEAN_MAX_TRANSPORT)
	testing.expect_value(t, world.planetary.ocean.transport_east[dry], i32(0))
	testing.expect_value(t, world.planetary.ocean.deep_transport_east[dry], i32(0))
}

@(test)
ocean_geothermal_heating_warms_submerged_cells :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init_seed(world, 5150))
	defer world_deinit(world)
	wet := -1
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if world.planetary.ocean.mean_depth_mm[index] > 0 {
			wet = index
			break
		}
	}
	testing.expect(t, wet >= 0)
	before := world.planetary.ocean.temperature[wet]
	world.planetary.geology.heat_flux_mw_m2[wet] = 200_000
	ocean_geothermal_step(&world.planetary)
	testing.expect(t, world.planetary.ocean.temperature[wet] > before)
}

@(test)
generated_world_spinup_produces_bounded_wind_and_sea_state :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	for tick in u64(0) ..< u64(PLANET_CLIMATE_CADENCE_TICKS * 64) {
		world_planetary_step(&world, tick)
	}
	planetary_diagnostics_update(&world)
	testing.expect(t, world.planetary.diagnostics.mean_wind_speed > 0)
	testing.expect(t, world.planetary.diagnostics.mean_wind_speed <= u32(PLANET_WIND_MAX * 2))
	testing.expect(t, world.planetary.diagnostics.mean_wave_height_mm > 0)
	testing.expect(t, world.planetary.diagnostics.mean_wave_height_mm <= WAVE_MAX_HEIGHT_MM)
	for temperature in world.planetary.climate.temperature {
		testing.expect(t, temperature < PLANET_MAX_TEMPERATURE)
	}
	for pressure in world.planetary.climate.pressure {
		testing.expect(t, pressure > 0 && pressure <= PLANET_MAX_PRESSURE)
	}
}
