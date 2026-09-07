#+build !js
package main

import shared "../shared"
import "core:fmt"
import "core:math"
import "core:mem"
import "core:strings"
import "core:testing"
import "ingot:asset"
import rl "ingot:gfx"

@(test)
ocean_spectral_cascades_are_bounded_powers_of_two :: proc(t: ^testing.T) {
	resolutions := OCEAN_SPECTRAL_RESOLUTION
	length_scales := OCEAN_SPECTRAL_LENGTH_SCALE
	for resolution, index in resolutions {
		testing.expect(t, resolution >= 128 && resolution <= 256)
		testing.expect(t, (resolution & (resolution - 1)) == 0)
		testing.expect_value(
			t,
			ocean_spectral_log2(resolution),
			u32(8 if resolution == 256 else 7),
		)
		if index > 0 {
			testing.expect(t, length_scales[index] > length_scales[index - 1])
			ratio := length_scales[index] / length_scales[index - 1]
			testing.expect(t, abs(ratio - math.round(ratio)) > 0.05)
		}
	}
	testing.expect_value(t, OCEAN_SPECTRAL_DISPATCHES_MAX, 53)
	testing.expect_value(t, ocean_spectral_update_dispatch_count(), OCEAN_SPECTRAL_DISPATCHES_MAX)
	testing.expect_value(t, ocean_spectral_compute_pass_count(), 1)
	testing.expect(t, OCEAN_SPECTRAL_DISPATCHES_MAX + 1 <= OCEAN_SPECTRAL_COMPUTE_BUFFER_MAX)
	testing.expect_value(t, OCEAN_SPECTRAL_UNIFORM_STRIDE, 256)
	testing.expect(t, OCEAN_SPECTRAL_UNIFORM_STRIDE >= OCEAN_SPECTRAL_UNIFORM_BYTES)
}

@(test)
ocean_pipeline_status_requires_compute_draw_and_bindings :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.spectral_init_state = .Ready
	renderer.wave_source = .Spectral
	renderer.spectral.ready = true
	renderer.spectral_update_serial = 7
	renderer.draw_diagnostics = {
		shader_id                     = 41,
		scene_color_id                = 42,
		scene_depth_id                = 43,
		spectral_texture_ids          = {44, 45, 46},
		near_draw_count               = 1,
		spectral_update_serial        = 7,
		spectral_displacement_enabled = true,
	}
	status := ocean_pipeline_status(renderer, 41)
	testing.expect_value(t, status.verdict, "PROVEN SPECTRAL")
	testing.expect(t, status.proven_active)

	renderer.draw_diagnostics.near_draw_count = 0
	status = ocean_pipeline_status(renderer, 41)
	testing.expect_value(t, status.verdict, "NO WATER DRAW")
	testing.expect(t, !status.proven_active)

	renderer.draw_diagnostics.near_draw_count = 1
	renderer.draw_diagnostics.spectral_texture_ids[1] = 0
	status = ocean_pipeline_status(renderer, 41)
	testing.expect(t, !status.spectral_textures_bound)
	testing.expect(t, !status.proven_active)

	renderer.spectral_init_state = .Unsupported
	status = ocean_pipeline_status(renderer, 41)
	testing.expect_value(t, status.verdict, "UNSUPPORTED")
}

@(test)
ocean_nearest_ring_adds_only_spectral_displacement :: proc(t: ^testing.T) {
	testing.expect_value(t, ocean_ring_displacement_mode(true), f32(0))
	testing.expect_value(t, ocean_ring_displacement_mode(false), f32(1))
}

@(test)
ocean_ring_updates_keep_fixed_step_work_local :: proc(t: ^testing.T) {
	for ring_index in 0 ..< OCEAN_CLIPMAP_RING_COUNT {
		testing.expect(
			t,
			ocean_ring_geometry_changed(ring_index, false, false, false, false, false, false),
		)
		testing.expect(
			t,
			ocean_ring_geometry_changed(ring_index, true, true, false, false, false, true),
		)
		testing.expect(
			t,
			ocean_ring_geometry_changed(ring_index, true, false, true, false, false, true),
		)
		testing.expect(
			t,
			ocean_ring_geometry_changed(ring_index, true, false, false, false, true, true),
		)
		testing.expect_value(
			t,
			ocean_ring_geometry_changed(ring_index, true, false, false, true, false, false),
			ring_index == 0,
		)
		testing.expect(
			t,
			!ocean_ring_geometry_changed(ring_index, true, false, false, true, false, true),
		)
	}
}

