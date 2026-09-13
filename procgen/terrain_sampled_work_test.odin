#+build !js
package procgen

import "core:testing"
import "ingot:asset"

@(test)
terrain_sampled_work_matches_whole_lattice_across_yields :: proc(t: ^testing.T) {
	cells := [3]int{8, 8, 8}
	positions := make([]asset.Vec3, 9 * 9 * 9)
	density := make([]f32, len(positions))
	normals := make([]asset.Vec3, len(positions))
	defer delete(positions)
	defer delete(density)
	defer delete(normals)
	for layer in 0 ..= cells.z {
		for row in 0 ..= cells.y {
			for column in 0 ..= cells.x {
				index := (layer * 9 + row) * 9 + column
				positions[index] = {f32(column), f32(row), f32(layer)}
				density[index] = 10.5 - f32(column + row + layer)
				normals[index] = {0.57735026, 0.57735026, 0.57735026}
			}
		}
	}
	lattice := Terrain_Sampled_Lattice{cells, positions, density, normals}
	capacity, count, slots, valid := terrain_sampled_count(lattice)
	testing.expect(t, valid)
	buffers: [2]Terrain_Volume_Buffer_V3
	for &buffer in buffers {
		buffer.mesh = {id = 1, vertices = make([]asset.Vertex, capacity),
			indices = make([]u32, count)}
		buffer.weld_keys = make([]u64, slots)
		buffer.weld_values = make([]u32, slots)
	}
	defer for &buffer in buffers {
		delete(buffer.mesh.vertices)
		delete(buffer.mesh.indices)
		delete(buffer.weld_keys)
		delete(buffer.weld_values)
	}
	expected, generated := terrain_sampled_generate(lattice, 1, &buffers[0])
	testing.expect(t, generated)
	work: Terrain_Sampled_Work
	testing.expect(t, terrain_sampled_work_begin(&work, lattice))
	for _ in 0 ..< 8 {
		before := work.cursor
		testing.expect(t, terrain_sampled_work_count(&work))
		testing.expect_value(t, work.cursor - before, TERRAIN_SAMPLED_WORK_CELLS)
	}
	testing.expect(t, work.counted)
	testing.expect_value(t, work.index_count, count)
	actual: Terrain_Volume_Result_V3
	for iteration in 0 ..< 8 {
		actual, generated = terrain_sampled_work_emit(&work, 1, &buffers[1])
		testing.expect(t, generated)
		testing.expect_value(t, work.complete, iteration == 7)
	}
	testing.expect_value(t, actual, expected)
	for index in 0 ..< int(actual.vertex_count) {
		testing.expect_value(t, buffers[0].mesh.vertices[index], buffers[1].mesh.vertices[index])
	}
	for index in 0 ..< int(actual.index_count) {
		testing.expect_value(t, buffers[0].mesh.indices[index], buffers[1].mesh.indices[index])
	}
}
