package main

import shared "../shared"
import "core:math"
import "core:strings"
import "core:testing"
import rl "ingot:gfx"
import b3 "vendor:box3d"

@(test)
debug_entity_outline_scale_is_bounded_and_pulses :: proc(t: ^testing.T) {
	testing.expect_value(t, debug_entity_outline_scale(-1), f32(1.025))
	testing.expect_value(t, debug_entity_outline_scale(0), f32(1.025))
	testing.expect_value(t, debug_entity_outline_scale(1), f32(1.04))
	testing.expect_value(t, debug_entity_outline_scale(2), f32(1.04))
}

@(test)
cloud_shader_uses_seamless_directional_storm_layers :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(SKY_SHADER, "atmosphere_cloud_projection(ray"))
	testing.expect(t, strings.contains(SKY_SHADER, "u.custom_params_3.xy"))
	testing.expect(t, strings.contains(SKY_SHADER, "u.custom_params_3.z"))
	testing.expect(t, strings.contains(SKY_SHADER, "storm_flash(u.light_params.w, storm)"))
	testing.expect(t, strings.contains(SKY_SHADER, "cloud_flash"))
	testing.expect(t, !strings.contains(SKY_SHADER, "atan2(ray"))
}

@(test)
ocean_shader_keeps_storm_displacement_and_removes_storm_surface_detail :: proc(t: ^testing.T) {
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let storm = clamp(u.custom_params_3.z, 0.0, 1.0)"),
	)
	water_source := WATER_SHADER[len(SHADER_PREAMBLE):]
	testing.expect(t, !strings.contains(water_source, "storm_flash("))
	testing.expect(t, !strings.contains(water_source, "storm_light_direction("))
	testing.expect(t, !strings.contains(water_source, "flash_reflection"))
	testing.expect(t, strings.contains(water_source, "world += displacement;"))
	testing.expect(t, strings.contains(water_source, "radial * clamp(dot(spectral_raw, radial), -radial_limit, radial_limit)"))
	testing.expect(t, strings.contains(water_source, "packet_displacement += packet.displacement * packet_active;"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let storm_surface_cleanup = smoothstep(0.05, 0.35, storm)",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let storm_surface_detail = 1.0 - storm_surface_cleanup"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"normalize(mix(displaced_geometry_normal, radial, radial_normal_weight))",
		),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"spectral_enabled * close_spectral_foam * storm_surface_detail",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "u.custom_params_2.x * storm_surface_detail"))
	testing.expect(t, strings.contains(WATER_SHADER, "0.12 * storm_surface_detail"))
	testing.expect(t, strings.contains(WATER_SHADER, "let displacement = radial * height"))
	testing.expect(t, !strings.contains(WATER_SHADER, "close_storm_surface"))
	testing.expect(t, !strings.contains(WATER_SHADER, "storm_surface_cleanup = storm *"))
	testing.expect(t, !strings.contains(WATER_SHADER, "detail_ripples("))
	testing.expect(t, !strings.contains(WATER_SHADER, "storm * 2.4"))
}

@(test)
ocean_overview_lighting_does_not_follow_clipmap_tessellation :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "let overview_normal_weight = smoothstep(120.0, 480.0, dist)"))
	testing.expect(t, strings.contains(WATER_SHADER, "let radial_normal_weight = select(max(storm_surface_cleanup, overview_normal_weight), 0.0, breaker_surface)"))
	testing.expect(t, strings.contains(WATER_SHADER, "normalize(mix(displaced_geometry_normal, radial, radial_normal_weight))"))
	testing.expect(t, strings.contains(WATER_SHADER, "let normal = select(geometry_normal, -geometry_normal, breaker_surface && dot(geometry_normal, view) < 0.0)"))
	testing.expect(t, strings.contains(WATER_SHADER, "planet_ambient_light(geometry_normal, radial, light)"))
	testing.expect(t, strings.contains(WATER_SHADER, "planet_direct_light(geometry_normal, radial, light)"))
}

@(test)
rain_streak_geometry_is_stable_smooth_and_wrapped :: proc(t: ^testing.T) {
	first := rain_streak_geometry(7, 1.25, 0.8, 20, 800, 600)
	repeat := rain_streak_geometry(7, 1.25, 0.8, 20, 800, 600)
	next := rain_streak_geometry(7, 1.26, 0.8, 20, 800, 600)
	wrapped := rain_streak_geometry(7, 10_001.25, 0.8, 20, 800, 600)
	testing.expect_value(t, first, repeat)
	testing.expect(t, abs(next.start.x - first.start.x) < 1)
	testing.expect(t, abs(next.start.y - first.start.y) < 10)
	testing.expect(t, wrapped.start.x >= 0 && wrapped.start.x < 800)
	testing.expect(t, wrapped.start.y >= 0 && wrapped.start.y < 600)
	testing.expect(t, first.end.x > first.start.x)
	testing.expect(t, first.end.y > first.start.y)
}

@(test)
ocean_visual_defaults_are_clean_with_sparse_bubbles :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	testing.expect_value(t, settings.wave_amplitude_scale, f32(1))
	testing.expect_value(t, settings.bubble_strength, f32(0.7))
	testing.expect_value(t, settings.roughness, f32(0.09))
	testing.expect_value(t, settings.foam_crest, f32(0.28))
	testing.expect_value(t, settings.foam_shore, f32(1))
	testing.expect_value(t, settings.foam_wind, f32(0))
	testing.expect_value(t, settings.ring_radius, [3]f32{180, 540, 1_800})
}

@(test)
ocean_far_faces_start_above_the_intermediate_zoom_band :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	limit := settings.middle_altitude_limit
	margin := max(limit * OCEAN_RENDER_MODE_HYSTERESIS_RATIO, OCEAN_RENDER_MODE_HYSTERESIS_MIN)
	testing.expect(t, settings.near_altitude_limit < settings.middle_altitude_limit)
	testing.expect(t, !ocean_far_faces_next(false, false, settings.near_altitude_limit + 1, limit))
	testing.expect(t, !ocean_far_faces_next(false, false, limit, limit))
	testing.expect(t, ocean_far_faces_next(false, false, limit + 1, limit))
	testing.expect(t, !ocean_far_faces_next(false, true, limit + margin, limit))
	testing.expect(t, ocean_far_faces_next(false, true, limit + margin + 1, limit))
	testing.expect(t, ocean_far_faces_next(true, true, limit - margin, limit))
	testing.expect(t, !ocean_far_faces_next(true, true, limit - margin - 1, limit))
	testing.expect_value(t, ocean_water_material_style(), rl.Gpu_Material_Style.Transparent)
}

@(test)
ocean_draw_layers_always_cover_the_perspective :: proc(t: ^testing.T) {
	far_faces, clipmap_overlays := ocean_draw_layers(false)
	testing.expect(t, far_faces)
	testing.expect(t, clipmap_overlays)
	far_faces, clipmap_overlays = ocean_draw_layers(true)
	testing.expect(t, far_faces)
	testing.expect(t, !clipmap_overlays)
}

@(test)
far_only_world_skips_scene_capture :: proc(t: ^testing.T) {
	testing.expect(t, world_scene_capture_required(false))
	testing.expect(t, !world_scene_capture_required(true))
}

@(test)
ocean_background_material_matches_the_render_mode :: proc(t: ^testing.T) {
	near_material := rl.Gpu_Material {
		shader = {id = 11},
		scene_color_texture = {id = 21},
		scene_depth_texture = {id = 22},
		texture = {id = 31},
		normal_texture = {id = 32},
		roughness_ao_texture = {id = 33},
		custom_params_7 = {8, 12, 0, 4},
		custom_params_8 = {1, 2, 3, 4},
	}
	far_shader := rl.Gpu_3D_Shader{id = 12}
	for far_only in ([]bool{false, true}) {
		material := ocean_background_material(near_material, far_shader, far_only)
		faces, overlays := ocean_draw_layers(far_only)
		testing.expect(t, faces)
		testing.expect_value(t, overlays, !far_only)
		testing.expect_value(t, world_scene_capture_required(far_only), overlays)
		testing.expect_value(t, material.shader.id, far_shader.id if far_only else near_material.shader.id)
		testing.expect_value(t, material.scene_color_texture.id, u32(0) if far_only else near_material.scene_color_texture.id)
		testing.expect_value(t, material.scene_depth_texture.id, u32(0) if far_only else near_material.scene_depth_texture.id)
		testing.expect_value(t, material.custom_params_7, [4]f32{8, 12, 1, 4})
		testing.expect_value(t, material.custom_params_8, near_material.custom_params_8)
		testing.expect_value(t, material.texture.id, near_material.texture.id)
		testing.expect_value(t, material.normal_texture.id, near_material.normal_texture.id)
		testing.expect_value(t, material.roughness_ao_texture.id, near_material.roughness_ao_texture.id)
	}
	testing.expect_value(t, near_material.custom_params_7.z, f32(0))
	testing.expect_value(t, near_material.scene_color_texture.id, u32(21))
}

@(test)
ocean_render_mode_is_stable_during_rotation :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	limit := settings.middle_altitude_limit
	for initial_far in ([]bool{false, true}) {
		active := initial_far
		for frame in 0 ..< 360 {
			angle := f32(frame) * math.PI / 180
			radius := f32(shared.PLANET_RADIUS) + limit
			position := [3]f32{math.cos(angle) * radius, math.sin(angle) * radius, 0}
			altitude := math.sqrt(position.x * position.x + position.y * position.y) - f32(shared.PLANET_RADIUS)
			active = ocean_far_faces_next(active, true, altitude, limit)
			testing.expect_value(t, active, initial_far)
			_, overlays := ocean_draw_layers(active)
			testing.expect_value(t, overlays, !initial_far)
		}
	}
}

@(test)
ocean_packet_count_is_identical_for_clipmap_and_far_faces :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.render_query.packet_count = OCEAN_RENDER_PACKET_MAX
	count := ocean_material_packet_count(renderer)
	testing.expect_value(t, count, OCEAN_RENDER_PACKET_MAX)
	for view in Ocean_Proof_View {
		word := ocean_material_mode_word(count, view)
		unpacked_count, unpacked_view := ocean_material_mode_unpack(word)
		testing.expect_value(t, unpacked_count, count)
		testing.expect_value(t, unpacked_view, view)
	}
}

