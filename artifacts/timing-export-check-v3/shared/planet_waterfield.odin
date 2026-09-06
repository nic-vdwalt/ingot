package shared

import procgen "ingot:procgen"

PLANET_WATERFIELD_ACTIVE_CAPACITY :: 65_536
PLANET_WATERFIELD_STEP_BUDGET :: 2_048

Planet_Waterfield :: struct {
	depths:       []u32,
	ground:       []i32,
	scratch:      []u32,
	active:       [PLANET_WATERFIELD_ACTIVE_CAPACITY]i32,
	active_marks: []bool,
	active_count: int,
	settled:      bool,
	revision:     u64,
	last_cells:   u32,
}

planet_waterfield_init :: proc(field: ^Planet_Waterfield, allocator := context.allocator) {
	assert(field != nil, "planet_waterfield_init: nil field")
	field^ = {}
	field.depths = make([]u32, PLANET_FIELD_CELLS, allocator)
	field.ground = make([]i32, PLANET_FIELD_CELLS, allocator)
	field.scratch = make([]u32, PLANET_FIELD_CELLS, allocator)
	field.active_marks = make([]bool, PLANET_FIELD_CELLS, allocator)
}

planet_waterfield_deinit :: proc(field: ^Planet_Waterfield, allocator := context.allocator) {
	assert(field != nil, "planet_waterfield_deinit: nil field")
	delete(field.active_marks, allocator)
	delete(field.scratch, allocator)
	delete(field.ground, allocator)
	delete(field.depths, allocator)
	field^ = {}
}

planet_waterfield_seed_rivers :: proc(field: ^Planet_Waterfield, foundation: ^Planet_Foundation) {
	assert(field != nil, "planet_waterfield_seed_rivers: nil field")
	assert(foundation != nil, "planet_waterfield_seed_rivers: nil foundation")
	assert(len(field.depths) == PLANET_FIELD_CELLS, "planet_waterfield_seed_rivers: storage")
	for strength, index in foundation.river_strength {
		if strength == 0 || foundation.base_height[index] >= foundation.sea_level do continue
		depth := u32(max(i32(strength) / 32, 1))
		field.depths[index] = max(field.depths[index], depth)
	}
	planet_waterfield_mirror_edges(field)
	field.settled = false
}

// planet_waterfield_step advances the flow one tick. Edge cells are stored
// 2-3 times (once per adjacent face); only the canonical copy participates
// in the flow and the duplicates are mirrored from it afterwards, so the
// logical volume is conserved and face seams never disagree about depth.
planet_waterfield_activate :: proc(field: ^Planet_Waterfield, coord: Planet_Coord) {
	assert(field != nil, "planet waterfield activate: nil field")
	canonical := planet_canonical(coord)
	index := planet_index(canonical)
	if field.active_marks[index] do return
	if field.active_count >= PLANET_WATERFIELD_ACTIVE_CAPACITY do return
	field.active_marks[index] = true
	field.active[field.active_count] = i32(index)
	field.active_count += 1
	field.settled = false
}

planet_waterfield_activate_region :: proc(field: ^Planet_Waterfield, center: Planet_Coord, radius: i32) {
	assert(field != nil, "planet waterfield activate region: nil field")
	for offset_v in -radius - 1 ..= radius + 1 {
		for offset_u in -radius - 1 ..= radius + 1 {
			planet_waterfield_activate(field, planet_neighbour(center, offset_u, offset_v))
		}
	}
}

planet_waterfield_step_active :: proc(field: ^Planet_Waterfield, budget := PLANET_WATERFIELD_STEP_BUDGET) -> bool {
	assert(field != nil, "planet waterfield active step: nil field")
	assert(budget > 0, "planet waterfield active step: invalid budget")
	field.last_cells = 0
	moved := false
	processed := min(field.active_count, budget)
	for _ in 0 ..< processed {
		field.active_count -= 1
		index := int(field.active[field.active_count])
		field.active_marks[index] = false
		face_stride := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
		face_index := index / face_stride
		remainder := index % face_stride
		coord := Planet_Coord {
			procgen.Terrain_Face_V4(face_index),
			i32(remainder % PLANET_FACE_RESOLUTION),
			i32(remainder / PLANET_FACE_RESOLUTION),
		}
		before := field.depths[index]
		if before == 0 do continue
		neighbours := [4]Planet_Coord {
			planet_neighbour(coord, -1, 0),
			planet_neighbour(coord, 1, 0),
			planet_neighbour(coord, 0, -1),
			planet_neighbour(coord, 0, 1),
		}
		surface := i64(field.ground[index]) + i64(before)
		best := neighbours[0]
		best_surface := max(i64)
		for neighbour in neighbours {
			neighbour_index := planet_index(neighbour)
			candidate := i64(field.ground[neighbour_index]) + i64(field.depths[neighbour_index])
			if candidate < best_surface {
				best = neighbour
				best_surface = candidate
			}
		}
		if surface > best_surface + 1 {
			best_index := planet_index(best)
			amount := min(u32((surface - best_surface) / 2), WATER_TRANSFER_MAX)
			amount = min(amount, field.depths[index])
			if amount > 0 {
				field.depths[index] -= amount
				field.depths[best_index] += amount
				_planet_water_mirror_cell(field, coord)
				_planet_water_mirror_cell(field, best)
				planet_waterfield_activate(field, coord)
				planet_waterfield_activate(field, best)
				for neighbour in neighbours do planet_waterfield_activate(field, neighbour)
				moved = true
			}
		}
		field.last_cells += 1
	}
	field.settled = field.active_count == 0
	if moved do field.revision += 1
	return moved
}

