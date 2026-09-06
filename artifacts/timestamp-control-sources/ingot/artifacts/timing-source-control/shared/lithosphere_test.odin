package shared

import "core:testing"
import procgen "ingot:procgen"

@(test)
lithosphere_is_deterministic_and_seeded :: proc(t: ^testing.T) {
	a, b, c: Lithosphere
	lithosphere_generate(&a, 41)
	lithosphere_generate(&b, 41)
	lithosphere_generate(&c, 42)
	testing.expect_value(t, a, b)
	testing.expect(t, a != c)
}

@(test)
lithosphere_contains_both_crust_kinds :: proc(t: ^testing.T) {
	value: Lithosphere
	lithosphere_generate(&value, 41)
	oceanic, continental := 0, 0
	for plate in value.plates {
		if plate.crust == .Oceanic do oceanic += 1
		else do continental += 1
	}
	testing.expect(t, oceanic > 0)
	testing.expect(t, continental > 0)
}

@(test)
lithosphere_plate_centres_own_their_samples :: proc(t: ^testing.T) {
	value: Lithosphere
	lithosphere_generate(&value, 99)
	for plate in value.plates {
		sample := lithosphere_sample(&value, plate.centre)
		testing.expect_value(t, sample.plate_id, plate.id)
		expected := Plate_Crust.Continental if tectonic_genesis_continents(&value, plate.centre) >= 0.5 else Plate_Crust.Oceanic
		testing.expect_value(t, sample.crust, expected)
	}
}

@(test)
lithosphere_sampling_is_cube_seam_invariant :: proc(t: ^testing.T) {
	value: Lithosphere
	lithosphere_generate(&value, 31337)
	coord := Planet_Coord{.Pos_X, 0, PLANET_FACE_CELLS / 2}
	sample := lithosphere_sample(&value, planet_direction(coord))
	duplicates, count := planet_duplicates(coord)
	testing.expect(t, count > 0)
	for duplicate in duplicates[:count] {
		other := lithosphere_sample(&value, planet_direction(duplicate))
		testing.expect_value(t, other.plate_id, sample.plate_id)
		testing.expect_value(t, other.boundary, sample.boundary)
		testing.expect(t, abs(other.elevation - sample.elevation) < 0.001)
	}
}

@(test)
lithosphere_oceanic_baseline_is_lower :: proc(t: ^testing.T) {
	testing.expect(t, LITHOSPHERE_OCEANIC_HEIGHT < LITHOSPHERE_CONTINENTAL_HEIGHT)
}

@(test)
lithosphere_velocity_is_tangent_everywhere :: proc(t: ^testing.T) {
	value: Lithosphere
	lithosphere_generate(&value, 91)
	for plate in value.plates {
		for direction in value.plates {
			velocity := lithosphere_plate_velocity_mm_yr(plate, direction.centre)
			testing.expect(t, abs(_lithosphere_dot(velocity, direction.centre)) < 0.0001)
		}
	}
}

@(test)
lithosphere_steps_are_bounded_deterministic_and_normalized :: proc(t: ^testing.T) {
	a, b: Lithosphere
	lithosphere_generate(&a, 91)
	lithosphere_generate(&b, 91)
	original := a.plates[0].centre
	for _ in 0 ..< 64 {
		lithosphere_step(&a, 6_371_000, LITHOSPHERE_STEP_MAX_YEARS)
		lithosphere_step(&b, 6_371_000, LITHOSPHERE_STEP_MAX_YEARS)
	}
	testing.expect_value(t, a, b)
	testing.expect(t, a.plates[0].centre != original)
	testing.expect_value(t, a.geological_age_years, u64(64) * u64(LITHOSPHERE_STEP_MAX_YEARS))
	for plate in a.plates {
		testing.expect(t, abs(_lithosphere_dot(plate.centre, plate.centre) - 1) < 0.0001)
	}
}

@(test)
lithosphere_publishes_physical_boundary_profiles :: proc(t: ^testing.T) {
	value: Lithosphere
	lithosphere_generate(&value, 31337)
	boundary_count, relief_count := 0, 0
	for face in procgen.Terrain_Face_V4 {
		for row in 0 ..= 32 {
			for column in 0 ..= 32 {
				direction := planet_direction_uv(face, f32(column * PLANET_FACE_CELLS / 32), f32(row * PLANET_FACE_CELLS / 32))
				sample := lithosphere_sample(&value, direction)
				if sample.boundary == .Intraplate do continue
				boundary_count += 1
				testing.expect(t, sample.boundary_distance >= 0)
				testing.expect(t, sample.boundary_distance <= LITHOSPHERE_PROFILE_MAX_DISTANCE)
				testing.expect_value(t, sample.elevation, sample.crust_elevation + sample.tectonic_relief)
				if abs(sample.tectonic_relief) > 0.25 do relief_count += 1
			}
		}
	}
	testing.expect(t, boundary_count > 0)
	testing.expect(t, relief_count > boundary_count / 4)
}

@(test)
lithosphere_convergent_roles_follow_crust_buoyancy :: proc(t: ^testing.T) {
	ocean := Lithosphere_Plate{id = 1, crust = .Oceanic, base_crust_age_ka = 120_000}
	continent := Lithosphere_Plate{id = 2, crust = .Continental, base_crust_age_ka = 900_000}
	young_ocean := Lithosphere_Plate{id = 3, crust = .Oceanic, base_crust_age_ka = 20_000}
	testing.expect_value(t, _lithosphere_subduction_role(ocean, continent), Plate_Role.Subducting)
	testing.expect_value(t, _lithosphere_subduction_role(continent, ocean), Plate_Role.Overriding)
	testing.expect_value(t, _lithosphere_subduction_role(ocean, young_ocean), Plate_Role.Subducting)
	testing.expect_value(t, _lithosphere_subduction_role(continent, continent), Plate_Role.Colliding)
}
