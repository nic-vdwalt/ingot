#+build !js
package procgen

import "core:testing"
import "ingot:asset"

TERRAIN_SAMPLED_TEST_CELLS :: 2
TERRAIN_SAMPLED_TEST_SAMPLES :: 27
TERRAIN_SAMPLED_TEST_VERTICES :: 152
TERRAIN_SAMPLED_TEST_INDICES :: 288
TERRAIN_SAMPLED_TEST_SLOTS :: 512

Terrain_Sampled_Test_Storage :: struct {
	positions:   [TERRAIN_SAMPLED_TEST_SAMPLES]asset.Vec3,
	density:     [TERRAIN_SAMPLED_TEST_SAMPLES]f32,
	normals:     [TERRAIN_SAMPLED_TEST_SAMPLES]asset.Vec3,
	weld_keys:   [TERRAIN_SAMPLED_TEST_SLOTS]u64,
	weld_values: [TERRAIN_SAMPLED_TEST_SLOTS]u32,
	vertices:    [TERRAIN_SAMPLED_TEST_VERTICES]asset.Vertex,
	indices:     [TERRAIN_SAMPLED_TEST_INDICES]u32,
}

@(test)
terrain_sampled_mesh_is_deterministic_and_bounded :: proc(t: ^testing.T) {
	first, second := new(Terrain_Sampled_Test_Storage), new(Terrain_Sampled_Test_Storage)
	defer free(first)
	defer free(second)
	_terrain_sampled_test_field(first)
	_terrain_sampled_test_field(second)
	lattice_a := _terrain_sampled_test_lattice(first)
	lattice_b := _terrain_sampled_test_lattice(second)
	buffer_a := _terrain_sampled_test_buffer(first, 1)
	buffer_b := _terrain_sampled_test_buffer(second, 2)
	capacity, indices, _, count_ok := terrain_sampled_count(lattice_a)
	result_a, ok_a := terrain_sampled_generate(lattice_a, 1, &buffer_a)
	result_b, ok_b := terrain_sampled_generate(lattice_b, 1, &buffer_b)
	testing.expect(t, count_ok && ok_a && ok_b)
	testing.expect_value(t, result_a, result_b)
	testing.expect_value(t, result_a.index_count, u32(indices))
	testing.expect(t, result_a.vertex_count <= u32(capacity))
	for vertex, index in buffer_a.mesh.vertices[:result_a.vertex_count] {
		testing.expect_value(t, vertex, buffer_b.mesh.vertices[index])
	}
	for index in 0 ..< int(result_a.index_count) {
		testing.expect_value(t, buffer_a.mesh.indices[index], buffer_b.mesh.indices[index])
	}
}

@(test)
terrain_sampled_mesh_rejects_invalid_input_without_publication :: proc(t: ^testing.T) {
	storage := new(Terrain_Sampled_Test_Storage)
	defer free(storage)
	_terrain_sampled_test_field(storage)
	lattice := _terrain_sampled_test_lattice(storage)
	buffer := _terrain_sampled_test_buffer(storage, 1)
	buffer.mesh.vertex_count = 7
	lattice.density[0] = transmute(f32)u32(0x7fc00000)
	_, ok := terrain_sampled_generate(lattice, 1, &buffer)
	testing.expect(t, !ok)
	testing.expect_value(t, buffer.mesh.vertex_count, u32(7))
}

@(private)
_terrain_sampled_test_field :: proc(storage: ^Terrain_Sampled_Test_Storage) {
	assert(storage != nil)
	index := 0
	for z in 0 ..= TERRAIN_SAMPLED_TEST_CELLS {
		for y in 0 ..= TERRAIN_SAMPLED_TEST_CELLS {
			for x in 0 ..= TERRAIN_SAMPLED_TEST_CELLS {
				storage.positions[index] = {f32(x), f32(y), f32(z)}
				storage.density[index] = 2.5 - f32(x + y + z)
				storage.normals[index] = {0.57735026, 0.57735026, 0.57735026}
				index += 1
			}
		}
	}
}

@(private)
_terrain_sampled_test_lattice :: proc(
	storage: ^Terrain_Sampled_Test_Storage,
) -> Terrain_Sampled_Lattice {
	assert(storage != nil)
	return {
		cells = {
			TERRAIN_SAMPLED_TEST_CELLS,
			TERRAIN_SAMPLED_TEST_CELLS,
			TERRAIN_SAMPLED_TEST_CELLS,
		},
		positions = storage.positions[:],
		density = storage.density[:],
		normals = storage.normals[:],
	}
}

@(private)
_terrain_sampled_test_buffer :: proc(
	storage: ^Terrain_Sampled_Test_Storage,
	id: u32,
) -> Terrain_Volume_Buffer_V3 {
	assert(storage != nil)
	return {
		weld_keys = storage.weld_keys[:],
		weld_values = storage.weld_values[:],
		mesh = {
			id = asset.Mesh_Id(id),
			vertices = storage.vertices[:],
			indices = storage.indices[:],
			primitive = .Triangles,
		},
	}
}
