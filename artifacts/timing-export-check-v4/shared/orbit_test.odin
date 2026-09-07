package shared

import "core:testing"

@(test)
orbit_epoch_is_seeded_and_deterministic :: proc(t: ^testing.T) {
	first, same, different: Orbit_State
	orbit_init(&first, 42)
	orbit_init(&same, 42)
	orbit_init(&different, 43)
	testing.expect_value(t, first.rotation_epoch, same.rotation_epoch)
	testing.expect_value(t, first.orbital_epoch, same.orbital_epoch)
	testing.expect_value(t, first.moon.phase, same.moon.phase)
	testing.expect(t, first.moon.phase != different.moon.phase)
	testing.expect(
		t,
		first.rotation_epoch != different.rotation_epoch ||
		first.orbital_epoch != different.orbital_epoch,
	)
}

@(test)
orbit_step_preserves_epoch_and_wraps :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	state: Orbit_State
	orbit_init(&state, 7)
	rotation_epoch := state.rotation_epoch
	orbital_epoch := state.orbital_epoch
	lunar_epoch := state.moon.phase
	orbit_step(&state, physical, u64(physical.rotation_period_s))
	testing.expect_value(t, state.rotation_phase, rotation_epoch)
	orbit_step(&state, physical, u64(physical.orbital_period_s - physical.rotation_period_s))
	testing.expect_value(t, state.orbital_phase, orbital_epoch)
	moon: Orbit_State
	orbit_init(&moon, 7)
	orbit_step(&moon, physical, ORBIT_LUNAR_SIDEREAL_PERIOD_S)
	testing.expect_value(t, moon.moon.phase, lunar_epoch)
}

@(test)
solar_geometry_inverts_hemispheres_and_varies_orbital_flux :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	orbit := Orbit_State {
		rotation_phase = 0,
		orbital_phase  = ORBIT_PHASE_SCALE / 4,
	}
	north := orbit_solar_incidence(60_000_000, 0, orbit, physical)
	south := orbit_solar_incidence(-60_000_000, 0, orbit, physical)
	testing.expect(t, north > south)
	orbit.orbital_phase = ORBIT_PHASE_SCALE * 3 / 4
	testing.expect(
		t,
		orbit_solar_incidence(-60_000_000, 0, orbit, physical) >
		orbit_solar_incidence(60_000_000, 0, orbit, physical),
	)
	testing.expect(
		t,
		orbit_flux_factor_ppm(0, physical) >
		orbit_flux_factor_ppm(ORBIT_PHASE_SCALE / 2, physical),
	)
}

@(test)
equinox_is_latitudinally_symmetric :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	orbit := Orbit_State {
		rotation_phase = 0,
		orbital_phase  = 0,
	}
	testing.expect_value(
		t,
		orbit_solar_incidence(45_000_000, 0, orbit, physical),
		orbit_solar_incidence(-45_000_000, 0, orbit, physical),
	)
}

@(test)
ephemeris_rotates_inertial_direction_into_planet_frame :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	physical.obliquity_microradians = 0
	orbit: Orbit_State
	orbit_init(&orbit, 11)
	orbit.orbital_phase = 0
	orbit.rotation_phase = 0
	inertial := orbit_ephemeris(orbit, physical)
	testing.expect(t, inertial.sun.inertial_direction.x > 0.99)
	testing.expect(t, abs(inertial.sun.inertial_direction.y) < 0.01)
	orbit.rotation_phase = ORBIT_PHASE_SCALE / 4
	rotated := orbit_ephemeris(orbit, physical)
	testing.expect(t, abs(rotated.sun.planet_fixed_direction.x) < 0.01)
	testing.expect(t, rotated.sun.planet_fixed_direction.y < -0.99)
}

@(test)
ephemeris_distance_tracks_eccentricity :: proc(t: ^testing.T) {
	body := Orbital_Body {
		semi_major_axis_km = 384_400,
		eccentricity_ppm   = 54_900,
		phase              = 0,
	}
	periapsis := orbit_body_distance_km(body)
	body.phase = ORBIT_PHASE_SCALE / 2
	apoapsis := orbit_body_distance_km(body)
	testing.expect(t, periapsis < u64(body.semi_major_axis_km))
	testing.expect(t, apoapsis > u64(body.semi_major_axis_km))
	testing.expect(t, periapsis < apoapsis)
}

@(test)
lunar_ephemeris_applies_inclination_and_node :: proc(t: ^testing.T) {
	body := Orbital_Body {
		semi_major_axis_km       = 384_400,
		inclination_microdegrees = 5_145_000,
		phase                    = ORBIT_PHASE_SCALE / 4,
	}
	first_node := orbit_body_ephemeris(body, 0, 0, 0)
	quarter_node := orbit_body_ephemeris(body, 0, ORBIT_PHASE_SCALE / 4, 0)
	testing.expect(t, first_node.inertial_direction.z > 0)
	testing.expect(t, first_node.inertial_direction.y > 0)
	testing.expect(t, quarter_node.inertial_direction.x < 0)
	testing.expect(t, abs(quarter_node.inertial_direction.y) < 0.01)
}

@(test)
lunar_phase_is_relative_to_sun :: proc(t: ^testing.T) {
	physical := planet_physical_earthlike()
	orbit: Orbit_State
	orbit_init(&orbit, 13)
	orbit.orbital_phase = ORBIT_PHASE_SCALE / 8
	orbit.moon.phase = orbit.orbital_phase
	new_moon := orbit_ephemeris(orbit, physical)
	testing.expect_value(t, new_moon.lunar_phase, u64(0))
	orbit.moon.phase = (orbit.orbital_phase + ORBIT_PHASE_SCALE / 2) % ORBIT_PHASE_SCALE
	full_moon := orbit_ephemeris(orbit, physical)
	testing.expect_value(t, full_moon.lunar_phase, ORBIT_PHASE_SCALE / 2)
}

@(test)
lunar_illuminated_fraction_matches_phase_convention :: proc(t: ^testing.T) {
	testing.expect_value(t, orbit_lunar_illuminated_fraction_ppm(0), u32(0))
	testing.expect_value(
		t,
		orbit_lunar_illuminated_fraction_ppm(ORBIT_PHASE_SCALE / 4),
		u32(500_000),
	)
	testing.expect_value(
		t,
		orbit_lunar_illuminated_fraction_ppm(ORBIT_PHASE_SCALE / 2),
		u32(1_000_000),
	)
	testing.expect_value(
		t,
		orbit_lunar_illuminated_fraction_ppm(ORBIT_PHASE_SCALE * 3 / 4),
		u32(500_000),
	)
	testing.expect_value(t, orbit_lunar_illuminated_fraction_ppm(ORBIT_PHASE_SCALE), u32(0))
}
