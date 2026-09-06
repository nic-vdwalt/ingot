package main

import shared "../shared"
import "core:math"
import rl "ingot:gfx"
import procgen "ingot:procgen"

OCEAN_WEATHER_FACE_CELLS :: 12
OCEAN_WEATHER_SUMMARY_COUNT ::
	shared.PLANET_FACE_COUNT * OCEAN_WEATHER_FACE_CELLS * OCEAN_WEATHER_FACE_CELLS
OCEAN_RENDER_PACKET_MAX :: 4
OCEAN_RENDER_METERS_PER_UNIT :: f32(25)
OCEAN_SIM_SECONDS_PER_REAL_SECOND :: f32(
	shared.PLANET_SIM_SECONDS_PER_TICK * u64(shared.TICKS_PER_SECOND),
)
OCEAN_RING_LOOKAHEAD_STEPS :: f32(2)
MOON_LIGHT_FULL_INTENSITY :: f32(0.065)
MOON_LIGHT_CLOUD_EXTINCTION :: f32(0.85)

ocean_render_packet_extent :: proc(meters: f32) -> f32 {
	return max(meters / OCEAN_RENDER_METERS_PER_UNIT, f32(1))
}

ocean_globe_meters_per_unit :: proc(world: ^shared.World) -> f32 {
	assert(world != nil, "ocean_globe_meters_per_unit: nil world")
	return max(f32(world.planetary.physical.radius_m) / shared.PLANET_RADIUS, f32(0.001))
}

ocean_significant_height_m :: proc(height_squared: u64, wet_count: int) -> f32 {
	if wet_count <= 0 do return 0
	return clamp(
		f32(math.sqrt(f64(height_squared) / f64(wet_count))) / 1_000,
		0,
		f32(shared.WAVE_MAX_HEIGHT_MM) / 1_000,
	)
}

ocean_continuous_wave_height :: proc(wind_sea_height, swell_height: f32) -> f32 {
	wind_sea := max(wind_sea_height, f32(0))
	swell := max(swell_height, f32(0))
	return math.sqrt(wind_sea * wind_sea + swell * swell)
}

Ocean_Weather_Summary :: struct {
	center:             [3]f32,
	direction:          [3]f32,
	wind_direction:     [3]f32,
	significant_height: f32,
	peak_period:        f32,
	breaking:           f32,
	wind_speed:         f32,
	precipitation:      f32,
	storm_energy:       f32,
	wet_fraction:       f32,
	wind_sea_height:    f32,
	swell_height:       f32,
}

Ocean_Render_Spectrum :: struct {
	direction:          [3]f32,
	significant_height: f32,
	wind_sea_height:    f32,
	swell_height:       f32,
	peak_period:        f32,
	wind_speed:         f32,
	depth:              f32,
	breaking:           f32,
}

Ocean_Render_Packet :: struct {
	id:                 u32,
	cell:               u32,
	radial:             bool,
	center:             [3]f32,
	direction:          [3]f32,
	significant_height: f32,
	period:             f32,
	envelope_length:    f32,
	envelope_width:     f32,
	front_radius:       f32,
	front_speed:        f32,
	band:               f32,
	phase_epoch:        f32,
	total_travel:       f32,
	phase_speed:        f32,
	group_speed:        f32,
	breaking:           f32,
	breaker_type:       shared.Wave_Breaker_Type,
}

Ocean_Weather_Diagnostics :: struct {
	wind_sea_height: f32,
	swell_height:    f32,
	fetch:           f32,
	breaking:        f32,
	current_speed:   f32,
}

Ocean_Weather_Cache :: struct {
	summaries:   [OCEAN_WEATHER_SUMMARY_COUNT]Ocean_Weather_Summary,
	diagnostics: Ocean_Weather_Diagnostics,
	revision:    u64,
	valid:       bool,
}

Visual_Weather :: struct {
	cloud:           f32,
	rain:            f32,
	fog:             f32,
	wind:            [2]f32,
	focus_direction: [3]f32,
}

