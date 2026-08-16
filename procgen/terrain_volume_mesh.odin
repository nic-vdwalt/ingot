package procgen

import "core:math"
import "ingot:asset"

TERRAIN_VOLUME_VERTICES_PER_CELL_V3 :: 36
TERRAIN_VOLUME_INDICES_PER_CELL_V3 :: 36

Terrain_Volume_Request_V3 :: struct {
	origin: [3]f32,
	cells:  [3]int,
	step:   f32,
}

Terrain_Volume_Buffer_V3 :: struct {
	density_halo: []f32,
	mesh:         asset.Mesh_Buffer,
}

terrain_volume_requirements_v3 :: proc(
	cells: [3]int,
) -> (
	density_count, vertex_max, index_max: int,
	ok: bool,
) {
	for count in cells do if count < 1 || count > TERRAIN_VOLUME_MAX_EDGE_V3 do return 0, 0, 0, false
	density_count = (cells.x + 2) * (cells.y + 2) * (cells.z + 2)
	if density_count > TERRAIN_VOLUME_MAX_SAMPLES_V3 do return 0, 0, 0, false
	cell_count := cells.x * cells.y * cells.z
	vertex_max = cell_count * TERRAIN_VOLUME_VERTICES_PER_CELL_V3
	index_max = cell_count * TERRAIN_VOLUME_INDICES_PER_CELL_V3
	return density_count, vertex_max, index_max, true
}

terrain_generate_volume_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	buffer: ^Terrain_Volume_Buffer_V3,
) -> bool {
	if buffer == nil || !terrain_recipe_validate_v3(recipe) do return false
	if request.step <= 0 || math.is_nan(request.step) || math.is_inf(request.step, 0) do return false
	for value in request.origin do if math.is_nan(value) || math.is_inf(value, 0) do return false
	density_count, _, _, valid := terrain_volume_requirements_v3(request.cells)
	if !valid || len(buffer.density_halo) < density_count do return false
	if !_terrain_volume_sample_v3(recipe, request, buffer.density_halo[:density_count]) do return false
	vertices, indices := _terrain_volume_count_v3(
		request.cells,
		buffer.density_halo[:density_count],
	)
	if vertices == 0 || indices == 0 do return false
	if len(buffer.mesh.vertices) < vertices || len(buffer.mesh.indices) < indices do return false
	asset.mesh_reset(&buffer.mesh)
	_terrain_volume_emit_v3(recipe, request, buffer, vertices, indices)
	view, ok := asset.mesh_view(&buffer.mesh)
	return ok && asset.mesh_validate(view)
}

@(private)
_terrain_volume_sample_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	density: []f32,
) -> bool {
	stride_x := request.cells.x + 2
	stride_y := request.cells.y + 2
	for z in 0 ..< request.cells.z + 2 {
		world_z := request.origin.z + f32(z - 1) * request.step
		for y in 0 ..< request.cells.y + 2 {
			world_y := request.origin.y + f32(y - 1) * request.step
			for x in 0 ..< request.cells.x + 2 {
				world_x := request.origin.x + f32(x - 1) * request.step
				value, ok := terrain_density_v3(recipe, world_x, world_y, world_z)
				if !ok do return false
				density[(z * stride_y + y) * stride_x + x] = value
			}
		}
	}
	return true
}

@(private)
_terrain_volume_count_v3 :: proc(cells: [3]int, density: []f32) -> (vertices, indices: int) {
	stride_x := cells.x + 2
	stride_y := cells.y + 2
	corner_offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	tetrahedra := _terrain_volume_tetrahedra_v3()
	for z in 0 ..< cells.z {
		for y in 0 ..< cells.y {
			for x in 0 ..< cells.x {
				origin := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				for tetrahedron in tetrahedra {
					inside := 0
					for corner in tetrahedron {
						if density[origin + corner_offsets[corner]] > 0 do inside += 1
					}
					if inside == 1 || inside == 3 {
						vertices += 3
						indices += 3
					} else if inside == 2 {
						vertices += 6
						indices += 6
					}
				}
			}
		}
	}
	return
}

