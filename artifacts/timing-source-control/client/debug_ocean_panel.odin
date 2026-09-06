package main

import shared "../shared"
import "core:fmt"
import "core:math"
import rl "ingot:gfx"

OCEAN_DEBUG_KEY_BASE :: u32(1_000)
OCEAN_DEBUG_TEST_PULSE_ID :: u32(0xFFFF_FFFE)
OCEAN_DEBUG_TEST_PULSE_TIME_SCALE :: f32(1)
OCEAN_DEBUG_TEST_PULSE_RADIUS :: f32(OCEAN_NEARSHORE_RADIUS * 2)

debug_ocean_test_pulse_id: u32
debug_ocean_test_pulse_height: f32 = 6.1
debug_ocean_test_pulse_interval: f32 = 1
debug_ocean_test_pulse_duration: f32 = 8
debug_ocean_test_pulse_pinned: bool
debug_ocean_test_pulse_source: [3]f32
debug_ocean_fixture_time_scale: f32 = 1
debug_ocean_pulse_directional: bool
debug_ocean_pulse_heading: f32

debug_ocean_fixture_query_update :: proc(renderer: ^Ocean_Renderer) {
	assert(renderer.nearshore.fixture_active)
	renderer.render_query = {
		center_direction = renderer.nearshore.focus,
		field_revision = renderer.render_query.field_revision + 1,
		ready = true,
	}
	renderer.macro.spectrum = {
		direction = renderer.nearshore.east,
		peak_period = 8,
	}
	ocean_macro_query_debug_packet_merge(&renderer.render_query, renderer.debug_pulse, renderer.debug_pulse_active)
}

debug_ocean_fixture_cancel_pending_tick :: proc(renderer: ^Ocean_Renderer) {
	if !renderer.nearshore.fixture_active do return
	renderer.nearshore.tick_pending = false
	renderer.nearshore.time_backlog = 0
	renderer.nearshore.last_advanced_time = 0
}

debug_ocean_stop_test_pulse :: proc(value: ^Client_State) {
	if value.terrain.ocean.nearshore.fixture_active {
		_ = ocean_surf_source_submit(value, {}, true)
		return
	}
	debug_ocean_test_pulse_clear(value)
}

debug_ocean_test_pulse_clear :: proc(value: ^Client_State) {
	renderer := &value.terrain.ocean
	renderer.debug_pulse_active = false
	renderer.debug_pulse = {}
	debug_ocean_test_pulse_id = 0
	debug_ocean_fixture_cancel_pending_tick(renderer)
	renderer.breakers.fronts = {}
	renderer.breakers.front_count = 0
	renderer.breakers.rejected_offshore = 0
	renderer.breakers.rejected_envelope = 0
	renderer.breakers.rejected_class = 0
	renderer.breakers.rejected_phase = 0
	renderer.breakers.mesh_dirty = false
	renderer.breakers.vertex_count = 0
	renderer.breakers.index_count = 0
	renderer.breakers.spray = {}
	renderer.breakers.spray_count = 0
	renderer.breakers.emitted_cycles = {}
	renderer.breakers.debug_impact_crests = {}
	renderer.breakers.debug_impact_valid = {}
	if renderer.nearshore.fixture_active {
		debug_ocean_fixture_query_update(renderer)
	} else {
		_ = ocean_macro_query_update(&renderer.render_query, &value.world, renderer.focus_direction, renderer.macro.time)
	}
	renderer.geometry_dirty = true
}

debug_ocean_reset_fixture :: proc(value: ^Client_State, focus: [3]f32, kind: Ocean_Surf_Fixture) {
	_, valid := ocean_wave_normalize(focus)
	if !valid do return
	surfboard_deinit(value)
	value.planet_cutaway = false
	value.sculpt_active = false
	value.balance.active = false
	renderer := &value.terrain.ocean
	if !renderer.fixture_clock_saved {
		renderer.fixture_saved_macro = renderer.macro
		renderer.fixture_saved_spectral_dt = renderer.spectral_pending_dt
		renderer.fixture_clock_saved = true
	}
	debug_ocean_test_pulse_clear(value)
	ocean_surf_events_reset(&renderer.surf_events)
	renderer.surf_ledger = {}
	ocean_surf_fixture_init(&renderer.nearshore, focus, kind)
	renderer.fixture_render.ready = false
	renderer.macro.time = 0
	renderer.macro.previous_time = 0
	renderer.macro.accumulator = 0
	renderer.macro.step_count = 0
	renderer.surf_dropped_time = 0
	renderer.breakers.last_time = 0
	renderer.spectral_pending_dt = 0
	debug_ocean_test_pulse_source = renderer.nearshore.focus
	debug_ocean_test_pulse_pinned = true
	debug_ocean_fixture_query_update(renderer)
}

debug_ocean_exit_fixture :: proc(value: ^Client_State) {
	surfboard_deinit(value)
	renderer := &value.terrain.ocean
	_, focus_valid := ocean_wave_normalize(renderer.focus_direction)
	if !focus_valid do renderer.focus_direction = renderer.nearshore.focus
	debug_ocean_fixture_cancel_pending_tick(renderer)
	renderer.nearshore.fixture_active = false
	renderer.nearshore.ready = false
	if renderer.fixture_clock_saved {
		renderer.macro = renderer.fixture_saved_macro
		renderer.spectral_pending_dt = renderer.fixture_saved_spectral_dt
		renderer.fixture_saved_macro = {}
		renderer.fixture_saved_spectral_dt = 0
		renderer.fixture_clock_saved = false
	}
	renderer.breakers.last_time = renderer.macro.time
	debug_ocean_test_pulse_pinned = false
	debug_ocean_test_pulse_clear(value)
	ocean_surf_events_reset(&renderer.surf_events)
	renderer.surf_ledger = {}
	summary := weather_ocean_sample(&renderer.weather, renderer.focus_direction)
	renderer.macro.spectrum = weather_ocean_render_spectrum(&value.world, renderer.focus_direction, summary)
}

debug_ocean_test_pulse_action :: proc(height: f32) -> u64 {
	height_mm := u64(clamp(height, f32(0.5), f32(20)) * 1_000 + 0.5)
	quarter_height := height_mm / 4
	return quarter_height * quarter_height
}

debug_ocean_test_pulse_front_speed :: proc(group_speed: f32) -> f32 {
	return max(
		group_speed / OCEAN_RENDER_METERS_PER_UNIT * OCEAN_DEBUG_TEST_PULSE_TIME_SCALE,
		f32(0.001),
	)
}