@(test)
ocean_material_mode_word_round_trips_packet_count_and_proof_view :: proc(t: ^testing.T) {
	for packet_count in 0 ..= OCEAN_RENDER_PACKET_MAX {
		for view in Ocean_Proof_View {
			word := ocean_material_mode_word(packet_count, view)
			testing.expect(t, word == f32(int(word)))
			unpacked_count, unpacked_view := ocean_material_mode_unpack(word)
			testing.expect_value(t, unpacked_count, packet_count)
			testing.expect_value(t, unpacked_view, view)
		}
	}
	count, view := ocean_material_mode_unpack(-3)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, view, Ocean_Proof_View.Composite)
	count, view = ocean_material_mode_unpack(2 + 100 * 8)
	testing.expect_value(t, count, 2)
	testing.expect_value(t, view, max(Ocean_Proof_View))
}

@(test)
surfboard_spawn_clearance_starts_hydrodynamic_points_immersed :: proc(t: ^testing.T) {
	points := surfboard_hydrodynamic_points()
	sample := Water_Physics_Sample {
		surface = {},
		normal  = {0, 0, 1},
		wet     = true,
	}
	for point in points {
		center := [3]f32 {
			point.local_position.x,
			point.local_position.y,
			SURFBOARD_SPAWN_CLEARANCE + point.local_position.z,
		}
		immersion := water_physics_submerged_fraction(center, point.immersion_radius, sample)
		testing.expect(t, immersion > 0 && immersion < 1)
	}
}

@(test)
ocean_visual_sanitize_orders_clipmap_thresholds :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	settings.ring_radius = {900, 100, 50}
	settings.near_altitude_limit = 3_000
	settings.middle_altitude_limit = 100
	ocean_visual_settings_sanitize(&settings)
	testing.expect(t, settings.ring_radius[0] < settings.ring_radius[1])
	testing.expect(t, settings.ring_radius[1] < settings.ring_radius[2])
	testing.expect(t, settings.near_altitude_limit <= settings.middle_altitude_limit)
}

@(test)
ocean_material_parameters_are_visual_only :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	summary := Ocean_Weather_Summary {
		significant_height = 2,
		peak_period        = 9.625,
		breaking           = 0.4,
		storm_energy       = 0.8,
	}
	primary, lighting, foam, medium := ocean_visual_material_params(settings, summary)
	testing.expect_value(t, primary.x, f32(2))
	testing.expect_value(t, lighting.y, f32(0.09))
	testing.expect_value(t, foam.z, f32(0.8))
	testing.expect_value(t, foam.w, f32(0.4))
	testing.expect_value(t, medium, [4]f32{1, 1, 0, 0})
}

@(test)
ocean_material_uses_wind_direction_with_wave_fallback :: proc(t: ^testing.T) {
	summary := Ocean_Weather_Summary {
		direction      = {1, 0, 0},
		wind_direction = {0, 1, 0},
	}
	testing.expect_value(t, ocean_visual_wind_direction(summary), [3]f32{0, 1, 0})
	summary.wind_direction = {}
	testing.expect_value(t, ocean_visual_wind_direction(summary), [3]f32{1, 0, 0})
}

@(test)
ocean_material_parameters_keep_calm_water_visible_unless_disabled :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	summary := Ocean_Weather_Summary{}
	primary, _, _, _ := ocean_visual_material_params(settings, summary)
	testing.expect_value(t, primary.x, f32(0))
	summary.significant_height = 2
	settings.wave_amplitude_scale = 3
	primary, _, _, _ = ocean_visual_material_params(settings, summary)
	testing.expect_value(t, primary.x, f32(6))
	summary.wind_sea_height = 3
	summary.swell_height = 4
	primary, _, _, _ = ocean_visual_material_params(settings, summary)
	testing.expect_value(t, primary.x, f32(15))
	settings.wave_amplitude_scale = 0
	primary, _, _, _ = ocean_visual_material_params(settings, summary)
	testing.expect_value(t, primary.x, f32(0))
}

@(test)
ocean_weather_preserves_twenty_foot_significant_height :: proc(t: ^testing.T) {
	height := ocean_significant_height_m(37_210_000, 1)
	testing.expect(t, abs(height - 6.1) < 0.000001)
}

@(test)
ocean_storm_forcing_is_bounded_and_immediate :: proc(t: ^testing.T) {
	calm := ocean_visual_storm_energy(2, 0)
	windy := ocean_visual_storm_energy(30, 0)
	storm := ocean_visual_storm_energy(30, 1)
	testing.expect_value(t, calm, f32(0))
	testing.expect(t, windy > calm && windy < storm)
	testing.expect_value(t, storm, f32(1))
	calm_floor := ocean_visual_wind_sea_floor(2, calm, 1)
	storm_floor := ocean_visual_wind_sea_floor(30, storm, 1)
	testing.expect_value(t, calm_floor, f32(0))
	testing.expect(t, storm_floor > 2)
	testing.expect(t, ocean_visual_wind_sea_floor(200, 1, 1) <= 6)
	testing.expect_value(t, ocean_visual_wind_sea_floor(30, 1, 0), f32(0))
}

@(test)
debug_ocean_test_pulse_is_visual_bounded_and_simulation_isolated :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(&value.world)
	cell := -1
	for depth, index in value.world.planetary.ocean.mean_depth_mm {
		if depth > 0 {
			cell = index
			break
		}
	}
	testing.expect(t, cell >= 0, "wet ocean cell")
	focus := shared.planet_sim_direction(shared.planet_sim_coord_for_index(cell))
	value.terrain.ocean.focus_direction = focus
	value.terrain.ocean.macro.time = 1
	waves := &value.world.planetary.waves
	packet_count_before := waves.packet_count
	next_packet_id_before := waves.next_packet_id
	packet_before := waves.packets[0]
	swell_before := waves.swell_variance[cell]
	height_before := waves.height_mm[cell]
	breaking_before := waves.breaking[cell]
	runup_before := waves.runup_mm[cell]
	previous_period := debug_ocean_test_pulse_interval
	defer debug_ocean_test_pulse_interval = previous_period
	debug_ocean_test_pulse_interval = 12
	packet_id, injected := debug_ocean_inject_test_pulse(value)
	testing.expect_value(t, value.terrain.ocean.debug_pulse.period, f32(12))
	testing.expect(t, injected)
	testing.expect_value(t, packet_id, OCEAN_DEBUG_TEST_PULSE_ID)
	testing.expect_value(t, waves.packet_count, packet_count_before)
	testing.expect_value(t, waves.next_packet_id, next_packet_id_before)
	testing.expect_value(t, waves.packets[0], packet_before)
	testing.expect_value(t, waves.swell_variance[cell], swell_before)
	testing.expect_value(t, waves.height_mm[cell], height_before)
	testing.expect_value(t, waves.breaking[cell], breaking_before)
	testing.expect_value(t, waves.runup_mm[cell], runup_before)
	testing.expect(t, value.terrain.ocean.render_query.ready)
	testing.expect(t, value.terrain.ocean.render_query.packet_count > 0)
	pulse_focus, pulse_focus_valid := ocean_wave_normalize(value.terrain.ocean.debug_pulse.center)
	testing.expect(t, pulse_focus_valid)
	metrics := debug_ocean_test_pulse_metrics(
		&value.terrain.ocean,
		packet_id,
		pulse_focus,
		f32(value.world.planetary.ocean.mean_depth_mm[cell]) / 1_000,
	)
	testing.expect_value(t, metrics.selected_id, packet_id)
	testing.expect(t, abs(metrics.significant_height - 6.1) < 0.0001)
	testing.expect(t, metrics.envelope_overlap > 0.99)
	testing.expect(t, abs(metrics.radial_displacement) < 0.001)
	testing.expect(t, metrics.velocity > 0.001)
	pulse := value.terrain.ocean.debug_pulse
	pulse_speed := math.sqrt(
		pulse.direction.x * pulse.direction.x +
		pulse.direction.y * pulse.direction.y +
		pulse.direction.z * pulse.direction.z,
	)
	testing.expect(t, pulse.radial)
	testing.expect(t, abs(pulse_speed - pulse.front_speed) < 0.001)
	testing.expect(
		t,
		abs(pulse.front_speed - debug_ocean_test_pulse_front_speed(pulse.group_speed)) < 0.0001,
	)
	testing.expect(t, abs(pulse.front_speed * OCEAN_RENDER_METERS_PER_UNIT - pulse.group_speed) < 0.001)
	testing.expect_value(t, pulse.front_radius, f32(0))
	testing.expect_value(
		t,
		pulse.band,
		max(max(debug_ocean_test_pulse_duration, pulse.period) * pulse.front_speed * 0.5, f32(1)),
	)
	testing.expect_value(t, pulse.phase_epoch, value.terrain.ocean.macro.time)
	testing.expect_value(t, pulse.envelope_length, OCEAN_DEBUG_TEST_PULSE_RADIUS)
	testing.expect_value(t, pulse.envelope_width, pulse.band)
	testing.expect(t, pulse.group_speed > 0)
	ring_position := shared.planet_position(pulse_focus, 0)
	ring_frame := ocean_packet_frame(
		pulse_focus,
		ring_position,
		pulse,
		pulse.phase_epoch + pulse.band * 3 / pulse.front_speed,
	)
	testing.expect(t, ring_frame.valid)
	testing.expect(t, ring_frame.envelope < 0.001)
	center_before := value.terrain.ocean.debug_pulse.center
	epoch_before := value.terrain.ocean.debug_pulse.phase_epoch
	debug_ocean_test_pulse_update(
		&value.terrain.ocean.debug_pulse,
		&value.terrain.ocean.debug_pulse_active,
		1,
	)
	testing.expect_value(t, value.terrain.ocean.debug_pulse.center, center_before)
	testing.expect_value(t, value.terrain.ocean.debug_pulse.phase_epoch, epoch_before)
	testing.expect_value(t, value.terrain.ocean.debug_pulse.total_travel, f32(1))
	testing.expect(t, value.terrain.ocean.debug_pulse_active)
	paused_elapsed := value.terrain.ocean.debug_pulse.total_travel
	debug_ocean_test_pulse_update(
		&value.terrain.ocean.debug_pulse,
		&value.terrain.ocean.debug_pulse_active,
		0,
	)
	testing.expect_value(t, value.terrain.ocean.debug_pulse.total_travel, paused_elapsed)
	retention := debug_ocean_test_pulse_retention(value.terrain.ocean.debug_pulse)
	testing.expect(
		t,
		abs(
			retention -
			(OCEAN_DEBUG_TEST_PULSE_RADIUS + pulse.band * OCEAN_RING_ENVELOPE_SIGMAS) /
				pulse.front_speed,
		) <
		0.001,
	)
	testing.expect(t, value.terrain.ocean.geometry_dirty)
	_ = ocean_macro_query_update(
		&value.terrain.ocean.render_query,
		&value.world,
		focus,
		value.terrain.ocean.macro.time,
	)
	ocean_macro_query_debug_packet_merge(
		&value.terrain.ocean.render_query,
		value.terrain.ocean.debug_pulse,
		value.terrain.ocean.debug_pulse_active,
	)
	found := false
	for id in value.terrain.ocean.render_query.packet_ids[:value.terrain.ocean.render_query.packet_count] {
		found = found || id == packet_id
	}
	testing.expect(t, found)
	testing.expect(t, value.terrain.ocean.render_query.packet_count <= OCEAN_MACRO_PACKET_MAX)
	debug_ocean_test_pulse_update(
		&value.terrain.ocean.debug_pulse,
		&value.terrain.ocean.debug_pulse_active,
		retention,
	)
	testing.expect(t, !value.terrain.ocean.debug_pulse_active)
}

