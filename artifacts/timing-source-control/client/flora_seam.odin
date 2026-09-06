// flora_seam.odin is planetforger's cube-sphere implementation of the flora
// world-model seam (see ../forgecore/WORLDMODEL.md). Positions are 3D points
// on (or near) the sphere surface; tiles are face-local blocks of the planet
// streaming grid, so the flora window crosses cube-face seams the same way
// the terrain does — through planet_neighbour.
package main

import shared "../shared"
import "core:math"
import "core:math/linalg"
import ecs "ingot:ecs"
import rl "ingot:gfx"
import procgen "ingot:procgen"

// One flora stream tile is one planet stream tile: 32 heightfield cells at
// GRID_CELL_SIZE 2 is exactly the 64-unit tile the shared flora constants
// are sized for.
#assert(f32(PLANET_STREAM_TILE_CELLS) * shared.GRID_CELL_SIZE == FLORA_STREAM_TILE_SIZE)

// flora_world_tile maps a focus direction (any vector toward the camera
// target) to its streaming tile. A degenerate zero focus — a fresh state
// before the camera seats — lands on the spawn face centre instead of
// asserting inside planet_locate.
flora_world_tile :: proc(focus_direction: [3]f32) -> Flora_Tile_Id {
	direction := focus_direction
	if linalg.dot(direction, direction) < 1e-6 do direction = {1, 0, 0}
	tile := planet_stream_tile(linalg.normalize(direction))
	return {face = i32(tile.face), tile_u = tile.tile_u, tile_v = tile.tile_v}
}

flora_tile_eq :: proc(a, b: Flora_Tile_Id) -> bool {
	return a.face == b.face && a.tile_u == b.tile_u && a.tile_v == b.tile_v
}

// flora_stream_window lists the resident window around center: the same
// 11x11 tile block the flat demo keeps, but stepped across cube-face seams
// through planet_neighbour and deduplicated, because offsets folding around
// a cube corner can land on the same tile twice.
flora_stream_window :: proc(
	center: Flora_Tile_Id,
	tiles: ^[FLORA_STREAM_TILE_COUNT]Flora_Tile_Id,
) -> int {
	cells := i32(PLANET_STREAM_TILE_CELLS)
	last_tile := i32(PLANET_STREAM_TILES_PER_FACE - 1)
	center_coord := shared.Planet_Coord {
		procgen.Terrain_Face_V4(center.face),
		center.tile_u * cells + cells / 2,
		center.tile_v * cells + cells / 2,
	}
	count := 0
	for dv in -FLORA_STREAM_RADIUS ..= FLORA_STREAM_RADIUS {
		for du in -FLORA_STREAM_RADIUS ..= FLORA_STREAM_RADIUS {
			neighbour := shared.planet_neighbour(center_coord, i32(du) * cells, i32(dv) * cells)
			tile := Flora_Tile_Id {
				face   = i32(neighbour.face),
				tile_u = clamp(neighbour.u / cells, 0, last_tile),
				tile_v = clamp(neighbour.v / cells, 0, last_tile),
			}
			duplicate := false
			for existing in 0 ..< count {
				if flora_tile_eq(tiles[existing], tile) {
					duplicate = true
					break
				}
			}
			if duplicate do continue
			tiles[count] = tile
			count += 1
		}
	}
	return count
}

// flora_scatter_position resolves a face-local scatter cell plus jitter to a
// world-space point on the analytic surface. Every direction on the sphere
// is in-world, so ok is always true.
flora_scatter_position :: proc(
	world: ^shared.World,
	tile: Flora_Tile_Id,
	cell_x, cell_y: i32,
	jitter_x, jitter_y, cell_size: f32,
) -> (
	position: [3]f32,
	ok: bool,
) {
	face := procgen.Terrain_Face_V4(tile.face)
	u := (f32(cell_x) + jitter_x) * cell_size / shared.GRID_CELL_SIZE
	v := (f32(cell_y) + jitter_y) * cell_size / shared.GRID_CELL_SIZE
	maximum := f32(shared.PLANET_FACE_CELLS)
	direction := shared.planet_direction_uv(face, clamp(u, 0, maximum), clamp(v, 0, maximum))
	height := shared.terrain_height_at_direction(world, direction)
	return shared.planet_position(direction, height), true
}

