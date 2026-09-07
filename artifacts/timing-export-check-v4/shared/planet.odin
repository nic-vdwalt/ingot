package shared

import "core:math"
import procgen "ingot:procgen"

PLANET_RADIUS :: f32(1080)
PLANET_FACE_COUNT :: len(procgen.Terrain_Face_V4)
PLANET_FACE_CELLS :: 768
PLANET_FACE_RESOLUTION :: PLANET_FACE_CELLS + 1
PLANET_FIELD_CELLS :: PLANET_FACE_COUNT * PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
PLANET_PATCHES_PER_FACE :: 8
PLANET_PATCH_CELLS :: PLANET_FACE_CELLS / PLANET_PATCHES_PER_FACE
#assert(PLANET_FACE_CELLS % PLANET_PATCHES_PER_FACE == 0)

Planet_Coord :: struct {
	face: procgen.Terrain_Face_V4,
	u:    i32,
	v:    i32,
}

planet_coord_valid :: proc(coord: Planet_Coord) -> bool {
	return coord.u >= 0 && coord.u < PLANET_FACE_RESOLUTION &&
		coord.v >= 0 && coord.v < PLANET_FACE_RESOLUTION
}

planet_index :: proc(coord: Planet_Coord) -> int {
	assert(planet_coord_valid(coord), "planet_index: invalid coordinate")
	face_stride := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
	return int(coord.face) * face_stride + int(coord.v) * PLANET_FACE_RESOLUTION + int(coord.u)
}

planet_direction :: proc(coord: Planet_Coord) -> [3]f32 {
	assert(planet_coord_valid(coord), "planet_direction: invalid coordinate")
	return planet_direction_uv(coord.face, f32(coord.u), f32(coord.v))
}

planet_direction_uv :: proc(face: procgen.Terrain_Face_V4, u, v: f32) -> [3]f32 {
	maximum := f32(PLANET_FACE_CELLS)
	assert(u >= 0 && u <= maximum, "planet_direction_uv: u outside face")
	assert(v >= 0 && v <= maximum, "planet_direction_uv: v outside face")
	return _planet_direction_extended(face, u, v)
}

planet_neighbour_direction :: proc(coord: Planet_Coord, du, dv: f32) -> [3]f32 {
	assert(planet_coord_valid(coord), "planet_neighbour_direction: invalid coordinate")
	assert(abs(du) <= f32(PLANET_FACE_CELLS), "planet_neighbour_direction: u step exceeds face")
	assert(abs(dv) <= f32(PLANET_FACE_CELLS), "planet_neighbour_direction: v step exceeds face")
	return _planet_direction_extended(coord.face, f32(coord.u) + du, f32(coord.v) + dv)
}

@(private)
_planet_direction_extended :: proc(face: procgen.Terrain_Face_V4, u, v: f32) -> [3]f32 {
	maximum := f32(PLANET_FACE_CELLS)
	face_u := u * 2 / maximum - 1
	face_v := v * 2 / maximum - 1
	a := math.tan(face_u * math.PI / 4)
	b := math.tan(face_v * math.PI / 4)
	direction: [3]f32
	switch face {
	case .Pos_X: direction = {1, b, -a}
	case .Neg_X: direction = {-1, b, a}
	case .Pos_Y: direction = {a, 1, -b}
	case .Neg_Y: direction = {a, -1, b}
	case .Pos_Z: direction = {a, b, 1}
	case .Neg_Z: direction = {-a, b, -1}
	}
	return _planet_normalize(direction)
}

planet_locate :: proc(direction: [3]f32) -> (face: procgen.Terrain_Face_V4, u, v: f32) {
	located_face, face_u, face_v := procgen.terrain_face_locate_v4(direction)
	maximum := f32(PLANET_FACE_CELLS)
	return located_face, (face_u + 1) * maximum * 0.5, (face_v + 1) * maximum * 0.5
}

planet_position :: proc(direction: [3]f32, height: f32) -> [3]f32 {
	return direction * (PLANET_RADIUS + height)
}

planet_basis :: proc(direction: [3]f32) -> (up, east, north: [3]f32) {
	return procgen.terrain_face_basis_v4(direction)
}

@(private)
_planet_normalize :: proc(value: [3]f32) -> [3]f32 {
	length_squared := value.x * value.x + value.y * value.y + value.z * value.z
	assert(length_squared > 0, "_planet_normalize: zero vector")
	return value / math.sqrt(length_squared)
}

