package shared

import procgen "ingot:procgen"

WATER_DEPTH_SCALE :: u32(4)
WATER_TRANSFER_MAX :: u32(4)
WATER_WET_THRESHOLD :: u32(1)

Waterfield :: Planet_Waterfield

waterfield_deinit :: proc(field: ^Waterfield, allocator := context.allocator) {
	assert(field != nil, "waterfield_deinit: nil field")
	delete(field.active_marks, allocator)
	delete(field.scratch, allocator)
	delete(field.ground, allocator)
	delete(field.depths, allocator)
	field^ = {}
}

// waterfield_initialize floods the planet to the foundation's sea level.
// The sea level is implicit in the depths afterwards, not stored as a plane.
waterfield_initialize :: proc(world: ^World) {
	assert(world != nil, "waterfield_initialize: nil world")
	assert(len(world.waterfield.depths) == PLANET_FIELD_CELLS, "waterfield_initialize: storage size")
	_planet_waterfield_ground_fill(world)
	level := i32(world.foundation.sea_level)
	_ = procgen.water_initialize(world.waterfield.ground[:], world.waterfield.depths[:], level)
	world.waterfield.revision = 1
	world.waterfield.settled = false
}

// waterfield_unsettle rearms the flow after anything writes ground or depth.
// A settled field is skipped by waterfield_step, so a write that forgets this
// leaves water frozen where it stands - the same class of silent staleness a
// missing terrain_mark_dirty produces for the terrain mesh.
waterfield_unsettle :: proc(field: ^Planet_Waterfield) {
	assert(field != nil, "waterfield_unsettle: nil field")
	field.settled = false
}

// waterfield_step advances the flow one tick and reports whether anything
// moved. A field already in equilibrium is skipped outright: the step is a
// full sweep of every cell, it runs on the main thread inside sim_tick, and
// on an unedited map every one of those sweeps finds nothing to do.
waterfield_step :: proc(world: ^World, tick: u64) -> bool {
	assert(world != nil, "waterfield_step: nil world")
	_ = tick
	if world.waterfield.active_count > 0 {
		return planet_waterfield_step_active(&world.waterfield)
	}
	return planet_waterfield_step(&world.waterfield)
}

// waterfield_terrain_changed rebuilds the whole ground field. Correct but
// expensive: PLANET_FIELD_CELLS is 3,548,166, so this is a full sweep of the
// world for any edit however small. Reserved for the cases that really do
// change everything - initialisation and a snapshot restore. Localised edits
// use waterfield_terrain_changed_rect.
waterfield_terrain_changed :: proc(world: ^World) {
	assert(world != nil, "waterfield_terrain_changed: nil world")
	assert(world.waterfield.revision < max(u64), "waterfield_terrain_changed: revision overflow")
	_planet_waterfield_ground_fill(world)
	world.waterfield.revision += 1
	waterfield_unsettle(&world.waterfield)
	_ = ocean_bathymetry_sync_all(world)
}

// waterfield_terrain_changed_rect refills only the brush window an edit
// touched: every cell within `radius` steps of the centre, crossing face
// seams through planet_neighbour and mirroring edge duplicates.
//
// This is the same computation as the full refill restricted to a window:
// the ground fill writes each cell from base_height + delta with no
// dependence on any neighbour, so refilling a subset leaves the array in
// exactly the state a full refill would. waterfield_test.odin pins that
// equivalence rather than leaving it as an argument in a comment.
//
// The cost difference is the point: a drag-sculpt issues several terraform
// commands per frame, and each one used to sweep millions of cells to update
// the ~121 the largest brush can reach.
waterfield_terrain_changed_rect :: proc(world: ^World, center: Planet_Coord, radius: i32) {
	assert(world != nil, "waterfield_terrain_changed_rect: nil world")
	assert(
		world.waterfield.revision < max(u64),
		"waterfield_terrain_changed_rect: revision overflow",
	)
	assert(planet_coord_valid(center), "waterfield_terrain_changed_rect: invalid centre")
	assert(
		radius >= 0 && radius <= PLANET_FACE_CELLS,
		"waterfield_terrain_changed_rect: radius out of range",
	)
	for offset_v in -radius ..= radius {
		for offset_u in -radius ..= radius {
			target := planet_neighbour(center, offset_u, offset_v)
			index := planet_index(target)
			height := terrain_height_fixed_at_coord(world, target)
			if world.waterfield.ground[index] != height do flora_disturb_cell(world, planetary_sample_index(planet_direction(target)), 2000)
			world.waterfield.ground[index] = height
			_planet_water_mirror_cell(&world.waterfield, target)
		}
	}
	world.waterfield.revision += 1
	planet_waterfield_activate_region(&world.waterfield, center, radius)
	_ = ocean_bathymetry_sync_rect(world, center, radius)
}