@(test)
debug_ocean_fixture_board_collides_with_synthetic_bed :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, cosmetics_init(&value.cosmetics))
	defer cosmetics_deinit(&value.cosmetics)
	defer surfboard_deinit(value)
	obstacle_definition := b3.DefaultBodyDef()
	obstacle_definition.position = {0, 0, 1068.7}
	obstacle := b3.CreateBody(value.cosmetics.world, obstacle_definition)
	obstacle_shape := b3.DefaultShapeDef()
	obstacle_shape.filter.categoryBits = PHYSICS_CATEGORY_TERRAIN
	obstacle_shape.filter.maskBits = PHYSICS_CATEGORY_SURFABLE
	obstacle_hull := b3.MakeBoxHull(10, 10, 0.1)
	_ = b3.CreateHullShape(obstacle, obstacle_shape, &obstacle_hull.base)
	ocean_surf_fixture_init(&value.terrain.ocean.nearshore, {0, 0, 1}, .Deep)
	testing.expect(t, surfboard_spawn(value, {0, 0, 1069}, {0, 0, 1}, {1, 0, 0}))
	testing.expect(t, b3.Body_IsValid(value.surfboard.fixture_body))
	b3.Body_SetLinearVelocity(value.surfboard.body, {0, 0, -2})
	for _ in 0 ..< 120 do b3.World_Step(value.surfboard.fixture_physics.world, COSMETIC_FIXED_DT, COSMETIC_SUBSTEPS)
	position := b3.Body_GetPosition(value.surfboard.body)
	testing.expect(t, position.z > 1068 && position.z < 1068.2)
	previous_body := value.surfboard.fixture_body
	previous_world := value.surfboard.fixture_physics.world
	surfboard_deinit(value)
	testing.expect(t, !b3.World_IsValid(previous_world))
	testing.expect(t, b3.World_IsValid(value.cosmetics.world))
	testing.expect(t, !b3.Body_IsValid(previous_body))
	testing.expect(t, value.surfboard.fixture_mesh == nil)
}

@(test)
debug_ocean_fixture_body_clock_matches_frame_partitions :: proc(t: ^testing.T) {
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	positions: [5][3]f32
	velocities: [5][3]f32
	angular_velocities: [5][3]f32
	orientations: [5]quaternion128
	frame_counts := [5]int{30, 60, 120, 60, 120}
	for partition in 0 ..< 5 {
		debug_ocean_fixture_time_scale = 0.5 if partition == 4 else 1
		value := new(Client_State)
		testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
		testing.expect(t, cosmetics_init(&value.cosmetics))
		renderer := &value.terrain.ocean
		ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
		testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
		value.surfboard.control = {0.1, -0.1}
		value.cosmetics.accumulator = COSMETIC_FIXED_DT * f32(partition)
		frames := frame_counts[partition]
		for frame in 0 ..< frames {
			elapsed := 2 / f32(frames) if partition == 4 else 1 / f32(frames)
			if partition == 3 do elapsed *= 0.5 if frame % 2 == 0 else 1.5
			_ = ocean_surf_advance(renderer, &value.world, renderer.nearshore.focus, elapsed, value)
		}
		steps_after_advance := renderer.macro.step_count
		ocean_renderer_update(renderer, &value.world, {}, renderer.nearshore.focus, 0, {}, 1, true, false)
		testing.expect_value(t, renderer.macro.step_count, steps_after_advance)
		testing.expect_value(t, renderer.macro.step_count, u64(60))
		orientations[partition] = b3.Body_GetTransform(value.surfboard.body).q
		angular_velocities[partition] = b3.Body_GetAngularVelocity(value.surfboard.body)
		positions[partition] = b3.Body_GetPosition(value.surfboard.body)
		velocities[partition] = b3.Body_GetLinearVelocity(value.surfboard.body)
		debug_ocean_fixture_time_scale = 0
		_ = ocean_surf_advance(renderer, &value.world, renderer.nearshore.focus, 1, value)
		testing.expect_value(t, b3.Body_GetPosition(value.surfboard.body), positions[partition])
		testing.expect_value(t, b3.Body_GetLinearVelocity(value.surfboard.body), velocities[partition])
		testing.expect_value(t, b3.Body_GetAngularVelocity(value.surfboard.body), angular_velocities[partition])
		testing.expect_value(t, b3.Body_GetTransform(value.surfboard.body).q, orientations[partition])
		debug_ocean_fixture_time_scale = 1
		steps_before := renderer.macro.step_count
		_ = ocean_surf_advance(renderer, &value.world, renderer.nearshore.focus, 1, value)
		testing.expect(t, renderer.surf_dropped_time >= 0.899 && renderer.surf_dropped_time <= 0.901)
		testing.expect(t, renderer.macro.step_count - steps_before <= u64(OCEAN_WAVE_MAX_STEPS_PER_FRAME))
		testing.expect_value(t, value.cosmetics.accumulator, COSMETIC_FIXED_DT * f32(partition))
		testing.expect_value(t, value.surfboard.fixture_physics.accumulator, f32(0))
		surfboard_deinit(value)
		cosmetics_deinit(&value.cosmetics)
		shared.world_deinit(&value.world)
		free(value)
	}
	for partition in 1 ..< 5 {
		testing.expect_value(t, orientations[0], orientations[partition])
		testing.expect_value(t, positions[0], positions[partition])
		testing.expect_value(t, velocities[0], velocities[partition])
		testing.expect_value(t, angular_velocities[0], angular_velocities[partition])
	}
}

@(test)
debug_ocean_fixture_moving_water_body_partitions_agree :: proc(t: ^testing.T) {
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	clients := [6]^Client_State{new(Client_State), new(Client_State), new(Client_State), new(Client_State), new(Client_State), new(Client_State)}
	defer {
		for value in clients {
			surfboard_deinit(value)
			cosmetics_deinit(&value.cosmetics)
			shared.world_deinit(&value.world)
			free(value)
		}
	}
	for value, index in clients {
		testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
		testing.expect(t, cosmetics_init(&value.cosmetics))
		renderer := &value.terrain.ocean
		ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Bank)
		renderer.debug_pulse = {
			id = OCEAN_DEBUG_TEST_PULSE_ID,
			center = {0, 0, 1080},
			direction = renderer.nearshore.east,
			significant_height = 2,
			period = 8,
			front_speed = 0.25,
			envelope_length = 100,
			envelope_width = 80,
			band = 100,
		}
		renderer.debug_pulse_active = index != 5
		testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
	}
	load_history_differs := false
	for frame in 0 ..< 480 {
		for value, index in clients {
			debug_ocean_fixture_time_scale = 0.5 if index == 4 else 1
			intervals := [4]f32{OCEAN_WAVE_FIXED_DT, OCEAN_WAVE_FIXED_DT, 0, 0}
			switch index {
			case 1: intervals = {OCEAN_WAVE_FIXED_DT * 2, 0, 0, 0}
			case 2: intervals = {OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 0.5}
			case 3: intervals = {OCEAN_WAVE_FIXED_DT * 0.5, OCEAN_WAVE_FIXED_DT * 1.5, 0, 0}
			case 4: intervals = {OCEAN_WAVE_FIXED_DT * 4, 0, 0, 0}
			}
			for interval in intervals {
				_ = ocean_surf_advance(&value.terrain.ocean, &value.world, {}, interval, value)
			}
		}
		first := clients[0]
		load_history_differs = load_history_differs || first.surfboard.fixture_physics.surfables[0].point_state != clients[5].surfboard.fixture_physics.surfables[0].point_state
		for second in clients[1:5] {
			testing.expect_value(t, b3.Body_GetTransform(first.surfboard.body), b3.Body_GetTransform(second.surfboard.body))
			testing.expect_value(t, b3.Body_GetLinearVelocity(first.surfboard.body), b3.Body_GetLinearVelocity(second.surfboard.body))
			testing.expect_value(t, b3.Body_GetAngularVelocity(first.surfboard.body), b3.Body_GetAngularVelocity(second.surfboard.body))
			testing.expect_value(t, first.surfboard.fixture_physics.surfables[0].point_state, second.surfboard.fixture_physics.surfables[0].point_state)
			if frame == 479 {
				testing.expect(t, first.terrain.ocean.breakers.front_count > 0)
				testing.expect_value(t, first.terrain.ocean.nearshore.state, second.terrain.ocean.nearshore.state)
				testing.expect_value(t, first.terrain.ocean.breakers.fronts, second.terrain.ocean.breakers.fronts)
				testing.expect_value(t, first.terrain.ocean.breakers.emitted_cycles, second.terrain.ocean.breakers.emitted_cycles)
			}
		}
	}
	testing.expect(t, load_history_differs)
	testing.expect(t, b3.Body_GetTransform(clients[0].surfboard.body) != b3.Body_GetTransform(clients[5].surfboard.body))
}

