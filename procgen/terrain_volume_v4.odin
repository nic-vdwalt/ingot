package procgen

import "core:math"
import "ingot:asset"

Terrain_Volume_Buffer_V4 :: struct {
	positions: []asset.Vec3,
	density:   []f32,
	normals:   []asset.Vec3,
	mesh:      Terrain_Volume_Buffer_V3,
}

terrain_volume_requirements_v4 :: proc(
	request: Terrain_Shell_Request_V4,
) -> (
	samples, vertex_max, index_max, weld_slots: int,
	ok: bool,
) {
	cells := [3]int{int(request.u_cells), int(request.v_cells), int(request.radial_cells)}
	for count in cells do if count < 1 || count > TERRAIN_VOLUME_MAX_EDGE_V3 do return 0, 0, 0, 0, false
	samples = (cells.x + 1) * (cells.y + 1) * (cells.z + 1)
	if samples > TERRAIN_VOLUME_MAX_SAMPLES_V3 do return 0, 0, 0, 0, false
	cell_count := cells.x * cells.y * cells.z
	vertex_max = cell_count * TERRAIN_VOLUME_EDGES_PER_CELL_V3
	index_max = cell_count * TERRAIN_VOLUME_INDICES_PER_CELL_V3
	weld_slots = _terrain_volume_weld_slots_v3(vertex_max)
	return samples, vertex_max, index_max, weld_slots, true
}

terrain_generate_volume_v4 :: proc(
	recipe: ^Terrain_Recipe_V4,
	request: Terrain_Shell_Request_V4,
	uv_scale: f32,
	buffer: ^Terrain_Volume_Buffer_V4,
) -> (
	Terrain_Volume_Result_V3,
	bool,
) {
	if recipe == nil || buffer == nil do return {}, false
	samples, _, _, _, valid := terrain_volume_requirements_v4(request)
	if !valid || len(buffer.positions) < samples || len(buffer.density) < samples ||
	   len(buffer.normals) < samples {
		return {}, false
	}
	volume := Terrain_Shell_Volume_V4 {
		positions = buffer.positions[:samples],
		density   = buffer.density[:samples],
	}
	if !terrain_shell_volume_sample_v4(recipe, request, &volume) do return {}, false
	_terrain_volume_normals_v4(request, buffer.positions[:samples], buffer.normals[:samples])
	lattice := Terrain_Sampled_Lattice {
		cells     = {int(request.u_cells), int(request.v_cells), int(request.radial_cells)},
		positions = buffer.positions[:samples],
		density   = buffer.density[:samples],
		normals   = buffer.normals[:samples],
	}
	return terrain_sampled_generate(lattice, uv_scale, &buffer.mesh)
}

@(private)
_terrain_volume_normals_v4 :: proc(
	request: Terrain_Shell_Request_V4,
	positions, normals: []asset.Vec3,
) {
	counts := [3]int{int(request.u_cells) + 1, int(request.v_cells) + 1, int(request.radial_cells) + 1}
	assert(len(positions) == counts.x * counts.y * counts.z)
	assert(len(normals) == len(positions))
	for z in 0 ..< counts.z {
		for y in 0 ..< counts.y {
			for x in 0 ..< counts.x {
				index := (z * counts.y + y) * counts.x + x
				position := positions[index]
				length := math.sqrt(position.x * position.x + position.y * position.y + position.z * position.z)
				assert(length > 0)
				normals[index] = position / length
			}
		}
	}
}
