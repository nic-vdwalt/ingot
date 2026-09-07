package shared

ORBIT_PHASE_SCALE :: u64(1_000_000_000)
ORBIT_TRIG_SCALE :: i32(1_000_000)
ORBIT_ASTRONOMICAL_UNIT_KM :: u32(149_597_870)
ORBIT_LUNAR_SIDEREAL_PERIOD_S :: u64(2_360_591)
ORBIT_LUNAR_NODE_PERIOD_S :: u64(586_863_360)

Orbital_Body :: struct {
	mass_teratonnes:          u64,
	semi_major_axis_km:       u32,
	eccentricity_ppm:         u32,
	inclination_microdegrees: i32,
	phase:                    u64,
}

Orbit_Vector :: struct {
	x: i64,
	y: i64,
	z: i64,
}

Orbital_Body_Ephemeris :: struct {
	body:                   Orbital_Body,
	distance_km:            u64,
	inertial_direction:     [3]f32,
	planet_fixed_direction: [3]f32,
}

Orbit_Ephemeris :: struct {
	sun:         Orbital_Body_Ephemeris,
	moon:        Orbital_Body_Ephemeris,
	lunar_phase: u64,
}

Orbit_State :: struct {
	simulated_seconds: u64,
	rotation_phase:    u64,
	orbital_phase:     u64,
	rotation_epoch:    u64,
	orbital_epoch:     u64,
	surface_revision:  u64,
	moon:              Orbital_Body,
}

orbit_seed_hash :: proc(seed, stream: u64) -> u64 {
	value := seed + stream * 0x9e3779b97f4a7c15
	value = (value ~ (value >> 30)) * 0xbf58476d1ce4e5b9
	value = (value ~ (value >> 27)) * 0x94d049bb133111eb
	return value ~ (value >> 31)
}

orbit_derived_epoch :: proc(state: Orbit_State, stream: u64) -> u64 {
	return orbit_seed_hash(state.orbital_epoch, stream) % ORBIT_PHASE_SCALE
}

orbit_phase_at :: proc(epoch, simulated_seconds, period_s: u64) -> u64 {
	assert(period_s > 0, "orbit_phase_at: zero period")
	return(
		(epoch + simulated_seconds % period_s * ORBIT_PHASE_SCALE / period_s) %
		ORBIT_PHASE_SCALE \
	)
}

orbit_retrograde_phase_at :: proc(epoch, simulated_seconds, period_s: u64) -> u64 {
	assert(period_s > 0, "orbit_retrograde_phase_at: zero period")
	advance := simulated_seconds % period_s * ORBIT_PHASE_SCALE / period_s
	return (epoch + ORBIT_PHASE_SCALE - advance) % ORBIT_PHASE_SCALE
}

orbit_init :: proc(state: ^Orbit_State, seed: u64) {
	assert(state != nil, "orbit_init: nil state")
	state^ = {
		rotation_epoch = orbit_seed_hash(seed, 0) % ORBIT_PHASE_SCALE,
		orbital_epoch = orbit_seed_hash(seed, 1) % ORBIT_PHASE_SCALE,
		moon = {
			mass_teratonnes = 73_420_000_000,
			semi_major_axis_km = 384_400,
			eccentricity_ppm = 54_900,
			inclination_microdegrees = 5_145_000,
		},
	}
	state.rotation_phase = state.rotation_epoch
	state.orbital_phase = state.orbital_epoch
	state.moon.phase = orbit_derived_epoch(state^, 2)
}

orbit_step :: proc(state: ^Orbit_State, physical: Planet_Physical_Parameters, seconds: u64) {
	assert(state != nil, "orbit_step: nil state")
	assert(
		physical.rotation_period_s > 0 && physical.orbital_period_s > 0,
		"orbit_step: invalid periods",
	)
	state.simulated_seconds += seconds
	state.rotation_phase =
		(state.rotation_epoch +
			state.simulated_seconds %
				u64(physical.rotation_period_s) *
				ORBIT_PHASE_SCALE /
				u64(physical.rotation_period_s)) %
		ORBIT_PHASE_SCALE
	state.orbital_phase =
		(state.orbital_epoch +
			state.simulated_seconds %
				u64(physical.orbital_period_s) *
				ORBIT_PHASE_SCALE /
				u64(physical.orbital_period_s)) %
		ORBIT_PHASE_SCALE
	state.moon.phase = orbit_phase_at(
		orbit_derived_epoch(state^, 2),
		state.simulated_seconds,
		ORBIT_LUNAR_SIDEREAL_PERIOD_S,
	)
}

