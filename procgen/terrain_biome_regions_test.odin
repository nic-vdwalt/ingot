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

// A province-scale survey needs far more cells than the fixed-layout cases
// above, so it allocates rather than growing the shared stack storage.
TERRAIN_REGION_SURVEY_EDGE :: 96
TERRAIN_REGION_SURVEY_CELLS :: TERRAIN_REGION_SURVEY_EDGE * TERRAIN_REGION_SURVEY_EDGE
TERRAIN_REGION_SURVEY_STEP :: f32(20)
TERRAIN_REGION_SURVEY_MINIMUM :: 64

// Biome extent is what makes a seed read as a place. If boundaries follow the
// top climate octave instead of the base wavelength, the resolver is handed
// speckle and has to merge nearly everything away; asserting that a large
// minimum converges without collapsing to a single region pins both ends.
@(test)
terrain_biome_regions_resolve_province_scale_climate :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(31337)
	half := f32(TERRAIN_REGION_SURVEY_EDGE) * TERRAIN_REGION_SURVEY_STEP / 2
	recipe.latitude_half_extent = half
	testing.expect(t, terrain_recipe_validate_v2(&recipe))

	raw := make([]Terrain_Biome_Blend_V2, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(raw)
	biomes := make([]Terrain_Biome_Blend_V2, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(biomes)
	patch_ids := make([]u32, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(patch_ids)
	labels := make([]u32, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(labels)
	queue := make([]u32, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(queue)
	component_sizes := make([]u32, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(component_sizes)
	component_ids := make([]u16, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(component_ids)
	merge_targets := make([]u32, TERRAIN_REGION_SURVEY_CELLS)
	defer delete(merge_targets)

	for row in 0 ..< TERRAIN_REGION_SURVEY_EDGE {
		world_y := f32(row) * TERRAIN_REGION_SURVEY_STEP - half
		for column in 0 ..< TERRAIN_REGION_SURVEY_EDGE {
			world_x := f32(column) * TERRAIN_REGION_SURVEY_STEP - half
			sample, ok := terrain_sample_prevalidated_v2(&recipe, world_x, world_y, 2)
			if !ok do continue
			raw[row * TERRAIN_REGION_SURVEY_EDGE + column] = sample.biomes
		}
	}
	request := Terrain_Biome_Region_Request {
		TERRAIN_REGION_SURVEY_EDGE,
		TERRAIN_REGION_SURVEY_EDGE,
		TERRAIN_REGION_SURVEY_MINIMUM,
		nil,
	}
	output := Terrain_Biome_Region_Output{biomes, patch_ids}
	scratch := Terrain_Biome_Region_Scratch {
		labels,
		queue,
		component_sizes,
		component_ids,
		merge_targets,
	}
	testing.expect(t, terrain_resolve_biome_regions(&recipe, request, raw, output, scratch))

	sizes := make([]int, TERRAIN_REGION_SURVEY_CELLS + 1)
	defer delete(sizes)
	regions := 0
	for patch in patch_ids {
		if sizes[patch] == 0 do regions += 1
		sizes[patch] += 1
	}
	testing.expectf(t, regions > 1, "climate collapsed to a single region")
	for size, patch in sizes {
		if size == 0 do continue
		testing.expectf(
			t,
			size >= TERRAIN_REGION_SURVEY_MINIMUM,
			"patch %d survived at %d cells, below the %d minimum",
			patch,
			size,
			TERRAIN_REGION_SURVEY_MINIMUM,
		)
	}
	mean := f32(TERRAIN_REGION_SURVEY_CELLS) / f32(regions)
	testing.expectf(
		t,
		mean >= f32(TERRAIN_REGION_SURVEY_MINIMUM),
		"mean region %f too small",
		mean,
	)
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
