#+build !js
package procgen

import "core:math"
import "core:testing"

@(test)
terrain_v4_presets_are_valid_and_reject_bad_ranges :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v4(41)
	testing.expect(t, terrain_recipe_validate_v4(&recipe))
	recipe.parameters.radius = 0
	testing.expect(t, !terrain_recipe_validate_v4(&recipe))
	recipe = terrain_normal_recipe_v4(41)
	recipe.parameters.minimum_radius = recipe.parameters.maximum_radius
	testing.expect(t, !terrain_recipe_validate_v4(&recipe))
	recipe = terrain_normal_recipe_v4(41)
	recipe.surface.latitude_offset = 1
	testing.expect(t, !terrain_recipe_validate_v4(&recipe))
}

@(test)
terrain_v4_face_parameterisation_round_trips :: proc(t: ^testing.T) {
	for face in Terrain_Face_V4 {
		for row in -7 ..= 7 {
			for column in -7 ..= 7 {
				u := f32(column) / 8
				v := f32(row) / 8
				direction := terrain_face_direction_v4(face, u, v)
				located, located_u, located_v := terrain_face_locate_v4(direction)
				testing.expect_value(t, located, face)
				testing.expectf(
					t,
					abs(located_u - u) < 0.00001,
					"face %v u %v != %v",
					face,
					located_u,
					u,
				)
				testing.expectf(
					t,
					abs(located_v - v) < 0.00001,
					"face %v v %v != %v",
					face,
					located_v,
					v,
				)
			}
		}
	}
}

@(test)
terrain_v4_shared_edges_agree_across_faces :: proc(t: ^testing.T) {
	for face in Terrain_Face_V4 {
		for edge in 0 ..< 4 {
			for index in -8 ..= 8 {
				along := f32(index) / 8
				u, v := along, f32(-1)
				switch edge {
				case 1:
					u, v = 1, along
				case 2:
					u, v = along, 1
				case 3:
					u, v = -1, along
				}
				direction := terrain_face_direction_v4(face, u, v)
				other, other_u, other_v := terrain_face_locate_v4(direction)
				rebuilt := terrain_face_direction_v4(other, other_u, other_v)
				delta := rebuilt - direction
				testing.expectf(
					t,
					_terrain_dot_v4(delta, delta) < 0.000000000001,
					"face %v edge %d sample %d did not meet its neighbour",
					face,
					edge,
					index,
				)
			}
		}
	}
}

@(test)
terrain_v4_surface_is_deterministic_and_uses_landform :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v4(91)
	different := false
	for row in -4 ..= 4 {
		for column in -4 ..= 4 {
			direction := terrain_face_direction_v4(.Pos_Z, f32(column) / 4, f32(row) / 4)
			a, a_ok := terrain_primary_surface_v4(&recipe, direction)
			b, b_ok := terrain_primary_surface_v4(&recipe, direction)
			testing.expect(t, a_ok && b_ok)
			testing.expect_value(t, a, b)
			different = different || a.height != a.landform
		}
	}
	testing.expect(t, different, "hill/detail terms never separated height from landform")
	recipe.surface.hill_height = 0
	recipe.surface.detail_height = 0
	for face in Terrain_Face_V4 {
		direction := terrain_face_direction_v4(face, 0.25, -0.5)
		sample, ok := terrain_primary_surface_v4(&recipe, direction)
		testing.expect(t, ok)
		testing.expect_value(t, sample.height, sample.landform)
	}
}

@(test)
terrain_v4_latitude_is_angular_and_monotonic :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v4(7)
	previous := -f32(math.PI)
	for index in -16 ..= 16 {
		latitude := f32(index) * f32(math.PI) / 32
		direction := [3]f32{math.cos(latitude), 0, math.sin(latitude)}
		sample, ok := terrain_primary_surface_v4(&recipe, direction)
		testing.expect(t, ok)
		testing.expectf(t, sample.latitude > previous, "latitude did not increase at %d", index)
		testing.expectf(
			t,
			abs(sample.latitude - latitude) < 0.00001,
			"%v != %v",
			sample.latitude,
			latitude,
		)
		previous = sample.latitude
	}
}

@(test)
terrain_v4_basis_is_orthonormal :: proc(t: ^testing.T) {
	for face in Terrain_Face_V4 {
		for row in -4 ..= 4 {
			for column in -4 ..= 4 {
				direction := terrain_face_direction_v4(face, f32(column) / 4, f32(row) / 4)
				up, east, north := terrain_face_basis_v4(direction)
				testing.expectf(t, abs(_terrain_dot_v4(up, up) - 1) < 0.00001, "up not unit")
				testing.expectf(t, abs(_terrain_dot_v4(east, east) - 1) < 0.00001, "east not unit")
				testing.expectf(
					t,
					abs(_terrain_dot_v4(north, north) - 1) < 0.00001,
					"north not unit",
				)
				testing.expectf(
					t,
					abs(_terrain_dot_v4(up, east)) < 0.00001,
					"up/east not perpendicular",
				)
				testing.expectf(
					t,
					abs(_terrain_dot_v4(up, north)) < 0.00001,
					"up/north not perpendicular",
				)
				testing.expectf(
					t,
					abs(_terrain_dot_v4(east, north)) < 0.00001,
					"east/north not perpendicular",
				)
			}
		}
	}
}

@(test)
terrain_v4_tangent_adjusted_cells_have_bounded_area :: proc(t: ^testing.T) {
	minimum, maximum := max(f32), f32(0)
	step := f32(1) / 32
	for row in -32 ..< 32 {
		for column in -32 ..< 32 {
			u := f32(column) * step
			v := f32(row) * step
			a := terrain_face_direction_v4(.Pos_Z, u, v)
			b := terrain_face_direction_v4(.Pos_Z, u + step, v)
			c := terrain_face_direction_v4(.Pos_Z, u, v + step)
			cross := _terrain_cross_v4(b - a, c - a)
			area := math.sqrt(_terrain_dot_v4(cross, cross))
			minimum = min(minimum, area)
			maximum = max(maximum, area)
		}
	}
	testing.expectf(t, maximum / minimum < 1.42, "cell area ratio %v", maximum / minimum)
}

@(test)
terrain_v4_density_changes_sign_at_the_surface :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v4(71)
	direction := terrain_face_direction_v4(.Pos_X, 0.2, -0.3)
	surface, surface_ok := terrain_primary_surface_v4(&recipe, direction)
	testing.expect(t, surface_ok)
	inside, inside_ok := terrain_density_v4(&recipe, direction * (surface.radius - 1))
	outside, outside_ok := terrain_density_v4(&recipe, direction * (surface.radius + 1))
	testing.expect(t, inside_ok && outside_ok)
	testing.expect(t, inside > 0)
	testing.expect(t, outside < 0)
}

@(test)
terrain_v4_shell_sampling_matches_direct_density :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v4(73)
	request := Terrain_Shell_Request_V4{.Pos_Z, -0.25, -0.25, 2, 2, 0.25, 0.25, -2, 2, 2}
	density: [27]f32
	testing.expect(t, terrain_shell_sample_v4(&recipe, request, density[:]))
	direction := terrain_face_direction_v4(.Pos_Z, -0.25, -0.25)
	direct, ok := terrain_density_v4(&recipe, direction * (recipe.parameters.radius - 2))
	testing.expect(t, ok)
	testing.expect_value(t, density[0], direct)
	testing.expect(t, !terrain_shell_sample_v4(&recipe, request, density[:26]))
}
