package main

import shared "../shared"
import "core:math"
import "ingot:asset"
import rl "ingot:gfx"
import procgen "ingot:procgen"

PLANET_RENDER_PATCH_COUNT :: shared.PLANET_FACE_COUNT *
	shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
PLANET_RENDER_PATCH_EDGE :: shared.PLANET_PATCH_CELLS + 1
PLANET_RENDER_PATCH_VERTICES :: PLANET_RENDER_PATCH_EDGE * PLANET_RENDER_PATCH_EDGE
PLANET_RENDER_PATCH_INDICES :: shared.PLANET_PATCH_CELLS * shared.PLANET_PATCH_CELLS * 6
#assert(
	PLANET_RENDER_PATCH_COUNT * TERRAIN_LOD_COUNT +
	shared.PLANET_FACE_COUNT +
	TERRAIN_MESH_SLOT_RESERVE <=
	rl.GPU_3D_MAX_MESHES,
)

Planet_Render_Patch :: struct {
	face:         procgen.Terrain_Face_V4,
	patch_u:      int,
	patch_v:      int,
	vertices:     []asset.Vertex,
	indices:      []u32,
	// Unit direction of the patch centre, for horizon culling.
	center:       [3]f32,
	height_min:   f32,
	height_max:   f32,
}

// planet_render_patch_generate builds one 97x97 spherical patch from the
// foundation tables: effective height (base + terraform delta) at every grid
// coordinate, a central-difference surface normal, the biome weight as the
// scalar fallback, and face-local UVs that index the per-face baked albedo.
//
// The foundation already holds the analytic sample at every one of these
// coordinates, so patch (re)generation is pure table math - the procgen
// noise stack never runs here, which is what makes the terraform rebuild
// path affordable.
planet_render_patch_generate :: proc(
	patch: ^Planet_Render_Patch,
	world: ^shared.World,
	allocator := context.allocator,
) -> bool {
	assert(patch != nil, "planet_render_patch_generate: nil patch")
	assert(world != nil, "planet_render_patch_generate: nil world")
	if patch.patch_u < 0 || patch.patch_u >= shared.PLANET_PATCHES_PER_FACE do return false
	if patch.patch_v < 0 || patch.patch_v >= shared.PLANET_PATCHES_PER_FACE do return false
	if patch.vertices == nil {
		patch.vertices = make([]asset.Vertex, PLANET_RENDER_PATCH_VERTICES, allocator)
	}
	if patch.indices == nil {
		patch.indices = make([]u32, PLANET_RENDER_PATCH_INDICES, allocator)
	}
	patch.height_min = max(f32)
	patch.height_max = min(f32)
	for row in 0 ..< PLANET_RENDER_PATCH_EDGE {
		for column in 0 ..< PLANET_RENDER_PATCH_EDGE {
			u := i32(patch.patch_u * shared.PLANET_PATCH_CELLS + column)
			v := i32(patch.patch_v * shared.PLANET_PATCH_CELLS + row)
			coord := shared.Planet_Coord{patch.face, u, v}
			height := shared.terrain_height_at_coord(world, coord)
			direction := shared.planet_direction(coord)
			index := row * PLANET_RENDER_PATCH_EDGE + column
			foundation_index := shared.planet_index(coord)
			patch.vertices[index] = {
				position = shared.planet_position(direction, height),
				normal = _planet_vertex_normal(world, coord, direction),
				scalar = f32(world.foundation.primary_weight[foundation_index]) / 255,
				uv = {f32(u) / shared.PLANET_FACE_CELLS, f32(v) / shared.PLANET_FACE_CELLS},
			}
			patch.height_min = min(patch.height_min, height)
			patch.height_max = max(patch.height_max, height)
		}
	}
	center_u := f32(patch.patch_u) + 0.5
	center_v := f32(patch.patch_v) + 0.5
	patch.center = shared.planet_direction_uv(
		patch.face,
		center_u * shared.PLANET_PATCH_CELLS,
		center_v * shared.PLANET_PATCH_CELLS,
	)
	cursor := 0
	for row in 0 ..< shared.PLANET_PATCH_CELLS {
		for column in 0 ..< shared.PLANET_PATCH_CELLS {
			a := u32(row * PLANET_RENDER_PATCH_EDGE + column)
			b := a + 1
			c := a + u32(PLANET_RENDER_PATCH_EDGE)
			d := c + 1
			patch.indices[cursor + 0] = a
			patch.indices[cursor + 1] = b
			patch.indices[cursor + 2] = c
			patch.indices[cursor + 3] = b
			patch.indices[cursor + 4] = d
			patch.indices[cursor + 5] = c
			cursor += 6
		}
	}
	return true
}

// _planet_vertex_normal derives a surface normal from the four neighbouring
// cells' positions, crossing face seams through planet_neighbour so patch
// borders agree with the adjacent face's geometry.
@(private)
_planet_vertex_normal :: proc(
	world: ^shared.World,
	coord: shared.Planet_Coord,
	direction: [3]f32,
) -> [3]f32 {
	left := _planet_surface_point(world, shared.planet_neighbour(coord, -1, 0))
	right := _planet_surface_point(world, shared.planet_neighbour(coord, 1, 0))
	down := _planet_surface_point(world, shared.planet_neighbour(coord, 0, -1))
	up := _planet_surface_point(world, shared.planet_neighbour(coord, 0, 1))
	tangent_u := right - left
	tangent_v := up - down
	normal := [3]f32 {
		tangent_u.y * tangent_v.z - tangent_u.z * tangent_v.y,
		tangent_u.z * tangent_v.x - tangent_u.x * tangent_v.z,
		tangent_u.x * tangent_v.y - tangent_u.y * tangent_v.x,
	}
	length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
	if length <= 0.000001 do return direction
	normal /= length
	// The cross product's sign depends on the face's UV handedness; flip it
	// toward the outward radial so lighting never inverts across faces.
	if normal.x * direction.x + normal.y * direction.y + normal.z * direction.z < 0 {
		normal = -normal
	}
	return normal
}

