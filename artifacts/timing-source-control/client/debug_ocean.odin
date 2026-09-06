package main

import "core:fmt"

Planet_Debug_Section :: enum u8 {
	Atmosphere,
	Ocean_State,
	Ocean_Rendering,
	Ocean_Clipmap,
	Ocean_Gpu,
}

console_ocean_status :: proc(value: ^Client_State) {
	assert(value != nil, "console_ocean_status: nil state")
	renderer := &value.terrain.ocean
	status := ocean_pipeline_status(renderer, value.terrain.water_shader.id)
	draw := renderer.draw_diagnostics
	console_print(value.console.terminal, fmt.tprintf("[planetforger] ocean %s", status.verdict))
	console_print(
		value.console.terminal,
		fmt.tprintf(
			"[planetforger] shader created=%d submitted=%d match=%v draws=%d/%d/%d",
			value.terrain.water_shader.id,
			draw.shader_id,
			status.custom_shader_submitted,
			draw.near_draw_count,
			draw.far_draw_count,
			draw.breaker_draw_count,
		),
	)
	console_print(
		value.console.terminal,
		fmt.tprintf(
			"[planetforger] spectral init=%v source=%v ready=%v serial=%d textures=%d/%d/%d",
			renderer.spectral_init_state,
			renderer.wave_source,
			renderer.spectral.ready,
			renderer.spectral_update_serial,
			draw.spectral_texture_ids[0],
			draw.spectral_texture_ids[1],
			draw.spectral_texture_ids[2],
		),
	)
	console_print(
		value.console.terminal,
		fmt.tprintf(
			"[planetforger] scene=%d/%d valid=%v failure=%v cascade=%d count=%d",
			draw.scene_color_id,
			draw.scene_depth_id,
			status.scene_inputs_valid,
			renderer.spectral_failure_stage,
			renderer.spectral_failure_cascade,
			renderer.spectral_failure_count,
		),
	)
}

Sim_Proof_Type :: enum u8 {
	None,
	Wind,
	Currents,
}

Sim_Proof_Settings :: struct {
	proof:           Sim_Proof_Type,
	density_scale:   f32,
	length_scale:    f32,
	lift:            f32,
	opacity:         f32,
	reference_speed: f32,
	pulse_speed:     f32,
	pulse_strength:  f32,
}

sim_proof_settings_default :: proc() -> Sim_Proof_Settings {
	return {
		proof = .None,
		density_scale = 1,
		length_scale = 1,
		lift = 2,
		opacity = 0.72,
		reference_speed = 40,
		pulse_speed = 1,
		pulse_strength = 0.35,
	}
}

sim_proof_settings_sanitize :: proc(settings: ^Sim_Proof_Settings) {
	assert(settings != nil, "sim proof settings: nil settings")
	if settings.proof > .Currents do settings.proof = .None
	settings.density_scale = clamp(settings.density_scale, 0.25, 2)
	settings.length_scale = clamp(settings.length_scale, 0.25, 2.5)
	settings.lift = clamp(settings.lift, 0.25, 12)
	settings.opacity = clamp(settings.opacity, 0.05, 1)
	settings.reference_speed = clamp(settings.reference_speed, 5, 120)
	settings.pulse_speed = clamp(settings.pulse_speed, 0, 4)
	settings.pulse_strength = clamp(settings.pulse_strength, 0, 1)
}

Water_Medium_Settings :: struct {
	absorption_scale: f32,
	scatter_scale:    f32,
	turbidity_scale:  f32,
}

Ocean_Proof_View :: enum u8 {
	Composite,
	Custom_Shader,
	Cascade_0,
	Cascade_1,
	Cascade_2,
	Jacobian_Foam,
	Spectral_Macro,
}