@(test)
ocean_geometry_updates_are_budgeted_to_one_unit :: proc(t: ^testing.T) {
	testing.expect_value(t, ocean_geometry_unit_limit(true), u32(1))
	testing.expect_value(t, ocean_geometry_unit_limit(false), u32(0))
	testing.expect_value(t, ocean_clipmap_row_budget(true), OCEAN_CLIPMAP_ROWS_PER_UPDATE)
	testing.expect_value(t, ocean_clipmap_row_budget(false), 0)
	testing.expect(t, ocean_far_update_admitted(0, true))
	testing.expect(t, !ocean_far_update_admitted(1, true))
	testing.expect(t, !ocean_far_update_admitted(0, false))
	testing.expect(t, OCEAN_CLIPMAP_ROWS_PER_UPDATE > 0)
	testing.expect(t, OCEAN_CLIPMAP_ROWS_PER_UPDATE < OCEAN_CLIPMAP_EDGE)
}

@(test)
ocean_anchor_stationary_and_sub_cell_motion_do_not_regenerate :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.ready = true
	renderer.anchor_direction = {1, 0, 0}
	renderer.anchor_east = {0, 1, 0}
	renderer.anchor_north = {0, 0, 1}
	testing.expect(t, !ocean_clipmap_anchor_update(renderer, renderer.anchor_direction, 10))
	sub_cell := ocean_clipmap_direction(
		renderer.anchor_direction,
		renderer.anchor_east,
		renderer.anchor_north,
		4.9,
		0,
	)
	testing.expect(t, !ocean_clipmap_anchor_update(renderer, sub_cell, 10))
	testing.expect_value(t, renderer.clipmap_metrics.anchor_changes, u64(0))
}

@(test)
ocean_anchor_generation_publishes_atomically :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.anchor_direction = {1, 0, 0}
	renderer.staging_anchor_direction = {0, 1, 0}
	renderer.staging_anchor_pending = true
	renderer.rings[0].has_water = false
	renderer.staging_rings[0].has_water = true
	ocean_ring_generation_begin(renderer, 11)
	testing.expect(t, renderer.staging_active)
	testing.expect(t, !ocean_ring_generation_complete(renderer))
	testing.expect_value(t, renderer.published_generation, u64(0))
	testing.expect_value(t, renderer.anchor_direction, [3]f32{1, 0, 0})
	testing.expect(t, !renderer.rings[0].has_water)
	for &pending in renderer.pending_rings do pending = false
	testing.expect(t, ocean_ring_generation_complete(renderer))
	ocean_ring_generation_publish(renderer)
	testing.expect_value(t, renderer.published_generation, u64(1))
	testing.expect_value(t, renderer.water_revision, u64(11))
	testing.expect_value(t, renderer.anchor_direction, [3]f32{0, 1, 0})
	testing.expect(t, renderer.rings[0].has_water)
	testing.expect(t, !renderer.staging_active)
}

@(test)
ocean_anchor_changes_do_not_reset_an_active_generation :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.ready = true
	renderer.anchor_direction = {1, 0, 0}
	renderer.anchor_east = {0, 1, 0}
	renderer.anchor_north = {0, 0, 1}
	ocean_ring_generation_begin(renderer, 3)
	renderer.pending_rings[0] = false
	staging_anchor := renderer.staging_anchor_direction
	changed := ocean_clipmap_anchor_update(renderer, {0, 1, 0}, 10)
	testing.expect(t, !changed)
	testing.expect_value(t, renderer.staging_generation, u64(1))
	testing.expect(t, !renderer.pending_rings[0])
	testing.expect_value(t, renderer.staging_anchor_direction, staging_anchor)
	testing.expect(t, renderer.pending_anchor_request)
	testing.expect_value(t, renderer.pending_anchor_radial, [3]f32{0, 1, 0})
	for &pending in renderer.pending_rings do pending = false
	ocean_ring_generation_publish(renderer)
	testing.expect(t, ocean_clipmap_anchor_update(renderer, {0, 1, 0}, 10))
	testing.expect_value(t, renderer.clipmap_metrics.anchor_changes, u64(1))
}