planet_waterfield_step :: proc(field: ^Planet_Waterfield) -> bool {
	assert(field != nil, "planet_waterfield_step: nil field")
	if field.settled do return false
	copy(field.scratch, field.depths)
	moved := false
	for face in procgen.Terrain_Face_V4 {
		for v in 0 ..< PLANET_FACE_RESOLUTION {
			for u in 0 ..< PLANET_FACE_RESOLUTION {
				coord := Planet_Coord{face, i32(u), i32(v)}
				if planet_coord_is_edge(coord) && planet_canonical(coord) != coord do continue
				moved = _planet_water_transfer(field, coord) || moved
			}
		}
	}
	copy(field.depths, field.scratch)
	planet_waterfield_mirror_edges(field)
	field.settled = !moved
	if moved do field.revision += 1
	return moved
}

// planet_waterfield_mirror_edges copies every canonical edge cell's depth
// onto its duplicates so per-face reads at the seams agree.
planet_waterfield_mirror_edges :: proc(field: ^Planet_Waterfield) {
	assert(field != nil, "planet_waterfield_mirror_edges: nil field")
	last := i32(PLANET_FACE_CELLS)
	for face in procgen.Terrain_Face_V4 {
		for u in i32(0) ..= last {
			_planet_water_mirror_cell(field, {face, u, 0})
			_planet_water_mirror_cell(field, {face, u, last})
		}
		for v in i32(1) ..< last {
			_planet_water_mirror_cell(field, {face, 0, v})
			_planet_water_mirror_cell(field, {face, last, v})
		}
	}
}

@(private)
_planet_water_mirror_cell :: proc(field: ^Planet_Waterfield, coord: Planet_Coord) {
	if planet_canonical(coord) != coord do return
	value := field.depths[planet_index(coord)]
	ground := field.ground[planet_index(coord)]
	duplicates, count := planet_duplicates(coord)
	for index in 0 ..< count {
		duplicate := planet_index(duplicates[index])
		field.depths[duplicate] = value
		field.ground[duplicate] = ground
	}
}

@(private)
_planet_water_transfer :: proc(field: ^Planet_Waterfield, coord: Planet_Coord) -> bool {
	assert(field != nil, "_planet_water_transfer: nil field")
	index := planet_index(coord)
	if field.depths[index] == 0 do return false
	neighbours := [?]Planet_Coord {
		planet_neighbour(coord, -1, 0),
		planet_neighbour(coord, 1, 0),
		planet_neighbour(coord, 0, -1),
		planet_neighbour(coord, 0, 1),
	}
	surface := i64(field.ground[index]) + i64(field.depths[index])
	best := neighbours[0]
	best_surface := max(i64)
	for neighbour in neighbours {
		neighbour_index := planet_index(neighbour)
		candidate := i64(field.ground[neighbour_index]) + i64(field.depths[neighbour_index])
		if candidate < best_surface {
			best, best_surface = neighbour, candidate
		}
	}
	if surface <= best_surface + 1 do return false
	best_index := planet_index(best)
	amount := u32(min((surface - best_surface) / 2, i64(WATER_TRANSFER_MAX)))
	amount = min(amount, field.scratch[index])
	if amount == 0 do return false
	field.scratch[index] -= amount
	field.scratch[best_index] += amount
	return true
}

_planet_waterfield_ground_fill :: proc(world: ^World) {
	assert(world != nil, "_planet_waterfield_ground_fill: nil world")
	assert(len(world.waterfield.ground) == PLANET_FIELD_CELLS, "_planet_waterfield_ground_fill: size")
	for index in 0 ..< PLANET_FIELD_CELLS {
		face_cells := PLANET_FACE_RESOLUTION * PLANET_FACE_RESOLUTION
		face := index / face_cells
		local := index % face_cells
		coord := Planet_Coord {
			face = procgen.Terrain_Face_V4(face),
			u = i32(local % PLANET_FACE_RESOLUTION),
			v = i32(local / PLANET_FACE_RESOLUTION),
		}
		world.waterfield.ground[index] = terrain_height_fixed_at_coord(world, coord)
	}
}