Ocean_Visual_Settings :: struct {
	automatic_weather:        bool,
	cloud_scale:              f32,
	fog_scale:                f32,
	sun_scale:                f32,
	ambient_scale:            f32,
	manual_cloud_coverage:    f32,
	manual_fog_density:       f32,
	manual_sun_intensity:     f32,
	manual_ambient_intensity: f32,
	storm_radius_km:          f32,
	storm_intensity:          f32,
	storm_wind_speed:         f32,
	storm_wind_heading:       f32,
	wave_amplitude_scale:     f32,
	bubble_strength:          f32,
	roughness:                f32,
	reflection_strength:      f32,
	foam_strength:            f32,
	foam_crest:               f32,
	foam_shore:               f32,
	foam_wind:                f32,
	absorption_scale:         f32,
	scatter_scale:            f32,
	water_medium:             [3]Water_Medium_Settings,
	underwater_enter_depth:   f32,
	underwater_exit_height:   f32,
	underwater_transition:    f32,
	ring_visible:             [OCEAN_CLIPMAP_RING_COUNT]bool,
	ring_radius:              [OCEAN_CLIPMAP_RING_COUNT]f32,
	rebuild_threshold:        f32,
	near_altitude_limit:      f32,
	middle_altitude_limit:    f32,
	proof_view:               Ocean_Proof_View,
}

ocean_visual_settings_default :: proc() -> Ocean_Visual_Settings {
	return {
		automatic_weather = true,
		cloud_scale = 1,
		fog_scale = 1,
		sun_scale = 1,
		ambient_scale = 1,
		manual_cloud_coverage = 0.25,
		manual_fog_density = 0.003,
		manual_sun_intensity = 0.9,
		manual_ambient_intensity = 0.35,
		storm_radius_km = 300,
		storm_intensity = 0.75,
		storm_wind_speed = 30,
		storm_wind_heading = 0,
		wave_amplitude_scale = 1,
		bubble_strength = 0.7,
		roughness = 0.09,
		reflection_strength = 1,
		foam_strength = 1,
		foam_crest = 0.28,
		foam_shore = 1,
		foam_wind = 0,
		absorption_scale = 1,
		scatter_scale = 1,
		water_medium = {
			{1, 1, 0.25},
			{1.25, 1.35, 0.45},
			{1.6, 1.7, 0.8},
		},
		underwater_enter_depth = 0.15,
		underwater_exit_height = 0.30,
		underwater_transition = 0.35,
		ring_visible = {true, true, true},
		ring_radius = {180, 540, 1_800},
		rebuild_threshold = 0.002,
		near_altitude_limit = 480,
		middle_altitude_limit = 1_200,
	}
}

ocean_visual_settings_sanitize :: proc(settings: ^Ocean_Visual_Settings) {
	assert(settings != nil, "ocean visual settings: nil settings")
	settings.cloud_scale = clamp(settings.cloud_scale, 0, 2)
	settings.fog_scale = clamp(settings.fog_scale, 0, 2)
	settings.sun_scale = clamp(settings.sun_scale, 0, 2)
	settings.ambient_scale = clamp(settings.ambient_scale, 0, 2)
	settings.manual_cloud_coverage = clamp(settings.manual_cloud_coverage, 0, 1)
	settings.manual_fog_density = clamp(settings.manual_fog_density, 0, 0.05)
	settings.manual_sun_intensity = clamp(settings.manual_sun_intensity, 0, 2)
	settings.manual_ambient_intensity = clamp(settings.manual_ambient_intensity, 0, 1)
	settings.storm_radius_km = clamp(settings.storm_radius_km, 25, 2_000)
	settings.storm_intensity = clamp(settings.storm_intensity, 0, 1)
	settings.storm_wind_speed = clamp(settings.storm_wind_speed, 0, 200)
	settings.storm_wind_heading = clamp(settings.storm_wind_heading, 0, 360)
	settings.wave_amplitude_scale = clamp(settings.wave_amplitude_scale, 0, 3)
	settings.bubble_strength = clamp(settings.bubble_strength, 0, 2)
	settings.roughness = clamp(settings.roughness, 0.02, 0.8)
	settings.reflection_strength = clamp(settings.reflection_strength, 0, 2)
	settings.foam_strength = clamp(settings.foam_strength, 0, 3)
	settings.foam_crest = clamp(settings.foam_crest, 0, 2)
	settings.foam_shore = clamp(settings.foam_shore, 0, 2)
	settings.foam_wind = clamp(settings.foam_wind, 0, 2)
	settings.absorption_scale = clamp(settings.absorption_scale, 0, 3)
	settings.scatter_scale = clamp(settings.scatter_scale, 0, 3)
	for &medium in settings.water_medium {
		medium.absorption_scale = clamp(medium.absorption_scale, 0, 3)
		medium.scatter_scale = clamp(medium.scatter_scale, 0, 3)
		medium.turbidity_scale = clamp(medium.turbidity_scale, 0, 4)
	}
	settings.underwater_enter_depth = clamp(settings.underwater_enter_depth, 0.01, 2)
	settings.underwater_exit_height = clamp(
		settings.underwater_exit_height,
		settings.underwater_enter_depth,
		4,
	)
	settings.underwater_transition = clamp(settings.underwater_transition, 0.05, 3)
	settings.ring_radius[0] = clamp(settings.ring_radius[0], 60, 600)
	settings.ring_radius[1] = clamp(settings.ring_radius[1], settings.ring_radius[0] + 60, 1_200)
	settings.ring_radius[2] = clamp(settings.ring_radius[2], settings.ring_radius[1] + 60, 2_400)
	settings.rebuild_threshold = clamp(settings.rebuild_threshold, 0.0005, 0.02)
	settings.near_altitude_limit = clamp(settings.near_altitude_limit, 100, 2_000)
	settings.middle_altitude_limit = clamp(
		settings.middle_altitude_limit,
		settings.near_altitude_limit,
		5_000,
	)
	if settings.proof_view > .Spectral_Macro do settings.proof_view = .Composite
}