@(test)
ocean_chunked_ring_fill_matches_full_rebuild :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.wave_source = .Spectral
	renderer.spectral.ready = true
	direction := shared.planet_sim_direction(
		{.Pos_X, shared.PLANET_SIM_FACE_CELLS / 2, shared.PLANET_SIM_FACE_CELLS / 2},
	)
	_, east, north := shared.planet_basis(direction)
	for ring_index in 0 ..< OCEAN_CLIPMAP_RING_COUNT {
		full := Ocean_Clipmap_Ring {
			inner_radius = f32(ring_index) * 180,
			outer_radius = f32(ring_index + 1) * 180,
			vertices     = make([]asset.Vertex, OCEAN_CLIPMAP_VERTICES),
			gpu_vertices = make([]rl.Gpu_3D_Vertex, OCEAN_CLIPMAP_VERTICES),
		}
		chunked := Ocean_Clipmap_Ring {
			inner_radius = full.inner_radius,
			outer_radius = full.outer_radius,
			vertices     = make([]asset.Vertex, OCEAN_CLIPMAP_VERTICES),
			gpu_vertices = make([]rl.Gpu_3D_Vertex, OCEAN_CLIPMAP_VERTICES),
		}
		defer delete(full.vertices)
		defer delete(full.gpu_vertices)
		defer delete(chunked.vertices)
		defer delete(chunked.gpu_vertices)
		ocean_ring_fill(&full, renderer, world, ring_index, direction, east, north)
		for row_begin := 0;
		    row_begin < OCEAN_CLIPMAP_EDGE;
		    row_begin += OCEAN_CLIPMAP_ROWS_PER_UPDATE {
			row_end := min(row_begin + OCEAN_CLIPMAP_ROWS_PER_UPDATE, OCEAN_CLIPMAP_EDGE)
			ocean_ring_fill_rows(
				&chunked,
				renderer,
				world,
				ring_index,
				row_begin,
				row_end,
				direction,
				east,
				north,
			)
		}
		testing.expect_value(t, len(chunked.vertices), OCEAN_CLIPMAP_VERTICES)
		testing.expect_value(t, chunked.has_water, full.has_water)
		testing.expect_value(t, chunked.cpu_macro_deformed, full.cpu_macro_deformed)
		testing.expect(
			t,
			mem.compare(mem.slice_to_bytes(chunked.vertices), mem.slice_to_bytes(full.vertices)) ==
			0,
			"chunked ring differs from full rebuild",
		)
		testing.expect(
			t,
			mem.compare(
				mem.slice_to_bytes(chunked.gpu_vertices),
				mem.slice_to_bytes(full.gpu_vertices),
			) ==
			0,
			"chunked GPU vertices differ from full rebuild",
		)
	}
}

@(test)
ocean_ring_indices_can_expand_after_an_annulus :: proc(t: ^testing.T) {
	ring := Ocean_Clipmap_Ring {
		inner_radius = 180,
		outer_radius = 540,
		indices      = make([]u32, OCEAN_CLIPMAP_INDICES_MAX),
	}
	defer delete(ring.indices)
	ocean_ring_indices_fill(&ring)
	annulus_count := ring.index_count
	ring.inner_radius = 0
	ocean_ring_indices_fill(&ring)
	testing.expect(t, ring.index_count > annulus_count)
	testing.expect_value(t, ring.index_count, OCEAN_CLIPMAP_INDICES_MAX)
	testing.expect_value(t, len(ring.indices), OCEAN_CLIPMAP_INDICES_MAX)
}

@(test)
ocean_spectral_cadence_preserves_elapsed_time :: proc(t: ^testing.T) {
	elapsed, remainder, due := ocean_spectral_step_due(OCEAN_WAVE_FIXED_DT)
	testing.expect(t, !due)
	testing.expect_value(t, elapsed, f32(0))
	testing.expect(t, abs(remainder - OCEAN_WAVE_FIXED_DT) < 0.000001)

	elapsed, remainder, due = ocean_spectral_step_due(OCEAN_WAVE_FIXED_DT * 2)
	testing.expect(t, due)
	testing.expect(t, abs(elapsed - OCEAN_SPECTRAL_UPDATE_INTERVAL) < 0.000001)
	testing.expect(t, remainder < 0.000001)

	elapsed, remainder, due = ocean_spectral_step_due(OCEAN_SPECTRAL_UPDATE_INTERVAL * 2.5)
	testing.expect(t, due)
	testing.expect(t, abs(elapsed - OCEAN_SPECTRAL_UPDATE_INTERVAL * 2) < 0.000001)
	testing.expect(t, abs(remainder - OCEAN_SPECTRAL_UPDATE_INTERVAL * 0.5) < 0.000001)
}

