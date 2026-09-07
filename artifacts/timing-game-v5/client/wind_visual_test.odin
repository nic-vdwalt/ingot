package main

import shared "../shared"
import "core:testing"

@(test)
sim_proof_settings_defaults_and_sanitize :: proc(t: ^testing.T) {
	settings := sim_proof_settings_default()
	testing.expect_value(t, settings.proof, Sim_Proof_Type.None)
	testing.expect_value(t, settings.density_scale, f32(1))
	testing.expect_value(t, settings.reference_speed, f32(40))
	settings.density_scale = 9
	settings.length_scale = 0
	settings.lift = 99
	settings.opacity = 0
	settings.reference_speed = 1
	settings.pulse_speed = 9
	settings.pulse_strength = -1
	sim_proof_settings_sanitize(&settings)
	testing.expect_value(t, settings.density_scale, f32(2))
	testing.expect_value(t, settings.length_scale, f32(0.25))
	testing.expect_value(t, settings.lift, f32(12))
	testing.expect_value(t, settings.opacity, f32(0.05))
	testing.expect_value(t, settings.reference_speed, f32(5))
	testing.expect_value(t, settings.pulse_speed, f32(4))
	testing.expect_value(t, settings.pulse_strength, f32(0))
}

@(test)
sim_proof_types_are_separate_and_currents_sample_both_layers :: proc(t: ^testing.T) {
	testing.expect(t, Sim_Proof_Type.Wind != Sim_Proof_Type.Currents)
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	coord := shared.Planet_Sim_Coord{.Pos_X, 48, 48}
	index := shared.planet_sim_index(coord)
	world.planetary.ocean.mean_depth_mm[index] = 100_000
	world.planetary.ocean.transport_east[index] = shared.PLANET_VELOCITY_SCALE * 3
	world.planetary.ocean.deep_transport_east[index] = -shared.PLANET_VELOCITY_SCALE * 2
	direction := shared.planet_sim_direction(coord)
	surface, surface_speed := sim_proof_world_vector(world, direction, .Currents, false)
	deep, deep_speed := sim_proof_world_vector(world, direction, .Currents, true)
	testing.expect(t, surface_speed > 0 && deep_speed > 0)
	testing.expect(t, wind_vector_dot(surface, deep) < 0)
}

@(test)
wind_world_vector_is_tangent :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	coord := shared.Planet_Sim_Coord{.Pos_X, 48, 48}
	index := shared.planet_sim_index(coord)
	world.planetary.climate.wind_east[index] = shared.PLANET_VELOCITY_SCALE * 12
	world.planetary.climate.wind_north[index] = shared.PLANET_VELOCITY_SCALE * 5
	direction := shared.planet_sim_direction(coord)
	vector, speed := wind_world_vector(world, direction)
	testing.expect(t, abs(wind_vector_dot(vector, direction)) < 0.001)
	testing.expect(t, speed > 0)
}

@(test)
wind_speed_mapping_is_bounded_and_monotonic :: proc(t: ^testing.T) {
	testing.expect_value(t, wind_display_strength(0, 40), f32(0))
	low := wind_display_strength(5, 40)
	high := wind_display_strength(20, 40)
	testing.expect(t, low > 0 && high > low)
	testing.expect_value(t, wind_display_strength(1000, 40), f32(1))
}

@(test)
wind_visual_geometry_is_bounded :: proc(t: ^testing.T) {
	layer: Wind_Visual_Layer
	wind_layer_init_storage(&layer, 2)
	defer wind_layer_deinit_storage(&layer)
	testing.expect_value(t, len(layer.vertices), 2 * WIND_VERTICES_PER_ARROW)
	testing.expect_value(t, len(layer.indices), 2 * WIND_INDICES_PER_ARROW)
	wind_layer_degenerate_from(&layer, 1)
	testing.expect_value(t, layer.arrow_count, 1)
	for vertex in layer.vertices[WIND_VERTICES_PER_ARROW:] {
		testing.expect_value(t, vertex.position, [3]f32{})
	}
	testing.expect(t, WIND_CLOSE_CAPACITY * WIND_VERTICES_PER_ARROW > 0)
	testing.expect(t, WIND_REGIONAL_CAPACITY * WIND_INDICES_PER_ARROW > 0)
	testing.expect_value(t, WIND_OVERVIEW_CAPACITY, 3_456)
}

@(test)
wind_world_vector_is_continuous_across_face_seam :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	for index in 0 ..< shared.PLANET_SIM_CELL_COUNT {
		world.planetary.climate.wind_east[index] = shared.PLANET_VELOCITY_SCALE * 10
		world.planetary.climate.wind_north[index] = 0
	}
	coord := shared.Planet_Coord{.Pos_X, 0, shared.PLANET_FACE_CELLS / 2}
	across := shared.planet_neighbour(coord, -1, 0)
	left, _ := wind_world_vector(world, shared.planet_direction(coord))
	right, _ := wind_world_vector(world, shared.planet_direction(across))
	testing.expect(
		t,
		wind_vector_dot(wind_vector_normalize(left), wind_vector_normalize(right)) > 0.7,
	)
}