ocean_visual_wind_direction :: proc(summary: Ocean_Weather_Summary) -> [3]f32 {
	direction := summary.wind_direction
	length_squared := direction.x * direction.x + direction.y * direction.y + direction.z * direction.z
	if length_squared <= 0.000001 do direction = summary.direction
	return direction
}

ocean_visual_material_params :: proc(
	settings: Ocean_Visual_Settings,
	summary: Ocean_Weather_Summary,
) -> (
	[4]f32,
	[4]f32,
	[4]f32,
	[4]f32,
) {
	significant_height := f32(0)
	if settings.wave_amplitude_scale > 0 {
		significant_height = ocean_continuous_wave_height(
			summary.wind_sea_height,
			summary.swell_height,
		) * settings.wave_amplitude_scale
		if significant_height <= 0 {
			significant_height = summary.significant_height * settings.wave_amplitude_scale
		}
	}
	wind_direction := ocean_visual_wind_direction(summary)
	primary := [4]f32 {
		clamp(significant_height, 0, 20),
		wind_direction.x,
		wind_direction.y,
		wind_direction.z,
	}
	lighting := [4]f32 {
		settings.bubble_strength,
		settings.roughness,
		settings.reflection_strength,
		settings.foam_strength,
	}
	foam := [4]f32 {
		settings.foam_crest,
		settings.foam_shore,
		clamp(summary.storm_energy, f32(0), f32(1)),
		summary.breaking,
	}
	medium := [4]f32 {
		settings.absorption_scale,
		settings.scatter_scale,
		0,
		0,
	}
	return primary, lighting, foam, medium
}

settings_demo_defaults :: proc(value: ^Client_State) {
	assert(value != nil, "settings_demo_defaults: nil state")
	value.ocean_visual = ocean_visual_settings_default()
	value.sim_proof_settings = sim_proof_settings_default()
}