@(test)
ocean_spectral_budget_deferral_preserves_time_and_is_bounded :: proc(t: ^testing.T) {
	testing.expect(t, !ocean_spectral_update_admitted(OCEAN_SPECTRAL_UPDATE_INTERVAL, false))
	testing.expect(t, ocean_spectral_update_admitted(OCEAN_SPECTRAL_UPDATE_INTERVAL, true))
	testing.expect(t, ocean_spectral_update_admitted(OCEAN_SPECTRAL_MAX_DEFERRED, false))
}

@(test)
ocean_spectral_initialization_waits_for_a_closed_frame :: proc(t: ^testing.T) {
	state := Ocean_Spectral_Init_State.Pending
	first := ocean_spectral_init_action(state, true, true, true)
	second := ocean_spectral_init_action(state, true, true, false)
	testing.expect_value(t, first, Ocean_Spectral_Init_Action.Wait)
	testing.expect_value(t, second, Ocean_Spectral_Init_Action.Initialize)
}

@(test)
ocean_spectral_initialization_is_independent_of_ring_allocation :: proc(t: ^testing.T) {
	state := Ocean_Spectral_Init_State.Pending
	ring_allocated := true
	action := ocean_spectral_init_action(state, true, true, false)
	testing.expect(t, ring_allocated)
	testing.expect_value(t, action, Ocean_Spectral_Init_Action.Initialize)
}

@(test)
ocean_spectral_initialization_preserves_terminal_fallbacks :: proc(t: ^testing.T) {
	unsupported := ocean_spectral_init_action(.Pending, false, true, false)
	failed := ocean_spectral_init_action(.Failed, true, true, false)
	ready := ocean_spectral_init_action(.Ready, true, true, false)
	testing.expect_value(t, unsupported, Ocean_Spectral_Init_Action.Unsupported)
	testing.expect_value(t, failed, Ocean_Spectral_Init_Action.None)
	testing.expect_value(t, ready, Ocean_Spectral_Init_Action.None)
}

@(test)
ocean_spectral_retry_only_rearms_a_failed_idle_renderer :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.spectral_init_state = .Failed
	renderer.spectral_failure_stage = .Uniform
	testing.expect(t, ocean_spectral_retry(renderer))
	testing.expect_value(t, renderer.spectral_init_state, Ocean_Spectral_Init_State.Pending)
	testing.expect_value(t, renderer.spectral_failure_stage, Ocean_Spectral_Failure_Stage.None)
	testing.expect(t, !ocean_spectral_retry(renderer))
	renderer.spectral_init_state = .Failed
	renderer.spectral.ready = true
	testing.expect(t, !ocean_spectral_retry(renderer))
}

@(test)
ocean_spectral_gaussian_is_deterministic_and_finite :: proc(t: ^testing.T) {
	first := ocean_spectral_gaussian(17, 3, 9)
	second := ocean_spectral_gaussian(17, 3, 9)
	other := ocean_spectral_gaussian(18, 3, 9)
	testing.expect_value(t, first, second)
	testing.expect(t, first != other)
	for component in first {
		testing.expect(t, !math.is_nan(component))
		testing.expect(t, !math.is_inf(component, 0))
	}
}

@(test)
ocean_spectral_shader_uses_independent_pairs_and_full_butterflies :: proc(t: ^testing.T) {
	testing.expect(t, len(OCEAN_SPECTRUM_INIT_SHADER) > 0)
	testing.expect(t, len(OCEAN_STOCKHAM_SHADER) > 0)
	testing.expect(t, len(OCEAN_SPECTRUM_EVOLVE_SHADER) > 0)
	butterfly_marker := "let sign = select(1.0, -1.0, offset >= span)"
	testing.expect(t, strings.contains(OCEAN_SPECTRUM_INIT_SHADER, "hash(id.xy)"))
	testing.expect(t, !strings.contains(OCEAN_SPECTRUM_INIT_SHADER, "canonical"))
	testing.expect(t, strings.contains(OCEAN_STOCKHAM_SHADER, butterfly_marker))
	testing.expect(t, strings.contains(OCEAN_SPECTRUM_EVOLVE_SHADER, "mirrored.x, -mirrored.y"))
	testing.expect(
		t,
		strings.contains(OCEAN_DERIVE_SHADER, "let fft_shift = select(1.0, -1.0, parity == 1)"),
	)
	testing.expect(
		t,
		strings.contains(OCEAN_DERIVE_SHADER, "return textureLoad(height, p, 0).x * fft_shift"),
	)
}