visual_weather_sample :: proc(value: ^Client_State) -> Visual_Weather {
	assert(value != nil, "visual_weather_sample: nil state")
	focus := value.orbit.target
	focus_length := math.sqrt(focus.x * focus.x + focus.y * focus.y + focus.z * focus.z)
	if focus_length <= 0.000001 do focus = shared.planet_direction({.Pos_X, 384, 384})
	else do focus /= focus_length
	center := shared.planet_sim_coord_for_index(shared.planetary_sample_index(focus))
	cloud_total, rain_total: u64
	wind_east_total, wind_north_total: i64
	count := u64(0)
	for dv in -2 ..= 2 {
		for du in -2 ..= 2 {
			coord := center
			step_u := i32(1) if du > 0 else i32(-1)
			step_v := i32(1) if dv > 0 else i32(-1)
			for _ in 0 ..< abs(du) do coord = shared.planet_sim_neighbour(coord, step_u, 0)
			for _ in 0 ..< abs(dv) do coord = shared.planet_sim_neighbour(coord, 0, step_v)
			index := shared.planet_sim_index(coord)
			cloud_total += u64(value.world.planetary.climate.cloud[index])
			rain_total += u64(value.world.planetary.climate.precipitation[index])
			wind_east_total += i64(value.world.planetary.climate.wind_east[index])
			wind_north_total += i64(value.world.planetary.climate.wind_north[index])
			count += 1
		}
	}
	return {
		cloud = clamp(f32(cloud_total / count) / f32(shared.CLIMATE_MAX_WATER), 0, 1),
		rain = clamp(f32(rain_total / count) / 20_000, 0, 1),
		wind = {
			f32(wind_east_total / i64(count)) / f32(shared.PLANET_VELOCITY_SCALE),
			f32(wind_north_total / i64(count)) / f32(shared.PLANET_VELOCITY_SCALE),
		},
		focus_direction = focus,
	}
}

weather_automatic_light :: proc(settings: Ocean_Visual_Settings) -> (sun, ambient: f32) {
	return clamp(
		f32(1.0) * settings.sun_scale,
		0,
		2,
	), clamp(f32(0.34) * settings.ambient_scale, 0, 1)
}

Weather_Orbital_Sample :: struct {
	sun_direction:  [3]f32,
	moon_direction: [3]f32,
	moon_distance:  f32,
	moon_phase:     f32,
}

weather_orbital_direction :: proc(from, to: [3]f32, fraction: f32) -> [3]f32 {
	if fraction <= 0 do return from
	if fraction >= 1 do return to
	start := from / math.sqrt(from.x * from.x + from.y * from.y + from.z * from.z)
	finish := to / math.sqrt(to.x * to.x + to.y * to.y + to.z * to.z)
	cosine := clamp(start.x * finish.x + start.y * finish.y + start.z * finish.z, f32(-1), f32(1))
	direction: [3]f32
	if cosine > 0.9995 {
		direction = start + (finish - start) * fraction
	} else {
		tangent := finish - start * cosine
		length := math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y + tangent.z * tangent.z)
		if length < 0.000001 {
			axis := [3]f32{1, 0, 0}
			if math.abs(start.x) > 0.9 do axis = {0, 1, 0}
			tangent = axis - start * (axis.x * start.x + axis.y * start.y + axis.z * start.z)
			length = math.sqrt(tangent.x * tangent.x + tangent.y * tangent.y + tangent.z * tangent.z)
		}
		angle := math.acos(cosine) * fraction
		direction = start * math.cos(angle) + tangent / length * math.sin(angle)
	}
	return direction / math.sqrt(direction.x * direction.x + direction.y * direction.y + direction.z * direction.z)
}

weather_orbital_sample_at :: proc(
	orbit: shared.Orbit_State,
	physical: shared.Planet_Physical_Parameters,
	accumulator: f64,
) -> Weather_Orbital_Sample {
	current := shared.orbit_ephemeris(orbit, physical)
	sample := Weather_Orbital_Sample {
		sun_direction = current.sun.planet_fixed_direction,
		moon_direction = current.moon.planet_fixed_direction,
		moon_distance = f32(current.moon.distance_km),
		moon_phase = f32(shared.orbit_lunar_illuminated_fraction_ppm(current.lunar_phase)) / f32(shared.ORBIT_TRIG_SCALE),
	}
	fraction := f32(clamp(accumulator / shared.TICK_DURATION_SECONDS, 0, 1))
	if fraction == 0 do return sample
	next_orbit := orbit
	shared.orbit_step(&next_orbit, physical, shared.PLANET_SIM_SECONDS_PER_TICK)
	next := shared.orbit_ephemeris(next_orbit, physical)
	sample.sun_direction = weather_orbital_direction(sample.sun_direction, next.sun.planet_fixed_direction, fraction)
	sample.moon_direction = weather_orbital_direction(sample.moon_direction, next.moon.planet_fixed_direction, fraction)
	next_phase := f32(shared.orbit_lunar_illuminated_fraction_ppm(next.lunar_phase)) / f32(shared.ORBIT_TRIG_SCALE)
	sample.moon_distance += (f32(next.moon.distance_km) - sample.moon_distance) * fraction
	sample.moon_phase += (next_phase - sample.moon_phase) * fraction
	return sample
}

