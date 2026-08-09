#+build !js
package procgen

import "core:testing"
import "ingot:asset"

Terrain_Test_Storage :: struct {
	vertices: [TERRAIN_CHUNK_VERTICES]asset.Vertex,
	indices:  [TERRAIN_CHUNK_INDICES]u32,
}

@(test)
terrain_generation_is_seed_deterministic :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_Test_Storage
	chunk_a := _terrain_test_chunk(&storage_a, 2, -3)
	chunk_b := _terrain_test_chunk(&storage_b, 2, -3)
	config := terrain_default_config(123456)
	testing.expect(t, terrain_generate_chunk(config, &chunk_a))
	testing.expect(t, terrain_generate_chunk(config, &chunk_b))
	testing.expect_value(t, chunk_a.mesh.vertex_count, chunk_b.mesh.vertex_count)
	testing.expect_value(t, chunk_a.mesh.index_count, chunk_b.mesh.index_count)
	for vertex, index in storage_a.vertices {
		testing.expect_value(t, vertex, storage_b.vertices[index])
	}
	for index_value, index in storage_a.indices {
		testing.expect_value(t, index_value, storage_b.indices[index])
	}
	testing.expect_value(t, chunk_a.placement_count, chunk_b.placement_count)
	for placement, index in chunk_a.placements[:chunk_a.placement_count] {
		testing.expect_value(t, placement, chunk_b.placements[index])
	}
}

@(test)
terrain_neighbors_share_border_samples :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_Test_Storage
	chunk_a := _terrain_test_chunk(&storage_a, 0, 0)
	chunk_b := _terrain_test_chunk(&storage_b, 1, 0)
	config := terrain_default_config(99)
	testing.expect(t, terrain_generate_chunk(config, &chunk_a))
	testing.expect(t, terrain_generate_chunk(config, &chunk_b))
	for row in 0 ..= TERRAIN_CHUNK_QUADS {
		left := storage_a.vertices[row * (TERRAIN_CHUNK_QUADS + 1) + TERRAIN_CHUNK_QUADS]
		right := storage_b.vertices[row * (TERRAIN_CHUNK_QUADS + 1)]
		testing.expect_value(t, left.position, right.position)
		testing.expect_value(t, left.normal, right.normal)
	}
}

@(test)
terrain_indices_are_valid_and_consistently_wound :: proc(t: ^testing.T) {
	storage: Terrain_Test_Storage
	chunk := _terrain_test_chunk(&storage, -4, 7)
	testing.expect(t, terrain_generate_chunk(terrain_default_config(7), &chunk))
	view, ok := asset.mesh_view(&chunk.mesh)
	testing.expect(t, ok)
	testing.expect(t, asset.mesh_validate(view))
	for triangle in 0 ..< TERRAIN_CHUNK_INDICES / 3 {
		a := storage.indices[triangle * 3]
		b := storage.indices[triangle * 3 + 1]
		c := storage.indices[triangle * 3 + 2]
		testing.expect(t, a != b && b != c && a != c)
	}
}

@(test)
terrain_placements_stay_bounded_and_inside_chunk :: proc(t: ^testing.T) {
	for seed in 1 ..= 16 {
		storage: Terrain_Test_Storage
		chunk := _terrain_test_chunk(&storage, seed - 8, 3)
		config := terrain_default_config(u64(seed))
		testing.expect(t, terrain_generate_chunk(config, &chunk))
		testing.expect(t, int(chunk.placement_count) <= TERRAIN_MAX_PLACEMENTS)
		for placement in chunk.placements[:chunk.placement_count] {
			testing.expect(t, placement.position[0] >= chunk.mesh.bounds.minimum[0])
			testing.expect(t, placement.position[0] <= chunk.mesh.bounds.maximum[0])
			testing.expect(t, placement.position[1] >= chunk.mesh.bounds.minimum[1])
			testing.expect(t, placement.position[1] <= chunk.mesh.bounds.maximum[1])
		}
	}
}

@(private)
_terrain_test_chunk :: proc(
	storage: ^Terrain_Test_Storage,
	chunk_x, chunk_y: int,
) -> Terrain_Chunk {
	assert(storage != nil, "_terrain_test_chunk: nil storage")
	return {
		mesh = {
			id = 1,
			vertices = storage.vertices[:],
			indices = storage.indices[:],
			primitive = .Triangles,
		},
		chunk_x = i32(chunk_x),
		chunk_y = i32(chunk_y),
	}
}