@(test)
debug_ocean_fixture_preserves_ordinary_bodies_across_lifecycle :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&value.world)
	testing.expect(t, cosmetics_init(&value.cosmetics))
	defer cosmetics_deinit(&value.cosmetics)
	defer surfboard_deinit(value)
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	value.terrain.ocean.focus_direction = {0, 0, 1}
	cosmetics_spawn_burst(&value.cosmetics, {0, 0, 1080})
	ordinary_body := value.cosmetics.bodies[0]
	ordinary_transform := b3.Body_GetTransform(ordinary_body)
	ordinary_velocity := b3.Body_GetLinearVelocity(ordinary_body)
	ordinary_angular := b3.Body_GetAngularVelocity(ordinary_body)
	value.cosmetics.accumulator = COSMETIC_FIXED_DT * 0.5
	kinds := [3]Ocean_Surf_Fixture{.Deep, .Bank, .Reef}
	for kind in kinds {
		debug_ocean_reset_fixture(value, {0, 0, 1}, kind)
		testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
		fixture_world := value.surfboard.fixture_physics.world
		testing.expect(t, fixture_world != value.cosmetics.world)
		testing.expect_value(t, value.cosmetics.surfable_count, u32(0))
		for _ in 0 ..< 6 {
			_ = ocean_surf_advance(&value.terrain.ocean, &value.world, {}, 0.1, value)
		}
		value.terrain.ocean.focus_direction = {}
		debug_ocean_exit_fixture(value)
		testing.expect_value(t, value.terrain.ocean.focus_direction, [3]f32{0, 0, 1})
		testing.expect(t, !value.terrain.ocean.nearshore.tick_pending)
		testing.expect(t, !b3.World_IsValid(fixture_world))
		testing.expect(t, value.surfboard.fixture_physics == nil)
		testing.expect_value(t, b3.Body_GetTransform(ordinary_body), ordinary_transform)
		testing.expect_value(t, b3.Body_GetLinearVelocity(ordinary_body), ordinary_velocity)
		testing.expect_value(t, b3.Body_GetAngularVelocity(ordinary_body), ordinary_angular)
		testing.expect_value(t, value.cosmetics.ages[0], f32(0))
		testing.expect_value(t, value.cosmetics.accumulator, COSMETIC_FIXED_DT * 0.5)
	}
	cosmetics_update(&value.cosmetics, value, COSMETIC_FIXED_DT)
	testing.expect(t, value.cosmetics.ages[0] > 0)
	testing.expect(t, b3.Body_GetPosition(ordinary_body) != ordinary_transform.p)
}

@(test)
debug_ocean_fixture_cfl_exhaustion_holds_completed_clock :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
	for &cell in renderer.nearshore.state do cell.momentum_x = cell.depth * 10000
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, OCEAN_WAVE_FIXED_DT), 0)
	testing.expect(t, renderer.nearshore.time_backlog > 0)
	testing.expect(t, renderer.nearshore.tick_pending)
	for cell in renderer.nearshore.state {
		testing.expect_value(t, cell.depth, f32(12))
		testing.expect_value(t, cell.momentum_x, f32(120000))
	}
	testing.expect(t, renderer.nearshore.pending_state != renderer.nearshore.state)
	testing.expect_value(t, renderer.macro.time, f32(0))
	testing.expect_value(t, renderer.macro.step_count, u64(0))
	testing.expect_value(t, renderer.spectral_pending_dt, f32(0))
	backlog := renderer.nearshore.time_backlog
	debug_ocean_fixture_time_scale = 0
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, 1), 0)
	testing.expect_value(t, renderer.nearshore.time_backlog, backlog)
	debug_ocean_fixture_time_scale = 1
	for &cell in renderer.nearshore.pending_state {
		cell.depth = 12
		cell.momentum_x = 0
		cell.momentum_y = 0
	}
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, OCEAN_WAVE_FIXED_DT * 0.25), 1)
	testing.expect_value(t, renderer.macro.step_count, u64(1))
	testing.expect_value(t, renderer.macro.time, OCEAN_WAVE_FIXED_DT)
	testing.expect_value(t, renderer.nearshore.time_backlog, f32(0))
	testing.expect_value(t, renderer.nearshore.last_advanced_time, backlog)
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.nearshore.state[0].momentum_x, f32(0))
}

@(test)
debug_ocean_fixture_pending_source_edits_preserve_completed_body :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&value.world)
	testing.expect(t, cosmetics_init(&value.cosmetics))
	defer cosmetics_deinit(&value.cosmetics)
	defer surfboard_deinit(value)
	previous_scale := debug_ocean_fixture_time_scale
	previous_pinned := debug_ocean_test_pulse_pinned
	previous_source := debug_ocean_test_pulse_source
	previous_id := debug_ocean_test_pulse_id
	defer {
		debug_ocean_fixture_time_scale = previous_scale
		debug_ocean_test_pulse_pinned = previous_pinned
		debug_ocean_test_pulse_source = previous_source
		debug_ocean_test_pulse_id = previous_id
	}
	debug_ocean_fixture_time_scale = 1
	renderer := &value.terrain.ocean
	renderer.focus_direction = {0, 0, 1}
	debug_ocean_reset_fixture(value, {0, 0, 1}, .Deep)
	testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
	_, injected := debug_ocean_inject_test_pulse(value)
	testing.expect(t, injected)
	transform := b3.Body_GetTransform(value.surfboard.body)
	velocity := b3.Body_GetLinearVelocity(value.surfboard.body)
	angular := b3.Body_GetAngularVelocity(value.surfboard.body)
	points := value.surfboard.fixture_physics.surfables[0].point_state
	pulse := renderer.debug_pulse
	for &cell in renderer.nearshore.state do cell.momentum_x = cell.depth * 10000
	renderer.nearshore.foam[OCEAN_NEARSHORE_COUNT / 2] = 0.75
	completed := new(Ocean_Nearshore)
	defer free(completed)
	completed^ = renderer.nearshore
	query := Ocean_Macro_Wave_Query{}
	water := world_water_physics_sample(value, &query, {0, 0, 1080}, 0)
	mesh := new(Ocean_Fixture_Renderer)
	defer free(mesh)
	ocean_fixture_mesh_fill(mesh, completed)
	center_vertex := mesh.water_vertices[OCEAN_NEARSHORE_COUNT / 2]
	for _ in 0 ..< 8 {
		for &cell in renderer.nearshore.pending_state do cell.momentum_x = cell.depth * 10000
		testing.expect_value(t, ocean_surf_advance(renderer, &value.world, {}, 0.1, value), 0)
		testing.expect(t, renderer.nearshore.tick_pending)
		testing.expect_value(t, renderer.nearshore.state, completed.state)
		testing.expect_value(t, renderer.nearshore.foam, completed.foam)
		testing.expect_value(t, world_water_physics_sample(value, &query, {0, 0, 1080}, 0), water)
		ocean_fixture_mesh_fill(mesh, &renderer.nearshore)
		testing.expect_value(t, mesh.water_vertices[OCEAN_NEARSHORE_COUNT / 2], center_vertex)
		testing.expect_value(t, b3.Body_GetTransform(value.surfboard.body), transform)
		testing.expect_value(t, b3.Body_GetLinearVelocity(value.surfboard.body), velocity)
		testing.expect_value(t, b3.Body_GetAngularVelocity(value.surfboard.body), angular)
		testing.expect_value(t, value.surfboard.fixture_physics.surfables[0].point_state, points)
		testing.expect_value(t, renderer.debug_pulse, pulse)
		testing.expect_value(t, renderer.macro.step_count, u64(0))
	}
	testing.expect_value(t, renderer.macro.accumulator, f32(0.5))
	testing.expect(t, math.abs(renderer.surf_dropped_time - 0.3) < 0.00001)
	debug_ocean_test_pulse_source = {}
	_, rejected := debug_ocean_inject_test_pulse(value)
	testing.expect(t, !rejected)
	testing.expect(t, renderer.nearshore.tick_pending)
	debug_ocean_test_pulse_source = renderer.nearshore.focus
	_, replaced := debug_ocean_inject_test_pulse(value)
	testing.expect(t, replaced)
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.nearshore.time_backlog, f32(0))
	testing.expect_value(t, renderer.nearshore.state, completed.state)
	testing.expect_value(t, renderer.macro.accumulator, f32(0.5))
	testing.expect_value(t, ocean_surf_advance(renderer, &value.world, {}, OCEAN_WAVE_FIXED_DT, value), 0)
	testing.expect(t, renderer.nearshore.tick_pending)
	debug_ocean_stop_test_pulse(value)
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.nearshore.time_backlog, f32(0))
	testing.expect_value(t, renderer.nearshore.state, completed.state)
	testing.expect_value(t, renderer.nearshore.foam, completed.foam)
	testing.expect_value(t, b3.Body_GetTransform(value.surfboard.body), transform)
	debug_ocean_reset_fixture(value, {0, 0, 1}, .Bank)
	testing.expect(t, !renderer.nearshore.tick_pending)
	testing.expect_value(t, renderer.macro.accumulator, f32(0))
	testing.expect(t, value.surfboard.fixture_physics == nil)
}

@(test)
debug_ocean_invalid_elapsed_preserves_clock_and_query :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	invalid := [5]f32{0, -1, transmute(f32)u32(0x7f800000), transmute(f32)u32(0xff800000), transmute(f32)u32(0x7fc00000)}
	for elapsed in invalid {
		testing.expect_value(t, ocean_surf_advance(renderer, world, {}, elapsed), 0)
		testing.expect_value(t, renderer.macro.accumulator, f32(0))
		testing.expect_value(t, renderer.surf_dropped_time, f32(0))
		testing.expect_value(t, renderer.render_query.field_revision, u64(0))
	}
	for scale in invalid {
		debug_ocean_fixture_time_scale = scale
		testing.expect_value(t, ocean_surf_advance(renderer, world, {}, 1), 0)
		testing.expect_value(t, renderer.macro.accumulator, f32(0))
		testing.expect_value(t, renderer.surf_dropped_time, f32(0))
		testing.expect_value(t, renderer.render_query.field_revision, u64(0))
	}
}

@(test)
debug_ocean_pulse_expiration_waits_for_completed_interval :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	ocean_surf_fixture_init(&renderer.nearshore, {0, 0, 1}, .Deep)
	renderer.debug_pulse = {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = {0, 0, 1080},
		period = 8,
		front_speed = 1,
		band = 1,
	}
	renderer.debug_pulse.total_travel = debug_ocean_test_pulse_retention(renderer.debug_pulse) - OCEAN_WAVE_FIXED_DT * 0.5
	renderer.debug_pulse_active = true
	travel := renderer.debug_pulse.total_travel
	for &cell in renderer.nearshore.state do cell.momentum_x = cell.depth * 10000
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, OCEAN_WAVE_FIXED_DT), 0)
	testing.expect(t, renderer.debug_pulse_active)
	testing.expect_value(t, renderer.debug_pulse.total_travel, travel)
	debug_ocean_fixture_time_scale = 0
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, 1), 0)
	testing.expect(t, renderer.debug_pulse_active)
	debug_ocean_fixture_time_scale = 1
	for &cell in renderer.nearshore.pending_state do cell = {depth = 12}
	testing.expect_value(t, ocean_surf_advance(renderer, world, {}, OCEAN_WAVE_FIXED_DT * 0.25), 1)
	testing.expect(t, !renderer.debug_pulse_active)
	testing.expect_value(t, renderer.render_query.packet_count, 0)
	testing.expect_value(t, renderer.macro.step_count, u64(1))
}