// waterfield_total sums the logical water volume: each edge cell counts once
// through its canonical copy, so seam duplicates do not inflate the total.
waterfield_total :: proc(field: ^Planet_Waterfield) -> u64 {
	assert(field != nil, "waterfield_total: nil field")
	volume: u64
	for face in procgen.Terrain_Face_V4 {
		for v in 0 ..< PLANET_FACE_RESOLUTION {
			for u in 0 ..< PLANET_FACE_RESOLUTION {
				coord := Planet_Coord{face, i32(u), i32(v)}
				if planet_coord_is_edge(coord) && planet_canonical(coord) != coord do continue
				volume += u64(field.depths[planet_index(coord)])
			}
		}
	}
	return volume
}

// waterfield_depth_fixed reads one cell's depth in quarter-unit fixed point.
waterfield_depth_fixed :: proc(field: ^Planet_Waterfield, coord: Planet_Coord) -> u32 {
	assert(field != nil, "waterfield_depth_fixed: nil field")
	if !planet_coord_valid(coord) do return 0
	return field.depths[planet_index(coord)]
}

waterfield_depth_at_coord :: proc(world: ^World, coord: Planet_Coord) -> f32 {
	assert(world != nil, "waterfield_depth_at_coord: nil world")
	if !planet_coord_valid(coord) do return 0
	depth := world.waterfield.depths[planet_index(coord)]
	return f32(depth) / f32(WATER_DEPTH_SCALE)
}

// waterfield_depth_at_direction bilinearly interpolates the depth field at
// an arbitrary sphere direction, matching how render vertices interpolate
// between cells.
waterfield_depth_at_direction :: proc(field: ^Planet_Waterfield, direction: [3]f32) -> f32 {
	assert(field != nil, "waterfield_depth_at_direction: nil field")
	face, located_u, located_v := planet_locate(direction)
	limit := f32(PLANET_FACE_CELLS)
	located_u = clamp(located_u, 0, limit)
	located_v = clamp(located_v, 0, limit)
	column := min(i32(located_u), i32(PLANET_FACE_CELLS - 1))
	row := min(i32(located_v), i32(PLANET_FACE_CELLS - 1))
	fraction_u := located_u - f32(column)
	fraction_v := located_v - f32(row)
	low := f32(waterfield_depth_fixed(field, {face, column, row})) * (1 - fraction_u)
	low += f32(waterfield_depth_fixed(field, {face, column + 1, row})) * fraction_u
	high := f32(waterfield_depth_fixed(field, {face, column, row + 1})) * (1 - fraction_u)
	high += f32(waterfield_depth_fixed(field, {face, column + 1, row + 1})) * fraction_u
	return (low * (1 - fraction_v) + high * fraction_v) / f32(WATER_DEPTH_SCALE)
}

waterfield_wet_at_coord :: proc(world: ^World, coord: Planet_Coord) -> bool {
	assert(world != nil, "waterfield_wet_at_coord: nil world")
	if !planet_coord_valid(coord) do return false
	return world.waterfield.depths[planet_index(coord)] >= WATER_WET_THRESHOLD
}

// waterfield_surface_at_coord is the water top in world-height units at a
// cell: effective ground plus the water column standing on it.
waterfield_surface_at_coord :: proc(world: ^World, coord: Planet_Coord) -> f32 {
	assert(world != nil, "waterfield_surface_at_coord: nil world")
	assert(planet_coord_valid(coord), "waterfield_surface_at_coord: invalid coordinate")
	ground := terrain_height_at_coord(world, coord)
	depth := world.waterfield.depths[planet_index(coord)]
	return ground + f32(depth) / f32(WATER_DEPTH_SCALE)
}