settings_demo_load :: proc(value: ^Client_State, key, text: string) -> bool {
	assert(value != nil, "settings_demo_load: nil state")
	settings := &value.ocean_visual
	proof_settings := &value.sim_proof_settings
	parsed := debug_parse_f32(text, 1)
	switch key {
	case "ocean_auto_weather":
		settings.automatic_weather = text != "0"
	case "ocean_cloud_scale":
		settings.cloud_scale = parsed
	case "ocean_fog_scale":
		settings.fog_scale = parsed
	case "ocean_sun_scale":
		settings.sun_scale = parsed
	case "ocean_ambient_scale":
		settings.ambient_scale = parsed
	case "weather_manual_cloud":
		settings.manual_cloud_coverage = parsed
	case "weather_manual_fog":
		settings.manual_fog_density = parsed
	case "weather_manual_sun":
		settings.manual_sun_intensity = parsed
	case "weather_manual_ambient":
		settings.manual_ambient_intensity = parsed
	case "weather_storm_radius_km":
		settings.storm_radius_km = parsed
	case "weather_storm_intensity":
		settings.storm_intensity = parsed
	case "weather_storm_wind_speed":
		settings.storm_wind_speed = parsed
	case "weather_storm_wind_heading":
		settings.storm_wind_heading = parsed
	case "ocean_wave_scale":
		settings.wave_amplitude_scale = parsed
	case "ocean_bubbles", "ocean_ripple":
		settings.bubble_strength = parsed
	case "ocean_roughness":
		settings.roughness = parsed
	case "ocean_reflection":
		settings.reflection_strength = parsed
	case "ocean_foam":
		settings.foam_strength = parsed
	case "ocean_foam_crest":
		settings.foam_crest = parsed
	case "ocean_foam_shore":
		settings.foam_shore = parsed
	case "ocean_foam_wind":
		settings.foam_wind = parsed
	case "ocean_absorption":
		settings.absorption_scale = parsed
	case "ocean_scatter":
		settings.scatter_scale = parsed
	case "water_ocean_absorption":
		settings.water_medium[0].absorption_scale = parsed
	case "water_ocean_scatter":
		settings.water_medium[0].scatter_scale = parsed
	case "water_ocean_turbidity":
		settings.water_medium[0].turbidity_scale = parsed
	case "water_lake_absorption":
		settings.water_medium[1].absorption_scale = parsed
	case "water_lake_scatter":
		settings.water_medium[1].scatter_scale = parsed
	case "water_lake_turbidity":
		settings.water_medium[1].turbidity_scale = parsed
	case "water_river_absorption":
		settings.water_medium[2].absorption_scale = parsed
	case "water_river_scatter":
		settings.water_medium[2].scatter_scale = parsed
	case "water_river_turbidity":
		settings.water_medium[2].turbidity_scale = parsed
	case "water_underwater_enter_depth":
		settings.underwater_enter_depth = parsed
	case "water_underwater_exit_height":
		settings.underwater_exit_height = parsed
	case "water_underwater_transition":
		settings.underwater_transition = parsed
	case "ocean_ring_0_visible":
		settings.ring_visible[0] = text != "0"
	case "ocean_ring_1_visible":
		settings.ring_visible[1] = text != "0"
	case "ocean_ring_2_visible":
		settings.ring_visible[2] = text != "0"
	case "ocean_ring_0_radius":
		settings.ring_radius[0] = parsed
	case "ocean_ring_1_radius":
		settings.ring_radius[1] = parsed
	case "ocean_ring_2_radius":
		settings.ring_radius[2] = parsed
	case "ocean_rebuild_threshold":
		settings.rebuild_threshold = parsed
	case "ocean_near_altitude":
		settings.near_altitude_limit = parsed
	case "ocean_middle_altitude":
		settings.middle_altitude_limit = parsed
	case "sim_proof_type":
		proof_settings.proof = Sim_Proof_Type(clamp(i32(parsed), i32(Sim_Proof_Type.None), i32(Sim_Proof_Type.Currents)))
	case "sim_proof_density", "wind_visual_density":
		proof_settings.density_scale = parsed
	case "sim_proof_length", "wind_visual_length":
		proof_settings.length_scale = parsed
	case "sim_proof_lift", "wind_visual_lift":
		proof_settings.lift = parsed
	case "sim_proof_opacity", "wind_visual_opacity":
		proof_settings.opacity = parsed
	case "sim_proof_reference_speed", "wind_visual_reference_speed":
		proof_settings.reference_speed = parsed
	case "sim_proof_pulse_speed", "wind_visual_pulse_speed":
		proof_settings.pulse_speed = parsed
	case "sim_proof_pulse_strength", "wind_visual_pulse_strength":
		proof_settings.pulse_strength = parsed
	case "wind_visual_enabled":
		proof_settings.proof = .Wind if text != "0" else .None
	case:
		return false
	}
	ocean_visual_settings_sanitize(settings)
	sim_proof_settings_sanitize(proof_settings)
	return true
}