@(test)
debug_ocean_pending_control_applies_once_at_publication :: proc(t: ^testing.T) {
	clients := [2]^Client_State{new(Client_State), new(Client_State)}
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	defer {
		for value in clients {
			surfboard_deinit(value)
			cosmetics_deinit(&value.cosmetics)
			shared.world_deinit(&value.world)
			free(value)
		}
	}
	for value in clients {
		testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
		testing.expect(t, cosmetics_init(&value.cosmetics))
		ocean_surf_fixture_init(&value.terrain.ocean.nearshore, {0, 0, 1}, .Deep)
		testing.expect(t, surfboard_spawn(value, {0, 0, 1080}, {0, 0, 1}, {1, 0, 0}))
		value.surfboard.control = {0.2, -0.1}
		for &cell in value.terrain.ocean.nearshore.state do cell.momentum_x = cell.depth * 10000
		testing.expect_value(t, ocean_surf_advance(&value.terrain.ocean, &value.world, {}, OCEAN_WAVE_FIXED_DT, value), 0)
		for &cell in value.terrain.ocean.nearshore.pending_state do cell = {depth = 12}
	}
	clients[0].surfboard.control = {-0.3, 0.4}
	for value in clients {
		testing.expect_value(t, ocean_surf_advance(&value.terrain.ocean, &value.world, {}, OCEAN_WAVE_FIXED_DT * 0.25, value), 1)
		testing.expect_value(t, value.terrain.ocean.macro.step_count, u64(1))
	}
	testing.expect_value(t, b3.Body_GetTransform(clients[0].surfboard.body), b3.Body_GetTransform(clients[1].surfboard.body))
	testing.expect_value(t, b3.Body_GetAngularVelocity(clients[0].surfboard.body), b3.Body_GetAngularVelocity(clients[1].surfboard.body))
	testing.expect_value(t, clients[0].surfboard.control, [2]f32{-0.3, 0.4})
	for value in clients {
		testing.expect_value(t, ocean_surf_advance(&value.terrain.ocean, &value.world, {}, OCEAN_WAVE_FIXED_DT, value), 1)
	}
	testing.expect(t, b3.Body_GetAngularVelocity(clients[0].surfboard.body) != b3.Body_GetAngularVelocity(clients[1].surfboard.body))
}

@(test)
debug_ocean_fixture_blocks_hidden_world_interaction :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.world_ready = true
	value.graphics_ready = true
	value.terrain.ready = true
	value.terrain.ocean.nearshore.fixture_active = true
	value.hover_valid = true
	_, hit := cursor_terrain_point(value)
	testing.expect(t, !hit)
	hover_update(value)
	testing.expect(t, !value.hover_valid)
	input_update(value)
}

@(test)
debug_ocean_pulse_uses_local_fixture_depth_and_rejects_dry_sources :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&value.world)
	previous_pinned := debug_ocean_test_pulse_pinned
	previous_source := debug_ocean_test_pulse_source
	previous_period := debug_ocean_test_pulse_interval
	defer {
		debug_ocean_test_pulse_pinned = previous_pinned
		debug_ocean_test_pulse_source = previous_source
		debug_ocean_test_pulse_interval = previous_period
	}
	debug_ocean_test_pulse_pinned = false
	debug_ocean_test_pulse_interval = 8
	renderer := &value.terrain.ocean
	focus := [3]f32{1, 0, 0}
	renderer.focus_direction = focus
	ocean_surf_fixture_init(&renderer.nearshore, focus, .Deep)
	for &depth in value.world.planetary.ocean.mean_depth_mm do depth = 0
	_, injected := debug_ocean_inject_test_pulse(value)
	testing.expect(t, injected, "fixture must not require a wet coarse ocean cell")
	phase_speed, group_speed := shared.wave_dispersion_speed_mm_s(
		value.world.planetary.physical.gravity_milli_m_s2,
		u32(12 * OCEAN_RENDER_METERS_PER_UNIT * 1_000),
		8_000,
	)
	testing.expect_value(t, renderer.debug_pulse.phase_speed, f32(phase_speed) / 1_000)
	testing.expect_value(t, renderer.debug_pulse.group_speed, f32(group_speed) / 1_000)
	packet := renderer.debug_pulse
	pin_modes := [2]bool{false, true}
	for pinned in pin_modes {
		debug_ocean_test_pulse_pinned = pinned
		debug_ocean_test_pulse_source = -focus
		renderer.focus_direction = -focus
		_, accepted := debug_ocean_inject_test_pulse(value)
		testing.expect(t, !accepted, "out-of-patch source must be rejected")
		testing.expect_value(t, renderer.debug_pulse, packet)
	}
	debug_ocean_test_pulse_source = focus
	_, pinned_accepted := debug_ocean_inject_test_pulse(value)
	testing.expect(t, pinned_accepted, "pinned source must ignore camera focus")
	testing.expect_value(t, renderer.debug_pulse.center, shared.planet_position(focus, 0))
	debug_ocean_test_pulse_source, _ = ocean_wave_normalize(ocean_nearshore_boundary_position(&renderer.nearshore, 0, 48))
	_, boundary_accepted := debug_ocean_inject_test_pulse(value)
	testing.expect(t, !boundary_accepted, "source must have interior wavemaker support")
	testing.expect_value(t, renderer.debug_pulse, packet)
	debug_ocean_test_pulse_source = focus
	for &depth in renderer.nearshore.still_depth do depth = 0
	_, unsupported_accepted := debug_ocean_inject_test_pulse(value)
	testing.expect(t, !unsupported_accepted, "transient wetting must not accept a source the wavemaker cannot drive")
	testing.expect_value(t, renderer.debug_pulse, packet)
	for &state in renderer.nearshore.state do state.depth = 0
	_, dry_accepted := debug_ocean_inject_test_pulse(value)
	testing.expect(t, !dry_accepted, "dry fixture source must be rejected")
}

@(test)
debug_ocean_directional_envelope_moves_at_bound_group_speed :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	packet := Ocean_Render_Packet {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = shared.planet_position({1, 0, 0}, 0),
		direction = {0, 1, 0},
		period = 8,
		front_speed = 2,
		phase_epoch = 5,
		envelope_length = 4,
		envelope_width = 20,
	}
	initial := ocean_packet_frame({1, 0, 0}, packet.center, packet, 5)
	departed := ocean_packet_frame({1, 0, 0}, packet.center, packet, 15)
	testing.expect_value(t, initial.envelope, f32(1))
	testing.expect_value(t, departed.envelope, f32(0))
	travel := packet.front_speed * 10
	angle := math.asin(travel / f32(shared.PLANET_RADIUS))
	arrival_radial := [3]f32{math.cos(angle), math.sin(angle), 0}
	arrival := ocean_packet_frame(arrival_radial, shared.planet_position(arrival_radial, 0), packet, 15)
	testing.expect(t, arrival.valid && arrival.envelope > 0.999)
	testing.expect(t, strings.contains(WATER_SHADER, "let directional_travel = max(-envelope_phase.w, 0.0) * max(t - phase_epoch, 0.0)"))
	testing.expect(t, strings.contains(WATER_SHADER, "let longitudinal = dot(offset, primary) - directional_travel"))
	ocean_macro_query_debug_packet_merge(&renderer.render_query, packet, true)
	bindings := ocean_material_packets(renderer)
	testing.expect_value(t, bindings.envelope_phase[0].w, -packet.front_speed)
	testing.expect_value(t, bindings.envelope_phase[0].z, packet.phase_epoch)
	testing.expect_value(t, bindings.direction_period[0].xyz, packet.direction * ocean_packet_wave_number(packet))
	packet.id = 123
	stationary := ocean_packet_frame({1, 0, 0}, packet.center, packet, 15)
	testing.expect_value(t, stationary.envelope, initial.envelope)
}

@(test)
debug_ocean_carrier_is_source_timed_and_depth_bound :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	modes := [2]bool{false, true}
	for radial in modes {
		packet := Ocean_Render_Packet {
			id = OCEAN_DEBUG_TEST_PULSE_ID,
			center = shared.planet_position({1, 0, 0}, 0),
			direction = {0, 1, 0},
			radial = radial,
			period = 8,
			phase_speed = 6,
			front_speed = 0.2,
			phase_epoch = 10,
			significant_height = 2,
			envelope_length = 20,
			envelope_width = 20,
			band = 20,
		}
		wave_number := ocean_packet_wave_number(packet)
		testing.expect(t, abs(wave_number * packet.phase_speed / OCEAN_RENDER_METERS_PER_UNIT - f32(math.TAU) / packet.period) < 0.00001)
		ocean_macro_query_debug_packet_merge(&renderer.render_query, packet, true)
		bindings := ocean_material_packets(renderer)
		bound_wave_number := -bindings.envelope_phase[0].w if radial else math.sqrt(
			bindings.direction_period[0].x * bindings.direction_period[0].x +
			bindings.direction_period[0].y * bindings.direction_period[0].y +
			bindings.direction_period[0].z * bindings.direction_period[0].z)
		testing.expect(t, abs(bound_wave_number - wave_number) < 0.00001)
		renderer.macro.spectrum.direction = {0, 1, 0}
		first := ocean_macro_wave_sample(&renderer.macro, &renderer.render_query, packet.center, 12, 1, 12)
		packet.phase_epoch += 100
		ocean_macro_query_debug_packet_merge(&renderer.render_query, packet, true)
		second := ocean_macro_wave_sample(&renderer.macro, &renderer.render_query, packet.center, 12, 1, 112)
		testing.expect_value(t, first, second)
		testing.expect(t, abs(first.displacement.x) > 0.1)
		packet.phase_speed *= 0.5
		testing.expect_value(t, ocean_packet_wave_number(packet), wave_number * 2)
		packet.id = 123
		testing.expect_value(t, ocean_packet_carrier_time(packet, 112), f32(112))
	}
	testing.expect(t, strings.contains(WATER_SHADER, "let carrier_time = select(t, max(t - phase_epoch, 0.0), debug_packet)"))
	testing.expect(t, strings.contains(WATER_SHADER, "select(length(supplied_world), -envelope_phase.w, radial_packet)"))
}