@(test)
ocean_far_water_shader_keeps_orbital_cues_without_near_refraction :: proc(t: ^testing.T) {
	testing.expect(
		t,
		strings.contains(FAR_WATER_SHADER, "let world = (model * vec4<f32>(position, 1.0)).xyz;"),
	)
	testing.expect(
		t,
		strings.contains(FAR_WATER_SHADER, "out.position = u.view_projection * vec4<f32>(world, 1.0);"),
	)
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "u.custom_params_7.y"))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "world +="))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "sin(phase)"))
	testing.expect(t, strings.contains(FAR_WATER_SHADER, "far_water_beyond_horizon"))
	testing.expect(t, strings.contains(FAR_WATER_SHADER, "atmosphere_sky"))
	testing.expect(t, strings.contains(FAR_WATER_SHADER, "atmosphere_apply"))
	testing.expect(t, strings.contains(FAR_WATER_SHADER, "storm"))
	testing.expect(t, strings.contains(FAR_WATER_SHADER, "smoothstep(0.5 - edge_width"))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "textureSample(scene_color_texture"))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "textureLoad(scene_depth_texture"))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "water_volume_integrate"))
	testing.expect(t, !strings.contains(FAR_WATER_SHADER, "spectral_sample"))
}

// The water sheet is transparent and writes no depth, so the far hemisphere of
// the globe must be discarded analytically or it draws over the sky at a
// grazing near-zoom angle. The rejection is suppressed when the eye is inside
// the fragment's radius so an underwater camera still sees the surface from
// below.
@(test)
ocean_water_shader_discards_the_far_horizon_but_stays_two_sided_underwater :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "fn water_beyond_horizon"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"if length(eye) <= length(world_position) { return false; }",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "return dot(eye - world_position, radial) < 0.0"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"if water_beyond_horizon(in.world_position, radial) { discard; }",
		),
	)
	// The rejection must precede the spectral cascade sampling it is meant to
	// short-circuit.
	horizon_index := strings.index(WATER_SHADER, "if water_beyond_horizon(in.world_position")
	cascade_index := strings.index(WATER_SHADER, "let spectral_0 = spectral_sample")
	testing.expect(t, horizon_index >= 0)
	testing.expect(t, cascade_index >= 0)
	testing.expect(t, horizon_index < cascade_index)
}

@(test)
ocean_water_shader_samples_all_spectral_cascades_in_world_space :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "textureSampleLevel"))
	testing.expect(t, strings.contains(WATER_SHADER, "dot(world, primary)"))
	testing.expect(t, strings.contains(WATER_SHADER, "mesh_texture, world"))
	testing.expect(t, strings.contains(WATER_SHADER, "mesh_normal_texture, world"))
	testing.expect(t, strings.contains(WATER_SHADER, "mesh_roughness_ao_texture, world"))
	scales := [3]string{"7.88", "30.76", "115.88"}
	for scale in scales {
		// One sample plus one distance fade per stage, plus the fragment pixel fade.
		testing.expect(t, strings.count(WATER_SHADER, scale) == 5)
		testing.expect(t, strings.count(WATER_SHADER, fmt.tprintf("secondary, %s,", scale)) == 2)
	}
	testing.expect(t, strings.contains(WATER_SHADER, "normalize(world) * packed.x * weight"))
	testing.expect(t, !strings.contains(WATER_SHADER, "tangent * tangent_scale"))
	testing.expect(
		t,
		!strings.contains(WATER_SHADER, "let spectral_scale = clamp(u.custom_params.x"),
	)
	testing.expect(t, !strings.contains(WATER_SHADER, "horizontal_direction * abs(packed.x)"))
	testing.expect(t, strings.contains(WATER_SHADER, "in.spectral_position"))
	testing.expect(t, strings.contains(WATER_SHADER, "cascade_0.displacement"))
	testing.expect(t, !strings.contains(WATER_SHADER, "spectral_0.slope"))
	testing.expect(t, strings.contains(WATER_SHADER, "cascade_0.jacobian"))
	testing.expect(t, !strings.contains(WATER_SHADER, "select(spectral_0"))
	testing.expect(t, strings.contains(WATER_SHADER, "sample = spectral_1"))
	testing.expect(t, strings.contains(WATER_SHADER, "sample = spectral_2"))
	testing.expect(t, !strings.contains(WATER_SHADER, "amplitude / 1.2"))
}

