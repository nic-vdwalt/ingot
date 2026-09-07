package shared

TIDE_POTENTIAL_SCALE :: i64(1_000_000)

tide_equilibrium_mm :: proc(
	physical: Planet_Physical_Parameters,
	ephemeris: Orbital_Body_Ephemeris,
	surface_direction: [3]f32,
) -> i32 {
	assert(physical.gravity_milli_m_s2 > 0, "tide_equilibrium_mm: zero gravity")
	distance := max(ephemeris.distance_km, u64(1))
	body_direction := ephemeris.planet_fixed_direction
	dot := clamp(
		body_direction.x * surface_direction.x +
		body_direction.y * surface_direction.y +
		body_direction.z * surface_direction.z,
		f32(-1),
		f32(1),
	)
	dot_micro := i64(dot * f32(TIDE_POTENTIAL_SCALE))
	legendre := (3 * dot_micro * dot_micro / 1_000_000 - 1_000_000) / 2
	numerator :=
		i64(ephemeris.body.mass_teratonnes / 1_000_000) *
		i64(physical.radius_m / 1000) *
		i64(physical.radius_m / 1000) *
		legendre
	denominator :=
		i64(distance * distance * distance / 1_000_000) * i64(physical.gravity_milli_m_s2)
	if denominator <= 0 do return 0
	return i32(clamp(numerator / denominator / 800, i64(-12_000), i64(12_000)))
}