@(test)
debug_ocean_fixture_clock_is_headless_partitioned_and_paused :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	first := new(Ocean_Renderer)
	second := new(Ocean_Renderer)
	defer free(first)
	defer free(second)
	previous_scale := debug_ocean_fixture_time_scale
	defer debug_ocean_fixture_time_scale = previous_scale
	debug_ocean_fixture_time_scale = 1
	ocean_surf_fixture_init(&first.nearshore, {1, 0, 0}, .Bank)
	ocean_surf_fixture_init(&second.nearshore, {1, 0, 0}, .Bank)
	first.debug_pulse = {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = shared.planet_position({1, 0, 0}, 0),
		direction = first.nearshore.east,
		significant_height = 2,
		period = 8,
		front_speed = 0.25,
		envelope_length = 100,
		envelope_width = 80,
		band = 100,
	}
	first.debug_pulse_active = true
	second.debug_pulse = first.debug_pulse
	second.debug_pulse_active = true
	for _ in 0 ..< 960 {
		_ = ocean_surf_advance(first, world, {-1, 0, 0}, OCEAN_WAVE_FIXED_DT)
	}
	for _ in 0 ..< 480 {
		_ = ocean_surf_advance(second, world, {0, 0, 1}, OCEAN_WAVE_FIXED_DT * 2)
	}
	testing.expect_value(t, first.macro.step_count, u64(960))
	testing.expect_value(t, first.macro.time, second.macro.time)
	testing.expect_value(t, first.nearshore.state, second.nearshore.state)
	testing.expect(t, first.breakers.front_count > 0)
	testing.expect_value(t, first.breakers.fronts, second.breakers.fronts)
	testing.expect_value(t, first.breakers.spray, second.breakers.spray)
	testing.expect_value(t, first.breakers.emitted_cycles, second.breakers.emitted_cycles)
	testing.expect_value(t, first.breakers.last_time, first.macro.time)
	testing.expect_value(t, first.breakers.mesh.id, u32(0))
	first.macro.accumulator = OCEAN_WAVE_FIXED_DT * 2
	debug_ocean_fixture_time_scale = 0
	paused := first.macro.time
	testing.expect_value(t, ocean_surf_advance(first, world, {}, 1), 0)
	testing.expect_value(t, first.macro.time, paused)
	testing.expect_value(t, first.macro.accumulator, OCEAN_WAVE_FIXED_DT * 2)
	debug_ocean_fixture_time_scale = 1
	first.macro.accumulator = 0
	ocean_renderer_update(first, world, {}, {}, 0, ocean_visual_settings_default(), OCEAN_WAVE_FIXED_DT)
	testing.expect_value(t, first.macro.step_count, u64(960))
	testing.expect_value(t, first.nearshore.state, second.nearshore.state)
	testing.expect_value(t, first.breakers.fronts, second.breakers.fronts)
	testing.expect_value(t, first.breakers.emitted_cycles, second.breakers.emitted_cycles)
	_ = ocean_surf_advance(first, world, {}, OCEAN_WAVE_FIXED_DT)
	testing.expect_value(t, first.macro.step_count, u64(961))
	testing.expect_value(t, first.surf_dropped_time, f32(0))
	_ = ocean_surf_advance(first, world, {}, 0.5)
	testing.expect(t, abs(first.surf_dropped_time - 0.4) < 0.0001)
	debug_ocean_fixture_time_scale = 0
	_ = ocean_surf_advance(first, world, {}, 1)
	testing.expect(t, abs(first.surf_dropped_time - 0.4) < 0.0001)
}

@(test)
debug_ocean_fixture_forcing_ignores_camera_and_weather :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	ocean_surf_fixture_init(&renderer.nearshore, {1, 0, 0}, .Deep)
	renderer.render_query.packet_count = 1
	renderer.render_query.packet_ids[0] = 123
	renderer.macro.spectrum.significant_height = 20
	debug_ocean_fixture_query_update(renderer)
	testing.expect_value(t, renderer.render_query.packet_count, 0)
	testing.expect_value(t, renderer.macro.spectrum.significant_height, f32(0))
	testing.expect_value(t, renderer.render_query.center_direction, renderer.nearshore.focus)
	renderer.debug_pulse = {id = OCEAN_DEBUG_TEST_PULSE_ID, significant_height = 2, period = 8}
	renderer.debug_pulse_active = true
	debug_ocean_fixture_query_update(renderer)
	first := renderer.render_query.packets[0]
	renderer.focus_direction = {-1, 0, 0}
	renderer.macro.spectrum.significant_height = 12
	renderer.render_query.packet_ids[0] = 999
	debug_ocean_fixture_query_update(renderer)
	testing.expect_value(t, renderer.render_query.packet_count, 1)
	testing.expect_value(t, renderer.render_query.packet_ids[0], OCEAN_DEBUG_TEST_PULSE_ID)
	testing.expect_value(t, renderer.render_query.packets[0], first)
	testing.expect_value(t, renderer.macro.spectrum.significant_height, f32(0))
	renderer.debug_pulse_active = false
	debug_ocean_fixture_query_update(renderer)
	testing.expect_value(t, renderer.render_query.packet_count, 0)
}

@(test)
debug_ocean_fixture_reset_replays_pulse_and_clears_transients :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&value.world)
	previous_pinned := debug_ocean_test_pulse_pinned
	previous_source := debug_ocean_test_pulse_source
	previous_id := debug_ocean_test_pulse_id
	defer {
		debug_ocean_test_pulse_pinned = previous_pinned
		debug_ocean_test_pulse_source = previous_source
		debug_ocean_test_pulse_id = previous_id
	}
	renderer := &value.terrain.ocean
	focus := [3]f32{1, 0, 0}
	renderer.macro.time = 42
	renderer.macro.previous_time = 41
	renderer.macro.accumulator = 0.005
	renderer.macro.step_count = 2520
	renderer.spectral_pending_dt = 0.125
	value.planet_cutaway = true
	value.sculpt_active = true
	value.balance.active = true
	debug_ocean_reset_fixture(value, focus, .Bank)
	testing.expect(t, !value.planet_cutaway)
	testing.expect(t, !value.sculpt_active)
	testing.expect(t, !value.balance.active)
	_, first_ok := debug_ocean_inject_test_pulse(value)
	testing.expect(t, first_ok)
	first := renderer.debug_pulse
	renderer.macro.time = 12
	renderer.macro.accumulator = 0.01
	renderer.macro.step_count = 720
	renderer.breakers.front_count = 1
	renderer.breakers.spray[0].active = true
	renderer.breakers.spray_count = 1
	renderer.breakers.vertex_count = 12
	renderer.focus_direction = -focus
	debug_ocean_reset_fixture(value, focus, .Bank)
	testing.expect(t, !renderer.debug_pulse_active)
	testing.expect_value(t, renderer.macro.time, f32(0))
	testing.expect_value(t, renderer.macro.accumulator, f32(0))
	testing.expect_value(t, renderer.macro.step_count, u64(0))
	testing.expect_value(t, renderer.breakers.front_count, u32(0))
	testing.expect_value(t, renderer.breakers.spray_count, u32(0))
	testing.expect_value(t, renderer.breakers.vertex_count, u32(0))
	testing.expect(t, !renderer.breakers.spray[0].active)
	_, second_ok := debug_ocean_inject_test_pulse(value)
	testing.expect(t, second_ok)
	testing.expect_value(t, renderer.debug_pulse, first)
	debug_ocean_stop_test_pulse(value)
	for id in renderer.render_query.packet_ids[:renderer.render_query.packet_count] {
		testing.expect(t, id != OCEAN_DEBUG_TEST_PULSE_ID)
	}
	testing.expect(t, renderer.nearshore.fixture_active)
	previous_directional := debug_ocean_pulse_directional
	previous_heading := debug_ocean_pulse_heading
	defer {
		debug_ocean_pulse_directional = previous_directional
		debug_ocean_pulse_heading = previous_heading
	}
	debug_ocean_pulse_directional = true
	_, east, north := shared.planet_basis(focus)
	for heading in ([]f32{0, 90}) {
		debug_ocean_pulse_heading = heading
		_, injected := debug_ocean_inject_test_pulse(value)
		testing.expect(t, injected && !renderer.debug_pulse.radial)
		expected := east if heading == 0 else north
		for component in 0 ..< 3 {
			testing.expect(t, abs(renderer.debug_pulse.direction[component] - expected[component]) < 0.00001)
		}
	}
	debug_ocean_exit_fixture(value)
	testing.expect_value(t, renderer.macro.time, f32(42))
	testing.expect_value(t, renderer.macro.previous_time, f32(41))
	testing.expect_value(t, renderer.macro.accumulator, f32(0.005))
	testing.expect_value(t, renderer.macro.step_count, u64(2520))
	testing.expect_value(t, renderer.spectral_pending_dt, f32(0.125))
	testing.expect(t, !renderer.fixture_clock_saved)
	testing.expect(t, !renderer.nearshore.fixture_active && !renderer.nearshore.ready)
	testing.expect(t, !renderer.debug_pulse_active && !debug_ocean_test_pulse_pinned)
	for id in renderer.render_query.packet_ids[:renderer.render_query.packet_count] {
		testing.expect(t, id != OCEAN_DEBUG_TEST_PULSE_ID)
	}
}

@(test)
automatic_weather_light_is_focus_independent :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	settings.sun_scale = 1.25
	settings.ambient_scale = 0.75
	sun, ambient := weather_automatic_light(settings)
	testing.expect_value(t, sun, f32(1.25))
	testing.expect_value(t, ambient, f32(0.255))
}

@(test)
orbital_lights_follow_lunar_phase_direction_distance_and_clouds :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.world.planetary.physical = shared.planet_physical_earthlike()
	shared.orbit_init(&value.world.planetary.orbit, 1)
	value.world.planetary.orbit.orbital_phase = 0
	value.world.planetary.orbit.moon.eccentricity_ppm = 0
	value.world.planetary.orbit.moon.phase = 0
	_, new_moon := weather_orbital_lights(value)
	testing.expect_value(t, new_moon.diffuse, f32(0))
	value.world.planetary.orbit.moon.phase = shared.ORBIT_PHASE_SCALE / 2
	_, full_moon := weather_orbital_lights(value)
	ephemeris := shared.orbit_ephemeris(
		value.world.planetary.orbit,
		value.world.planetary.physical,
	)
	testing.expect_value(t, full_moon.direction, ephemeris.moon.planet_fixed_direction)
	testing.expect_value(t, MOON_LIGHT_FULL_INTENSITY, f32(0.065))
	testing.expect_value(t, full_moon.diffuse, MOON_LIGHT_FULL_INTENSITY)
	value.atmosphere.cloud_coverage = 1
	_, cloudy_moon := weather_orbital_lights(value)
	testing.expect(t, cloudy_moon.diffuse < full_moon.diffuse)
}

@(test)
weather_override_can_disable_automatic_renderer_updates :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.world.planetary.physical = shared.planet_physical_earthlike()
	shared.orbit_init(&value.world.planetary.orbit, 1)
	value.ocean_visual = ocean_visual_settings_default()
	value.ocean_visual.automatic_weather = false
	value.ocean_visual.manual_cloud_coverage = 0.75
	weather_apply_atmosphere(value)
	testing.expect_value(t, value.atmosphere.cloud_coverage, f32(0.75))
	testing.expect_value(t, value.atmosphere.cloud_wind, [2]f32{})
	testing.expect_value(t, value.atmosphere.storm_intensity, f32(0.06))
}