@(test)
ocean_packet_envelope_moves_at_group_velocity_while_crest_moves_at_phase_velocity :: proc(
	t: ^testing.T,
) {
	period := f32(9.625)
	phase_speed := 9.81 * period / f32(math.TAU)
	group_speed := phase_speed * 0.5
	testing.expect(t, abs(group_speed * 600 - 4_508.4) < 1)
	testing.expect(t, abs(phase_speed * 600 - 9_016.8) < 1)
}

@(test)
ocean_spectral_period_drives_physical_peak :: proc(t: ^testing.T) {
	omega := ocean_spectral_peak_omega(9.625)
	wavelength := ocean_spectral_deep_water_wavelength(9.625)
	testing.expect(t, omega > 0.65 && omega < 0.66)
	testing.expect(t, wavelength > 144 && wavelength < 146)
	testing.expect(t, OCEAN_SPECTRAL_ENERGY_WEIGHT[0] + OCEAN_SPECTRAL_ENERGY_WEIGHT[1] > 0.8)
}

@(test)
ocean_spectral_tma_is_continuous_and_bounded :: proc(t: ^testing.T) {
	testing.expect(t, abs(ocean_spectral_tma_factor_nondimensional(0)) < 0.0001)
	testing.expect(t, abs(ocean_spectral_tma_factor_nondimensional(1) - 0.5) < 0.0001)
	testing.expect(t, abs(ocean_spectral_tma_factor_nondimensional(2) - 1) < 0.0001)
	testing.expect(
		t,
		ocean_spectral_tma_factor_nondimensional(0.999) <
		ocean_spectral_tma_factor_nondimensional(1.001),
	)
	testing.expect(t, ocean_spectral_tma_factor_nondimensional(1.999) <= 1)
}

@(test)
ocean_spectral_finite_depth_reduces_frequency :: proc(t: ^testing.T) {
	k := f32(0.08)
	shallow := ocean_spectral_dispersion(k, 4)
	deep := ocean_spectral_dispersion(k, 4_000)
	testing.expect(t, shallow > 0)
	testing.expect(t, shallow < deep)
	testing.expect(t, abs(deep - math.sqrt(9.81 * k)) < 0.001)
}

@(test)
ocean_spectral_normalization_tracks_significant_height :: proc(t: ^testing.T) {
	weather := Ocean_Render_Spectrum {
		wind_sea_height = 2,
		peak_period     = 8,
		depth           = 64,
	}
	first := ocean_spectral_cascade_alpha(weather, 192, 128, 0.55)
	weather.wind_sea_height = 4
	second := ocean_spectral_cascade_alpha(weather, 192, 128, 0.55)
	testing.expect(t, first > 0)
	testing.expect(t, abs(second / first - 4) < 0.001)
}

@(test)
ocean_spectral_normalization_is_directionally_symmetric :: proc(t: ^testing.T) {
	weather := Ocean_Render_Spectrum {
		direction       = {1, 0, 0},
		wind_sea_height = 4,
		peak_period     = 8,
		depth           = 64,
	}
	east := ocean_spectral_cascade_alpha(weather, 192, 128, 0.55)
	weather.direction = {0, 1, 0}
	north := ocean_spectral_cascade_alpha(weather, 192, 128, 0.55)
	testing.expect(t, east > 0)
	testing.expect(t, abs(east - north) / east < 0.01)
}

@(test)
ocean_spectral_swell_only_energy_favors_long_cascades :: proc(t: ^testing.T) {
	weather := Ocean_Render_Spectrum {
		swell_height = 3,
		peak_period  = 12,
		depth        = 64,
	}
	short := ocean_spectral_cascade_alpha(
		weather,
		192,
		128,
		0,
		OCEAN_SPECTRAL_SWELL_ENERGY_WEIGHT[0],
	)
	long := ocean_spectral_cascade_alpha(
		weather,
		3_072,
		128,
		0,
		OCEAN_SPECTRAL_SWELL_ENERGY_WEIGHT[2],
	)
	testing.expect(t, short > 0)
	testing.expect(t, long > short)
}