planet_neighbour :: proc(coord: Planet_Coord, du, dv: i32) -> Planet_Coord {
	assert(planet_coord_valid(coord), "planet_neighbour: invalid coordinate")
	assert(abs(du) <= PLANET_FACE_CELLS, "planet_neighbour: u step exceeds face")
	assert(abs(dv) <= PLANET_FACE_CELLS, "planet_neighbour: v step exceeds face")
	u := coord.u + du
	v := coord.v + dv
	if u >= 0 && u < PLANET_FACE_RESOLUTION && v >= 0 && v < PLANET_FACE_RESOLUTION {
		return planet_canonical({coord.face, u, v})
	}
	direction := _planet_direction_extended(coord.face, f32(u), f32(v))
	face, located_u, located_v := planet_locate(direction)
	return planet_canonical(
		{
			face,
			i32(clamp(located_u + 0.5, 0, f32(PLANET_FACE_CELLS))),
			i32(clamp(located_v + 0.5, 0, f32(PLANET_FACE_CELLS))),
		},
	)
}

// planet_coord_is_edge reports whether the cell sits on a face boundary and
// therefore has one or two duplicates on adjacent faces sharing the same
// direction. Face edges store the same sphere point 2-3 times (769 vertices
// over 768 cells), and nothing else keeps those duplicates in sync.
planet_coord_is_edge :: proc(coord: Planet_Coord) -> bool {
	return coord.u == 0 || coord.u == PLANET_FACE_CELLS ||
		coord.v == 0 || coord.v == PLANET_FACE_CELLS
}

// _planet_face_project inverts _planet_direction_extended for one named face:
// it recovers the face-local (u, v) a direction lands on, reporting ok only
// when the direction actually falls inside that face's angular domain.
@(private)
_planet_face_project :: proc(
	face: procgen.Terrain_Face_V4,
	direction: [3]f32,
) -> (
	u, v: f32,
	ok: bool,
) {
	k: f32
	a, b: f32
	switch face {
	case .Pos_X:
		k = direction.x
		if k <= 0 do return 0, 0, false
		a = -direction.z / k
		b = direction.y / k
	case .Neg_X:
		k = -direction.x
		if k <= 0 do return 0, 0, false
		a = direction.z / k
		b = direction.y / k
	case .Pos_Y:
		k = direction.y
		if k <= 0 do return 0, 0, false
		a = direction.x / k
		b = -direction.z / k
	case .Neg_Y:
		k = -direction.y
		if k <= 0 do return 0, 0, false
		a = direction.x / k
		b = direction.z / k
	case .Pos_Z:
		k = direction.z
		if k <= 0 do return 0, 0, false
		a = direction.x / k
		b = direction.y / k
	case .Neg_Z:
		k = -direction.z
		if k <= 0 do return 0, 0, false
		a = -direction.x / k
		b = direction.y / k
	}
	epsilon := f32(1e-4)
	if abs(a) > 1 + epsilon || abs(b) > 1 + epsilon do return 0, 0, false
	maximum := f32(PLANET_FACE_CELLS)
	face_u := math.atan(clamp(a, -1, 1)) * 4 / math.PI
	face_v := math.atan(clamp(b, -1, 1)) * 4 / math.PI
	return (face_u + 1) * maximum * 0.5, (face_v + 1) * maximum * 0.5, true
}

// planet_duplicates lists the coordinates on *other* faces that store the
// same sphere direction as an edge cell. Interior cells have none; edge
// cells have one; the eight cube corners have two.
planet_duplicates :: proc(coord: Planet_Coord) -> (result: [2]Planet_Coord, count: int) {
	assert(planet_coord_valid(coord), "planet_duplicates: invalid coordinate")
	if !planet_coord_is_edge(coord) do return {}, 0
	direction := planet_direction(coord)
	epsilon := f32(1e-3)
	for face in procgen.Terrain_Face_V4 {
		if face == coord.face do continue
		u, v, ok := _planet_face_project(face, direction)
		if !ok do continue
		rounded_u := math.round(u)
		rounded_v := math.round(v)
		if abs(u - rounded_u) > epsilon || abs(v - rounded_v) > epsilon do continue
		if rounded_u < 0 || rounded_u > f32(PLANET_FACE_CELLS) do continue
		if rounded_v < 0 || rounded_v > f32(PLANET_FACE_CELLS) do continue
		if count >= len(result) do break
		result[count] = {face, i32(rounded_u), i32(rounded_v)}
		count += 1
	}
	return result, count
}

// planet_canonical maps every duplicate of an edge cell onto one canonical
// owner (the smallest face/v/u in the duplicate group), so writes always
// land on a single cell and mirrors keep the copies in agreement.
planet_canonical :: proc(coord: Planet_Coord) -> Planet_Coord {
	if !planet_coord_is_edge(coord) do return coord
	duplicates, count := planet_duplicates(coord)
	best := coord
	for index in 0 ..< count {
		candidate := duplicates[index]
		if _planet_coord_less(candidate, best) do best = candidate
	}
	return best
}

@(private)
_planet_coord_less :: proc(a, b: Planet_Coord) -> bool {
	if a.face != b.face do return a.face < b.face
	if a.v != b.v do return a.v < b.v
	return a.u < b.u
}