@(test)
manual_weather_applies_saved_atmosphere_values :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.world.planetary.physical = shared.planet_physical_earthlike()
	shared.orbit_init(&value.world.planetary.orbit, 1)
	value.ocean_visual = ocean_visual_settings_default()
	value.ocean_visual.automatic_weather = false
	value.ocean_visual.manual_cloud_coverage = 0.75
	value.ocean_visual.manual_fog_density = 0.02
	value.ocean_visual.manual_sun_intensity = 0.4
	value.ocean_visual.manual_ambient_intensity = 0.6
	weather_apply_atmosphere(value)
	testing.expect_value(t, value.atmosphere.cloud_coverage, f32(0.75))
	testing.expect_value(t, value.atmosphere.fog_density, f32(0.02))
	testing.expect_value(t, value.atmosphere.sun_intensity, f32(0.4))
	testing.expect_value(t, value.atmosphere.ambient_intensity, f32(0.6))
}

@(test)
weather_generator_settings_are_bounded :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	settings.manual_cloud_coverage = 2
	settings.manual_fog_density = 1
	settings.storm_radius_km = 0
	settings.storm_intensity = 2
	settings.storm_wind_speed = 500
	settings.storm_wind_heading = 500
	ocean_visual_settings_sanitize(&settings)
	testing.expect_value(t, settings.manual_cloud_coverage, f32(1))
	testing.expect_value(t, settings.manual_fog_density, f32(0.05))
	testing.expect_value(t, settings.storm_radius_km, f32(25))
	testing.expect_value(t, settings.storm_intensity, f32(1))
	testing.expect_value(t, settings.storm_wind_speed, f32(200))
	testing.expect_value(t, settings.storm_wind_heading, f32(360))
}

@(test)
weather_storm_cardinal_headings_match_focus_basis :: proc(t: ^testing.T) {
	focus := shared.planet_sim_direction(
		{.Pos_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	_, east, north := shared.planet_basis(focus)
	headings := [4]f32{0, 90, 180, 270}
	expected := [4][3]f32{north, east, -north, -east}
	for heading, index in headings {
		local_east, local_north := weather_storm_wind(focus, focus, heading, 20, 1)
		world_direction := east * f32(local_east) + north * f32(local_north)
		length := math.sqrt(
			world_direction.x * world_direction.x +
			world_direction.y * world_direction.y +
			world_direction.z * world_direction.z,
		)
		world_direction /= length
		alignment :=
			world_direction.x * expected[index].x +
			world_direction.y * expected[index].y +
			world_direction.z * expected[index].z
		testing.expect(t, alignment > 0.999)
	}
}

@(test)
weather_storm_parallel_transport_preserves_heading_and_falloff :: proc(t: ^testing.T) {
	focus := shared.planet_sim_direction(
		{.Pos_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	destination := shared.planet_sim_direction(
		{.Pos_Y, shared.PLANET_SIM_FACE_CELLS / 3, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	_, focus_east, _ := shared.planet_basis(focus)
	_, destination_east, destination_north := shared.planet_basis(destination)
	east, north := weather_storm_wind(focus, destination, 90, 40, 1)
	half_east, half_north := weather_storm_wind(focus, destination, 90, 40, 0.5)
	world_direction := destination_east * f32(east) + destination_north * f32(north)
	length := math.sqrt(
		world_direction.x * world_direction.x +
		world_direction.y * world_direction.y +
		world_direction.z * world_direction.z,
	)
	world_direction /= length
	transported := weather_parallel_transport(destination, focus, world_direction)
	alignment :=
		transported.x * focus_east.x + transported.y * focus_east.y + transported.z * focus_east.z
	testing.expect(t, alignment > 0.999)
	full_speed := math.sqrt(f32(east * east + north * north))
	half_speed := math.sqrt(f32(half_east * half_east + half_north * half_north))
	testing.expect(t, abs(half_speed / full_speed - 0.5) < 0.001)
}

@(test)
weather_storm_generation_is_local_and_bounded :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	focus := shared.planet_sim_direction(
		{.Pos_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	center := shared.planetary_sample_index(focus)
	outside := shared.planet_sim_index(
		{.Neg_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	outside_cloud := world.planetary.climate.cloud[outside]
	outside_wind := world.planetary.climate.wind_east[outside]
	settings := ocean_visual_settings_default()
	settings.storm_radius_km = 300
	settings.storm_intensity = 1
	settings.storm_wind_speed = 200
	settings.storm_wind_heading = 90
	count := weather_generate_storm(&world.planetary, focus, settings)
	testing.expect(t, count > 0 && count < shared.PLANET_SIM_CELL_COUNT)
	testing.expect(t, world.planetary.climate.cloud[center] > 0)
	testing.expect(t, world.planetary.climate.pressure[center] < shared.CLIMATE_STANDARD_PRESSURE)
	testing.expect(t, abs(world.planetary.climate.wind_east[center]) <= shared.PLANET_WIND_MAX)
	testing.expect(t, abs(world.planetary.climate.wind_north[center]) <= shared.PLANET_WIND_MAX)
	testing.expect_value(t, world.planetary.climate.cloud[outside], outside_cloud)
	testing.expect_value(t, world.planetary.climate.wind_east[outside], outside_wind)
	shared.planetary_diagnostics_update(world)
	testing.expect(t, world.planetary.diagnostics.steps > 1)
}

@(test)
weather_calm_is_local :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	focus := shared.planet_sim_direction(
		{.Pos_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	center := shared.planetary_sample_index(focus)
	outside := shared.planet_sim_index(
		{.Neg_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	world.planetary.climate.cloud[center] = shared.CLIMATE_MAX_WATER
	world.planetary.climate.wind_east[center] = shared.PLANET_WIND_MAX
	world.planetary.climate.cloud[outside] = 123
	count := weather_calm(&world.planetary, focus, 300)
	testing.expect(t, count > 0)
	testing.expect(t, world.planetary.climate.cloud[center] < shared.CLIMATE_MAX_WATER)
	testing.expect(t, world.planetary.climate.wind_east[center] < shared.PLANET_WIND_MAX)
	testing.expect_value(t, world.planetary.climate.cloud[outside], u32(123))
}

@(test)
ocean_settings_load_clamps_and_serializes :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	settings_demo_defaults(value)
	testing.expect(t, settings_demo_load(value, "ocean_roughness", "4"))
	testing.expect_value(t, value.ocean_visual.roughness, f32(0.8))
	testing.expect(t, settings_demo_load(value, "ocean_ripple", "1.25"))
	testing.expect_value(t, value.ocean_visual.bubble_strength, f32(1.25))
	testing.expect(t, settings_demo_load(value, "ocean_ring_0_radius", "10"))
	testing.expect_value(t, value.ocean_visual.ring_radius[0], f32(60))
	testing.expect(t, settings_demo_load(value, "weather_storm_wind_speed", "75"))
	testing.expect_value(t, value.ocean_visual.storm_wind_speed, f32(75))
	testing.expect(t, settings_demo_load(value, "wind_visual_enabled", "1"))
	testing.expect_value(t, value.sim_proof_settings.proof, Sim_Proof_Type.Wind)
	testing.expect(t, settings_demo_load(value, "sim_proof_type", "2"))
	testing.expect(t, settings_demo_load(value, "wind_visual_density", "9"))
	testing.expect_value(t, value.sim_proof_settings.density_scale, f32(2))
	testing.expect(t, settings_demo_load(value, "sim_proof_reference_speed", "1"))
	testing.expect_value(t, value.sim_proof_settings.reference_speed, f32(5))
	text := settings_demo_text(value)
	testing.expect(t, strings.contains(text, "weather_storm_wind_speed=75.0"))
	testing.expect(t, strings.contains(text, "weather_manual_cloud="))
	testing.expect(t, strings.contains(text, "ocean_bubbles=1.250"))
	testing.expect(t, !strings.contains(text, "ocean_ripple="))
	testing.expect(t, strings.contains(text, "sim_proof_type=2"))
	testing.expect(t, strings.contains(text, "sim_proof_density=2.000"))
	testing.expect(t, !strings.contains(text, "wind_visual_enabled="))
	testing.expect(t, !settings_demo_load(value, "unknown", "1"))
}

@(test)
simulation_proofs_expose_separate_wind_and_current_views :: proc(t: ^testing.T) {
	testing.expect(t, Sim_Proof_Type.None != Sim_Proof_Type.Wind)
	testing.expect(t, Sim_Proof_Type.Wind != Sim_Proof_Type.Currents)
	settings := sim_proof_settings_default()
	testing.expect_value(t, settings.proof, Sim_Proof_Type.None)
}

@(test)
water_medium_defaults_are_distinct :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	testing.expect(t, settings.water_medium[0] != settings.water_medium[1])
	testing.expect(t, settings.water_medium[1] != settings.water_medium[2])
	testing.expect_value(t, settings.underwater_enter_depth, f32(0.15))
	testing.expect_value(t, settings.underwater_exit_height, f32(0.30))
	testing.expect_value(t, settings.underwater_transition, f32(0.35))
}

@(test)
water_underwater_settings_sanitize_preserves_hysteresis :: proc(t: ^testing.T) {
	settings := ocean_visual_settings_default()
	for &medium in settings.water_medium {
		medium = {9, 9, 9}
	}
	settings.underwater_enter_depth = -1
	settings.underwater_exit_height = 0
	settings.underwater_transition = 0
	ocean_visual_settings_sanitize(&settings)
	for medium in settings.water_medium {
		testing.expect_value(t, medium.absorption_scale, f32(3))
		testing.expect_value(t, medium.scatter_scale, f32(3))
		testing.expect_value(t, medium.turbidity_scale, f32(4))
	}
	testing.expect_value(t, settings.underwater_enter_depth, f32(0.01))
	testing.expect(t, settings.underwater_exit_height >= settings.underwater_enter_depth)
	testing.expect_value(t, settings.underwater_transition, f32(0.05))
}

@(test)
water_underwater_hysteresis_does_not_chatter :: proc(t: ^testing.T) {
	testing.expect(t, !water_underwater_target(false, -0.14, 0.15, 0.30))
	testing.expect(t, water_underwater_target(false, -0.15, 0.15, 0.30))
	testing.expect(t, water_underwater_target(true, 0.29, 0.15, 0.30))
	testing.expect(t, !water_underwater_target(true, 0.30, 0.15, 0.30))
}

@(test)
water_underwater_transition_is_bounded :: proc(t: ^testing.T) {
	entering := water_underwater_blend_next(0, true, 0.1, 0.4)
	exiting := water_underwater_blend_next(1, false, 0.1, 0.4)
	testing.expect(t, entering > 0 && entering < 1)
	testing.expect(t, exiting > 0 && exiting < 1)
	testing.expect_value(t, water_underwater_blend_next(0, true, 2, 0.4), f32(1))
	testing.expect_value(t, water_underwater_blend_next(1, false, 2, 0.4), f32(0))
}

@(test)
water_underwater_settings_persist :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	settings_demo_defaults(value)
	testing.expect(t, settings_demo_load(value, "water_river_turbidity", "9"))
	testing.expect_value(t, value.ocean_visual.water_medium[2].turbidity_scale, f32(4))
	testing.expect(t, settings_demo_load(value, "water_underwater_enter_depth", "-1"))
	testing.expect_value(t, value.ocean_visual.underwater_enter_depth, f32(0.01))
	text := settings_demo_text(value)
	testing.expect(t, strings.contains(text, "water_ocean_absorption="))
	testing.expect(t, strings.contains(text, "water_lake_scatter="))
	testing.expect(t, strings.contains(text, "water_river_turbidity=4.000"))
	testing.expect(t, strings.contains(text, "water_underwater_transition="))
}

@(test)
world_shader_contract_applies_underwater_extinction :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn underwater_apply"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "u.custom_params_5.w"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "exp(-absorption * path"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fog.a * (1.0 - underwater)"))
}

@(test)
water_shader_proof_views_are_explicit_and_default_to_composite :: proc(t: ^testing.T) {
	testing.expect_value(t, ocean_visual_settings_default().proof_view, Ocean_Proof_View.Composite)
	testing.expect(t, strings.contains(WATER_SHADER, "let proof_view = min(params_7_w >> 3u, 6u)"))
	testing.expect(t, !strings.contains(WATER_SHADER, "clamp(u.custom_params_5.x"))
	testing.expect(t, strings.contains(WATER_SHADER, "proof_view == 1u"))
	testing.expect(t, strings.contains(WATER_SHADER, "proof_view >= 2u && proof_view <= 4u"))
	testing.expect(t, strings.contains(WATER_SHADER, "proof_view == 5u"))
	testing.expect(t, strings.contains(WATER_SHADER, "proof_view == 6u"))
}

@(test)
water_shader_integrates_the_displaced_water_volume :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "@location(7) radial_displacement: f32"))
	testing.expect(t, strings.contains(WATER_SHADER, "in.depth + in.radial_displacement"))
	testing.expect(t, strings.contains(WATER_SHADER, "fn water_volume_integrate"))
	testing.expect(t, strings.contains(WATER_SHADER, "sample_index < 6u"))
	testing.expect(t, strings.contains(WATER_SHADER, "inscatter += transmittance"))
	testing.expect(t, strings.contains(WATER_SHADER, "transmittance *= step_transmittance"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "volume_physical = (depth_palette * volume.transmittance"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "volume_color = mix(volume_physical, depth_palette"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "scene_refraction.rgb * volume.transmittance"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "let generated_lit = atmosphere_apply(color"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let lit = mix(generated_lit, transmitted_scene"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "return vec4<f32>(lit * alpha, alpha)"))
}

@(test)
water_shader_uses_resolved_scene_only_for_transmission :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "fn water_screen_offset("))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "u.view_projection * vec4<f32>(world_position"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "shaded_normal - geometry_normal"))
	testing.expect(t, !strings.contains(WATER_SHADER, "let distortion = normal.xy"))
	testing.expect(t, strings.contains(WATER_SHADER, "scene_water_sample"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "source_depth = textureLoad(scene_depth_texture"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "refracted_depth = textureLoad(scene_depth_texture"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "depth_width = max(fwidth(position.z)"))
	testing.expect(t, strings.contains(WATER_SHADER, "depth_continuity"))
	testing.expect(t, strings.contains(WATER_SHADER, "shoreline_valid"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let refraction_weight = scene_refraction.a * mix("),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"scene_transmission_weight = refraction_weight * (1.0 - reflection_weight)",
		),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"mix(generated_lit, transmitted_scene, scene_transmission_weight)",
		),
	)
	testing.expect(
		t,
		!strings.contains(WATER_SHADER, "transmitted_scene * (ambient_water + direct_water)"),
	)
	testing.expect(t, !strings.contains(WATER_SHADER, "let transmitted_lit = atmosphere_apply("))
	testing.expect(t, !strings.contains(WATER_SHADER, "scene_reflection_sample"))
	testing.expect(t, !strings.contains(WATER_SHADER, "scene_reflection.rgb"))
}

@(test)
water_shader_filters_view_response_and_unresolved_highlights :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "filtered_view_cosine"))
	testing.expect(t, strings.contains(WATER_SHADER, "geometry_ndv"))
	testing.expect(t, strings.contains(WATER_SHADER, "geometry_ndl"))
	testing.expect(t, strings.contains(WATER_SHADER, "let grazing = smoothstep"))
	testing.expect(
		t,
		!strings.contains(
			WATER_SHADER,
			"let spectral_resolved = 1.0 - smoothstep(80.0, 900.0, dist);",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "let surface_reference = select(radial, normalize(in.normal), breaker_surface);"))
	testing.expect(t, !strings.contains(WATER_SHADER, "spectral_gradient * spectral_enabled"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let spectral_unresolved = spectral_enabled * mean_square_slope *",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "let normal_dx = dpdx(normal);"))
	testing.expect(t, strings.contains(WATER_SHADER, "let normal_dy = dpdy(normal);"))
	testing.expect(t, strings.contains(WATER_SHADER, "normal_variance * 0.32"))
	testing.expect(t, strings.contains(WATER_SHADER, "ggx_distribution(ndh, roughness)"))
	testing.expect(
		t,
		!strings.contains(WATER_SHADER[len(SHADER_PREAMBLE):], "flash_distribution"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "fn water_environment_reflection("))
	testing.expect(t, strings.contains(WATER_SHADER, "let spread = roughness * roughness"))
	testing.expect(t, strings.contains(WATER_SHADER, "water_environment_reflection("))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let volume_illumination = planet_light_level"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let environment_fill = depth_palette * ambient_water"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let multiple_scatter = roughness * roughness"),
	)
	testing.expect(t, !strings.contains(WATER_SHADER, "let light = view"))
	testing.expect(t, !strings.contains(WATER_SHADER, "reflect(-light, normal)"))
}