@(test)
ocean_spectral_weather_threshold_preserves_continuity :: proc(t: ^testing.T) {
	first := Ocean_Render_Spectrum {
		direction       = {1, 0, 0},
		wind_sea_height = 2,
		peak_period     = 8,
		depth           = 64,
	}
	close := first
	close.wind_sea_height += 0.1
	testing.expect(t, !ocean_spectral_weather_changed(first, close))
	close.wind_sea_height += 0.2
	testing.expect(t, ocean_spectral_weather_changed(first, close))
	close = first
	close.swell_height = 0.25
	testing.expect(t, ocean_spectral_weather_changed(first, close))
}

@(test)
ocean_spectral_choppiness_tracks_weather_and_is_bounded :: proc(t: ^testing.T) {
	calm := ocean_spectral_choppiness({})
	windy := ocean_spectral_choppiness({wind_speed = 24, wind_sea_height = 2})
	storm := ocean_spectral_choppiness({wind_speed = 60, wind_sea_height = 8, breaking = 1})
	testing.expect_value(t, calm, f32(0.35))
	testing.expect(t, calm < windy && windy < storm)
	testing.expect_value(t, storm, f32(1.5))
}

@(test)
ocean_water_shader_combines_authoritative_wind_sea_packets_and_chop :: proc(t: ^testing.T) {
	testing.expect(t, strings.contains(WATER_SHADER, "fn wind_sea_field"))
	testing.expect(t, strings.contains(WATER_SHADER, "fn wave_packet_field"))
	testing.expect(t, strings.contains(WATER_SHADER, "let packet_period = max(direction_period.w, 0.25);"))
	testing.expect(t, strings.contains(WATER_SHADER, "select(sin(carrier) * 0.78 + sin(sideband) * 0.22, sin(carrier), debug_packet) * packet_amplitude"))
	testing.expect(t, strings.contains(WATER_SHADER, "let debug_limit = 0.5 * min(packet_height, max(depth, 0.0) * 0.78) * wet;"))
	testing.expect(t, strings.contains(WATER_SHADER, "radial * height + primary * cos(carrier) * packet_amplitude * 0.48"))
	testing.expect(t, strings.contains(WATER_SHADER, "let directional_envelope = exp"))
	testing.expect(t, strings.contains(WATER_SHADER, "let supplied_world = direction_period.xyz"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let centre_tangent = supplied_world - packet_center_radial * dot(supplied_world, packet_center_radial)",
		),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let radial_packet = length(supplied_world) > 0.0001 && length(centre_tangent) <= 0.001 * length(supplied_world)",
		),
	)
	testing.expect(t, !strings.contains(WATER_SHADER, "let radial_packet = length(supplied)"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let radial_distance = 2.0 * asin(min(length(radial - packet_center_radial) * 0.5, 1.0)) * 1080.0",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "let front_speed = length(supplied_world);"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let ring_front = envelope_phase.x + front_speed * max(t - phase_epoch, 0.0)",
		),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"exp(-ring_offset * ring_offset / (packet_width * packet_width))",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "abs(ring_offset) <= packet_width * 2.0"))
	testing.expect(t, strings.contains(WATER_SHADER, "wave_number - omega * t)"))
	testing.expect(t, !strings.contains(WATER_SHADER, "let time_scale = select(1.0, 32.0"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let carrier_coordinate = select(directional_coordinate, radial_distance",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "@location(5) wave_data: vec3<f32>"))
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let orbital_ring = smoothstep(600.0, 2400.0, eye_altitude)",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "sqrt(max(1.0 - packet_mix * packet_mix"))
	testing.expect(t, strings.contains(WATER_SHADER, "packet_displacement;"))
	testing.expect(t, strings.contains(WATER_SHADER, "let period = max(u.custom_params_7.x, 2.0)"))
	testing.expect(t, strings.contains(WATER_SHADER, "let packet_height = clamp(center_height.w"))
	testing.expect(t, strings.contains(WATER_SHADER, "let packet_count = params_7_w & 7u"))
	testing.expect(t, strings.contains(WATER_SHADER, "packet_index < packet_count"))
	testing.expect(t, !strings.contains(WATER_SHADER, "u32(u.custom_params_7.w)"))
	testing.expect(t, strings.contains(WATER_SHADER, "displacement_mode < 0.0"))
	testing.expect(t, strings.contains(WATER_SHADER, "select(gpu_displacement, vec3<f32>(0.0)"))
	testing.expect(
		t,
		strings.contains(OCEAN_DERIVE_SHADER, "vec4<f32>(center, 0.0, 0.0, jacobian)"),
	)
	testing.expect(t, !strings.contains(OCEAN_DERIVE_SHADER, "let horizontal ="))
	testing.expect(t, !strings.contains(WATER_SHADER, "shore_noise"))
	testing.expect(t, strings.contains(WATER_SHADER, "bubble_support"))
	testing.expect(t, strings.contains(WATER_SHADER, "let displacement = radial * height"))
	testing.expect(t, !strings.contains(WATER_SHADER, "let radial_limit = min(amplitude"))
	testing.expect(
		t,
		!strings.contains(WATER_SHADER, "mix(wind_sea.displacement, packet.displacement"),
	)
}

@(test)
ocean_water_shader_fades_each_cascade_at_its_own_resolution :: proc(t: ^testing.T) {
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "fn cascade_distance_resolved(scale: f32, dist: f32)"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "smoothstep(scale * 12.0, scale * 40.0, dist)"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"fn cascade_pixel_resolved(coordinates: vec2<f32>, scale: f32, resolution: f32)",
		),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "/ scale * resolution"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "scale: f32, resolved: f32) -> SpectralSample"),
	)
	testing.expect(t, strings.contains(WATER_SHADER, "mix(1.0, packed.w, weight)"))
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "cascade_pixel_resolved(spectral_uv, 7.88, 256.0)"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "cascade_pixel_resolved(spectral_uv, 30.76, 128.0)"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "cascade_pixel_resolved(spectral_uv, 115.88, 128.0)"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "cascade_distance_resolved(7.88, camera_dist)"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let mean_square_slope = clamp(0.003 + 0.025 * u.custom_params.x",
		),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"(1.0 - resolved_0) * 0.55 + (1.0 - resolved_1) * 0.35 + (1.0 - resolved_2) * 0.10",
		),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "let wavelength = 6.28318530718 / wave_number"),
	)
	testing.expect(
		t,
		strings.contains(WATER_SHADER, "amplitude * cascade_distance_resolved(wavelength, dist)"),
	)
	testing.expect(t, !strings.contains(WATER_SHADER, "let orbital_wave"))
	testing.expect(t, !strings.contains(WATER_SHADER, "smoothstep(80.0, 900.0, dist)"))
	testing.expect(
		t,
		!strings.contains(WATER_SHADER, "min(dot(spectral_slope, spectral_slope), 0.18)"),
	)
	testing.expect(
		t,
		strings.contains(
			WATER_SHADER,
			"let orbital_ring = smoothstep(600.0, 2400.0, eye_altitude)",
		),
	)
}

