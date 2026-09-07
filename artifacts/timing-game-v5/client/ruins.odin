package main

import shared "../shared"
import "core:math"
import "core:math/linalg"
import ecs "ingot:ecs"
import rl "ingot:gfx"
import procgen "ingot:procgen"

// Streaming window: ruins exist for an 11x11 block of 64-unit tiles centred
// on the camera target. Each tile generates its candidate sites from a
// canonical per-tile cell rectangle, so a tile's ruins are identical no
// matter which window contains it, and the resident set stays bounded
// regardless of total world area.
RUIN_STREAM_TILE_SIZE :: f32(64)
RUIN_STREAM_RADIUS :: 5
RUIN_STREAM_DIAMETER :: 2 * RUIN_STREAM_RADIUS + 1
RUIN_STREAM_TILE_COUNT :: RUIN_STREAM_DIAMETER * RUIN_STREAM_DIAMETER
RUIN_WORLD_TILES :: int(2 * shared.WORLD_HALF_SIZE / RUIN_STREAM_TILE_SIZE)
RUIN_SITES_PER_TILE :: 4
RUIN_SITE_MAX :: RUIN_STREAM_TILE_COUNT * RUIN_SITES_PER_TILE
RUIN_PARTS_PER_SITE :: 4
RUIN_INSTANCE_MAX :: RUIN_SITE_MAX * RUIN_PARTS_PER_SITE
RUIN_CLEARANCE :: f32(7)
#assert(RUIN_WORLD_TILES * int(RUIN_STREAM_TILE_SIZE) == int(2 * shared.WORLD_HALF_SIZE))
RUIN_MESHES := [RUIN_PARTS_PER_SITE]Structure_Mesh_Id {
	.Ruin_Wall_A,
	.Ruin_Wall_B,
	.Ruin_Wall_C,
	.Ruin_Wall_D,
}

Ruin_Site :: struct {
	key:      u64,
	position: [3]f32,
	yaw:      f32,
	scale:    f32,
}

Ruin_Instance :: struct {
	mesh:      Structure_Mesh_Id,
	transform: rl.Matrix,
}

Ruins :: struct {
	sites:          [RUIN_SITE_MAX]Ruin_Site,
	site_count:     int,
	instances:      [RUIN_INSTANCE_MAX]Ruin_Instance,
	instance_count: int,
	// Centre tile of the resident streaming window; sites regenerate when
	// the camera target crosses into a different tile.
	stream_tile:    [2]i32,
	stream_valid:   bool,
	ready:          bool,
}

// _ruin_focus_tile maps a world-space focus point to its streaming tile,
// clamped inside the world so edge focus keeps a full window.
_ruin_focus_tile :: proc(focus: [2]f32) -> [2]i32 {
	tile_x := i32(math.floor((focus.x + shared.WORLD_HALF_SIZE) / RUIN_STREAM_TILE_SIZE))
	tile_y := i32(math.floor((focus.y + shared.WORLD_HALF_SIZE) / RUIN_STREAM_TILE_SIZE))
	last := i32(RUIN_WORLD_TILES - 1)
	return {clamp(tile_x, 0, last), clamp(tile_y, 0, last)}
}

// ruins_generate places ruin sites deterministically from the world seed for
// the streaming window around focus. terrain may be nil (headless tests):
// site z then falls back to the analytic height instead of probing the
// rendered isosurface.
ruins_generate :: proc(
	value: ^Ruins,
	terrain: ^Terrain,
	world: ^shared.World,
	focus: [2]f32,
) -> bool {
	assert(value != nil, "ruins_generate: nil ruins")
	assert(world != nil, "ruins_generate: nil world")
	value^ = {}
	center := _ruin_focus_tile(focus)
	value.stream_tile = center
	value.stream_valid = true
	limit := i32(shared.WORLD_HALF_SIZE / shared.GRID_CELL_SIZE) - 5
	cells_per_tile := i32(RUIN_STREAM_TILE_SIZE / shared.GRID_CELL_SIZE)
	cell_origin := -i32(shared.WORLD_HALF_SIZE / shared.GRID_CELL_SIZE)
	last_tile := i32(RUIN_WORLD_TILES - 1)
	tile_min_x := clamp(center.x - RUIN_STREAM_RADIUS, 0, last_tile)
	tile_max_x := clamp(center.x + RUIN_STREAM_RADIUS, 0, last_tile)
	tile_min_y := clamp(center.y - RUIN_STREAM_RADIUS, 0, last_tile)
	tile_max_y := clamp(center.y + RUIN_STREAM_RADIUS, 0, last_tile)
	for tile_y in tile_min_y ..= tile_max_y {
		for tile_x in tile_min_x ..= tile_max_x {
			minimum_cell := [2]i32 {
				max(cell_origin + tile_x * cells_per_tile, -limit),
				max(cell_origin + tile_y * cells_per_tile, -limit),
			}
			maximum_cell := [2]i32 {
				min(cell_origin + (tile_x + 1) * cells_per_tile - 1, limit),
				min(cell_origin + (tile_y + 1) * cells_per_tile - 1, limit),
			}
			if minimum_cell.x > maximum_cell.x || minimum_cell.y > maximum_cell.y do continue
			config := procgen.Feature_Placement_Config {
				seed               = world.foundation.seed,
				salt               = 0x5255_494E_5349_5445,
				minimum_cell       = minimum_cell,
				maximum_cell       = maximum_cell,
				cluster_cells      = 24,
				chance             = 900,
				cell_world_size    = shared.GRID_CELL_SIZE,
				jitter             = 0.7,
				minimum_separation = 28,
				scale_minimum      = 0.8,
				scale_maximum      = 1.1,
				output_limit       = RUIN_SITES_PER_TILE,
			}
			candidates: [RUIN_SITES_PER_TILE]procgen.Feature_Placement
			count, ok := procgen.feature_placement_generate(config, candidates[:])
			if !ok do return false
			for candidate in candidates[:count] {
				if value.site_count >= RUIN_SITE_MAX do break
				if !_ruin_site_valid(world, candidate.position) do continue
				height := shared.terrain_height(world, candidate.position.x, candidate.position.y)
				if terrain != nil && terrain.ready {
					height = terrain_surface_height(
						terrain,
						candidate.position.x,
						candidate.position.y,
					)
				}
				value.sites[value.site_count] = {
					key      = candidate.key,
					position = {candidate.position.x, candidate.position.y, height - 0.12},
					yaw      = candidate.yaw,
					scale    = candidate.scale,
				}
				_ruin_site_assemble(value, &value.sites[value.site_count])
				value.site_count += 1
			}
		}
	}
	value.ready = true
	return true
}

