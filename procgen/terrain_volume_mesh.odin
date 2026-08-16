package procgen

import "core:math"
import "ingot:asset"

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
	return density_count, cell_count * 24, cell_count * 36, true
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
		world_z := request.origin.z + (f32(z) - 0.5) * request.step
		for y in 0 ..< request.cells.y + 2 {
			world_y := request.origin.y + (f32(y) - 0.5) * request.step
			for x in 0 ..< request.cells.x + 2 {
				world_x := request.origin.x + (f32(x) - 0.5) * request.step
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
	for z in 0 ..< cells.z {
		for y in 0 ..< cells.y {
			for x in 0 ..< cells.x {
				center := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				if density[center] <= 0 do continue
				neighbors := [?]int {
					-1,
					1,
					-stride_x,
					stride_x,
					-stride_x * stride_y,
					stride_x * stride_y,
				}
				for neighbor in neighbors {
					if density[center + neighbor] <= 0 {
						vertices += 4
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
	written_vertices, written_indices := 0, 0
	minimum := asset.Vec3{f32(3.402823466e+38), f32(3.402823466e+38), f32(3.402823466e+38)}
	maximum := asset.Vec3{f32(-3.402823466e+38), f32(-3.402823466e+38), f32(-3.402823466e+38)}
	for z in 0 ..< request.cells.z {
		for y in 0 ..< request.cells.y {
			for x in 0 ..< request.cells.x {
				center := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				if buffer.density_halo[center] <= 0 do continue
				cell_min := request.origin + [3]f32{f32(x), f32(y), f32(z)} * request.step
				_terrain_volume_emit_cell_v3(
					recipe,
					request,
					buffer,
					center,
					cell_min,
					stride_x,
					stride_y,
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
	request: Terrain_Volume_Request_V3,
	buffer: ^Terrain_Volume_Buffer_V3,
	center: int,
	cell_min: [3]f32,
	stride_x, stride_y: int,
	vertex_cursor, index_cursor: ^int,
	minimum, maximum: ^asset.Vec3,
) {
	assert(buffer != nil && vertex_cursor != nil && index_cursor != nil, "volume cell pointers")
	neighbors := [?]int{-1, 1, -stride_x, stride_x, -stride_x * stride_y, stride_x * stride_y}
	for face in 0 ..< 6 {
		if buffer.density_halo[center + neighbors[face]] > 0 do continue
		_terrain_volume_emit_face_v3(
			recipe,
			request.step,
			buffer,
			face,
			cell_min,
			vertex_cursor,
			index_cursor,
			minimum,
			maximum,
		)
	}
}

@(private)
_terrain_volume_emit_face_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	step: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
	face: int,
	cell_min: [3]f32,
	vertex_cursor, index_cursor: ^int,
	minimum, maximum: ^asset.Vec3,
) {
	assert(face >= 0 && face < 6, "_terrain_volume_emit_face_v3: invalid face")
	corners := [6][4][3]f32 {
		{{0, 0, 0}, {0, 0, 1}, {0, 1, 1}, {0, 1, 0}},
		{{1, 0, 0}, {1, 1, 0}, {1, 1, 1}, {1, 0, 1}},
		{{0, 0, 0}, {1, 0, 0}, {1, 0, 1}, {0, 0, 1}},
		{{0, 1, 0}, {0, 1, 1}, {1, 1, 1}, {1, 1, 0}},
		{{0, 0, 0}, {0, 1, 0}, {1, 1, 0}, {1, 0, 0}},
		{{0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}},
	}
	base := u32(vertex_cursor^)
	for corner in corners[face] {
		position := cell_min + corner * step
		normal := _terrain_density_normal_v3(recipe, position, step * 0.25)
		buffer.mesh.vertices[vertex_cursor^] = {
			position = position,
			normal   = normal,
			scalar   = clamp(normal.z * 0.5 + 0.5, 0, 1),
			uv       = {position.x / 32, position.y / 32},
		}
		for axis in 0 ..< 3 {
			minimum[axis] = min(minimum[axis], position[axis])
			maximum[axis] = max(maximum[axis], position[axis])
		}
		vertex_cursor^ += 1
	}
	face_indices := [?]u32{0, 1, 2, 0, 2, 3}
	for offset in face_indices {
		buffer.mesh.indices[index_cursor^] = base + offset
		index_cursor^ += 1
	}
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