debug_ocean_test_pulse_retention :: proc(packet: Ocean_Render_Packet) -> f32 {
	return(
		(OCEAN_DEBUG_TEST_PULSE_RADIUS + packet.band * OCEAN_RING_ENVELOPE_SIGMAS) /
		max(packet.front_speed, f32(0.001)) \
	)
}

debug_ocean_test_pulse_update :: proc(packet: ^Ocean_Render_Packet, active: ^bool, elapsed: f32) {
	assert(packet != nil && active != nil, "debug ocean pulse update: nil input")
	if !active^ || elapsed <= 0 do return
	packet.total_travel += elapsed
	if packet.total_travel >= debug_ocean_test_pulse_retention(packet^) do active^ = false
}

Debug_Ocean_Test_Pulse_Metrics :: struct {
	selected_id:         u32,
	significant_height:  f32,
	envelope_overlap:    f32,
	radial_displacement: f32,
	velocity:            f32,
}

debug_ocean_test_pulse_build :: proc(value: ^Client_State) -> (packet: Ocean_Render_Packet, valid: bool) {
	assert(value != nil, "debug ocean inject pulse: nil state")
	renderer := &value.terrain.ocean
	planet := &value.world.planetary
	source := renderer.focus_direction
	if debug_ocean_test_pulse_pinned do source = debug_ocean_test_pulse_source
	focus, focus_valid := ocean_wave_normalize(source)
	if !focus_valid do return {}, false
	cell := shared.planetary_sample_index(focus)
	center_direction := focus
	face, local_u, local_v := shared.planet_locate(focus)
	local_depth := shared.waterfield_depth_at_coord(&value.world, {face, i32(local_u), i32(local_v)})
	if renderer.nearshore.fixture_active {
		local_sample, local_valid := ocean_nearshore_surface_sample(&renderer.nearshore, shared.planet_position(focus, 0))
		if !local_valid do return {}, false
		source_cells: [36]int
		if ocean_nearshore_source_cells(&renderer.nearshore, shared.planet_position(focus, 0), &source_cells) == 0 do return {}, false
		local_depth = local_sample.depth
	}
	if !(local_depth > OCEAN_NEARSHORE_DRY_DEPTH) do return {}, false
	height := clamp(debug_ocean_test_pulse_height, f32(0.5), f32(20))
	interval := clamp(debug_ocean_test_pulse_interval, f32(0.25), f32(20))
	duration := clamp(debug_ocean_test_pulse_duration, interval, f32(30))
	period_ms := u32(interval * 1_000 + 0.5)
	depth_mm := u32(clamp(local_depth * OCEAN_RENDER_METERS_PER_UNIT * 1_000, f32(1), f32(1_000_000_000)))
	phase_speed, group_speed := shared.wave_dispersion_speed_mm_s(
		planet.physical.gravity_milli_m_s2,
		depth_mm,
		period_ms,
	)
	front_speed := debug_ocean_test_pulse_front_speed(f32(group_speed) / 1_000)
	band := max(duration * front_speed * 0.5, f32(1))
	packet = {
		id                 = OCEAN_DEBUG_TEST_PULSE_ID,
		cell               = u32(cell),
		radial             = true,
		center             = shared.planet_position(center_direction, 0),
		direction          = center_direction * front_speed,
		significant_height = height,
		period             = interval,
		envelope_length    = OCEAN_DEBUG_TEST_PULSE_RADIUS,
		envelope_width     = band,
		front_radius       = 0,
		front_speed        = front_speed,
		band               = band,
		phase_epoch        = renderer.macro.time,
		phase_speed        = f32(phase_speed) / 1_000,
		group_speed        = f32(group_speed) / 1_000,
	}
	if debug_ocean_pulse_directional {
		_, east, north := shared.planet_basis(focus)
		heading := debug_ocean_pulse_heading * f32(math.PI / 180)
		packet.radial = false
		packet.direction = east * math.cos(heading) + north * math.sin(heading)
		packet.envelope_length = band
		packet.envelope_width = OCEAN_NEARSHORE_RADIUS * 0.5
	}
	return packet, true
}

debug_ocean_test_pulse_apply :: proc(value: ^Client_State, packet: Ocean_Render_Packet) {
	renderer := &value.terrain.ocean
	debug_ocean_fixture_cancel_pending_tick(renderer)
	renderer.debug_pulse = packet
	renderer.breakers.debug_impact_crests = {}
	renderer.breakers.debug_impact_valid = {}
	renderer.debug_pulse_active = true
	if renderer.nearshore.fixture_active {
		debug_ocean_fixture_query_update(renderer)
	} else {
		focus, _ := ocean_wave_normalize(packet.center)
		_ = ocean_macro_query_update(&renderer.render_query, &value.world, focus, renderer.macro.time)
		ocean_macro_query_debug_packet_merge(&renderer.render_query, renderer.debug_pulse, true)
	}
	renderer.geometry_dirty = true
	debug_ocean_test_pulse_id = OCEAN_DEBUG_TEST_PULSE_ID
}

debug_ocean_inject_test_pulse :: proc(value: ^Client_State) -> (u32, bool) {
	packet, valid := debug_ocean_test_pulse_build(value)
	if !valid do return 0, false
	if value.terrain.ocean.nearshore.fixture_active {
		if !ocean_surf_source_submit(value, packet) do return 0, false
	} else {
		debug_ocean_test_pulse_apply(value, packet)
	}
	return packet.id, true
}

debug_ocean_test_pulse_metrics :: proc(
	renderer: ^Ocean_Renderer,
	packet_id: u32,
	focus: [3]f32,
	depth: f32,
) -> Debug_Ocean_Test_Pulse_Metrics {
	assert(renderer != nil, "debug ocean pulse metrics: nil renderer")
	result: Debug_Ocean_Test_Pulse_Metrics
	position := shared.planet_position(focus, 0)
	radial, valid_focus := ocean_wave_normalize(position)
	if !valid_focus do return result
	for packet in renderer.render_query.packets[:renderer.render_query.packet_count] {
		if packet.id != packet_id do continue
		result.selected_id = packet.id
		result.significant_height = packet.significant_height
		frame := ocean_packet_frame(radial, position, packet, renderer.macro.time)
		if !frame.valid do break
		result.envelope_overlap = frame.envelope
		sample := ocean_macro_wave_sample(
			&renderer.macro,
			&renderer.render_query,
			position,
			max(depth, f32(0.04)),
			1,
			renderer.macro.time,
		)
		result.radial_displacement =
			sample.displacement.x * focus.x +
			sample.displacement.y * focus.y +
			sample.displacement.z * focus.z
		result.velocity = math.sqrt(
			sample.velocity.x * sample.velocity.x +
			sample.velocity.y * sample.velocity.y +
			sample.velocity.z * sample.velocity.z,
		)
		break
	}
	return result
}