@(test)
ocean_spectral_state_does_not_require_resources :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	ocean_spectral_apply_state(
		renderer,
		{significant_height = 4, wind_sea_height = 3, peak_period = 9.625, direction = {0, 1, 0}},
	)
	testing.expect(t, !renderer.spectral.ready)
	testing.expect_value(t, renderer.spectral.phase, f32(0))
}

@(test)
ocean_packet_state_is_owned_by_macro_query :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.render_query.packets[0] = {
		id                 = 17,
		center             = {1_080, 0, 0},
		direction          = {0, 1, 0},
		significant_height = 4,
		period             = 9.625,
		envelope_length    = 1_160,
		envelope_width     = 2_320,
	}
	renderer.render_query.packet_ids[0] = 17
	renderer.render_query.packet_count = 1
	ocean_spectral_apply_state(renderer, {})
	testing.expect_value(t, renderer.render_query.packet_count, 1)
	testing.expect_value(t, renderer.render_query.packet_ids[0], u32(17))
	testing.expect_value(t, renderer.render_query.packets[0].significant_height, f32(4))
}

@(test)
ocean_spectral_state_does_not_mutate_macro_packets :: proc(t: ^testing.T) {
	renderer := new(Ocean_Renderer)
	defer free(renderer)
	renderer.render_query.packet_count = 1
	renderer.render_query.packet_ids[0] = 4
	for _ in 0 ..< 120 {
		ocean_spectral_apply_state(renderer, {significant_height = 6, wind_sea_height = 6})
	}
	testing.expect_value(t, renderer.render_query.packet_count, 1)
	testing.expect_value(t, renderer.render_query.packet_ids[0], u32(4))
}