orbit_triangle_cos :: proc(phase: u64) -> i32 {
	wrapped := phase % ORBIT_PHASE_SCALE
	half := ORBIT_PHASE_SCALE / 2
	if wrapped < half {
		return i32(1_000_000 - i64(wrapped) * 2_000_000 / i64(half))
	}
	return i32(-1_000_000 + i64(wrapped - half) * 2_000_000 / i64(half))
}

orbit_triangle_sin :: proc(phase: u64) -> i32 {
	return orbit_triangle_cos((phase + ORBIT_PHASE_SCALE * 3 / 4) % ORBIT_PHASE_SCALE)
}

orbit_lunar_illuminated_fraction_ppm :: proc(lunar_phase: u64) -> u32 {
	cosine := i64(orbit_triangle_cos(lunar_phase))
	return u32((i64(ORBIT_TRIG_SCALE) - cosine) / 2)
}

orbit_phase_from_microdegrees :: proc(angle_microdegrees: i32) -> u64 {
	wrapped := i64(angle_microdegrees) * i64(ORBIT_PHASE_SCALE) / 360_000_000
	wrapped = wrapped % i64(ORBIT_PHASE_SCALE)
	if wrapped < 0 do wrapped += i64(ORBIT_PHASE_SCALE)
	return u64(wrapped)
}

orbit_phase_difference :: proc(phase, reference: u64) -> u64 {
	return(
		(phase % ORBIT_PHASE_SCALE + ORBIT_PHASE_SCALE - reference % ORBIT_PHASE_SCALE) %
		ORBIT_PHASE_SCALE \
	)
}

orbit_rotate_x :: proc(vector: Orbit_Vector, phase: u64) -> Orbit_Vector {
	cosine := i64(orbit_triangle_cos(phase))
	sine := i64(orbit_triangle_sin(phase))
	return {
		x = vector.x,
		y = (vector.y * cosine - vector.z * sine) / i64(ORBIT_TRIG_SCALE),
		z = (vector.y * sine + vector.z * cosine) / i64(ORBIT_TRIG_SCALE),
	}
}

orbit_rotate_z :: proc(vector: Orbit_Vector, phase: u64) -> Orbit_Vector {
	cosine := i64(orbit_triangle_cos(phase))
	sine := i64(orbit_triangle_sin(phase))
	return {
		x = (vector.x * cosine - vector.y * sine) / i64(ORBIT_TRIG_SCALE),
		y = (vector.x * sine + vector.y * cosine) / i64(ORBIT_TRIG_SCALE),
		z = vector.z,
	}
}

orbit_vector_direction :: proc(vector: Orbit_Vector) -> [3]f32 {
	magnitude := integer_sqrt(u64(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z))
	assert(magnitude > 0, "orbit_vector_direction: zero vector")
	return {
		f32(vector.x) / f32(magnitude),
		f32(vector.y) / f32(magnitude),
		f32(vector.z) / f32(magnitude),
	}
}

orbit_body_distance_km :: proc(body: Orbital_Body) -> u64 {
	eccentricity := i64(body.eccentricity_ppm)
	eccentricity_squared_ppm := eccentricity * eccentricity / i64(ORBIT_TRIG_SCALE)
	cosine := i64(orbit_triangle_cos(body.phase))
	numerator := i64(body.semi_major_axis_km) * (i64(ORBIT_TRIG_SCALE) - eccentricity_squared_ppm)
	denominator := i64(ORBIT_TRIG_SCALE) + eccentricity * cosine / i64(ORBIT_TRIG_SCALE)
	assert(denominator > 0, "orbit_body_distance_km: invalid eccentricity")
	return u64(max(numerator / denominator, i64(1)))
}