_debug_ocean_save :: proc(value: ^Client_State) {
	assert(value != nil, "debug ocean save: nil state")
	ocean_visual_settings_sanitize(&value.ocean_visual)
	settings_save(value)
}

_debug_planet_atmosphere :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	settings := &value.ocean_visual
	changed := debug_panel_extension_checkbox(
		panel,
		OCEAN_DEBUG_KEY_BASE + 1,
		"automatic weather",
		&settings.automatic_weather,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 2,
		"cloud scale",
		&settings.cloud_scale,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 3,
		"fog scale",
		&settings.fog_scale,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 4,
		"sun scale",
		&settings.sun_scale,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 5,
		"ambient scale",
		&settings.ambient_scale,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 6,
		"manual cloud",
		&settings.manual_cloud_coverage,
		0,
		1,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 7,
		"manual fog",
		&settings.manual_fog_density,
		0,
		0.05,
		0.0005,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 8,
		"manual sun",
		&settings.manual_sun_intensity,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 9,
		"manual ambient",
		&settings.manual_ambient_intensity,
		0,
		1,
		0.01,
	)
	if changed {
		_debug_ocean_save(value)
		weather_apply_atmosphere(value)
	}
	diagnostics := &value.world.planetary.diagnostics
	debug_panel_extension_readout(
		panel,
		"mode",
		"physical simulation" if settings.automatic_weather else "manual rendering",
	)
	debug_panel_extension_readout(
		panel,
		"mean humidity",
		fmt.tprintf(
			"%.1f%%",
			f32(diagnostics.mean_humidity) * 100 / f32(shared.CLIMATE_MAX_WATER),
		),
	)
	debug_panel_extension_readout(
		panel,
		"mean precipitation",
		fmt.tprintf("%d", diagnostics.mean_precipitation),
	)
	debug_panel_extension_readout(
		panel,
		"mean wind",
		fmt.tprintf(
			"%.2f m/s",
			f32(diagnostics.mean_wind_speed) / f32(shared.PLANET_VELOCITY_SCALE),
		),
	)
	debug_panel_extension_readout(
		panel,
		"atmosphere cadence",
		fmt.tprintf("%d tick", shared.PLANET_ATMOSPHERE_DYNAMICS_CADENCE_TICKS),
	)
	debug_panel_extension_readout(panel, "diagnostic steps", fmt.tprintf("%d", diagnostics.steps))
}

_debug_weather_generator :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	settings := &value.ocean_visual
	changed := debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 70,
		"radius",
		&settings.storm_radius_km,
		25,
		2_000,
		25,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 71,
		"intensity",
		&settings.storm_intensity,
		0,
		1,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 72,
		"wind speed",
		&settings.storm_wind_speed,
		0,
		200,
		1,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 73,
		"wind heading",
		&settings.storm_wind_heading,
		0,
		360,
		1,
	)
	if changed do _debug_ocean_save(value)
	debug_panel_extension_readout(panel, "radius units", "km")
	debug_panel_extension_readout(panel, "wind units", "m/s / degrees")
	debug_panel_extension_readout(panel, "forcing", "physical, transient")
	focus := value.terrain.ocean.focus_direction
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 74, "Generate storm at focus") {
		_ = weather_generate_storm(&value.world.planetary, focus, settings^)
		weather_refresh(value)
		value.status = "storm generated"
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 75, "Calm weather at focus") {
		_ = weather_calm(&value.world.planetary, focus, settings.storm_radius_km)
		weather_refresh(value)
		value.status = "weather calmed"
	}
}

_debug_ocean_state :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	renderer := &value.terrain.ocean
	summary := weather_ocean_sample(&renderer.weather, renderer.focus_direction)
	diagnostics := renderer.weather.diagnostics
	debug_panel_extension_readout(panel, "renderer ready", fmt.tprintf("%v", renderer.ready))
	debug_panel_extension_readout(
		panel,
		"significant height",
		fmt.tprintf("%.2f m", summary.significant_height),
	)
	continuous_height := math.sqrt(
		summary.wind_sea_height * summary.wind_sea_height +
		summary.swell_height * summary.swell_height,
	)
	debug_panel_extension_readout(
		panel,
		"wind sea / swell / combined",
		fmt.tprintf(
			"%.2f / %.2f / %.2f m",
			summary.wind_sea_height,
			summary.swell_height,
			continuous_height,
		),
	)
	debug_panel_extension_readout(panel, "peak period", fmt.tprintf("%.2f s", summary.peak_period))
	debug_panel_extension_readout(
		panel,
		"wind / wet",
		fmt.tprintf("%.2f m/s / %.0f%%", summary.wind_speed, summary.wet_fraction * 100),
	)
	debug_panel_extension_readout(panel, "breaking", fmt.tprintf("%.1f%%", summary.breaking * 100))
	debug_panel_extension_readout(
		panel,
		"direction",
		fmt.tprintf(
			"%.2f %.2f %.2f",
			summary.direction.x,
			summary.direction.y,
			summary.direction.z,
		),
	)
	debug_panel_extension_readout(
		panel,
		"wind sea / swell",
		fmt.tprintf("%.2f / %.2f m", diagnostics.wind_sea_height, diagnostics.swell_height),
	)
	debug_panel_extension_readout(panel, "mean fetch", fmt.tprintf("%.0f m", diagnostics.fetch))
	debug_panel_extension_readout(
		panel,
		"mean current",
		fmt.tprintf("%.2f m/s", diagnostics.current_speed),
	)
	debug_panel_extension_readout(
		panel,
		"cache revision",
		fmt.tprintf("%d", renderer.weather.revision),
	)
	debug_panel_extension_readout(
		panel,
		"macro time / steps",
		fmt.tprintf("%.2f / %d", renderer.macro.time, renderer.macro.step_count),
	)
	spectral_ready := renderer.wave_source == .Spectral && renderer.spectral.ready
	debug_panel_extension_readout(
		panel,
		"wave source / ready",
		fmt.tprintf("%v / %v", renderer.wave_source, spectral_ready),
	)
	debug_panel_extension_readout(
		panel,
		"spectral init",
		fmt.tprintf("%v", renderer.spectral_init_state),
	)
	if renderer.spectral_init_state == .Failed &&
	   debug_panel_extension_button(
		   panel,
		   OCEAN_DEBUG_KEY_BASE + 82,
		   "Retry spectral initialization",
	   ) {
		if ocean_spectral_retry(renderer) do value.status = "spectral initialization retry queued"
	}
	debug_panel_extension_readout(
		panel,
		"camera water kind",
		fmt.tprintf("%v", renderer.underwater.kind),
	)
	debug_panel_extension_readout(
		panel,
		"camera submersion",
		fmt.tprintf("%.2f m", renderer.underwater.submersion),
	)
	debug_panel_extension_readout(
		panel,
		"underwater target / active",
		fmt.tprintf("%v / %v", renderer.underwater.target, renderer.underwater.active),
	)
	debug_panel_extension_readout(
		panel,
		"underwater blend",
		fmt.tprintf("%.0f%%", renderer.underwater.blend * 100),
	)
	debug_panel_extension_readout(
		panel,
		"underwater transitions",
		fmt.tprintf("%d", renderer.underwater.transition_count),
	)
	debug_panel_extension_readout(
		panel,
		"active absorption",
		fmt.tprintf(
			"%.3f %.3f %.3f",
			renderer.underwater.absorption[0],
			renderer.underwater.absorption[1],
			renderer.underwater.absorption[2],
		),
	)
	debug_panel_extension_readout(
		panel,
		"active scattering / turbidity",
		fmt.tprintf(
			"%.3f %.3f %.3f / %.2f",
			renderer.underwater.scattering[0],
			renderer.underwater.scattering[1],
			renderer.underwater.scattering[2],
			renderer.underwater.turbidity,
		),
	)
}

