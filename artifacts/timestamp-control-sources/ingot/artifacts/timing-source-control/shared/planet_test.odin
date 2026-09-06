package shared

import procgen "ingot:procgen"
import "core:testing"

@(test)
planet_coordinates_round_trip_across_faces :: proc(t: ^testing.T) {
	for face in procgen.Terrain_Face_V4 {
		for row in 0 ..= 8 {
			for column in 0 ..= 8 {
				u := i32(column * PLANET_FACE_CELLS / 8)
				v := i32(row * PLANET_FACE_CELLS / 8)
				coord := Planet_Coord{face, u, v}
				direction := planet_direction(coord)
				located, located_u, located_v := planet_locate(direction)
				rebuilt := planet_direction_uv(located, located_u, located_v)
				delta := rebuilt - direction
				testing.expectf(t, delta.x * delta.x + delta.y * delta.y + delta.z * delta.z < 0.000000000001, "face %v coordinate did not round trip", face)
			}
		}
	}
}

@(test)
planet_neighbours_cross_every_face_edge :: proc(t: ^testing.T) {
	middle := i32(PLANET_FACE_CELLS / 2)
	for face in procgen.Terrain_Face_V4 {
		edges := [?]struct { coord: Planet_Coord, du, dv: i32 } {
			{{face, 0, middle}, -1, 0},
			{{face, PLANET_FACE_CELLS, middle}, 1, 0},
			{{face, middle, 0}, 0, -1},
			{{face, middle, PLANET_FACE_CELLS}, 0, 1},
		}
		for edge in edges {
			neighbour := planet_neighbour(edge.coord, edge.du, edge.dv)
			testing.expect(t, planet_coord_valid(neighbour))
			testing.expectf(t, neighbour.face != face, "face %v edge did not cross", face)
		}
	}
}

@(test)
planet_diagonal_neighbours_cross_edges_deterministically :: proc(t: ^testing.T) {
	middle := i32(PLANET_FACE_CELLS / 2)
	for face in procgen.Terrain_Face_V4 {
		edges := [?]struct { coord: Planet_Coord, du, dv: i32 } {
			{{face, 0, middle}, -1, 1},
			{{face, PLANET_FACE_CELLS, middle}, 1, -1},
			{{face, middle, 0}, 1, -1},
			{{face, middle, PLANET_FACE_CELLS}, -1, 1},
		}
		for edge in edges {
			first := planet_neighbour(edge.coord, edge.du, edge.dv)
			second := planet_neighbour(edge.coord, edge.du, edge.dv)
			testing.expect(t, planet_coord_valid(first))
			testing.expect_value(t, first, second)
			testing.expect_value(t, planet_canonical(first), first)
		}
	}
}

@(test)
planet_index_covers_each_face_without_overlap :: proc(t: ^testing.T) {
	first := Planet_Coord{.Pos_X, 0, 0}
	last := Planet_Coord{.Neg_Z, PLANET_FACE_CELLS, PLANET_FACE_CELLS}
	testing.expect_value(t, planet_index(first), 0)
	testing.expect_value(t, planet_index(last), PLANET_FIELD_CELLS - 1)
	stride := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
	for face in procgen.Terrain_Face_V4 {
		coord := Planet_Coord{face, 0, 0}
		testing.expect_value(t, planet_index(coord), int(face) * stride)
	}
}

// Every edge cell shares its direction with exactly one duplicate (two at a
// cube corner), and the whole duplicate group agrees on one canonical owner.
@(test)
planet_edge_duplicates_share_direction_and_canonical :: proc(t: ^testing.T) {
	middle := i32(PLANET_FACE_CELLS / 2)
	last := i32(PLANET_FACE_CELLS)
	samples := [?]Planet_Coord {
		{.Pos_X, 0, middle},
		{.Pos_X, last, middle},
		{.Pos_Y, middle, 0},
		{.Neg_Z, middle, last},
		{.Pos_X, 0, 0}, // cube corner
		{.Neg_Y, last, last}, // cube corner
	}
	for coord, sample_index in samples {
		duplicates, count := planet_duplicates(coord)
		corner := sample_index >= 4
		expected := 2 if corner else 1
		testing.expectf(t, count == expected, "coord %v has %d duplicates, expected %d", coord, count, expected)
		direction := planet_direction(coord)
		canonical := planet_canonical(coord)
		for index in 0 ..< count {
			duplicate := duplicates[index]
			testing.expect(t, duplicate.face != coord.face, "duplicate on another face")
			other := planet_direction(duplicate)
			delta := other - direction
			testing.expectf(
				t,
				delta.x * delta.x + delta.y * delta.y + delta.z * delta.z < 0.000001,
				"duplicate %v of %v is a different direction",
				duplicate,
				coord,
			)
			testing.expect_value(t, planet_canonical(duplicate), canonical)
		}
	}
}

@(test)
planet_interior_cells_have_no_duplicates :: proc(t: ^testing.T) {
	coord := Planet_Coord{.Pos_Z, 5, 700}
	_, count := planet_duplicates(coord)
	testing.expect_value(t, count, 0)
	testing.expect_value(t, planet_canonical(coord), coord)
}