settings_demo_text :: proc(value: ^Client_State) -> string {
	assert(value != nil, "settings_demo_text: nil state")
	s := &value.ocean_visual
	proof := &value.sim_proof_settings
	return fmt.tprintf(
		"ocean_auto_weather=%d\nocean_cloud_scale=%.3f\nocean_fog_scale=%.3f\n" +
		"ocean_sun_scale=%.3f\nocean_ambient_scale=%.3f\n" +
		"weather_manual_cloud=%.3f\nweather_manual_fog=%.4f\n" +
		"weather_manual_sun=%.3f\nweather_manual_ambient=%.3f\n" +
		"weather_storm_radius_km=%.1f\nweather_storm_intensity=%.3f\n" +
		"weather_storm_wind_speed=%.1f\nweather_storm_wind_heading=%.1f\n" +
		"ocean_wave_scale=%.3f\nocean_bubbles=%.3f\nocean_roughness=%.3f\n" +
		"ocean_reflection=%.3f\n" +
		"ocean_foam=%.3f\nocean_foam_crest=%.3f\nocean_foam_shore=%.3f\n" +
		"ocean_foam_wind=%.3f\nocean_absorption=%.3f\nocean_scatter=%.3f\n" +
		"water_ocean_absorption=%.3f\nwater_ocean_scatter=%.3f\nwater_ocean_turbidity=%.3f\n" +
		"water_lake_absorption=%.3f\nwater_lake_scatter=%.3f\nwater_lake_turbidity=%.3f\n" +
		"water_river_absorption=%.3f\nwater_river_scatter=%.3f\nwater_river_turbidity=%.3f\n" +
		"water_underwater_enter_depth=%.3f\nwater_underwater_exit_height=%.3f\n" +
		"water_underwater_transition=%.3f\n" +
		"ocean_ring_0_visible=%d\nocean_ring_1_visible=%d\nocean_ring_2_visible=%d\n" +
		"ocean_ring_0_radius=%.3f\nocean_ring_1_radius=%.3f\nocean_ring_2_radius=%.3f\n" +
		"ocean_rebuild_threshold=%.4f\nocean_near_altitude=%.3f\n" +
		"ocean_middle_altitude=%.3f\n" +
		"sim_proof_type=%d\nsim_proof_density=%.3f\nsim_proof_length=%.3f\n" +
		"sim_proof_lift=%.3f\nsim_proof_opacity=%.3f\nsim_proof_reference_speed=%.3f\n" +
		"sim_proof_pulse_speed=%.3f\nsim_proof_pulse_strength=%.3f\n",
		int(s.automatic_weather),
		s.cloud_scale,
		s.fog_scale,
		s.sun_scale,
		s.ambient_scale,
		s.manual_cloud_coverage,
		s.manual_fog_density,
		s.manual_sun_intensity,
		s.manual_ambient_intensity,
		s.storm_radius_km,
		s.storm_intensity,
		s.storm_wind_speed,
		s.storm_wind_heading,
		s.wave_amplitude_scale,
		s.bubble_strength,
		s.roughness,
		s.reflection_strength,
		s.foam_strength,
		s.foam_crest,
		s.foam_shore,
		s.foam_wind,
		s.absorption_scale,
		s.scatter_scale,
		s.water_medium[0].absorption_scale,
		s.water_medium[0].scatter_scale,
		s.water_medium[0].turbidity_scale,
		s.water_medium[1].absorption_scale,
		s.water_medium[1].scatter_scale,
		s.water_medium[1].turbidity_scale,
		s.water_medium[2].absorption_scale,
		s.water_medium[2].scatter_scale,
		s.water_medium[2].turbidity_scale,
		s.underwater_enter_depth,
		s.underwater_exit_height,
		s.underwater_transition,
		int(s.ring_visible[0]),
		int(s.ring_visible[1]),
		int(s.ring_visible[2]),
		s.ring_radius[0],
		s.ring_radius[1],
		s.ring_radius[2],
		s.rebuild_threshold,
		s.near_altitude_limit,
		s.middle_altitude_limit,
		int(proof.proof),
		proof.density_scale,
		proof.length_scale,
		proof.lift,
		proof.opacity,
		proof.reference_speed,
		proof.pulse_speed,
		proof.pulse_strength,
	)
}

game_prefs_app :: proc() -> string {
	return "planetforger"
}