flora_position_in_world :: proc(position: [3]f32) -> bool {
	_ = position
	return true
}

flora_scatter_sample :: proc(
	world: ^shared.World,
	position: [3]f32,
) -> (
	sample: shared.Terrain_Sample,
	height: f32,
) {
	direction := linalg.normalize(position)
	coord := shared.planet_coord_from_direction(direction)
	sample = shared.terrain_sample_at_coord(world, coord)
	sample.moisture = f32(world.foundation.moisture[shared.planet_index(coord)]) / 255
	height = shared.terrain_height_at_direction(world, direction)
	return
}

flora_ecology_enabled :: proc(world: ^shared.World) -> bool {
	_ = world
	return true
}

flora_ecology_revision :: proc(world: ^shared.World) -> u64 {
	return world.flora_ecology.revision
}

flora_ecology_visual :: proc(
	world: ^shared.World,
	position: [3]f32,
	selector: u16,
) -> (Flora_Ecology_Visual, bool) {
	direction := linalg.normalize(position)
	sample, found := shared.flora_ecology_visual_sample_state(&world.flora_ecology, direction, selector)
	if !found do return {}, false
	return {
		lineage = u64(sample.lineage),
		form = u8(sample.form),
		cover = sample.cover,
		biomass = sample.biomass,
		age_steps = sample.age_steps,
		morphology_family = sample.morphology_family,
		stature = sample.stature,
	}, true
}

flora_collision_sample :: proc(
	world: ^shared.World,
	position: [3]f32,
) -> shared.Flora_Logical_Sample {
	coord := shared.planet_coord_from_direction(linalg.normalize(position))
	index := shared.planet_index(coord)
	return {
		height_fixed = shared.terrain_height_fixed_at_coord(world, coord),
		sea_fixed    = i32(world.foundation.sea_level),
		snow_fixed   = i32(world.foundation.snow_level),
		moisture     = world.foundation.moisture[index],
		slope        = world.foundation.slope[index],
		biome        = world.foundation.primary_biome[index],
	}
}

flora_placement_allowed :: proc(world: ^shared.World, position: [3]f32) -> bool {
	coord := shared.planet_coord_from_direction(linalg.normalize(position))
	return shared.planet_placement_allowed(world, coord)
}

// flora_surface_distance_squared is the chord distance between two surface
// points. Chord and geodesic agree to well under a percent at clearance
// scales (a few units against radius 1080), so the 2D silhouette margins
// carry over unchanged.
flora_surface_distance_squared :: proc(a, b: [3]f32) -> f32 {
	delta := a - b
	return linalg.dot(delta, delta)
}

// flora_node_window_contains accepts nodes within a conservative chord
// radius of the window centre: the 11x11 tile window's half diagonal
// (~498 units) plus the surface height band and clearance margins. A
// superset of the exact window only costs clearance tests, never correctness.
flora_node_window_contains :: proc(center: Flora_Tile_Id, position: [3]f32) -> bool {
	cells := i32(PLANET_STREAM_TILE_CELLS)
	center_coord := shared.Planet_Coord {
		procgen.Terrain_Face_V4(center.face),
		center.tile_u * cells + cells / 2,
		center.tile_v * cells + cells / 2,
	}
	center_position := shared.planet_position(shared.planet_direction(center_coord), 0)
	radius := f32(640) + FLORA_NODE_CLEARANCE + 2
	return flora_surface_distance_squared(position, center_position) <= radius * radius
}