@(private)
_terrain_volume_emit_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	buffer: ^Terrain_Volume_Buffer_V3,
	vertex_count, index_count: int,
) {
	assert(buffer != nil, "_terrain_volume_emit_v3: nil buffer")
	assert(vertex_count > 0 && index_count > 0, "_terrain_volume_emit_v3: empty mesh")
	stride_x := request.cells.x + 2
	stride_y := request.cells.y + 2
	corner_offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	corner_units := _terrain_volume_corner_units_v3()
	written_vertices, written_indices := 0, 0
	minimum := asset.Vec3{f32(3.402823466e+38), f32(3.402823466e+38), f32(3.402823466e+38)}
	maximum := asset.Vec3{f32(-3.402823466e+38), f32(-3.402823466e+38), f32(-3.402823466e+38)}
	for z in 0 ..< request.cells.z {
		for y in 0 ..< request.cells.y {
			for x in 0 ..< request.cells.x {
				cell_min := request.origin + [3]f32{f32(x), f32(y), f32(z)} * request.step
				origin := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				positions: [8]asset.Vec3
				densities: [8]f32
				for unit, corner in corner_units {
					positions[corner] = cell_min + asset.Vec3(unit) * request.step
					densities[corner] = buffer.density_halo[origin + corner_offsets[corner]]
				}
				_terrain_volume_emit_cell_v3(
					recipe,
					request.step,
					buffer,
					positions,
					densities,
					&written_vertices,
					&written_indices,
					&minimum,
					&maximum,
				)
			}
		}
	}
	assert(written_vertices == vertex_count, "_terrain_volume_emit_v3: vertex count mismatch")
	assert(written_indices == index_count, "_terrain_volume_emit_v3: index count mismatch")
	buffer.mesh.vertex_count = u32(written_vertices)
	buffer.mesh.index_count = u32(written_indices)
	buffer.mesh.primitive = .Triangles
	buffer.mesh.bounds = {minimum, maximum}
}

@(private)
_terrain_volume_emit_cell_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	step: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
	positions: [8]asset.Vec3,
	densities: [8]f32,
	vertex_cursor, index_cursor: ^int,
	minimum, maximum: ^asset.Vec3,
) {
	assert(buffer != nil && vertex_cursor != nil && index_cursor != nil, "volume cell pointers")
	for tetrahedron in _terrain_volume_tetrahedra_v3() {
		tetra_positions: [4]asset.Vec3
		tetra_densities: [4]f32
		for corner, index in tetrahedron {
			tetra_positions[index] = positions[corner]
			tetra_densities[index] = densities[corner]
		}
		_terrain_volume_emit_tetrahedron_v3(
			recipe,
			step,
			buffer,
			tetra_positions,
			tetra_densities,
			vertex_cursor,
			index_cursor,
			minimum,
			maximum,
		)
	}
}

@(private)
_terrain_volume_emit_tetrahedron_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	step: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
	positions: [4]asset.Vec3,
	densities: [4]f32,
	vertex_cursor, index_cursor: ^int,
	minimum, maximum: ^asset.Vec3,
) {
	inside_indices, outside_indices: [4]int
	inside_count, outside_count := 0, 0
	for density, index in densities {
		if density > 0 {
			inside_indices[inside_count] = index
			inside_count += 1
		} else {
			outside_indices[outside_count] = index
			outside_count += 1
		}
	}
	if inside_count == 0 || inside_count == 4 do return
	points: [4]asset.Vec3
	point_count := 0
	for inside in inside_indices[:inside_count] {
		for outside in outside_indices[:outside_count] {
			points[point_count] = _terrain_volume_intersection_v3(
				positions[inside],
				positions[outside],
				densities[inside],
				densities[outside],
			)
			point_count += 1
		}
	}
	if point_count == 3 {
		_terrain_volume_emit_triangle_v3(
			recipe,
			step,
			buffer,
			{points[0], points[1], points[2]},
			vertex_cursor,
			index_cursor,
			minimum,
			maximum,
		)
	} else {
		assert(point_count == 4, "_terrain_volume_emit_tetrahedron_v3: crossing count")
		_terrain_volume_emit_triangle_v3(
			recipe,
			step,
			buffer,
			{points[0], points[1], points[3]},
			vertex_cursor,
			index_cursor,
			minimum,
			maximum,
		)
		_terrain_volume_emit_triangle_v3(
			recipe,
			step,
			buffer,
			{points[0], points[3], points[2]},
			vertex_cursor,
			index_cursor,
			minimum,
			maximum,
		)
	}
}

