#+build !js
package procgen

import "core:testing"

TERRAIN_REGION_TEST_EDGE :: 5
TERRAIN_REGION_TEST_CELLS :: TERRAIN_REGION_TEST_EDGE * TERRAIN_REGION_TEST_EDGE

Terrain_Region_Test_Storage :: struct {
	raw:             [TERRAIN_REGION_TEST_CELLS]Terrain_Biome_Blend_V2,
	biomes:          [TERRAIN_REGION_TEST_CELLS]Terrain_Biome_Blend_V2,
	patch_ids:       [TERRAIN_REGION_TEST_CELLS]u32,
	labels:          [TERRAIN_REGION_TEST_CELLS]u32,
	queue:           [TERRAIN_REGION_TEST_CELLS]u32,
	component_sizes: [TERRAIN_REGION_TEST_CELLS]u32,
	component_ids:   [TERRAIN_REGION_TEST_CELLS]u16,
	merge_targets:   [TERRAIN_REGION_TEST_CELLS]u32,
}

@(test)
terrain_biome_regions_are_connected_canonical_and_deterministic :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_Region_Test_Storage
	for index in 0 ..< TERRAIN_REGION_TEST_CELLS {
		id := u16(2)
		if index % TERRAIN_REGION_TEST_EDGE >= 3 do id = 3
		storage_a.raw[index] = {id, 4, 0.6}
		storage_b.raw[index] = storage_a.raw[index]
	}
	recipe := terrain_default_recipe_v2(7)
	request := Terrain_Biome_Region_Request {
		TERRAIN_REGION_TEST_EDGE,
		TERRAIN_REGION_TEST_EDGE,
		2,
		nil,
	}
	testing.expect(
		t,
		terrain_resolve_biome_regions(
			&recipe,
			request,
			storage_a.raw[:],
			_terrain_region_output(&storage_a),
			_terrain_region_scratch(&storage_a),
		),
	)
	testing.expect(
		t,
		terrain_resolve_biome_regions(
			&recipe,
			request,
			storage_b.raw[:],
			_terrain_region_output(&storage_b),
			_terrain_region_scratch(&storage_b),
		),
	)
	testing.expect_value(t, storage_a.biomes, storage_b.biomes)
	testing.expect_value(t, storage_a.patch_ids, storage_b.patch_ids)
	for biome in storage_a.biomes {
		testing.expect_value(t, biome.primary_id, biome.secondary_id)
		testing.expect_value(t, biome.primary_weight, f32(1))
	}
	testing.expect(t, _terrain_region_patch_connected(storage_a.patch_ids[:], 1))
	testing.expect(t, _terrain_region_patch_connected(storage_a.patch_ids[:], 2))
}

@(test)
terrain_biome_regions_merge_by_shared_boundary :: proc(t: ^testing.T) {
	storage: Terrain_Region_Test_Storage
	for &biome in storage.raw do biome = {2, 2, 1}
	center := 2 * TERRAIN_REGION_TEST_EDGE + 2
	storage.raw[center] = {3, 3, 1}
	recipe := terrain_default_recipe_v2(9)
	request := Terrain_Biome_Region_Request {
		TERRAIN_REGION_TEST_EDGE,
		TERRAIN_REGION_TEST_EDGE,
		2,
		nil,
	}
	testing.expect(
		t,
		terrain_resolve_biome_regions(
			&recipe,
			request,
			storage.raw[:],
			_terrain_region_output(&storage),
			_terrain_region_scratch(&storage),
		),
	)
	testing.expect_value(t, storage.biomes[center].primary_id, u16(2))
	testing.expect_value(t, storage.patch_ids[center], storage.patch_ids[0])
}