_debug_ocean_rendering :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	s := &value.ocean_visual
	changed := debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 20,
		"wave amplitude",
		&s.wave_amplitude_scale,
		0,
		3,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 21,
		"bubbles",
		&s.bubble_strength,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 22,
		"roughness",
		&s.roughness,
		0.02,
		0.8,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 23,
		"reflection",
		&s.reflection_strength,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 24,
		"foam",
		&s.foam_strength,
		0,
		3,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 25,
		"crest foam",
		&s.foam_crest,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 26,
		"shore foam",
		&s.foam_shore,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 27,
		"wind foam (legacy)",
		&s.foam_wind,
		0,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 28,
		"absorption",
		&s.absorption_scale,
		0,
		3,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 29,
		"scatter",
		&s.scatter_scale,
		0,
		3,
		0.01,
	)
	_ = debug_panel_extension_group(panel, "OPTICS & UNDERWATER", .Advanced)
	medium_names := [3]string{"ocean", "lake", "river"}
	for &medium, medium_index in s.water_medium {
		base := OCEAN_DEBUG_KEY_BASE + 100 + u32(medium_index * 3)
		changed |= debug_panel_extension_slider(
			panel,
			base,
			fmt.tprintf("%s absorption", medium_names[medium_index]),
			&medium.absorption_scale,
			0,
			3,
			0.05,
		)
		changed |= debug_panel_extension_slider(
			panel,
			base + 1,
			fmt.tprintf("%s scattering", medium_names[medium_index]),
			&medium.scatter_scale,
			0,
			3,
			0.05,
		)
		changed |= debug_panel_extension_slider(
			panel,
			base + 2,
			fmt.tprintf("%s turbidity", medium_names[medium_index]),
			&medium.turbidity_scale,
			0,
			4,
			0.05,
		)
	}
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 109,
		"underwater enter depth",
		&s.underwater_enter_depth,
		0.01,
		2,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 110,
		"underwater exit height",
		&s.underwater_exit_height,
		0.01,
		4,
		0.01,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 111,
		"underwater transition",
		&s.underwater_transition,
		0.05,
		3,
		0.05,
	)
	if changed do _debug_ocean_save(value)
	_ = debug_panel_extension_group(panel, "APPEARANCE", .Simple)
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 30, "Reset ocean visuals") {
		value.ocean_visual = ocean_visual_settings_default()
		value.terrain.ocean.geometry_dirty = true
		settings_save(value)
	}
}

_debug_ocean_clipmap :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	s := &value.ocean_visual
	geometry_changed := false
	far_only := value.terrain.ocean.far_faces_active
	ocean_mode := "far only" if far_only else "far + clipmap"
	debug_panel_extension_readout(panel, "active layers", ocean_mode)
	debug_panel_extension_readout(panel, "far only", fmt.tprintf("%v", far_only))
	for index in 0 ..< OCEAN_CLIPMAP_RING_COUNT {
		geometry_changed |= debug_panel_extension_checkbox(
			panel,
			OCEAN_DEBUG_KEY_BASE + 40 + u32(index),
			fmt.tprintf("ring %d visible", index),
			&s.ring_visible[index],
		)
		geometry_changed |= debug_panel_extension_slider(
			panel,
			OCEAN_DEBUG_KEY_BASE + 50 + u32(index),
			fmt.tprintf("ring %d radius", index),
			&s.ring_radius[index],
			60,
			2_400,
			10,
		)
		ring := &value.terrain.ocean.rings[index]
		draw_state := "draw"
		if far_only do draw_state = "far only"
		else if !s.ring_visible[index] do draw_state = "disabled"
		else if !ring.has_water do draw_state = "dry"
		else if ring.gpu_mesh.id == 0 do draw_state = "no mesh"
		debug_panel_extension_readout(
			panel,
			fmt.tprintf("ring %d mesh / state", index),
			fmt.tprintf(
				"%d / %s / water=%v cpu=%v",
				ring.gpu_mesh.id,
				draw_state,
				ring.has_water,
				ring.cpu_macro_deformed,
			),
		)
	}
	geometry_changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 60,
		"rebuild threshold",
		&s.rebuild_threshold,
		0.0005,
		0.02,
		0.0005,
	)
	geometry_changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 61,
		"near altitude",
		&s.near_altitude_limit,
		100,
		2_000,
		10,
	)
	geometry_changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 62,
		"middle altitude",
		&s.middle_altitude_limit,
		100,
		5_000,
		10,
	)
	if geometry_changed {
		ocean_visual_settings_sanitize(s)
		value.terrain.ocean.geometry_dirty = true
		settings_save(value)
	}
}

