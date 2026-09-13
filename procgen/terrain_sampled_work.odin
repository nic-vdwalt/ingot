package procgen

import "core:math"
import "ingot:asset"

TERRAIN_SAMPLED_WORK_CELLS :: 64

Terrain_Sampled_Work :: struct {
	lattice: Terrain_Sampled_Lattice,
	cursor: int,
	index_count: int,
	vertex_capacity: int,
	weld_slots: int,
	counted: bool,
	emitting: bool,
	complete: bool,
	emit: _Terrain_Sampled_Emit,
}

terrain_sampled_work_begin :: proc(
	work: ^Terrain_Sampled_Work,
	lattice: Terrain_Sampled_Lattice,
) -> bool {
	assert(work != nil)
	if !_terrain_sampled_valid(lattice) do return false
	capacity := lattice.cells.x * lattice.cells.y * lattice.cells.z *
		TERRAIN_VOLUME_EDGES_PER_CELL_V3
	work^ = {lattice = lattice, vertex_capacity = capacity,
		weld_slots = _terrain_volume_weld_slots_v3(capacity)}
	return true
}

terrain_sampled_work_count :: proc(work: ^Terrain_Sampled_Work) -> bool {
	assert(work != nil)
	if work.counted do return true
	if work.lattice.positions == nil || work.emitting do return false
	cells := work.lattice.cells
	total := cells.x * cells.y * cells.z
	assert(work.cursor >= 0 && work.cursor <= total)
	stride_x, stride_y := cells.x + 1, cells.y + 1
	offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	finish := min(work.cursor + TERRAIN_SAMPLED_WORK_CELLS, total)
	for cell in work.cursor ..< finish {
		column := cell % cells.x
		row := cell / cells.x % cells.y
		layer := cell / (cells.x * cells.y)
		origin := (layer * stride_y + row) * stride_x + column
		positions: [8]asset.Vec3
		for corner in 0 ..< 8 do positions[corner] = work.lattice.positions[origin + offsets[corner]]
		work.index_count += 3 * _terrain_volume_count_cell_v3(
			positions, work.lattice.density, offsets, origin,
		)
	}
	work.cursor = finish
	work.counted = finish == total
	return true
}

terrain_sampled_work_emit :: proc(
	work: ^Terrain_Sampled_Work,
	uv_scale: f32,
	buffer: ^Terrain_Volume_Buffer_V3,
) -> (Terrain_Volume_Result_V3, bool) {
	assert(work != nil)
	if buffer == nil || !work.counted || uv_scale <= 0 ||
		math.is_nan(uv_scale) || math.is_inf(uv_scale, 0) do return {}, false
	if work.complete do return {}, false
	if work.index_count == 0 {
		asset.mesh_reset(&buffer.mesh)
		work.complete = true
		return {_terrain_volume_uniform_v3(work.lattice.density), 0, 0}, true
	}
	if len(buffer.mesh.vertices) < work.vertex_capacity ||
		len(buffer.mesh.indices) < work.index_count ||
		len(buffer.weld_keys) < work.weld_slots ||
		len(buffer.weld_values) < work.weld_slots do return {}, false
	if !work.emitting {
		asset.mesh_reset(&buffer.mesh)
		for slot in 0 ..< work.weld_slots do buffer.weld_keys[slot] = TERRAIN_VOLUME_WELD_EMPTY_V3
		work.emit = {lattice = work.lattice, uv_scale = uv_scale,
			slot_mask = u64(work.weld_slots - 1),
			minimum = {max(f32), max(f32), max(f32)},
			maximum = {-max(f32), -max(f32), -max(f32)}}
		work.cursor = 0
		work.emitting = true
	}
	work.emit.buffer = buffer
	defer work.emit.buffer = nil
	cells := work.lattice.cells
	total := cells.x * cells.y * cells.z
	assert(work.cursor >= 0 && work.cursor <= total)
	stride_x, stride_y := cells.x + 1, cells.y + 1
	offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	finish := min(work.cursor + TERRAIN_SAMPLED_WORK_CELLS, total)
	for cell in work.cursor ..< finish {
		column := cell % cells.x
		row := cell / cells.x % cells.y
		layer := cell / (cells.x * cells.y)
		origin := (layer * stride_y + row) * stride_x + column
		positions: [8]asset.Vec3
		indices: [8]int
		for corner in 0 ..< 8 {
			indices[corner] = origin + offsets[corner]
			positions[corner] = work.lattice.positions[indices[corner]]
		}
		_terrain_sampled_emit_cell(&work.emit, positions, indices)
	}
	work.cursor = finish
	if finish != total do return {}, true
	if work.emit.indices != work.index_count do return {}, false
	buffer.mesh.vertex_count = u32(work.emit.vertices)
	buffer.mesh.index_count = u32(work.emit.indices)
	buffer.mesh.primitive = .Triangles
	buffer.mesh.bounds = {work.emit.minimum, work.emit.maximum}
	view, view_ok := asset.mesh_view(&buffer.mesh)
	if !view_ok || !asset.mesh_validate(view) do return {}, false
	work.complete = true
	return {_terrain_volume_uniform_v3(work.lattice.density),
		u32(work.emit.vertices), u32(work.emit.indices)}, true
}