weather_orbital_lights :: proc(value: ^Client_State) -> (sun, moon: rl.Gpu_3D_Light) {
	assert(value != nil, "weather_orbital_lights: nil state")
	planet := &value.world.planetary
	sample := weather_orbital_sample_at(planet.orbit, planet.physical, value.accumulator)
	sun = atmosphere_light(&value.atmosphere)
	sun.direction = sample.sun_direction
	phase := sample.moon_phase
	reference_distance := f32(planet.orbit.moon.semi_major_axis_km)
	distance := max(sample.moon_distance, f32(1))
	distance_scale := reference_distance * reference_distance / (distance * distance)
	cloud_transmittance :=
		1 - clamp(value.atmosphere.cloud_coverage, f32(0), f32(1)) * MOON_LIGHT_CLOUD_EXTINCTION
	moon = {
		direction = sample.moon_direction,
		diffuse   = clamp(
			MOON_LIGHT_FULL_INTENSITY * phase * distance_scale * cloud_transmittance,
			0,
			MOON_LIGHT_FULL_INTENSITY * 1.15,
		),
	}
	return
}

weather_sync_sun_direction :: proc(value: ^Client_State) {
	assert(value != nil, "weather_sync_sun_direction: nil state")
	planet := &value.world.planetary
	sample := weather_orbital_sample_at(planet.orbit, planet.physical, value.accumulator)
	value.atmosphere.sun_direction = sample.sun_direction
}

weather_apply_atmosphere :: proc(value: ^Client_State) {
	assert(value != nil, "weather_apply_atmosphere: nil state")
	settings := value.ocean_visual
	if !settings.automatic_weather {
		weather := Visual_Weather {
			cloud = settings.manual_cloud_coverage,
			rain  = clamp(settings.manual_fog_density / 0.05, 0, 1),
			fog   = settings.manual_fog_density,
		}
		value.atmosphere.cloud_coverage = weather.cloud
		value.atmosphere.cloud_wind = {}
		value.atmosphere.storm_intensity = weather.rain
		value.atmosphere.fog_density = weather.fog
		value.atmosphere.sun_intensity = settings.manual_sun_intensity
		value.atmosphere.ambient_intensity = settings.manual_ambient_intensity
		weather_sync_sun_direction(value)
		value.visual_weather = weather
		return
	}
	weather := visual_weather_sample(value)
	value.atmosphere.cloud_coverage = clamp(weather.cloud * 1.25 * settings.cloud_scale, 0, 1)
	value.atmosphere.cloud_wind = {
		clamp(weather.wind.x, -200, 200),
		clamp(weather.wind.y, -200, 200),
	}
	value.atmosphere.storm_intensity = clamp(weather.rain, 0, 1)
	base_fog := 0.0015 + weather.cloud * 0.006 + weather.rain * 0.010
	value.atmosphere.fog_density = clamp(base_fog * settings.fog_scale, 0, 0.05)
	weather.cloud = value.atmosphere.cloud_coverage
	weather.fog = value.atmosphere.fog_density
	value.atmosphere.sun_intensity, value.atmosphere.ambient_intensity = weather_automatic_light(
		settings,
	)
	weather_sync_sun_direction(value)
	value.visual_weather = weather
}

weather_storm_falloff :: proc(
	focus, direction: [3]f32,
	radius_km: f32,
	planet_radius_m: u64,
) -> f32 {
	if radius_km <= 0 || planet_radius_m == 0 do return 0
	dot := clamp(focus.x * direction.x + focus.y * direction.y + focus.z * direction.z, -1, 1)
	distance_km := math.acos(dot) * f32(planet_radius_m) / 1_000
	return clamp(1 - distance_km / radius_km, 0, 1)
}

weather_parallel_transport :: proc(from, to, tangent: [3]f32) -> [3]f32 {
	cosine := clamp(from.x * to.x + from.y * to.y + from.z * to.z, f32(-1), f32(1))
	axis := [3]f32 {
		from.y * to.z - from.z * to.y,
		from.z * to.x - from.x * to.z,
		from.x * to.y - from.y * to.x,
	}
	sine := math.sqrt(axis.x * axis.x + axis.y * axis.y + axis.z * axis.z)
	if sine <= 0.000001 {
		if cosine > 0 do return tangent
		_, axis, _ = shared.planet_basis(from)
		sine = 0
		cosine = -1
	} else {
		axis /= sine
	}
	axis_dot := axis.x * tangent.x + axis.y * tangent.y + axis.z * tangent.z
	cross := [3]f32 {
		axis.y * tangent.z - axis.z * tangent.y,
		axis.z * tangent.x - axis.x * tangent.z,
		axis.x * tangent.y - axis.y * tangent.x,
	}
	transported := tangent * cosine + cross * sine + axis * axis_dot * (1 - cosine)
	transported -= to * (transported.x * to.x + transported.y * to.y + transported.z * to.z)
	length := math.sqrt(
		transported.x * transported.x +
		transported.y * transported.y +
		transported.z * transported.z,
	)
	if length <= 0.000001 do return {}
	return transported / length
}