_debug_ocean_gpu :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	assert(value != nil && panel != nil, "debug ocean gpu: nil input")
	capabilities := rl.capabilities()
	renderer := &value.terrain.ocean
	status := ocean_pipeline_status(renderer, value.terrain.water_shader.id)
	draw := renderer.draw_diagnostics
	debug_panel_extension_readout(panel, "pipeline verdict", status.verdict)
	debug_panel_extension_readout(
		panel,
		"custom shader created / submitted",
		fmt.tprintf(
			"%d / %d / %v",
			value.terrain.water_shader.id,
			draw.shader_id,
			status.custom_shader_submitted,
		),
	)
	debug_panel_extension_readout(
		panel,
		"draw / spectral serial",
		fmt.tprintf("%d / %d", draw.draw_serial, draw.spectral_update_serial),
	)
	debug_panel_extension_readout(
		panel,
		"draws near / far / breakers",
		fmt.tprintf(
			"%d / %d / %d",
			draw.near_draw_count,
			draw.far_draw_count,
			draw.breaker_draw_count,
		),
	)
	debug_panel_extension_readout(
		panel,
		"spectral textures / valid",
		fmt.tprintf(
			"%d / %d / %d / %v",
			draw.spectral_texture_ids[0],
			draw.spectral_texture_ids[1],
			draw.spectral_texture_ids[2],
			status.spectral_textures_bound,
		),
	)
	debug_panel_extension_readout(
		panel,
		"ring modes / spectral",
		fmt.tprintf(
			"%.0f / %.0f / %.0f / %v",
			draw.ring_displacement_modes[0],
			draw.ring_displacement_modes[1],
			draw.ring_displacement_modes[2],
			status.spectral_displacement_enabled,
		),
	)
	debug_panel_extension_readout(
		panel,
		"scene color / depth / valid",
		fmt.tprintf(
			"%d / %d / %v",
			draw.scene_color_id,
			draw.scene_depth_id,
			status.scene_inputs_valid,
		),
	)
	debug_panel_extension_readout(
		panel,
		"failure stage / cascade / count",
		fmt.tprintf(
			"%v / %d / %d",
			renderer.spectral_failure_stage,
			renderer.spectral_failure_cascade,
			renderer.spectral_failure_count,
		),
	)
	debug_panel_extension_readout(
		panel,
		"spectral recovery",
		"use Retry spectral initialization when state is Failed",
	)
	debug_panel_extension_readout(
		panel,
		"sky shader",
		fmt.tprintf("%d", value.atmosphere.sky_shader.id),
	)
	proof_view := f32(value.ocean_visual.proof_view)
	if debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 81,
		"proof view (0-6)",
		&proof_view,
		0,
		6,
		1,
	) {
		value.ocean_visual.proof_view = Ocean_Proof_View(i32(proof_view))
	}
	debug_panel_extension_readout(
		panel,
		"proof view",
		fmt.tprintf("%v", value.ocean_visual.proof_view),
	)
	debug_panel_extension_readout(
		panel,
		"cascade resolutions",
		fmt.tprintf(
			"%d / %d / %d",
			renderer.cascades[0].resolution,
			renderer.cascades[1].resolution,
			renderer.cascades[2].resolution,
		),
	)
	debug_panel_extension_readout(
		panel,
		"cascade scales",
		fmt.tprintf(
			"%.0f / %.0f / %.0f m",
			OCEAN_SPECTRAL_LENGTH_SCALE[0],
			OCEAN_SPECTRAL_LENGTH_SCALE[1],
			OCEAN_SPECTRAL_LENGTH_SCALE[2],
		),
	)
	debug_panel_extension_readout(
		panel,
		"wind chop significant height",
		fmt.tprintf("%.2f m", OCEAN_SPECTRAL_WIND_CHOP_HEIGHT),
	)
	debug_panel_extension_readout(
		panel,
		"spectral dispatches / submissions",
		fmt.tprintf(
			"%d / %d",
			renderer.spectral.dispatch_count,
			renderer.spectral.submission_count,
		),
	)
	debug_panel_extension_readout(
		panel,
		"spectral stages E/F/D/Foam",
		fmt.tprintf(
			"%d / %d / %d / %d",
			renderer.spectral.stage_dispatch_count[.Evolve],
			renderer.spectral.stage_dispatch_count[.Fft],
			renderer.spectral.stage_dispatch_count[.Derive],
			renderer.spectral.stage_dispatch_count[.Foam],
		),
	)
	debug_panel_extension_readout(
		panel,
		"spectral transition",
		fmt.tprintf("%.0f%%", renderer.spectral.weather.progress * 100),
	)
	debug_panel_extension_readout(
		panel,
		"renderer / simulation packets",
		fmt.tprintf("%d / %d", renderer.render_query.packet_count, value.world.planetary.waves.packet_count),
	)
	debug_panel_extension_readout(panel, "pulse authority", "client-only analytic packet")
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 317, "Toggle radial / directional pulse") {
		debug_ocean_pulse_directional = !debug_ocean_pulse_directional
	}
	debug_panel_extension_readout(panel, "directional pulse", fmt.tprintf("%t", debug_ocean_pulse_directional))
	if debug_ocean_pulse_directional {
		debug_panel_extension_slider(panel, OCEAN_DEBUG_KEY_BASE + 318, "heading degrees from local east", &debug_ocean_pulse_heading, -180, 180, 5)
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 303, "Pin pulse source here") {
		debug_ocean_test_pulse_source = renderer.focus_direction
		debug_ocean_test_pulse_pinned = true
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 304, "Unpin pulse source") {
		debug_ocean_test_pulse_pinned = false
	}
	debug_panel_extension_readout(panel, "source pinned", fmt.tprintf("%t", debug_ocean_test_pulse_pinned))
	fixture_names := [4]string{"Deep-water fixture", "Beach fixture", "Bank fixture", "Reef fixture"}
	for name, index in fixture_names {
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 310 + u32(index), name) {
			fixture_focus := renderer.nearshore.focus if renderer.nearshore.fixture_active else renderer.focus_direction
			debug_ocean_reset_fixture(value, fixture_focus, Ocean_Surf_Fixture(index))
		}
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 314, "Exit surf fixture") {
		debug_ocean_exit_fixture(value)
	}
	debug_panel_extension_readout(panel, "isolated bed/water/board (world tools disabled)", fmt.tprintf("%t", renderer.nearshore.fixture_active))
	if renderer.nearshore.fixture_active {
		debug_panel_extension_slider(
			panel,
			OCEAN_DEBUG_KEY_BASE + 315,
			"surf clock scale (0 pauses)",
			&debug_ocean_fixture_time_scale,
			0,
			1,
			0.05,
		)
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 300, "8 second swell") {
		debug_ocean_test_pulse_interval = 8
		debug_ocean_test_pulse_duration = 24
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 301, "12 second swell") {
		debug_ocean_test_pulse_interval = 12
		debug_ocean_test_pulse_duration = 30
	}
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 302, "Stop pulse") {
		debug_ocean_stop_test_pulse(value)
	}
	debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 82,
		"crest-to-trough height (world units)",
		&debug_ocean_test_pulse_height,
		0.5,
		20,
		0.1,
	)
	debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 83,
		"wave period seconds",
		&debug_ocean_test_pulse_interval,
		0.25,
		20,
		0.25,
	)
	debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 84,
		"packet envelope duration seconds",
		&debug_ocean_test_pulse_duration,
		1,
		30,
		1,
	)
	pulse_period := clamp(debug_ocean_test_pulse_interval, f32(0.25), f32(20))
	wave_count := clamp(debug_ocean_test_pulse_duration / pulse_period, f32(1), f32(30) / pulse_period)
	previous_wave_count := wave_count
	debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 316,
		"nominal waves in envelope",
		&wave_count,
		1,
		30 / pulse_period,
		0.25,
	)
	if wave_count != previous_wave_count {
		debug_ocean_test_pulse_duration = wave_count * pulse_period
	}
	if debug_panel_extension_button(
		panel,
		OCEAN_DEBUG_KEY_BASE + 80,
		fmt.tprintf("Start %.1f unit pulse train", debug_ocean_test_pulse_height),
	) {
		_, injected := debug_ocean_inject_test_pulse(value)
		if injected {
			value.status = "ocean pulse train started"
		} else {
			value.status = "pulse train failed: source needs wet interior wavemaker cells"
		}
	}
	debug_panel_extension_readout(
		panel,
		"pulse train active / elapsed",
		fmt.tprintf("%t / %.1f s", renderer.debug_pulse_active, renderer.debug_pulse.total_travel),
	)
	focus, focus_valid := ocean_wave_normalize(renderer.focus_direction)
	metrics: Debug_Ocean_Test_Pulse_Metrics
	local_wind_sea_height := f32(0)
	local_swell_height := f32(0)
	if focus_valid {
		cell := shared.planetary_sample_index(focus)
		face, local_u, local_v := shared.planet_locate(focus)
		depth := shared.waterfield_depth_at_coord(&value.world, {face, i32(local_u), i32(local_v)})
		if renderer.nearshore.fixture_active {
			local_sample, valid := ocean_nearshore_surface_sample(&renderer.nearshore, shared.planet_position(focus, 0))
			depth = local_sample.depth if valid else 0
		}
		waves := &value.world.planetary.waves
		local_wind_sea_height = f32(shared.integer_sqrt(waves.wind_sea_variance[cell]) * 4) / 1_000
		local_swell_height = f32(shared.integer_sqrt(waves.swell_variance[cell]) * 4) / 1_000
		metrics = debug_ocean_test_pulse_metrics(renderer, debug_ocean_test_pulse_id, focus, depth)
	}
	debug_panel_extension_readout(
		panel,
		"authoritative local wind sea / swell",
		fmt.tprintf("%.3f / %.3f m", local_wind_sea_height, local_swell_height),
	)
	debug_panel_extension_readout(
		panel,
		"selected pulse packet ID",
		fmt.tprintf("%d", metrics.selected_id),
	)
	debug_panel_extension_readout(
		panel,
		"pulse height / overlap",
		fmt.tprintf("%.2f units / %.1f%%", metrics.significant_height, metrics.envelope_overlap * 100),
	)
	debug_panel_extension_readout(
		panel,
		"CPU macro radial / velocity",
		fmt.tprintf("%.3f units / %.3f units/s", metrics.radial_displacement, metrics.velocity),
	)
	if renderer.debug_pulse_active {
		packet := renderer.debug_pulse
		wavelength := f32(math.TAU) / ocean_packet_wave_number(packet)
		debug_panel_extension_readout(panel, "period / source wavelength", fmt.tprintf("%.2f s / %.2f m", packet.period, wavelength * OCEAN_RENDER_METERS_PER_UNIT))
		cells_per_wave := wavelength / (OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS))
		debug_panel_extension_readout(panel, "solver cells / wavelength", fmt.tprintf("%.2f (%s)", cells_per_wave, "unresolved" if cells_per_wave < 8 else "resolution candidate"))
		frame := ocean_packet_frame(focus, shared.planet_position(focus, 0), packet, renderer.macro.time)
		if frame.valid {
			phase, crest, arrived := ocean_breaker_arrival(packet, frame.carrier_coordinate, renderer.macro.time)
			local_phase := renderer.macro.time / packet.period + phase
			debug_panel_extension_readout(panel, "carrier crest / lifecycle", fmt.tprintf("%d / %.3f (%s)", crest, local_phase - math.floor(local_phase), "arrived" if arrived else "pending"))
		}
		debug_panel_extension_readout(panel, "phase / group speed", fmt.tprintf("%.2f / %.2f m/s", packet.phase_speed, packet.group_speed))
		local_sample, local_valid := ocean_nearshore_surface_sample(&renderer.nearshore, shared.planet_position(focus, 0))
		if local_valid {
			debug_panel_extension_readout(panel, "local solver depth", fmt.tprintf("%.3f units", local_sample.depth))
			debug_panel_extension_readout(panel, "local amplitude limit", fmt.tprintf("%.3f units", ocean_debug_depth_amplitude(packet.significant_height, local_sample.depth, 1)))
		}
		debug_panel_extension_readout(panel, "plunging fronts", fmt.tprintf("%d", renderer.breakers.front_count))
		debug_panel_extension_readout(panel, "rejected offshore / envelope / class", fmt.tprintf("%d / %d / %d", renderer.breakers.rejected_offshore, renderer.breakers.rejected_envelope, renderer.breakers.rejected_class))
		debug_panel_extension_readout(panel, "rejected crest arrival", fmt.tprintf("%d", renderer.breakers.rejected_phase))
	}
	debug_panel_extension_readout(panel, "solver diagnostics scope", "last invocation, not completed tick; per unit density")
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	cell_area := f64(spacing * spacing)
	debug_panel_extension_readout(panel, "source momentum x/y (world units)", fmt.tprintf("%.6f / %.6f", renderer.nearshore.last_source_momentum.x * cell_area, renderer.nearshore.last_source_momentum.y * cell_area))
	debug_panel_extension_readout(panel, "source mechanical energy (world units)", fmt.tprintf("%.6f", renderer.nearshore.last_source_energy * cell_area))
	debug_panel_extension_readout(
		panel,
		"nearshore substeps",
		fmt.tprintf("%d", renderer.nearshore.last_substeps),
	)
	debug_panel_extension_readout(
		panel,
		"nearshore mass residual (depth sum)",
		fmt.tprintf("%.6f", renderer.nearshore.last_mass_error),
	)
	debug_panel_extension_readout(panel, "boundary mass (depth sum)", fmt.tprintf("%.6f", renderer.nearshore.last_boundary_mass))
	debug_panel_extension_readout(panel, "wavemaker mass (depth sum)", fmt.tprintf("%.6f", renderer.nearshore.last_source_mass))
	debug_panel_extension_readout(panel, "positivity correction (depth sum)", fmt.tprintf("%.6f", renderer.nearshore.last_clamp_mass))
	debug_panel_extension_readout(panel, "solver backlog / dropped seconds", fmt.tprintf("%.6f / %.6f", renderer.nearshore.time_backlog, renderer.nearshore.dropped_time))
	debug_panel_extension_readout(panel, "surf clock dropped seconds", fmt.tprintf("%.6f", renderer.surf_dropped_time))
	if renderer.nearshore.fixture_active {
		debug_panel_extension_readout(panel, "eligible / clip / cap seconds", fmt.tprintf("%.6f / %.6f / %.6f", renderer.surf_ledger.eligible_scaled, renderer.surf_ledger.clip_rejected, renderer.surf_ledger.cap_rejected))
		debug_panel_extension_readout(panel, "queued / rejected commands", fmt.tprintf("%d / %d", renderer.surf_events.count, renderer.surf_events.rejected))
	}
	debug_panel_extension_readout(
		panel,
		"macro fixed steps",
		fmt.tprintf("%d", renderer.macro.step_count),
	)
	surf_packet_count := 0
	if value.cosmetics.surfable_count > 0 {
		surf_packet_count = value.cosmetics.surfables[0].query.packet_count
	}
	debug_panel_extension_readout(panel, "surf packet count", fmt.tprintf("%d", surf_packet_count))
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 90, "Spawn / reset surfboard") {
		focus_position := shared.planet_position(renderer.focus_direction, 0)
		sample := world_water_physics_sample(
			value,
			&renderer.render_query,
			focus_position,
			renderer.macro.time,
		)
		if !sample.wet {
			value.status = "surfboard spawn requires water"
		} else if surfboard_spawn(
			value,
			sample.surface,
			sample.normal,
			renderer.macro.spectrum.direction,
		) {
			value.status = "surfboard ready"
		} else {
			value.status = "surfboard spawn failed"
		}
	}
	debug_panel_extension_readout(
		panel,
		"spray particles",
		fmt.tprintf("%d", renderer.breakers.spray_count),
	)
	debug_panel_extension_readout(
		panel,
		"spectral memory",
		fmt.tprintf("%.2f MiB", f64(renderer.spectral.memory_bytes) / (1024 * 1024)),
	)
	debug_panel_extension_readout(
		panel,
		"terrain bake rows / uploads",
		fmt.tprintf("%d / %d", value.terrain.last_bake_rows, value.terrain.last_upload_faces),
	)
	debug_panel_extension_readout(
		panel,
		"plunging fronts",
		fmt.tprintf("%d / %d", renderer.breakers.front_count, OCEAN_BREAKER_FRONT_MAX),
	)
	debug_panel_extension_readout(panel, "compute", fmt.tprintf("%v", capabilities.compute))
	debug_panel_extension_readout(
		panel,
		"storage buffers",
		fmt.tprintf("%v", capabilities.storage_buffers),
	)
	debug_panel_extension_readout(
		panel,
		"storage textures",
		fmt.tprintf("%v", capabilities.storage_textures),
	)
	debug_panel_extension_readout(
		panel,
		"sampleable depth",
		fmt.tprintf("%v", capabilities.sampleable_depth),
	)
	debug_panel_extension_readout(
		panel,
		"multiple targets",
		fmt.tprintf("%v", capabilities.multiple_color_attachments),
	)
	debug_panel_extension_readout(
		panel,
		"foam history",
		fmt.tprintf("%v", value.terrain.ocean.foam_history.valid),
	)
}