// ruins_stream_update regenerates the resident window when the camera target
// crosses a tile boundary. Per-tile generation is canonical, so revisited
// tiles produce identical ruins.
ruins_stream_update :: proc(
	value: ^Ruins,
	terrain: ^Terrain,
	world: ^shared.World,
	focus: [2]f32,
) {
	assert(value != nil, "ruins_stream_update: nil ruins")
	assert(world != nil, "ruins_stream_update: nil world")
	if !value.ready do return
	tile := _ruin_focus_tile(focus)
	if value.stream_valid && tile == value.stream_tile do return
	_ = ruins_generate(value, terrain, world, focus)
}

ruins_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "ruins_draw: nil state")
	assert(pass != nil, "ruins_draw: nil pass")
	if !value.ruins.ready do return
	for mesh in RUIN_MESHES {
		count := 0
		for instance in value.ruins.instances[:value.ruins.instance_count] {
			if instance.mesh != mesh do continue
			if count >= len(value.draw_transforms) do break
			value.draw_transforms[count] = instance.transform
			count += 1
		}
		if count == 0 do continue
		rl.draw_gpu_mesh_instanced(
			&pass^,
			structure_mesh(value, mesh),
			value.draw_transforms[:count],
			{
				color = {154, 143, 126, 255},
				style = .Opaque,
				shader = value.atmosphere.object_shader,
			},
		)
	}
}

ruins_contains :: proc(value: ^Ruins, x, y, clearance: f32) -> bool {
	assert(value != nil, "ruins_contains: nil ruins")
	assert(clearance >= 0, "ruins_contains: negative clearance")
	for site in value.sites[:value.site_count] {
		delta_x := x - site.position.x
		delta_y := y - site.position.y
		if delta_x * delta_x + delta_y * delta_y < clearance * clearance do return true
	}
	return false
}

@(private)
_ruin_site_valid :: proc(world: ^shared.World, position: [2]f32) -> bool {
	assert(world != nil, "_ruin_site_valid: nil world")
	grid_x := i32(math.floor(position.x / shared.GRID_CELL_SIZE + 0.5))
	grid_y := i32(math.floor(position.y / shared.GRID_CELL_SIZE + 0.5))
	if !shared.placement_allowed(world, grid_x, grid_y) do return false
	sample := shared.terrain_sample(world, position.x, position.y)
	if sample.slope > shared.PLACEMENT_MAX_SLOPE * 0.75 do return false
	for index in 0 ..< ecs.set_len(&world.nodes) {
		entity := world.nodes.header.entities[index]
		transform, found := ecs.get(&world.transforms, entity)
		if !found do continue
		delta_x := position.x - transform.position.x
		delta_y := position.y - transform.position.y
		if delta_x * delta_x + delta_y * delta_y < RUIN_CLEARANCE * RUIN_CLEARANCE do return false
	}
	return true
}

@(private)
_ruin_site_assemble :: proc(value: ^Ruins, site: ^Ruin_Site) {
	assert(value != nil, "_ruin_site_assemble: nil ruins")
	assert(site != nil, "_ruin_site_assemble: nil site")
	offsets := [RUIN_PARTS_PER_SITE][2]f32{{-2.4, -1.8}, {2.2, -1.7}, {-2.1, 1.9}, {2.5, 2.0}}
	part_count := 2 + int((site.key >> 12) % 3)
	for part_index in 0 ..< part_count {
		assert(value.instance_count < RUIN_INSTANCE_MAX, "_ruin_site_assemble: overflow")
		mesh_index := int((site.key >> u32(part_index * 7)) % RUIN_PARTS_PER_SITE)
		offset := offsets[part_index]
		cosine, sine := math.cos(site.yaw), math.sin(site.yaw)
		position := [3]f32 {
			site.position.x + (offset.x * cosine - offset.y * sine) * site.scale,
			site.position.y + (offset.x * sine + offset.y * cosine) * site.scale,
			site.position.z,
		}
		yaw := site.yaw + f32(part_index) * math.PI * 0.5
		value.instances[value.instance_count] = {
			mesh      = RUIN_MESHES[mesh_index],
			transform = rl.MatrixTranslate(
				position.x,
				position.y,
				position.z,
			) * linalg.matrix4_rotate_f32(yaw, {0, 0, 1}) * rl.MatrixScale(site.scale, site.scale, site.scale),
		}
		value.instance_count += 1
	}
}
