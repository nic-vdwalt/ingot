package shared

import "core:testing"

@(test)
planet_heightfield_brush_crosses_face_seam :: proc(t: ^testing.T) {
	field: Planet_Heightfield
	planet_heightfield_init(&field)
	defer planet_heightfield_deinit(&field)
	center := Planet_Coord{.Pos_X, 0, PLANET_FACE_CELLS / 2}
	planet_heightfield_apply(&field, center, 1, 2)
	across := planet_neighbour(center, -1, 0)
	testing.expect(t, across.face != center.face)
	testing.expect(t, planet_heightfield_delta(&field, across) > 0)
	testing.expect(t, field.modified)
}

@(test)
planet_heightfield_brush_is_deterministic :: proc(t: ^testing.T) {
	first, second: Planet_Heightfield
	planet_heightfield_init(&first)
	planet_heightfield_init(&second)
	defer planet_heightfield_deinit(&first)
	defer planet_heightfield_deinit(&second)
	center := Planet_Coord{.Pos_Z, 384, 384}
	planet_heightfield_apply(&first, center, -1, 4)
	planet_heightfield_apply(&second, center, -1, 4)
	for delta, index in first.deltas {
		testing.expect_value(t, delta, second.deltas[index])
	}
}
