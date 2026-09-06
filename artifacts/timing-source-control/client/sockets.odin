// sockets.odin seats buildings into the terrain. Every building gets a rim
// skirt: a ring whose inner edge sits at a fixed collar height on the
// building's disc base and whose outer edge follows the terrain surface.
// Bare resource nodes get no skirt; their rocks meet the ground directly,
// and a ring around them flared into a visible cone on sloped ground. All
// rings share one mesh with world-normalized UVs sampling the terrain
// albedo, so rims wear the ground's own colors and the seam between prop and
// terrain disappears. The mesh is rebuilt only when occupants or terrain
// change.
package main

import shared "../shared"
import "core:math"
import ecs "ingot:ecs"
import rl "ingot:gfx"

MAX_SOCKETS :: MAX_DRAW_INSTANCES + 256
SOCKET_SEGMENTS :: 16
SOCKET_RING_VERTS :: (SOCKET_SEGMENTS + 1) * 2
SOCKET_RING_INDICES :: SOCKET_SEGMENTS * 6
// How far disc bases extend below their anchor so slopes never open a gap.
SOCKET_SINK :: f32(0.5)
SOCKET_SKIRT_WIDTH :: f32(0.6)
// Inner ring height above the anchor; tucks under every disc's top face.
SOCKET_COLLAR :: f32(0.1)
// Outer ring lift above the sampled surface to avoid z-fighting.
SOCKET_LIFT :: f32(0.04)
SOCKET_FALLBACK_COLOR :: rl.Color{96, 86, 74, 255}

Sockets :: struct {
	mesh:     rl.Gpu_Mesh,
	vertices: [MAX_SOCKETS * SOCKET_RING_VERTS]rl.Gpu_3D_Vertex,
	indices:  [MAX_SOCKETS * SOCKET_RING_INDICES]u32,
	dirty:    bool,
	built:    bool,
}

// socket_radius mirrors the drawn disc radius of each occupant so the skirt
// collar always tucks under the disc rim. Bases span their footprints and no
// longer scale with level (level growth is height-only).
socket_radius :: proc(kind: shared.Building_Kind, level: u8) -> f32 {
	if level == 0 {
		width, height := shared.building_footprint(kind)
		return f32(max(width, height)) * shared.GRID_CELL_SIZE * 0.4
	}
	return BUILDING_MODELS[kind].socket_radius
}

// sockets_update rebuilds the combined skirt mesh when flagged dirty and the
// terrain height cache is settled (no chunk regen pending), so outer rings
// never sample stale heights.
sockets_update :: proc(value: ^Client_State) {
	assert(value != nil, "sockets_update: nil state")
	if !value.terrain.ready do return
	for chunk_dirty in value.terrain.dirty do if chunk_dirty do return
	if value.sockets.built && !value.sockets.dirty do return
	vertex_count := 0
	index_count := 0
	it := ecs.iter2(&value.world.transforms, &value.world.buildings)
	for {
		entity, transform, building, ok := ecs.iter2_next(&it)
		if !ok do break
		_ = transform
		radius := socket_radius(building.kind, building.level)
		_socket_ring_emit(
			value,
			building_center(value, entity),
			radius,
			&vertex_count,
			&index_count,
		)
	}
	if vertex_count == 0 {
		if value.sockets.mesh.id != 0 do rl.destroy_gpu_mesh(&value.sockets.mesh)
		value.sockets.mesh = {}
		value.sockets.dirty = false
		value.sockets.built = true
		return
	}
	mesh, ok := rl.create_gpu_mesh(
		value.sockets.vertices[:vertex_count],
		value.sockets.indices[:index_count],
		.Triangles,
	)
	if !ok do return
	if value.sockets.mesh.id != 0 do rl.destroy_gpu_mesh(&value.sockets.mesh)
	value.sockets.mesh = mesh
	value.sockets.dirty = false
	value.sockets.built = true
}

// _socket_ring_emit appends one skirt ring. Winding is CCW seen from above
// (+Z), matching the terrain mesh. UVs use the terrain's world-normalized
// mapping so the ring samples the albedo texel directly beneath it.
_socket_ring_emit :: proc(
	value: ^Client_State,
	anchor: [3]f32,
	radius: f32,
	vertex_count: ^int,
	index_count: ^int,
) {
	assert(radius > 0, "_socket_ring_emit: non-positive radius")
	if vertex_count^ + SOCKET_RING_VERTS > len(value.sockets.vertices) do return
	base := u32(vertex_count^)
	world_span := 2 * shared.WORLD_HALF_SIZE
	for segment in 0 ..= SOCKET_SEGMENTS {
		angle := 2 * math.PI * f32(segment) / f32(SOCKET_SEGMENTS)
		direction := [2]f32{math.cos(angle), math.sin(angle)}
		inner := [2]f32{anchor.x + direction.x * radius, anchor.y + direction.y * radius}
		outer_radius := radius + SOCKET_SKIRT_WIDTH
		outer := [2]f32 {
			anchor.x + direction.x * outer_radius,
			anchor.y + direction.y * outer_radius,
		}
		outer_z := terrain_height_cached(&value.terrain, outer.x, outer.y) + SOCKET_LIFT
		value.sockets.vertices[vertex_count^ + 0] = {
			position = {inner.x, inner.y, anchor.z + SOCKET_COLLAR},
			normal   = {0, 0, 1},
			uv       = {
				(inner.x + shared.WORLD_HALF_SIZE) / world_span,
				(inner.y + shared.WORLD_HALF_SIZE) / world_span,
			},
		}
		value.sockets.vertices[vertex_count^ + 1] = {
			position = {outer.x, outer.y, outer_z},
			normal   = {0, 0, 1},
			uv       = {
				(outer.x + shared.WORLD_HALF_SIZE) / world_span,
				(outer.y + shared.WORLD_HALF_SIZE) / world_span,
			},
		}
		vertex_count^ += 2
	}
	for segment in 0 ..< SOCKET_SEGMENTS {
		inner := base + u32(segment * 2)
		outer := inner + 1
		next_inner := base + u32((segment + 1) * 2)
		next_outer := next_inner + 1
		value.sockets.indices[index_count^ + 0] = inner
		value.sockets.indices[index_count^ + 1] = outer
		value.sockets.indices[index_count^ + 2] = next_outer
		value.sockets.indices[index_count^ + 3] = inner
		value.sockets.indices[index_count^ + 4] = next_outer
		value.sockets.indices[index_count^ + 5] = next_inner
		index_count^ += 6
	}
}

sockets_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "sockets_draw: nil state")
	assert(pass != nil, "sockets_draw: nil pass")
	if value.sockets.mesh.id == 0 do return
	material := rl.Gpu_Material {
		color = SOCKET_FALLBACK_COLOR,
	}
	// Bind the hovered face's terrain albedo so the socket apron matches
	// the ground it sits on; the flat world resolves every face to its one
	// world-spanning bake.
	albedo := terrain_albedo_binding(&value.terrain, value.hover_face)
	if albedo.id != 0 {
		material = {
			color   = rl.WHITE,
			texture = albedo,
		}
	}
	material.shader = value.atmosphere.object_shader
	rl.draw_gpu_mesh(&pass^, value.sockets.mesh, rl.Matrix(1), material)
}