orbit_body_ephemeris :: proc(
	body: Orbital_Body,
	rotation_phase: u64,
	ascending_node_phase: u64,
	obliquity_phase: u64,
) -> Orbital_Body_Ephemeris {
	direction := Orbit_Vector {
		x = i64(orbit_triangle_cos(body.phase)),
		y = i64(orbit_triangle_sin(body.phase)),
	}
	direction = orbit_rotate_x(
		direction,
		orbit_phase_from_microdegrees(body.inclination_microdegrees),
	)
	direction = orbit_rotate_z(direction, ascending_node_phase)
	direction = orbit_rotate_x(direction, obliquity_phase)
	inertial_direction := orbit_vector_direction(direction)
	planet_fixed := orbit_rotate_z(direction, orbit_phase_difference(0, rotation_phase))
	return {
		body = body,
		distance_km = orbit_body_distance_km(body),
		inertial_direction = inertial_direction,
		planet_fixed_direction = orbit_vector_direction(planet_fixed),
	}
}

orbit_ephemeris :: proc(
	orbit: Orbit_State,
	physical: Planet_Physical_Parameters,
) -> Orbit_Ephemeris {
	obliquity_microdegrees := i32(i64(physical.obliquity_microradians) * 57_295_780 / 1_000_000)
	obliquity_phase := orbit_phase_from_microdegrees(obliquity_microdegrees)
	sun := Orbital_Body {
		mass_teratonnes    = 1_988_470_000_000_000_000,
		semi_major_axis_km = ORBIT_ASTRONOMICAL_UNIT_KM,
		eccentricity_ppm   = physical.orbital_eccentricity_ppm,
		phase              = orbit.orbital_phase,
	}
	lunar_node_phase := orbit_retrograde_phase_at(
		orbit_derived_epoch(orbit, 3),
		orbit.simulated_seconds,
		ORBIT_LUNAR_NODE_PERIOD_S,
	)
	return {
		sun = orbit_body_ephemeris(sun, orbit.rotation_phase, 0, obliquity_phase),
		moon = orbit_body_ephemeris(
			orbit.moon,
			orbit.rotation_phase,
			lunar_node_phase,
			obliquity_phase,
		),
		lunar_phase = orbit_phase_difference(orbit.moon.phase, sun.phase),
	}
}

orbit_solar_declination_microdegrees :: proc(
	orbital_phase: u64,
	physical: Planet_Physical_Parameters,
) -> i32 {
	obliquity_microdegrees := i64(physical.obliquity_microradians) * 57_295_780 / 1_000_000
	return i32(
		obliquity_microdegrees * i64(orbit_triangle_sin(orbital_phase)) / i64(ORBIT_TRIG_SCALE),
	)
}

orbit_flux_factor_ppm :: proc(orbital_phase: u64, physical: Planet_Physical_Parameters) -> u32 {
	variation :=
		i64(physical.orbital_eccentricity_ppm) *
		2 *
		i64(orbit_triangle_cos(orbital_phase)) /
		i64(ORBIT_TRIG_SCALE)
	return u32(clamp(i64(1_000_000) + variation, i64(500_000), i64(1_500_000)))
}

orbit_latitude_phase :: proc(latitude_microdegrees: i32) -> u64 {
	return orbit_phase_from_microdegrees(latitude_microdegrees)
}

orbit_solar_incidence :: proc(
	latitude_microdegrees: i32,
	longitude_phase: u64,
	orbit: Orbit_State,
	physical: Planet_Physical_Parameters,
) -> i32 {
	declination := orbit_solar_declination_microdegrees(orbit.orbital_phase, physical)
	latitude_phase := orbit_latitude_phase(latitude_microdegrees)
	declination_phase := orbit_latitude_phase(declination)
	sin_latitude := i64(orbit_triangle_sin(latitude_phase))
	cos_latitude := i64(orbit_triangle_cos(latitude_phase))
	sin_declination := i64(orbit_triangle_sin(declination_phase))
	cos_declination := i64(orbit_triangle_cos(declination_phase))
	hour := orbit_triangle_cos((orbit.rotation_phase + longitude_phase) % ORBIT_PHASE_SCALE)
	incidence :=
		sin_latitude * sin_declination / i64(ORBIT_TRIG_SCALE) +
		cos_latitude * cos_declination / i64(ORBIT_TRIG_SCALE) * i64(hour) / i64(ORBIT_TRIG_SCALE)
	return i32(clamp(incidence, i64(0), i64(ORBIT_TRIG_SCALE)))
}
