#+build !js
package main

import shared "../shared"
import "core:math"
import "core:testing"

@(test)
weather_orbital_sampling_is_continuous_and_bounded :: proc(t: ^testing.T) {
	physical := shared.planet_physical_earthlike()
	orbit: shared.Orbit_State
	shared.orbit_init(&orbit, 1)
	orbit.rotation_epoch = shared.ORBIT_PHASE_SCALE - 1_000
	shared.orbit_step(&orbit, physical, 0)
	original := orbit
	next := orbit
	shared.orbit_step(&next, physical, shared.PLANET_SIM_SECONDS_PER_TICK)
	duration := shared.TICK_DURATION_SECONDS
	start := weather_orbital_sample_at(orbit, physical, 0)
	finish := weather_orbital_sample_at(next, physical, 0)
	middle := weather_orbital_sample_at(orbit, physical, duration * 0.5)
	testing.expect_value(t, start.sun_direction, shared.orbit_ephemeris(orbit, physical).sun.planet_fixed_direction)
	testing.expect_value(t, weather_orbital_sample_at(orbit, physical, duration), finish)
	testing.expect_value(t, weather_orbital_sample_at(orbit, physical, duration * 10), finish)
	testing.expect_value(t, weather_orbital_sample_at(orbit, physical, -duration), start)
	testing.expect(t, middle.sun_direction != start.sun_direction)
	testing.expect(t, middle.sun_direction != finish.sun_direction)
	testing.expect(t, math.abs(middle.moon_distance - (start.moon_distance + finish.moon_distance) * 0.5) < 0.1)
	testing.expect(t, math.abs(middle.moon_phase - (start.moon_phase + finish.moon_phase) * 0.5) < 0.000001)
	for direction in ([][3]f32{middle.sun_direction, middle.moon_direction}) {
		testing.expect(t, math.abs(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z - 1) < 0.00001)
	}
	before := weather_orbital_sample_at(orbit, physical, duration - 0.000001)
	after := weather_orbital_sample_at(next, physical, 0.000001)
	for index in 0 ..< 3 {
		testing.expect(t, math.abs(before.sun_direction[index] - after.sun_direction[index]) < 0.00001)
	}
	for fps in ([]int{30, 60, 120}) {
		elapsed: f64
		for _ in 0 ..< fps / 10 {
			elapsed += 1 / f64(fps)
		}
		sample := weather_orbital_sample_at(orbit, physical, elapsed)
		reference := weather_orbital_sample_at(orbit, physical, 0.1)
		for index in 0 ..< 3 {
			testing.expect(t, math.abs(sample.sun_direction[index] - reference.sun_direction[index]) < 0.000001)
		}
	}
	testing.expect_value(t, orbit, original)
}

@(test)
weather_orbital_direction_handles_degenerate_arcs :: proc(t: ^testing.T) {
	start := [3]f32{1, 0, 0}
	testing.expect_value(t, weather_orbital_direction(start, start, 0.5), start)
	for finish in ([][3]f32{{-1, 0, 0}, {0, 1, 0}, {1, 0.00001, 0}}) {
		middle := weather_orbital_direction(start, finish, 0.5)
		testing.expect(t, math.abs(middle.x * middle.x + middle.y * middle.y + middle.z * middle.z - 1) < 0.00001)
	}
}

@(test)
weather_orbital_rendering_holds_on_pause_and_resets_without_history :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	planet := &value.world.planetary
	planet.physical = shared.planet_physical_earthlike()
	shared.orbit_init(&planet.orbit, 1)
	value.ocean_visual = ocean_visual_settings_default()
	value.accumulator = shared.TICK_DURATION_SECONDS * 0.5
	original := planet.orbit
	for automatic in ([]bool{false, true}) {
		value.ocean_visual.automatic_weather = automatic
		if !automatic do weather_apply_atmosphere(value)
		intensity := value.atmosphere.sun_intensity
		weather_sync_sun_direction(value)
		sun, _ := weather_orbital_lights(value)
		testing.expect_value(t, value.atmosphere.sun_direction, sun.direction)
		testing.expect_value(t, value.atmosphere.sun_intensity, intensity)
		value.pause.open = true
		for _ in 0 ..< 120 {
			weather_sync_sun_direction(value)
			paused, _ := weather_orbital_lights(value)
			testing.expect_value(t, paused.direction, sun.direction)
		}
		value.pause.open = false
	}
	testing.expect_value(t, planet.orbit, original)
	shared.orbit_init(&planet.orbit, 42)
	value.accumulator = 0
	weather_sync_sun_direction(value)
	testing.expect_value(t, value.atmosphere.sun_direction, shared.orbit_ephemeris(planet.orbit, planet.physical).sun.planet_fixed_direction)
}

@(private = "file")
_weather_test_world_init :: proc(world: ^shared.World) {
	planet := &world.planetary
	planet.physical = shared.planet_physical_earthlike()
	shared.planet_sim_grid_init(&planet.grid, planet.physical)
	planet.ocean.mean_depth_mm = make([]u32, shared.PLANET_SIM_CELL_COUNT)
	shared.waves_init(&planet.waves)
	for index in 0 ..< shared.PLANET_SIM_CELL_COUNT do planet.ocean.mean_depth_mm[index] = 500_000
}

@(private = "file")
_weather_test_world_deinit :: proc(world: ^shared.World) {
	planet := &world.planetary
	shared.waves_deinit(&planet.waves)
	delete(planet.ocean.mean_depth_mm)
	shared.planet_sim_grid_deinit(&planet.grid)
}