_debug_sim_proof :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	settings := &value.sim_proof_settings
	proof_value := f32(settings.proof)
	changed := debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 10,
		"proof type (0 off / 1 wind / 2 currents)",
		&proof_value,
		0,
		2,
		1,
	)
	if changed do settings.proof = Sim_Proof_Type(i32(proof_value))
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 11,
		"density",
		&settings.density_scale,
		0.25,
		2,
		0.05,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 12,
		"length",
		&settings.length_scale,
		0.25,
		2.5,
		0.05,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 13,
		"surface lift",
		&settings.lift,
		0.25,
		12,
		0.25,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 14,
		"opacity",
		&settings.opacity,
		0.05,
		1,
		0.05,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 15,
		"reference speed",
		&settings.reference_speed,
		5,
		120,
		1,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 16,
		"pulse speed",
		&settings.pulse_speed,
		0,
		4,
		0.1,
	)
	changed |= debug_panel_extension_slider(
		panel,
		OCEAN_DEBUG_KEY_BASE + 17,
		"pulse strength",
		&settings.pulse_strength,
		0,
		1,
		0.05,
	)
	if changed {
		sim_proof_settings_sanitize(settings)
		value.sim_proof_revision += 1
		settings_save(value)
	}
	source := "disabled"
	if settings.proof == .Wind do source = "surface climate east / north"
	if settings.proof == .Currents do source = "topwater + deep return circulation"
	debug_panel_extension_readout(panel, "selected proof", fmt.tprintf("%v", settings.proof))
	debug_panel_extension_readout(panel, "source", source)
	debug_panel_extension_readout(
		panel,
		"active arrows",
		fmt.tprintf("%d", wind_visual_active_count(&value.wind_visual)),
	)
	debug_panel_extension_readout(
		panel,
		"surface / deep arrows",
		fmt.tprintf(
			"%d / %d",
			value.wind_visual.close.arrow_count + value.wind_visual.regional.arrow_count + value.wind_visual.overview.arrow_count,
			value.wind_visual.deep_close.arrow_count + value.wind_visual.deep_regional.arrow_count + value.wind_visual.deep_overview.arrow_count,
		),
	)
	debug_panel_extension_readout(
		panel,
		"last update tick",
		fmt.tprintf("%d", value.wind_visual.last_tick),
	)
	if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 18, "Rebuild simulation proof") {
		wind_visual_mark_dirty(&value.wind_visual)
	}
}