@(test)
water_shader_volume_is_bounded_to_authoritative_wet_columns :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "let displaced_column_depth = select("))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "max(in.depth + in.radial_displacement, 0.0)"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "in.depth > 0.0"))
	testing.expect(t, strings.contains(WATER_SHADER, "darkening *= exp(-step_length"))
}

@(test)
water_shader_preserves_camera_invariant_depth_layers :: proc(t: ^testing.T) {
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let vertical_depth = clamp(displaced_column_depth / 6.0"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let depth_factor = clamp(max(vertical_depth, 1.0 - in.shallow)",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let depth_palette = mix(shallow_palette, u.color.rgb"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let depth_contrast_floor = mix(0.34, 0.52, unresolved_energy)",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "spectral_unresolved / max(mean_square_slope"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let depth_chroma_support = (1.0 - view_fresnel) * (1.0 - foam_amount)",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "color = mix(color, depth_palette * ambient_water"),
	)
	testing.expect(
		t,
		!strings.contains(
			WATER_SHADER,
			"depth_factor = clamp(max(vertical_depth, 1.0 - in.shallow) *",
		),
	)
	testing.expect(
		t,
		!strings.contains(WATER_SHADER, "environment_fill = environment_irradiance *"),
	)
}

@(test)
world_shaders_share_planet_lighting_and_stable_reflections :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn planet_solar_factor("))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn planet_ambient_light("))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn planet_direct_light("))
	testing.expect(t, strings.contains(POST_PROCESS_SHADER, "color = max(contrasted, color);"))
	testing.expect(
		t,
		strings.contains(
			POST_PROCESS_SHADER,
			"let shadow_weight = (1.0 - smoothstep(0.08, 0.35, luminance)) * cu.overview;",
		),
	)
	testing.expect(
		t,
		strings.contains(
			POST_PROCESS_SHADER,
			"let lifted_shadows = pow(max(color, vec3<f32>(0.0)), vec3<f32>(0.78));",
		),
	)
	testing.expect(
		t,
		strings.contains(
			POST_PROCESS_SHADER,
			"color = mix(color, lifted_shadows, shadow_weight * 0.45);",
		),
	)
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn planet_moon_light("))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "u.secondary_light_direction.xyz"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "let moon_above_horizon = smoothstep("))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "let night = 1.0 - planet_solar_factor("))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "fn atmosphere_optical_depth("))
	testing.expect(
		t,
		strings.contains(SHADER_PREAMBLE, "let shell_exit = max(-b + sqrt(discriminant), 0.0)"),
	)
	testing.expect(
		t,
		strings.contains(SHADER_PREAMBLE, "let segment_length = min(max(dist, 0.0), shell_exit)"),
	)
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "sample_index < 8u"))
	testing.expect(t, !strings.contains(SHADER_PREAMBLE, "abs(dot(view, up))"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "let fog_daylight = planet_solar_factor"))
	testing.expect(t, strings.contains(SHADER_PREAMBLE, "let illumination = planet_light_level"))
	testing.expect(t, !strings.contains(SHADER_PREAMBLE, "moon_direction = -light"))
	testing.expect(t, !strings.contains(WATER_SHADER, "mix(0.34, 1.0, light_cosine)"))
	testing.expect(t, !strings.contains(WATER_SHADER, "environment_daylight"))
	testing.expect(t, strings.contains(WATER_SHADER, "let sign_z = select(-1.0, 1.0"))
	testing.expect(t, strings.contains(WATER_SHADER, "tangent_positive + tangent_negative"))
	testing.expect(t, strings.contains(WATER_SHADER, "bitangent_positive + bitangent_negative"))
	testing.expect(t, !strings.contains(WATER_SHADER, "abs(reflected.z) > 0.88"))
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "planet_ambient_light(normal, radial, light)"),
	)
	testing.expect(
		t,
		strings.contains(FLORA_SHADER, "planet_ambient_light(normal, radial, light)"),
	)
}

@(test)
water_optical_profiles_are_kind_specific :: proc(t: ^testing.T) {
	ocean := water_optical_profile(.Ocean, 0.25)
	lake := water_optical_profile(.Lake, 0.25)
	river := water_optical_profile(.River, 0.25)
	testing.expect(t, ocean != lake && lake != river && ocean != river)
	testing.expect_value(t, ocean.turbidity, f32(0.25))
	testing.expect_value(t, lake.turbidity, f32(0.25))
	testing.expect_value(t, river.turbidity, f32(0.25))
	testing.expect(t, river.absorption[0] > lake.absorption[0])
	testing.expect(t, lake.absorption[0] > ocean.absorption[0])
}