@(test)
terrain_biome_regions_keep_protected_components :: proc(t: ^testing.T) {
	storage: Terrain_Region_Test_Storage
	for &biome in storage.raw do biome = {2, 2, 1}
	center := 2 * TERRAIN_REGION_TEST_EDGE + 2
	storage.raw[center] = {0, 0, 1}
	recipe := terrain_default_recipe_v2(11)
	protected := [?]u16{0}
	request := Terrain_Biome_Region_Request {
		TERRAIN_REGION_TEST_EDGE,
		TERRAIN_REGION_TEST_EDGE,
		2,
		protected[:],
	}
	testing.expect(
		t,
		terrain_resolve_biome_regions(
			&recipe,
			request,
			storage.raw[:],
			_terrain_region_output(&storage),
			_terrain_region_scratch(&storage),
		),
	)
	testing.expect_value(t, storage.biomes[center].primary_id, u16(0))
	testing.expect(t, storage.patch_ids[center] != storage.patch_ids[0])
}

@(test)
terrain_biome_regions_reject_capacity_without_publication :: proc(t: ^testing.T) {
	storage: Terrain_Region_Test_Storage
	for index in 0 ..< TERRAIN_REGION_TEST_CELLS {
		storage.raw[index] = {2, 2, 1}
		storage.biomes[index] = {9, 9, 0.25}
		storage.patch_ids[index] = 99
	}
	recipe := terrain_default_recipe_v2(13)
	request := Terrain_Biome_Region_Request {
		TERRAIN_REGION_TEST_EDGE,
		TERRAIN_REGION_TEST_EDGE,
		2,
		nil,
	}
	output := _terrain_region_output(&storage)
	output.patch_ids = output.patch_ids[:len(output.patch_ids) - 1]
	testing.expect(
		t,
		!terrain_resolve_biome_regions(
			&recipe,
			request,
			storage.raw[:],
			output,
			_terrain_region_scratch(&storage),
		),
	)
	for index in 0 ..< TERRAIN_REGION_TEST_CELLS {
		testing.expect_value(t, storage.biomes[index], Terrain_Biome_Blend_V2{9, 9, 0.25})
		testing.expect_value(t, storage.patch_ids[index], u32(99))
	}
}

@(private)
_terrain_region_output :: proc(
	storage: ^Terrain_Region_Test_Storage,
) -> Terrain_Biome_Region_Output {
	assert(storage != nil, "terrain region test output storage")
	return {storage.biomes[:], storage.patch_ids[:]}
}

@(private)
_terrain_region_scratch :: proc(
	storage: ^Terrain_Region_Test_Storage,
) -> Terrain_Biome_Region_Scratch {
	assert(storage != nil, "terrain region test scratch storage")
	return {
		storage.labels[:],
		storage.queue[:],
		storage.component_sizes[:],
		storage.component_ids[:],
		storage.merge_targets[:],
	}
}

@(private)
_terrain_region_patch_connected :: proc(patches: []u32, patch: u32) -> bool {
	seen: [TERRAIN_REGION_TEST_CELLS]bool
	queue: [TERRAIN_REGION_TEST_CELLS]u32
	origin := -1
	for value, index in patches do if value == patch {
		origin = index
		break
	}
	if origin < 0 do return false
	head, tail := 0, 1
	queue[0] = u32(origin)
	seen[origin] = true
	for head < tail {
		index := int(queue[head])
		head += 1
		x, y := index % TERRAIN_REGION_TEST_EDGE, index / TERRAIN_REGION_TEST_EDGE
		neighbors := [?][2]int{{x - 1, y}, {x + 1, y}, {x, y - 1}, {x, y + 1}}
		for neighbor in neighbors {
			if neighbor.x < 0 || neighbor.x >= TERRAIN_REGION_TEST_EDGE do continue
			if neighbor.y < 0 || neighbor.y >= TERRAIN_REGION_TEST_EDGE do continue
			next := neighbor.y * TERRAIN_REGION_TEST_EDGE + neighbor.x
			if seen[next] || patches[next] != patch do continue
			seen[next] = true
			queue[tail] = u32(next)
			tail += 1
		}
	}
	for value, index in patches do if value == patch && !seen[index] do return false
	return true
}