// flora_building_blocks tests the candidate against each building's
// footprint rectangle in the building's own tangent frame, the spherical
// equivalent of the flat grid-aligned AABB.
flora_building_blocks :: proc(world: ^shared.World, position: [3]f32, margin: f32) -> bool {
	cell := shared.GRID_CELL_SIZE
	for building_index in 0 ..< ecs.set_len(&world.buildings) {
		entity := world.buildings.header.entities[building_index]
		building := &world.buildings.items[building_index]
		transform, ok := ecs.get(&world.transforms, entity)
		if !ok do continue
		width, height := shared.building_footprint(building.kind)
		half_width := f32(width - 1) * cell * 0.5 + margin
		half_height := f32(height - 1) * cell * 0.5 + margin
		center :=
			transform.position +
			transform.east * (f32(width - 1) * cell * 0.5) +
			transform.north * (f32(height - 1) * cell * 0.5)
		delta := position - center
		if abs(linalg.dot(delta, transform.east)) <= half_width &&
		   abs(linalg.dot(delta, transform.north)) <= half_height {
			return true
		}
	}
	return false
}

// flora_ruins_blocks: ruins still lay out on the flat face plane and are not
// drawn on the sphere, so their flat-coordinate sites must not block
// sphere-surface flora.
flora_ruins_blocks :: proc(ruins: ^Ruins, position: [3]f32, clearance: f32) -> bool {
	_ = ruins
	_ = position
	_ = clearance
	return false
}

flora_scatter_basis :: proc(position: [3]f32) -> (up, east, north: [3]f32) {
	return shared.planet_basis(linalg.normalize(position))
}

// flora_seat_position seats an instance on the sphere: cached is the
// analytic radial height the uproot test compares against; Probe and Surface
// both use the physics isosurface probe (which itself falls back to the
// analytic height when no physics world exists — the GPU-less benchmark and
// the background scatter thread must stay off Box3D, which Cached
// guarantees).
flora_seat_position :: proc(
	terrain: ^Terrain,
	position: [3]f32,
	mesh: Flora_Mesh_Id,
	scale: f32,
	mode: Flora_Seat_Mode,
) -> (
	seated: [3]f32,
	cached: f32,
) {
	direction := linalg.normalize(position)
	coord := shared.planet_coord_from_direction(direction)
	cached = shared.terrain_height_at_coord(terrain.world_ref, coord)
	seat := cached
	if mode != .Cached {
		seat = terrain_surface_height_at_direction(terrain, direction)
	}
	seated = shared.planet_position(direction, seat - _flora_sink(mesh) * scale)
	return
}

// flora_surface_slope finite-differences the current (terraform-inclusive)
// height field along the face axes, crossing seams through planet_neighbour —
// the same probe the flat reseat sweep uses, on the sphere's own grid.
flora_surface_slope :: proc(terrain: ^Terrain, position: [3]f32) -> f32 {
	direction := linalg.normalize(position)
	coord := shared.planet_coord_from_direction(direction)
	world := terrain.world_ref
	step := shared.GRID_CELL_SIZE
	height := shared.terrain_height_at_coord(world, coord)
	height_u := shared.terrain_height_at_coord(world, shared.planet_neighbour(coord, 1, 0))
	height_v := shared.terrain_height_at_coord(world, shared.planet_neighbour(coord, 0, 1))
	return(
		math.sqrt(
			(height_u - height) * (height_u - height) +
			(height_v - height) * (height_v - height),
		) /
		step \
	)
}

// flora_instance_transform composes translate * tangent_frame * rotate_z *
// uniform_scale from the baked yaw trig and the stored surface basis: model
// Z stands on the surface normal, model X/Y spin around it by yaw.
flora_instance_transform :: proc(instance: ^Flora_Instance) -> rl.Matrix {
	cosine := instance.cos_yaw * instance.scale
	sine := instance.sin_yaw * instance.scale
	column_x := instance.east * cosine + instance.north * sine
	column_y := instance.east * (-sine) + instance.north * cosine
	column_z := instance.up * instance.scale
	position := instance.position
	// The row-per-line layout is the whole point: odinfmt would otherwise put
	// each of the sixteen scalars on its own line and the matrix stops being
	// readable as a matrix.
	//odinfmt: disable
	return rl.Matrix{
		column_x.x, column_y.x, column_z.x, position.x,
		column_x.y, column_y.y, column_z.y, position.y,
		column_x.z, column_y.z, column_z.z, position.z,
		0, 0, 0, 1,
	}
	//odinfmt: enable
}