@(private = "file")
_weather_test_distance_mm :: proc(world: ^shared.World, from, to: int) -> u64 {
	waves := &world.planetary.waves
	angle := shared.wave_angle_between(waves.cell_direction[from], waves.cell_direction[to])
	return u64(f64(angle) * f64(world.planetary.physical.radius_m) * 1_000)
}

@(test)
ring_packet_projects_as_radial_render_packet :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	_weather_test_world_init(world)
	defer _weather_test_world_deinit(world)
	planet := &world.planetary
	source := shared.planet_sim_index({.Pos_X, 48, 48})
	focus_cell := shared.planet_sim_index({.Pos_X, 54, 48})
	far_cell := shared.planet_sim_index({.Pos_X, 20, 48})
	radius_mm := _weather_test_distance_mm(world, source, focus_cell)
	planet.waves.packets[0] = {
		active           = true,
		id               = 11,
		source_id        = 1,
		source_cell      = u32(source),
		period_ms        = 9_625,
		action           = 2_325_625,
		radius_mm        = radius_mm,
		band_mm          = shared.wave_ring_band_mm(planet, u32(source), 9_625),
		group_speed_mm_s = 7_515,
		phase_epoch_ms   = 3_000,
	}
	planet.waves.packet_count = 1
	storage: [OCEAN_RENDER_PACKET_MAX]Ocean_Render_Packet
	focus := planet.waves.cell_direction[focus_cell]
	packets := weather_ocean_render_packets(world, focus, {}, &storage)
	testing.expect_value(t, len(packets), 1)
	if len(packets) == 0 do return
	packet := packets[0]
	globe := ocean_globe_meters_per_unit(world)
	testing.expect(t, packet.radial)
	testing.expect_value(t, packet.id, u32(11))
	testing.expect(t, abs(packet.front_radius - f32(radius_mm) / 1_000 / globe) < 0.01)
	testing.expect(t, packet.band > 1)
	expected_speed := 7.515 * OCEAN_SIM_SECONDS_PER_REAL_SECOND / globe
	testing.expect(t, abs(packet.front_speed - expected_speed) < 0.01)
	speed := math.sqrt(
		packet.direction.x * packet.direction.x +
		packet.direction.y * packet.direction.y +
		packet.direction.z * packet.direction.z,
	)
	testing.expect(t, abs(speed - packet.front_speed) < 0.001)
	source_direction := planet.waves.cell_direction[source]
	expected_center := shared.planet_position(source_direction, 0)
	testing.expect(t, abs(packet.center.x - expected_center.x) < 0.01)
	testing.expect(t, abs(packet.center.y - expected_center.y) < 0.01)
	testing.expect(t, abs(packet.center.z - expected_center.z) < 0.01)
	testing.expect(t, abs(packet.significant_height - 6.1) < 0.01)
	testing.expect_value(t, packet.phase_epoch, f32(3))
	far_packets := weather_ocean_render_packets(
		world,
		planet.waves.cell_direction[far_cell],
		{},
		&storage,
	)
	testing.expect_value(t, len(far_packets), 0)
}

@(test)
ring_query_extrapolates_between_wave_steps :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	_weather_test_world_init(world)
	defer _weather_test_world_deinit(world)
	planet := &world.planetary
	source := shared.planet_sim_index({.Pos_X, 48, 48})
	focus_cell := shared.planet_sim_index({.Pos_X, 52, 48})
	planet.waves.packets[0] = {
		active           = true,
		id               = 5,
		source_id        = 1,
		source_cell      = u32(source),
		period_ms        = 9_625,
		action           = 2_325_625,
		radius_mm        = _weather_test_distance_mm(world, source, focus_cell),
		band_mm          = shared.wave_ring_band_mm(planet, u32(source), 9_625),
		group_speed_mm_s = 7_515,
	}
	planet.waves.packet_count = 1
	focus := shared.planet_position(planet.waves.cell_direction[focus_cell], 0)
	query: Ocean_Macro_Wave_Query
	testing.expect(t, ocean_macro_query_update(&query, world, focus, 2))
	testing.expect_value(t, query.packet_count, 1)
	first := query.packets[0]
	testing.expect_value(t, first.phase_epoch, f32(2))
	step := u64(shared.PLANET_SIM_SECONDS_PER_TICK * shared.PLANET_WAVE_CADENCE_TICKS)
	planet.waves.packets[0].radius_mm += u64(planet.waves.packets[0].group_speed_mm_s) * step
	real_step := f32(step) / OCEAN_SIM_SECONDS_PER_REAL_SECOND
	_ = ocean_macro_query_update(&query, world, focus, 2 + real_step)
	continued := query.packets[0]
	testing.expect_value(t, continued.phase_epoch, f32(2))
	testing.expect_value(t, continued.front_radius, first.front_radius)
	testing.expect(
		t,
		abs(
			ocean_ring_front(continued, 2 + real_step) -
			f32(planet.waves.packets[0].radius_mm) / 1_000 / ocean_globe_meters_per_unit(world),
		) <
		continued.band * OCEAN_RING_CONTINUE_TOLERANCE,
	)
	planet.waves.packets[0].radius_mm += u64(planet.waves.packets[0].group_speed_mm_s) * step * 10
	_ = ocean_macro_query_update(&query, world, focus, 2 + real_step * 2)
	testing.expect_value(t, query.packet_count, 1)
	testing.expect_value(t, query.packets[0].phase_epoch, 2 + real_step * 2)
}