@(private)
_terrain_volume_emit_triangle_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	step: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
	positions: [3]asset.Vec3,
	vertex_cursor, index_cursor: ^int,
	minimum, maximum: ^asset.Vec3,
) {
	triangle := positions
	normals := [3]asset.Vec3 {
		_terrain_density_normal_v3(recipe, triangle[0], step * 0.25),
		_terrain_density_normal_v3(recipe, triangle[1], step * 0.25),
		_terrain_density_normal_v3(recipe, triangle[2], step * 0.25),
	}
	edge_a := triangle[1] - triangle[0]
	edge_b := triangle[2] - triangle[0]
	cross := asset.Vec3 {
		edge_a.y * edge_b.z - edge_a.z * edge_b.y,
		edge_a.z * edge_b.x - edge_a.x * edge_b.z,
		edge_a.x * edge_b.y - edge_a.y * edge_b.x,
	}
	average := normals[0] + normals[1] + normals[2]
	if cross.x * average.x + cross.y * average.y + cross.z * average.z < 0 {
		triangle[1], triangle[2] = triangle[2], triangle[1]
		normals[1], normals[2] = normals[2], normals[1]
	}
	base := u32(vertex_cursor^)
	for position, index in triangle {
		normal := normals[index]
		buffer.mesh.vertices[vertex_cursor^] = {
			position = position,
			normal   = normal,
			scalar   = clamp(normal.z * 0.5 + 0.5, 0, 1),
			uv       = _terrain_volume_projection_uv_v3(normal, position),
		}
		for axis in 0 ..< 3 {
			minimum[axis] = min(minimum[axis], position[axis])
			maximum[axis] = max(maximum[axis], position[axis])
		}
		vertex_cursor^ += 1
	}
	for offset in 0 ..< 3 {
		buffer.mesh.indices[index_cursor^] = base + u32(offset)
		index_cursor^ += 1
	}
}

@(private)
_terrain_volume_intersection_v3 :: proc(
	inside, outside: asset.Vec3,
	inside_density, outside_density: f32,
) -> asset.Vec3 {
	denominator := inside_density - outside_density
	if abs(denominator) <= 0.000001 do return (inside + outside) * 0.5
	factor := clamp(inside_density / denominator, 0, 1)
	return inside + (outside - inside) * factor
}

@(private)
_terrain_volume_projection_uv_v3 :: proc(normal, position: asset.Vec3) -> asset.Vec2 {
	absolute := asset.Vec3{abs(normal.x), abs(normal.y), abs(normal.z)}
	if absolute.x >= absolute.y && absolute.x >= absolute.z {
		return {position.y / 32, position.z / 32}
	}
	if absolute.y >= absolute.z do return {position.x / 32, position.z / 32}
	return {position.x / 32, position.y / 32}
}

@(private)
_terrain_volume_corner_offsets_v3 :: proc(stride_x, stride_y: int) -> [8]int {
	assert(stride_x >= 3 && stride_y >= 3, "_terrain_volume_corner_offsets_v3: strides")
	plane := stride_x * stride_y
	return {0, 1, 1 + stride_x, stride_x, plane, plane + 1, plane + 1 + stride_x, plane + stride_x}
}

@(private)
_terrain_volume_corner_units_v3 :: proc() -> [8][3]f32 {
	return {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}}
}

@(private)
_terrain_volume_tetrahedra_v3 :: proc() -> [6][4]int {
	return {{0, 5, 1, 6}, {0, 1, 2, 6}, {0, 2, 3, 6}, {0, 3, 7, 6}, {0, 7, 4, 6}, {0, 4, 5, 6}}
}

@(private)
_terrain_density_normal_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	position: [3]f32,
	step: f32,
) -> asset.Vec3 {
	left, _ := terrain_density_v3(recipe, position.x - step, position.y, position.z)
	right, _ := terrain_density_v3(recipe, position.x + step, position.y, position.z)
	down, _ := terrain_density_v3(recipe, position.x, position.y - step, position.z)
	up, _ := terrain_density_v3(recipe, position.x, position.y + step, position.z)
	below, _ := terrain_density_v3(recipe, position.x, position.y, position.z - step)
	above, _ := terrain_density_v3(recipe, position.x, position.y, position.z + step)
	normal := asset.Vec3{left - right, down - up, below - above}
	length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
	if length <= 0 do return {0, 0, 1}
	return normal / length
}