weather_storm_wind :: proc(
	focus, direction: [3]f32,
	heading_degrees, speed_m_s, falloff: f32,
) -> (
	i32,
	i32,
) {
	_, focus_east, focus_north := shared.planet_basis(focus)
	_, local_east, local_north := shared.planet_basis(direction)
	heading := heading_degrees * math.PI / 180
	focus_wind := focus_east * math.sin(heading) + focus_north * math.cos(heading)
	wind := weather_parallel_transport(focus, direction, focus_wind)
	east := wind.x * local_east.x + wind.y * local_east.y + wind.z * local_east.z
	north := wind.x * local_north.x + wind.y * local_north.y + wind.z * local_north.z
	length := math.sqrt(east * east + north * north)
	if length <= 0.000001 do return 0, 0
	scaled := speed_m_s * f32(shared.PLANET_VELOCITY_SCALE) * falloff / length
	return i32(east * scaled), i32(north * scaled)
}

weather_generate_storm :: proc(
	planet: ^shared.Planetary_State,
	focus: [3]f32,
	settings: Ocean_Visual_Settings,
) -> int {
	assert(planet != nil, "weather_generate_storm: nil planet")
	shared.planetary_mark_mutated(planet)
	changed := 0
	for index in 0 ..< shared.PLANET_SIM_CELL_COUNT {
		direction := shared.planet_sim_direction(shared.planet_sim_coord_for_index(index))
		falloff := weather_storm_falloff(
			focus,
			direction,
			settings.storm_radius_km,
			planet.physical.radius_m,
		)
		effect := falloff * settings.storm_intensity
		if effect <= 0 do continue
		water := u32(f32(shared.CLIMATE_MAX_WATER) * effect)
		planet.climate.vapour[index] = max(planet.climate.vapour[index], water)
		planet.climate.cloud[index] = max(planet.climate.cloud[index], water)
		planet.climate.precipitation[index] = max(
			planet.climate.precipitation[index],
			u32(20_000 * effect),
		)
		pressure_deficit := i64(f32(shared.PLANET_PRESSURE_ANOMALY_MAX_PA) * effect)
		target_pressure := max(i64(1), i64(shared.CLIMATE_STANDARD_PRESSURE) - pressure_deficit)
		planet.climate.pressure[index] = u32(
			min(i64(planet.climate.pressure[index]), target_pressure),
		)
		planet.climate.column_mass[index] = shared.climate_column_mass_from_pressure(
			planet.climate.pressure[index],
			planet.physical.gravity_milli_m_s2,
		)
		wind_east, wind_north := weather_storm_wind(
			focus,
			direction,
			settings.storm_wind_heading,
			settings.storm_wind_speed,
			effect,
		)
		planet.climate.wind_east[index] = clamp(
			wind_east,
			-shared.PLANET_WIND_MAX,
			shared.PLANET_WIND_MAX,
		)
		planet.climate.wind_north[index] = clamp(
			wind_north,
			-shared.PLANET_WIND_MAX,
			shared.PLANET_WIND_MAX,
		)
		changed += 1
	}
	return changed
}

weather_calm :: proc(planet: ^shared.Planetary_State, focus: [3]f32, radius_km: f32) -> int {
	assert(planet != nil, "weather_calm: nil planet")
	shared.planetary_mark_mutated(planet)
	changed := 0
	for index in 0 ..< shared.PLANET_SIM_CELL_COUNT {
		direction := shared.planet_sim_direction(shared.planet_sim_coord_for_index(index))
		falloff := weather_storm_falloff(focus, direction, radius_km, planet.physical.radius_m)
		if falloff <= 0 do continue
		remaining := 1 - falloff
		planet.climate.cloud[index] = u32(f32(planet.climate.cloud[index]) * remaining)
		planet.climate.precipitation[index] = u32(
			f32(planet.climate.precipitation[index]) * remaining,
		)
		planet.climate.wind_east[index] = i32(f32(planet.climate.wind_east[index]) * remaining)
		planet.climate.wind_north[index] = i32(f32(planet.climate.wind_north[index]) * remaining)
		changed += 1
	}
	return changed
}