@(private)
_planet_surface_point :: proc(world: ^shared.World, coord: shared.Planet_Coord) -> [3]f32 {
	height := shared.terrain_height_at_coord(world, coord)
	return shared.planet_position(shared.planet_direction(coord), height)
}

planet_render_patch_deinit :: proc(patch: ^Planet_Render_Patch, allocator := context.allocator) {
	assert(patch != nil, "planet_render_patch_deinit: nil patch")
	delete(patch.indices, allocator)
	delete(patch.vertices, allocator)
	patch^ = {}
}

PLANET_SECTION_SEGMENTS :: 192
PLANET_SECTION_BANDS :: 5
PLANET_SECTION_VERTICES :: PLANET_SECTION_SEGMENTS * PLANET_SECTION_BANDS * 4
PLANET_SECTION_INDICES :: PLANET_SECTION_SEGMENTS * PLANET_SECTION_BANDS * 6

Planet_Section_Mesh :: struct {
	vertices: [PLANET_SECTION_VERTICES]rl.Gpu_3D_Vertex,
	indices:  [PLANET_SECTION_INDICES]u32,
	normal:   [3]f32,
}

planet_section_basis :: proc(normal: [3]f32) -> (right, up: [3]f32, ok: bool) {
	length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
	if length <= 0.000001 do return {}, {}, false
	n := normal / length
	reference := [3]f32{0, 0, 1}
	if math.abs(n.z) > 0.95 do reference = {0, 1, 0}
	right = {
		reference.y * n.z - reference.z * n.y,
		reference.z * n.x - reference.x * n.z,
		reference.x * n.y - reference.y * n.x,
	}
	right_length := math.sqrt(right.x * right.x + right.y * right.y + right.z * right.z)
	if right_length <= 0.000001 do return {}, {}, false
	right /= right_length
	up = {
		n.y * right.z - n.z * right.y,
		n.z * right.x - n.x * right.z,
		n.x * right.y - n.y * right.x,
	}
	return right, up, true
}

planet_section_generate :: proc(section: ^Planet_Section_Mesh, world: ^shared.World, normal: [3]f32) -> bool {
	assert(section != nil && world != nil, "planet section generate: nil input")
	right, up, ok := planet_section_basis(normal)
	if !ok do return false
	normal_length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
	section.normal = normal / normal_length
	radii := [PLANET_SECTION_BANDS + 1]f32{0, 0.22, 0.48, 0.90, 0.98, 1.0}
	vertex_cursor, index_cursor := 0, 0
	for band in 0 ..< PLANET_SECTION_BANDS {
		for segment in 0 ..< PLANET_SECTION_SEGMENTS {
			next := (segment + 1) % PLANET_SECTION_SEGMENTS
			angle_a := f32(segment) / PLANET_SECTION_SEGMENTS * 2 * f32(math.PI)
			angle_b := f32(next) / PLANET_SECTION_SEGMENTS * 2 * f32(math.PI)
			direction_a := right * f32(math.cos(angle_a)) + up * f32(math.sin(angle_a))
			direction_b := right * f32(math.cos(angle_b)) + up * f32(math.sin(angle_b))
			sample := shared.planetary_sample_index(direction_a)
			value := f32(world.planetary.geology.heat_flux_mw_m2[sample]) / 500
			if band == 3 do value = f32(world.planetary.geology.crust_thickness_m[sample]) / 80_000
			if band == 4 do value = f32(world.planetary.ocean.mean_depth_mm[sample]) / 20_000_000
			inner := radii[band] * shared.PLANET_RADIUS
			outer := radii[band + 1] * shared.PLANET_RADIUS
			if band == 4 && world.planetary.ocean.mean_depth_mm[sample] == 0 do outer = inner
			base := u32(vertex_cursor)
			section.vertices[vertex_cursor + 0] = {position = direction_a * inner, normal = section.normal, scalar = f32(band), uv = {value, 0}}
			section.vertices[vertex_cursor + 1] = {position = direction_b * inner, normal = section.normal, scalar = f32(band), uv = {value, 0}}
			section.vertices[vertex_cursor + 2] = {position = direction_a * outer, normal = section.normal, scalar = f32(band), uv = {value, 1}}
			section.vertices[vertex_cursor + 3] = {position = direction_b * outer, normal = section.normal, scalar = f32(band), uv = {value, 1}}
			section.indices[index_cursor + 0] = base
			section.indices[index_cursor + 1] = base + 2
			section.indices[index_cursor + 2] = base + 1
			section.indices[index_cursor + 3] = base + 1
			section.indices[index_cursor + 4] = base + 2
			section.indices[index_cursor + 5] = base + 3
			vertex_cursor += 4
			index_cursor += 6
		}
	}
	assert(vertex_cursor == PLANET_SECTION_VERTICES, "planet section vertex count")
	assert(index_cursor == PLANET_SECTION_INDICES, "planet section index count")
	return true
}
