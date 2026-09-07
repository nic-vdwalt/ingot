package shared

import "core:testing"

@(test)
planet_water_crosses_cube_face_seam :: proc(t: ^testing.T) {
	field: Planet_Waterfield
	planet_waterfield_init(&field)
	defer planet_waterfield_deinit(&field)
	center := Planet_Coord{.Pos_X, 0, PLANET_FACE_CELLS / 2}
	across := planet_neighbour(center, -1, 0)
	center_index := planet_index(center)
	across_index := planet_index(across)
	field.depths[center_index] = 8
	field.ground[across_index] = -8
	moved := planet_waterfield_step(&field)
	testing.expect(t, moved)
	testing.expect(t, field.depths[across_index] > 0)
	testing.expect(t, across.face != center.face)
}

@(test)
planet_water_settles_when_every_surface_matches :: proc(t: ^testing.T) {
	field: Planet_Waterfield
	planet_waterfield_init(&field)
	defer planet_waterfield_deinit(&field)
	moved := planet_waterfield_step(&field)
	testing.expect(t, !moved)
	testing.expect(t, field.settled)
}

@(test)
planet_water_active_step_is_bounded_and_crosses_seams :: proc(t: ^testing.T) {
	field: Planet_Waterfield
	planet_waterfield_init(&field)
	defer planet_waterfield_deinit(&field)
	center := Planet_Coord{.Pos_X, 0, PLANET_FACE_CELLS / 2}
	across := planet_neighbour(center, -1, 0)
	field.depths[planet_index(center)] = 8
	field.ground[planet_index(across)] = -8
	planet_waterfield_activate_region(&field, center, 0)
	moved := planet_waterfield_step_active(&field, 16)
	testing.expect(t, moved)
	testing.expect(t, field.last_cells <= 16)
	testing.expect(t, field.depths[planet_index(across)] > 0)
}

@(test)
planet_water_active_step_never_exceeds_budget :: proc(t: ^testing.T) {
	field: Planet_Waterfield
	planet_waterfield_init(&field)
	defer planet_waterfield_deinit(&field)
	center := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	field.depths[planet_index(center)] = 64
	planet_waterfield_activate_region(&field, center, 12)
	_ = planet_waterfield_step_active(&field, 32)
	testing.expect(t, field.last_cells <= 32)
	testing.expect(t, field.active_count > 0)
}