weather_refresh :: proc(value: ^Client_State) {
	assert(value != nil, "weather_refresh: nil state")
	shared.planetary_diagnostics_update(&value.world)
	weather_ocean_cache_update(&value.terrain.ocean.weather, &value.world)
	weather_apply_atmosphere(value)
}

ocean_visual_storm_energy :: proc(wind_speed, precipitation: f32) -> f32 {
	wind := clamp((wind_speed - 6) / 24, f32(0), f32(1))
	wind = wind * wind * (3 - 2 * wind)
	rain := clamp(precipitation, f32(0), f32(1))
	return clamp(max(rain, wind * (0.35 + rain * 0.65)), f32(0), f32(1))
}

ocean_visual_wind_sea_floor :: proc(wind_speed, storm_energy, wet_fraction: f32) -> f32 {
	wind_wave := max(wind_speed - 3, f32(0)) * 0.075
	storm_chop := storm_energy * (0.35 + max(wind_speed - 8, f32(0)) * 0.035)
	return clamp((wind_wave + storm_chop) * clamp(wet_fraction, f32(0), f32(1)), f32(0), f32(6))
}

weather_ocean_cache_update :: proc(cache: ^Ocean_Weather_Cache, world: ^shared.World) {
	assert(cache != nil, "weather_ocean_cache_update: nil cache")
	assert(world != nil, "weather_ocean_cache_update: nil world")
	bin_span := shared.PLANET_SIM_FACE_CELLS / OCEAN_WEATHER_FACE_CELLS
	wind_sea_total: f64
	swell_total: f64
	fetch_total: u64
	breaking_global: u64
	current_total: u64
	global_wet_count := 0
	for face_index in 0 ..< shared.PLANET_FACE_COUNT {
		for row in 0 ..< OCEAN_WEATHER_FACE_CELLS {
			for column in 0 ..< OCEAN_WEATHER_FACE_CELLS {
				summary_index :=
					face_index * OCEAN_WEATHER_FACE_CELLS * OCEAN_WEATHER_FACE_CELLS +
					row * OCEAN_WEATHER_FACE_CELLS +
					column
				face := procgen.Terrain_Face_V4(face_index)
				center_coord := shared.Planet_Sim_Coord {
					face = face,
					u    = i32(column * bin_span + bin_span / 2),
					v    = i32(row * bin_span + bin_span / 2),
				}
				center := shared.planet_sim_direction(center_coord)
				_, fallback, _ := shared.planet_basis(center)
				height_squared: u64
				height_total: u64
				wind_sea_variance_total: u64
				swell_variance_total: u64
				period_weighted: u64
				breaking_total: u64
				wind_total: u64
				precipitation_total: u64
				direction_sum: [3]f32
				wind_direction_sum: [3]f32
				wet_count := 0
				for local_row in 0 ..< bin_span {
					for local_column in 0 ..< bin_span {
						coord := shared.Planet_Sim_Coord {
							face = face,
							u    = i32(column * bin_span + local_column),
							v    = i32(row * bin_span + local_row),
						}
						index := shared.planet_sim_index(coord)
						if world.planetary.ocean.mean_depth_mm[index] == 0 do continue
						height := world.planetary.waves.height_mm[index]
						height_squared += u64(height) * u64(height)
						height_total += u64(max(height, u32(1)))
						period_weighted +=
							u64(world.planetary.waves.period_ms[index]) * u64(max(height, u32(1)))
						breaking_total += u64(world.planetary.waves.breaking[index])
						precipitation_total += u64(world.planetary.climate.precipitation[index])
						wind_east := i64(world.planetary.climate.wind_east[index])
						wind_north := i64(world.planetary.climate.wind_north[index])
						wind_speed := shared.integer_sqrt(
							u64(wind_east * wind_east + wind_north * wind_north),
						)
						wind_total += wind_speed
						wind_sea_total += math.sqrt(
							f64(world.planetary.waves.wind_sea_variance[index]),
						)
						swell_total += math.sqrt(f64(world.planetary.waves.swell_variance[index]))
						wind_sea_variance_total += world.planetary.waves.wind_sea_variance[index]
						swell_variance_total += world.planetary.waves.swell_variance[index]
						fetch_total += u64(world.planetary.waves.fetch_m[index])
						breaking_global += u64(world.planetary.waves.breaking[index])
						current_east := i64(world.planetary.ocean.transport_east[index])
						current_north := i64(world.planetary.ocean.transport_north[index])
						current_total += shared.integer_sqrt(
							u64(current_east * current_east + current_north * current_north),
						)
						global_wet_count += 1
						radial := shared.planet_sim_direction(coord)
						_, east, north := shared.planet_basis(radial)
						direction_sum +=
							(east * f32(world.planetary.waves.direction_east[index]) +
								north * f32(world.planetary.waves.direction_north[index])) *
							f32(height)
						wind_direction_sum +=
							(east * f32(wind_east) + north * f32(wind_north)) * f32(wind_speed)
						wet_count += 1
					}
				}
				direction_length := math.sqrt(
					direction_sum.x * direction_sum.x +
					direction_sum.y * direction_sum.y +
					direction_sum.z * direction_sum.z,
				)
				direction := fallback
				if direction_length > 0.000001 do direction = direction_sum / direction_length
				wind_direction_length := math.sqrt(
					wind_direction_sum.x * wind_direction_sum.x +
					wind_direction_sum.y * wind_direction_sum.y +
					wind_direction_sum.z * wind_direction_sum.z,
				)
				wind_direction := direction
				if wind_direction_length > 0.000001 {
					wind_direction = wind_direction_sum / wind_direction_length
				}
				summary := Ocean_Weather_Summary {
					center         = center,
					direction      = direction,
					wind_direction = wind_direction,
				}
				if wet_count > 0 {
					summary.significant_height = ocean_significant_height_m(
						height_squared,
						wet_count,
					)
					summary.peak_period =
						f32(period_weighted) / f32(max(height_total, u64(1))) / 1_000
					summary.breaking = clamp(
						f32(breaking_total) / f32(wet_count * int(shared.CLIMATE_MAX_WATER)),
						0,
						1,
					)
					summary.wind_speed =
						f32(wind_total) / f32(wet_count * int(shared.PLANET_VELOCITY_SCALE))
					summary.precipitation = clamp(
						f32(precipitation_total) / f32(wet_count * 20_000),
						0,
						1,
					)
					summary.storm_energy = ocean_visual_storm_energy(
						summary.wind_speed,
						summary.precipitation,
					)
					summary.wet_fraction = f32(wet_count) / f32(bin_span * bin_span)
					simulated_wind_sea :=
						4 * f32(math.sqrt(f64(wind_sea_variance_total) / f64(wet_count))) / 1_000
					summary.wind_sea_height = max(
						simulated_wind_sea,
						ocean_visual_wind_sea_floor(
							summary.wind_speed,
							summary.storm_energy,
							summary.wet_fraction,
						),
					)
					summary.swell_height =
						4 * f32(math.sqrt(f64(swell_variance_total) / f64(wet_count))) / 1_000
				}
				cache.summaries[summary_index] = summary
			}
		}
	}
	if global_wet_count > 0 {
		count := f64(global_wet_count)
		cache.diagnostics = {
			wind_sea_height = f32(wind_sea_total / count / 1_000),
			swell_height    = f32(swell_total / count / 1_000),
			fetch           = f32(fetch_total) / f32(global_wet_count),
			breaking        = f32(
				breaking_global,
			) / f32(global_wet_count * int(shared.CLIMATE_MAX_WATER)),
			current_speed   = f32(
				current_total,
			) / f32(global_wet_count * int(shared.PLANET_VELOCITY_SCALE)),
		}
	} else {
		cache.diagnostics = {}
	}
	cache.revision += 1
	cache.valid = true
}