@(test)
wind_surface_height_selects_water_surface :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	coord := shared.Planet_Coord {
		.Pos_X,
		shared.PLANET_FACE_CELLS / 2,
		shared.PLANET_FACE_CELLS / 2,
	}
	direction := shared.planet_direction(coord)
	ground := shared.terrain_height_at_coord(world, coord)
	height := wind_surface_height(world, direction)
	testing.expect(t, height >= ground)
}

@(test)
wind_material_only_settings_do_not_rebuild_geometry :: proc(t: ^testing.T) {
	settings := sim_proof_settings_default()
	geometry := wind_visual_geometry_settings(settings)
	settings.opacity *= 0.5
	settings.pulse_speed *= 0.5
	settings.pulse_strength *= 0.5
	testing.expect_value(t, wind_visual_geometry_settings(settings), geometry)
}

@(test)
wind_mode_excludes_hidden_deep_layers :: proc(t: ^testing.T) {
	testing.expect_value(t, wind_visual_required_layer_count(.Wind), 3)
	testing.expect_value(t, wind_visual_required_layer_count(.Currents), 6)
}

@(test)
wind_new_requests_queue_without_resetting_active_progress :: proc(t: ^testing.T) {
	visual: Wind_Visual
	settings := sim_proof_settings_default()
	settings.proof = .Wind
	wind_visual_generation_request(&visual, {1, 0, 0}, settings)
	visual.build_layer = 1
	visual.build_arrow = 72
	settings.proof = .Currents
	wind_visual_generation_request(&visual, {0, 1, 0}, settings)
	testing.expect_value(t, visual.generation, u64(1))
	testing.expect_value(t, visual.build_layer, 1)
	testing.expect_value(t, visual.build_arrow, 72)
	testing.expect(t, visual.pending)
	testing.expect_value(t, visual.pending_focus, [3]f32{0, 1, 0})
	testing.expect_value(t, visual.pending_settings.proof, Sim_Proof_Type.Currents)
}

@(test)
wind_generation_progress_survives_continuous_tick_requests :: proc(t: ^testing.T) {
	visual: Wind_Visual
	settings := sim_proof_settings_default()
	settings.proof = .Wind
	wind_visual_generation_request(&visual, {1, 0, 0}, settings)
	for tick in 1 ..= 48 {
		visual.build_arrow += WIND_BUILD_ARROWS_PER_UPDATE
		wind_visual_generation_request(&visual, {f32(tick), 0, 0}, settings)
	}
	testing.expect_value(t, visual.generation, u64(1))
	testing.expect(t, visual.build_arrow > WIND_CLOSE_CAPACITY)
	testing.expect(t, visual.pending)
}

wind_visual_test_storage_init :: proc(visual: ^Wind_Visual) {
	wind_layer_init_storage(&visual.close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&visual.regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&visual.overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&visual.deep_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&visual.deep_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&visual.deep_overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&visual.staging_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&visual.staging_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&visual.staging_overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&visual.staging_deep_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&visual.staging_deep_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&visual.staging_deep_overview, WIND_OVERVIEW_CAPACITY)
}

wind_visual_test_storage_deinit :: proc(visual: ^Wind_Visual) {
	wind_layer_deinit_storage(&visual.close)
	wind_layer_deinit_storage(&visual.regional)
	wind_layer_deinit_storage(&visual.overview)
	wind_layer_deinit_storage(&visual.deep_close)
	wind_layer_deinit_storage(&visual.deep_regional)
	wind_layer_deinit_storage(&visual.deep_overview)
	wind_layer_deinit_storage(&visual.staging_close)
	wind_layer_deinit_storage(&visual.staging_regional)
	wind_layer_deinit_storage(&visual.staging_overview)
	wind_layer_deinit_storage(&visual.staging_deep_close)
	wind_layer_deinit_storage(&visual.staging_deep_regional)
	wind_layer_deinit_storage(&visual.staging_deep_overview)
}

@(test)
wind_currents_eventually_publish_while_ticks_keep_changing :: proc(t: ^testing.T) {
	world := new(shared.World)
	visual := new(Wind_Visual)
	defer free(world)
	defer free(visual)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	wind_visual_test_storage_init(visual)
	defer wind_visual_test_storage_deinit(visual)
	settings := sim_proof_settings_default()
	settings.proof = .Currents
	visual.close.arrow_count = 17
	wind_visual_generation_request(visual, {1, 0, 0}, settings)
	for frame in 0 ..< 120 {
		if frame % 30 == 0 do wind_visual_generation_request(visual, {1, f32(frame) * 0.001, 0}, settings)
		wind_visual_generation_step(visual, world, settings, WIND_BUILD_ARROWS_PER_UPDATE)
		if visual.published_generation == 0 do testing.expect_value(t, visual.close.arrow_count, 17)
	}
	testing.expect(t, visual.published_generation > 0)
	testing.expect(t, visual.generation > visual.published_generation)
	testing.expect(t, visual.building)
}
