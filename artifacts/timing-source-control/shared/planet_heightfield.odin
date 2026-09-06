package shared

Planet_Heightfield :: struct {
	deltas:   []i16,
	modified: bool,
}

planet_heightfield_init :: proc(field: ^Planet_Heightfield, allocator := context.allocator) {
	assert(field != nil, "planet_heightfield_init: nil field")
	field^ = {}
	field.deltas = make([]i16, PLANET_FIELD_CELLS, allocator)
}

planet_heightfield_deinit :: proc(field: ^Planet_Heightfield, allocator := context.allocator) {
	assert(field != nil, "planet_heightfield_deinit: nil field")
	delete(field.deltas, allocator)
	field^ = {}
}

planet_heightfield_delta :: proc(field: ^Planet_Heightfield, coord: Planet_Coord) -> f32 {
	assert(field != nil, "planet_heightfield_delta: nil field")
	assert(len(field.deltas) == PLANET_FIELD_CELLS, "planet_heightfield_delta: storage")
	return f32(field.deltas[planet_index(coord)]) / f32(HEIGHT_DELTA_SCALE)
}

planet_heightfield_apply :: proc(
	field: ^Planet_Heightfield,
	center: Planet_Coord,
	direction: i16,
	radius: i32 = TERRAFORM_RADIUS,
) {
	assert(field != nil, "planet_heightfield_apply: nil field")
	assert(direction == 1 || direction == -1, "planet_heightfield_apply: invalid direction")
	assert(terraform_radius_valid(radius), "planet_heightfield_apply: radius")
	rings := i16(radius + 1)
	for offset_v in -radius ..= radius {
		for offset_u in -radius ..= radius {
			target := planet_neighbour(center, offset_u, offset_v)
			ring := max(abs(offset_u), abs(offset_v))
			amount := direction * (TERRAFORM_PEAK * i16(i32(rings) - ring)) / rings
			index := planet_index(target)
			total := field.deltas[index] + amount
			field.deltas[index] = clamp(total, -TERRAFORM_MAX_DELTA, TERRAFORM_MAX_DELTA)
			if field.deltas[index] != 0 do field.modified = true
			planet_heightfield_mirror(field, target)
		}
	}
}

// planet_heightfield_mirror copies an edge cell's delta onto its duplicates
// on adjacent faces. Face edges store the same sphere point 2-3 times, and a
// write that only lands on one copy shows up as a crack at the seam. Every
// path that writes deltas at a possibly-edge coordinate must call this.
planet_heightfield_mirror :: proc(field: ^Planet_Heightfield, coord: Planet_Coord) {
	assert(field != nil, "planet_heightfield_mirror: nil field")
	if !planet_coord_is_edge(coord) do return
	value := field.deltas[planet_index(coord)]
	duplicates, count := planet_duplicates(coord)
	for index in 0 ..< count {
		field.deltas[planet_index(duplicates[index])] = value
	}
}