debug_panel_world_extension :: proc(value: ^Client_State, panel: ^Debug_Panel_Extension_Context) {
	assert(value != nil && panel != nil, "debug world extension: nil input")
	if debug_panel_extension_category(panel, .Weather) {
		_ = debug_panel_extension_group(panel, "WEATHER & ATMOSPHERE", .Simple)
		debug_panel_extension_readout(
			panel,
			"focus cloud / rain / fog",
			fmt.tprintf("%.0f%% / %.0f%% / %.4f", value.visual_weather.cloud * 100, value.visual_weather.rain * 100, value.visual_weather.fog),
		)
		_debug_planet_atmosphere(value, panel)
		_debug_weather_generator(value, panel)
	}
	if debug_panel_extension_category(panel, .World) &&
	   debug_panel_extension_group(panel, "SIMULATION PROOFS", .Advanced) {
		_debug_sim_proof(value, panel)
	}
	if debug_panel_extension_category(panel, .Water) {
		_ = debug_panel_extension_group(panel, "OCEAN HEALTH", .Simple)
		_debug_ocean_state(value, panel)
		_ = debug_panel_extension_group(panel, "OCEAN APPEARANCE", .Simple)
		_debug_ocean_rendering(value, panel)
		if debug_panel_extension_group(panel, "CLIPMAP", .Advanced) {
			_debug_ocean_clipmap(value, panel)
		}
		if debug_panel_extension_group(panel, "PIPELINE DIAGNOSTICS", .Advanced) {
			_debug_ocean_gpu(value, panel)
		}
	}
	if debug_panel_extension_category(panel, .Entities) {
		_ = debug_panel_extension_group(panel, "FLORA EVOLUTION", .Simple)
		diagnostics := &value.world.flora_ecology.diagnostics
		debug_panel_extension_readout(
			panel,
			"ecology step / revision",
			fmt.tprintf("%d / %d", value.world.flora_ecology.step, value.world.flora_ecology.revision),
		)
		debug_panel_extension_readout(
			panel,
			"occupied cells / lineages",
			fmt.tprintf("%d / %d", diagnostics.occupied_cells, diagnostics.lineages),
		)
		debug_panel_extension_readout(panel, "pioneer / grass cover", fmt.tprintf("%d / %d", diagnostics.pioneer_cover, diagnostics.grass_cover))
		debug_panel_extension_readout(panel, "shrub / tree cover", fmt.tprintf("%d / %d", diagnostics.shrub_cover, diagnostics.tree_cover))
		debug_panel_extension_readout(panel, "biomass", fmt.tprintf("%d", diagnostics.total_biomass))
		debug_panel_extension_readout(panel, "mutations / extinctions", fmt.tprintf("%d / %d", diagnostics.mutations, diagnostics.extinctions))
		debug_panel_extension_readout(panel, "flora time scale", fmt.tprintf("%dx", value.flora_time_scale))
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 76, "Flora time: paused") do value.flora_time_scale = 0
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 77, "Flora time: 1x") do value.flora_time_scale = 1
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 78, "Flora time: 10x") do value.flora_time_scale = 10
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 79, "Flora time: 100x") do value.flora_time_scale = 100
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 80, "Flora time: 1000x") do value.flora_time_scale = 1000
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 81, "Step flora once") do value.flora_step_requested = true
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 82, "Inoculate pioneers") do value.flora_inoculate_requested = true
		if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 83, "Sterilize planet") do value.flora_sterilize_requested = true
		if debug_panel_extension_group(panel, "FLORA LINEAGE MAP", .Simple) {
			ecology := &value.world.flora_ecology
			lineage, lineage_index, lineage_found := flora_lineage_debug_resolve(
				&value.flora_lineage_debug,
				ecology,
			)
			if !lineage_found {
				debug_panel_extension_readout(panel, "lineage", "none; inoculate pioneers")
			} else {
				population := flora_lineage_debug_population(ecology, lineage.id)
				debug_panel_extension_readout(
					panel,
					"lineage / roster",
					fmt.tprintf("#%d / %d of %d", u64(lineage.id), lineage_index + 1, ecology.lineage_count),
				)
				debug_panel_extension_readout(
					panel,
					"parent / founder",
					fmt.tprintf("#%d / #%d", u64(lineage.parent), u64(lineage.founder)),
				)
				debug_panel_extension_readout(
					panel,
					"generation / birth / form",
					fmt.tprintf("%d / %d / %v", lineage.generation, lineage.birth_step, lineage.form),
				)
				debug_panel_extension_readout(
					panel,
					"temperature optimum / tolerance",
					fmt.tprintf("%d / %d", lineage.temperature_optimum, lineage.temperature_tolerance),
				)
				debug_panel_extension_readout(
					panel,
					"moisture optimum / tolerance",
					fmt.tprintf("%d / %d", lineage.moisture_optimum, lineage.moisture_tolerance),
				)
				debug_panel_extension_readout(
					panel,
					"colonisation / competition",
					fmt.tprintf("%d / %d", lineage.colonisation, lineage.competition),
				)
				debug_panel_extension_readout(
					panel,
					"cells / cover / biomass",
					fmt.tprintf("%d / %d / %d", population.active_cells, population.total_cover, population.total_biomass),
				)
				debug_panel_extension_readout(panel, "stature / crown spread", fmt.tprintf("%d / %d", lineage.stature, lineage.crown_spread))
				debug_panel_extension_readout(panel, "branch density / wood strength", fmt.tprintf("%d / %d", lineage.branch_density, lineage.wood_strength))
				debug_panel_extension_readout(panel, "morphology family", fmt.tprintf("%d", shared.flora_morphology_family(lineage)))
				debug_panel_extension_readout(panel, "children", fmt.tprintf("%d", population.child_count))
				debug_panel_extension_readout(
					panel,
					"population state",
					"extant" if population.strongest_cell >= 0 else "extinct",
				)
				if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 200, "Previous lineage") do flora_lineage_debug_select_offset(&value.flora_lineage_debug, ecology, -1)
				if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 201, "Next lineage") do flora_lineage_debug_select_offset(&value.flora_lineage_debug, ecology, 1)
				if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 202, "Parent lineage") do _ = flora_lineage_debug_select_parent(&value.flora_lineage_debug, ecology)
				if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 203, "Previous child") do _ = flora_lineage_debug_select_child(&value.flora_lineage_debug, ecology, -1)
				if debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 204, "Next child") do _ = flora_lineage_debug_select_child(&value.flora_lineage_debug, ecology, 1)
				if population.strongest_cell >= 0 &&
				   debug_panel_extension_button(panel, OCEAN_DEBUG_KEY_BASE + 205, "Jump to strongest population") {
					if flora_lineage_debug_jump(value, population.strongest_cell) do value.status = "focused flora lineage"
				}
			}
		}
	}
}