weather_ocean_sample :: proc(
	cache: ^Ocean_Weather_Cache,
	direction: [3]f32,
) -> Ocean_Weather_Summary {
	assert(cache != nil, "weather_ocean_sample: nil cache")
	if !cache.valid do return {}
	best_indices: [4]int
	best_dots := [4]f32{-2, -2, -2, -2}
	for summary, index in cache.summaries {
		dot :=
			summary.center.x * direction.x +
			summary.center.y * direction.y +
			summary.center.z * direction.z
		for rank in 0 ..< len(best_indices) {
			if dot <= best_dots[rank] do continue
			shift := len(best_indices) - 1
			for shift > rank {
				best_dots[shift] = best_dots[shift - 1]
				best_indices[shift] = best_indices[shift - 1]
				shift -= 1
			}
			best_dots[rank] = dot
			best_indices[rank] = index
			break
		}
	}
	result: Ocean_Weather_Summary
	weight_total := f32(0)
	direction_sum: [3]f32
	wind_direction_sum: [3]f32
	for index, rank in best_indices {
		summary := cache.summaries[index]
		weight := max(best_dots[rank] - best_dots[len(best_dots) - 1] + 0.0001, 0.0001)
		result.significant_height += summary.significant_height * weight
		result.peak_period += summary.peak_period * weight
		result.breaking += summary.breaking * weight
		result.wind_speed += summary.wind_speed * weight
		result.precipitation += summary.precipitation * weight
		result.storm_energy += summary.storm_energy * weight
		result.wet_fraction += summary.wet_fraction * weight
		result.wind_sea_height += summary.wind_sea_height * weight
		result.swell_height += summary.swell_height * weight
		direction_sum += summary.direction * weight
		wind_direction_sum += summary.wind_direction * weight
		weight_total += weight
	}
	if weight_total <= 0 do return cache.summaries[best_indices[0]]
	result.significant_height /= weight_total
	result.peak_period /= weight_total
	result.breaking /= weight_total
	result.wind_speed /= weight_total
	result.precipitation = clamp(result.precipitation / weight_total, f32(0), f32(1))
	result.storm_energy = clamp(result.storm_energy / weight_total, f32(0), f32(1))
	result.wet_fraction /= weight_total
	result.wind_sea_height /= weight_total
	result.swell_height /= weight_total
	length := math.sqrt(
		direction_sum.x * direction_sum.x +
		direction_sum.y * direction_sum.y +
		direction_sum.z * direction_sum.z,
	)
	result.direction = direction_sum / max(length, 0.0001)
	wind_length := math.sqrt(
		wind_direction_sum.x * wind_direction_sum.x +
		wind_direction_sum.y * wind_direction_sum.y +
		wind_direction_sum.z * wind_direction_sum.z,
	)
	result.wind_direction = wind_direction_sum / max(wind_length, 0.0001)
	result.center = direction
	return result
}

