package procgen

import "core:math"
import "ingot:asset"

Terrain_Sampled_Lattice :: struct {
	cells:     [3]int,
	positions: []asset.Vec3,
	density:   []f32,
	normals:   []asset.Vec3,
}

terrain_sampled_count :: proc(
	lattice: Terrain_Sampled_Lattice,
) -> (
	vertex_capacity, index_count, weld_slots: int,
	ok: bool,
) {
	if !_terrain_sampled_valid(lattice) do return 0, 0, 0, false
	stride_x, stride_y := lattice.cells.x + 1, lattice.cells.y + 1
	offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	for z in 0 ..< lattice.cells.z {
		for y in 0 ..< lattice.cells.y {
			for x in 0 ..< lattice.cells.x {
				origin := (z * stride_y + y) * stride_x + x
				positions: [8]asset.Vec3
				for corner in 0 ..< 8 do positions[corner] = lattice.positions[origin + offsets[corner]]
				triangles := _terrain_volume_count_cell_v3(
					positions,
					lattice.density,
					offsets,
					origin,
				)
				index_count += triangles * 3
			}
		}
	}
	cell_count := lattice.cells.x * lattice.cells.y * lattice.cells.z
	vertex_capacity = cell_count * TERRAIN_VOLUME_EDGES_PER_CELL_V3
	weld_slots = _terrain_volume_weld_slots_v3(vertex_capacity)
	return vertex_capacity, index_count, weld_slots, true
}

terrain_sampled_generate :: proc(
	lattice: Terrain_Sampled_Lattice,
	uv_scale: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
) -> (
	Terrain_Volume_Result_V3,
	bool,
) {
	if buffer == nil || uv_scale <= 0 || math.is_nan(uv_scale) || math.is_inf(uv_scale, 0) {
		return {}, false
	}
	vertex_capacity, index_count, weld_slots, valid := terrain_sampled_count(lattice)
	if !valid do return {}, false
	occupancy := _terrain_volume_uniform_v3(lattice.density)
	if index_count == 0 {
		asset.mesh_reset(&buffer.mesh)
		return {occupancy, 0, 0}, true
	}
	if len(buffer.mesh.vertices) < vertex_capacity || len(buffer.mesh.indices) < index_count {
		return {}, false
	}
	if len(buffer.weld_keys) < weld_slots || len(buffer.weld_values) < weld_slots do return {}, false
	asset.mesh_reset(&buffer.mesh)
	for slot in 0 ..< weld_slots do buffer.weld_keys[slot] = TERRAIN_VOLUME_WELD_EMPTY_V3
	state := _Terrain_Sampled_Emit {
		lattice   = lattice,
		buffer    = buffer,
		uv_scale  = uv_scale,
		slot_mask = u64(weld_slots - 1),
		minimum   = {max(f32), max(f32), max(f32)},
		maximum   = {-max(f32), -max(f32), -max(f32)},
	}
	_terrain_sampled_emit(&state)
	if state.indices != index_count do return {}, false
	buffer.mesh.vertex_count = u32(state.vertices)
	buffer.mesh.index_count = u32(state.indices)
	buffer.mesh.primitive = .Triangles
	buffer.mesh.bounds = {state.minimum, state.maximum}
	view, view_ok := asset.mesh_view(&buffer.mesh)
	if !view_ok || !asset.mesh_validate(view) do return {}, false
	return {occupancy, u32(state.vertices), u32(state.indices)}, true
}

@(private)
_terrain_sampled_valid :: proc(lattice: Terrain_Sampled_Lattice) -> bool {
	for count in lattice.cells {
		if count < 1 || count > TERRAIN_VOLUME_MAX_EDGE_V3 do return false
	}
	required := (lattice.cells.x + 1) * (lattice.cells.y + 1) * (lattice.cells.z + 1)
	if required > TERRAIN_VOLUME_MAX_SAMPLES_V3 do return false
	if len(lattice.positions) != required || len(lattice.density) != required || len(lattice.normals) != required {
		return false
	}
	for index in 0 ..< required {
		position, normal, density := lattice.positions[index], lattice.normals[index], lattice.density[index]
		for value in position do if math.is_nan(value) || math.is_inf(value, 0) do return false
		for value in normal do if math.is_nan(value) || math.is_inf(value, 0) do return false
		if math.is_nan(density) || math.is_inf(density, 0) do return false
		length_squared := normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
		if length_squared <= 0.000001 do return false
	}
	return true
}

@(private)
_Terrain_Sampled_Emit :: struct {
	lattice:   Terrain_Sampled_Lattice,
	buffer:    ^Terrain_Volume_Buffer_V3,
	uv_scale:  f32,
	slot_mask: u64,
	vertices:  int,
	indices:   int,
	minimum:   asset.Vec3,
	maximum:   asset.Vec3,
}