weather_ocean_render_spectrum :: proc(
	world: ^shared.World,
	focus: [3]f32,
	summary: Ocean_Weather_Summary,
) -> Ocean_Render_Spectrum {
	assert(world != nil, "weather_ocean_render_spectrum: nil world")
	index := shared.planetary_sample_index(focus)
	direction := summary.wind_direction
	direction_length := math.sqrt(
		direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
	)
	if direction_length > 0.000001 {
		direction /= direction_length
	} else {
		_, direction, _ = shared.planet_basis(focus)
	}
	return {
		direction = direction,
		significant_height = clamp(summary.wind_sea_height, 0, 20),
		wind_sea_height = clamp(summary.wind_sea_height, 0, 20),
		swell_height = 0,
		peak_period = clamp(summary.peak_period, 2, 30),
		wind_speed = max(summary.wind_speed, 0),
		depth = max(f32(world.planetary.ocean.mean_depth_mm[index]) / 1_000, 0.05),
		breaking = clamp(summary.breaking, 0, 1),
	}
}

ocean_packet_id_in :: proc(ids: []u32, id: u32) -> bool {
	for retained in ids do if retained == id do return true
	return false
}

weather_ocean_render_packets :: proc(
	world: ^shared.World,
	focus: [3]f32,
	retained_ids: []u32,
	storage: ^[OCEAN_RENDER_PACKET_MAX]Ocean_Render_Packet,
) -> []Ocean_Render_Packet {
	assert(world != nil && storage != nil, "weather_ocean_render_packets: nil input")
	focus_length := math.sqrt(focus.x * focus.x + focus.y * focus.y + focus.z * focus.z)
	if focus_length <= 0.0001 do return storage[:0]
	focus_direction := focus / focus_length
	for &packet in storage do packet = {}
	count := 0
	best_scores := [OCEAN_RENDER_PACKET_MAX]f32{-1, -1, -1, -1}
	projected: [OCEAN_RENDER_PACKET_MAX * 4]shared.Wave_Packet_Body_State
	query_radius_mm := u64(OCEAN_NEARSHORE_RADIUS * 8 * 1_000)
	projected_count := shared.waves_query_packets_body(
		&world.planetary,
		focus_direction,
		query_radius_mm,
		projected[:],
	)
	globe_meters_per_unit := ocean_globe_meters_per_unit(world)
	step_seconds := f32(shared.PLANET_SIM_SECONDS_PER_TICK * shared.PLANET_WAVE_CADENCE_TICKS)
	for packet in projected[:projected_count] {
		center := packet.center_direction
		dot := clamp(
			center.x * focus_direction.x +
			center.y * focus_direction.y +
			center.z * focus_direction.z,
			-1,
			1,
		)
		distance := math.acos(dot) * f32(world.planetary.physical.radius_m)
		band_m := max(f32(packet.band_mm) / 1_000, 1)
		group_m_s := f32(packet.group_speed_mm_s) / 1_000
		ring_gap := abs(distance - f32(packet.radius_mm) / 1_000)
		lookahead := group_m_s * step_seconds * OCEAN_RING_LOOKAHEAD_STEPS
		effective_gap := max(ring_gap - lookahead, 0)
		if effective_gap > band_m * 3 do continue
		score :=
			f32(shared.integer_sqrt(packet.action)) *
				math.exp(-effective_gap * effective_gap / (band_m * band_m)) +
			f32(packet.breaking)
		if ocean_packet_id_in(retained_ids, packet.id) do score *= 1 + OCEAN_PACKET_RETAIN_BONUS
		insert := -1
		for rank in 0 ..< OCEAN_RENDER_PACKET_MAX {
			if score > best_scores[rank] ||
			   (score == best_scores[rank] &&
					   (storage[rank].id == 0 || packet.id < storage[rank].id)) {
				insert = rank
				break
			}
		}
		if insert < 0 do continue
		for rank := OCEAN_RENDER_PACKET_MAX - 1; rank > insert; rank -= 1 {
			best_scores[rank] = best_scores[rank - 1]
			storage[rank] = storage[rank - 1]
		}
		best_scores[insert] = score
		front_speed := group_m_s * OCEAN_SIM_SECONDS_PER_REAL_SECOND / globe_meters_per_unit
		band := max(band_m / globe_meters_per_unit, f32(1))
		storage[insert] = {
			id                 = packet.id,
			cell               = packet.cell,
			radial             = true,
			center             = shared.planet_position(center, 0),
			direction          = center * front_speed,
			significant_height = f32(shared.integer_sqrt(packet.action) * 4) / 1_000,
			period             = f32(packet.period_ms) / 1_000,
			envelope_length    = band,
			envelope_width     = band,
			front_radius       = f32(packet.radius_mm) / 1_000 / globe_meters_per_unit,
			front_speed        = front_speed,
			band               = band,
			phase_epoch        = f32(packet.phase_epoch_ms) / 1_000,
			total_travel       = f32(packet.total_travel_mm) / 1_000,
			phase_speed        = f32(packet.phase_speed_mm_s) / 1_000,
			group_speed        = group_m_s,
			breaking           = f32(packet.breaking) / f32(shared.CLIMATE_MAX_WATER),
			breaker_type       = packet.breaker_type,
		}
		count = min(count + 1, OCEAN_RENDER_PACKET_MAX)
	}
	return storage[:count]
}
weather_water_parameters :: proc(world: ^shared.World, face_index: int) -> [4]f32 {
	assert(world != nil, "weather_water_parameters: nil world")
	assert(
		face_index >= 0 && face_index < shared.PLANET_FACE_COUNT,
		"weather_water_parameters: face",
	)
	face_cells := shared.PLANET_SIM_FACE_CELLS * shared.PLANET_SIM_FACE_CELLS
	start := face_index * face_cells
	height_squared: u64
	direction_sum: [3]f32
	wet_count := 0
	for local_index in 0 ..< face_cells {
		index := start + local_index
		if world.planetary.ocean.mean_depth_mm[index] == 0 do continue
		height := world.planetary.waves.height_mm[index]
		height_squared += u64(height) * u64(height)
		coord := shared.planet_sim_coord_for_index(index)
		radial := shared.planet_sim_direction(coord)
		_, east, north := shared.planet_basis(radial)
		direction_sum +=
			(east * f32(world.planetary.waves.direction_east[index]) +
				north * f32(world.planetary.waves.direction_north[index])) *
			f32(height)
		wet_count += 1
	}
	center := shared.Planet_Sim_Coord {
		face = procgen.Terrain_Face_V4(face_index),
		u    = shared.PLANET_SIM_FACE_CELLS / 2,
		v    = shared.PLANET_SIM_FACE_CELLS / 2,
	}
	_, fallback, _ := shared.planet_basis(shared.planet_sim_direction(center))
	direction_length := math.sqrt(
		direction_sum.x * direction_sum.x +
		direction_sum.y * direction_sum.y +
		direction_sum.z * direction_sum.z,
	)
	direction := fallback
	if direction_length > 0.000001 do direction = direction_sum / direction_length
	amplitude: f32
	if wet_count > 0 {
		amplitude = clamp(f32(math.sqrt(f64(height_squared) / f64(wet_count))) / 1_000, 0, 2.5)
	}
	return {amplitude, direction.x, direction.y, direction.z}
}