@(private)
_terrain_sampled_emit :: proc(state: ^_Terrain_Sampled_Emit) {
	assert(state != nil && state.buffer != nil)
	stride_x, stride_y := state.lattice.cells.x + 1, state.lattice.cells.y + 1
	offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	for z in 0 ..< state.lattice.cells.z {
		for y in 0 ..< state.lattice.cells.y {
			for x in 0 ..< state.lattice.cells.x {
				origin := (z * stride_y + y) * stride_x + x
				positions: [8]asset.Vec3
				indices: [8]int
				for corner in 0 ..< 8 {
					indices[corner] = origin + offsets[corner]
					positions[corner] = state.lattice.positions[indices[corner]]
				}
				_terrain_sampled_emit_cell(state, positions, indices)
			}
		}
	}
}

@(private)
_terrain_sampled_emit_cell :: proc(
	state: ^_Terrain_Sampled_Emit,
	positions: [8]asset.Vec3,
	indices: [8]int,
) {
	assert(state != nil)
	for tetrahedron in _terrain_volume_tetrahedra_v3() {
		tetra_positions: [4]asset.Vec3
		tetra_densities: [4]f32
		tetra_indices: [4]int
		for corner, index in tetrahedron {
			tetra_positions[index] = positions[corner]
			tetra_densities[index] = state.lattice.density[indices[corner]]
			tetra_indices[index] = indices[corner]
		}
		_terrain_sampled_emit_tetrahedron(state, tetra_positions, tetra_densities, tetra_indices)
	}
}

@(private)
_terrain_sampled_emit_tetrahedron :: proc(
	state: ^_Terrain_Sampled_Emit,
	positions: [4]asset.Vec3,
	densities: [4]f32,
	lattice_indices: [4]int,
) {
	assert(state != nil)
	crossings, count := _terrain_volume_crossings_v3(positions, densities)
	if count == 0 do return
	triples, triple_count := _terrain_volume_triangles_v3(count)
	for triple in triples[:triple_count] {
		corners: [3]asset.Vec3
		for crossing, corner in triple do corners[corner] = crossings[crossing].position
		if _terrain_volume_area_squared_v3(corners) <= TERRAIN_VOLUME_MIN_AREA_V3 do continue
		indices: [3]u32
		for crossing, corner in triple {
			indices[corner] = _terrain_sampled_weld(state, crossings[crossing], lattice_indices)
		}
		_terrain_sampled_emit_indices(state, corners, indices)
	}
}

@(private)
_terrain_sampled_weld :: proc(
	state: ^_Terrain_Sampled_Emit,
	crossing: _Terrain_Volume_Crossing_V3,
	indices: [4]int,
) -> u32 {
	assert(state != nil && state.slot_mask > 0)
	low := u64(min(indices[crossing.inside], indices[crossing.outside]))
	high := u64(max(indices[crossing.inside], indices[crossing.outside]))
	key := low << 32 | high
	slot := (key * 0x9E3779B97F4A7C15 >> 32) & state.slot_mask
	for _ in 0 ..= int(state.slot_mask) {
		existing := state.buffer.weld_keys[slot]
		if existing == key do return state.buffer.weld_values[slot]
		if existing == TERRAIN_VOLUME_WELD_EMPTY_V3 do break
		slot = (slot + 1) & state.slot_mask
	}
	index := u32(state.vertices)
	state.buffer.weld_keys[slot] = key
	state.buffer.weld_values[slot] = index
	_terrain_sampled_append_vertex(state, crossing, indices)
	return index
}

@(private)
_terrain_sampled_append_vertex :: proc(
	state: ^_Terrain_Sampled_Emit,
	crossing: _Terrain_Volume_Crossing_V3,
	indices: [4]int,
) {
	assert(state != nil && state.vertices < len(state.buffer.mesh.vertices))
	normal := _terrain_volume_blend_normal_v3(
		state.lattice.normals[indices[crossing.inside]],
		state.lattice.normals[indices[crossing.outside]],
		crossing.factor,
	)
	position := crossing.position
	state.buffer.mesh.vertices[state.vertices] = {
		position = position,
		normal   = normal,
		scalar   = clamp(normal.z * 0.5 + 0.5, 0, 1),
		uv       = _terrain_volume_projection_uv_v3(normal, position, state.uv_scale),
	}
	for axis in 0 ..< 3 {
		state.minimum[axis] = min(state.minimum[axis], position[axis])
		state.maximum[axis] = max(state.maximum[axis], position[axis])
	}
	state.vertices += 1
}

@(private)
_terrain_sampled_emit_indices :: proc(
	state: ^_Terrain_Sampled_Emit,
	corners: [3]asset.Vec3,
	indices: [3]u32,
) {
	assert(state != nil && state.indices + 3 <= len(state.buffer.mesh.indices))
	cross := _terrain_volume_cross_v3(corners)
	average :=
		state.buffer.mesh.vertices[indices[0]].normal +
		state.buffer.mesh.vertices[indices[1]].normal +
		state.buffer.mesh.vertices[indices[2]].normal
	order := indices
	if cross.x * average.x + cross.y * average.y + cross.z * average.z < 0 {
		order[1], order[2] = order[2], order[1]
	}
	for index in order {
		state.buffer.mesh.indices[state.indices] = index
		state.indices += 1
	}
}
