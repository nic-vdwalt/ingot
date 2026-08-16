#+build !js
package procgen

import "core:testing"

TERRAIN_V2_TEST_EDGE :: 33
TERRAIN_V2_TEST_SAMPLES :: TERRAIN_V2_TEST_EDGE * TERRAIN_V2_TEST_EDGE
TERRAIN_V2_TEST_HALO :: (TERRAIN_V2_TEST_EDGE + 2) * (TERRAIN_V2_TEST_EDGE + 2)

Terrain_V2_Test_Storage :: struct {
	height_halo:     [TERRAIN_V2_TEST_HALO]f32,
	heights:         [TERRAIN_V2_TEST_SAMPLES]f32,
	moisture:        [TERRAIN_V2_TEST_SAMPLES]f32,
	temperature:     [TERRAIN_V2_TEST_SAMPLES]f32,
	continentalness: [TERRAIN_V2_TEST_SAMPLES]f32,
	ruggedness:      [TERRAIN_V2_TEST_SAMPLES]f32,
	derivative_x:    [TERRAIN_V2_TEST_SAMPLES]f32,
	derivative_y:    [TERRAIN_V2_TEST_SAMPLES]f32,
	slope:           [TERRAIN_V2_TEST_SAMPLES]f32,
	biomes:          [TERRAIN_V2_TEST_SAMPLES]Terrain_Biome_Blend_V2,
}

@(test)
terrain_v2_default_recipe_is_valid :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(42)
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	testing.expect_value(t, recipe.version, TERRAIN_RECIPE_VERSION_V2)
	testing.expect(t, recipe.biome_profile_count > 1)
}

@(test)
terrain_v2_field_is_deterministic_and_matches_direct_samples :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_V2_Test_Storage
	buffer_a := _terrain_v2_test_buffer(&storage_a)
	buffer_b := _terrain_v2_test_buffer(&storage_b)
	recipe := terrain_default_recipe_v2(123456)
	request := Terrain_Field_Request_V2{-32, -32, 2, TERRAIN_V2_TEST_EDGE, TERRAIN_V2_TEST_EDGE}
	testing.expect(t, terrain_generate_field_v2(&recipe, request, buffer_a))
	testing.expect(t, terrain_generate_field_v2(&recipe, request, buffer_b))
	testing.expect_value(t, storage_a, storage_b)
	index := 17 * TERRAIN_V2_TEST_EDGE + 11
	sample, ok := terrain_sample_v2(&recipe, -32 + 11 * 2, -32 + 17 * 2, 2)
	testing.expect(t, ok)
	testing.expect_value(t, storage_a.heights[index], sample.height)
	testing.expect_value(t, storage_a.derivative_x[index], sample.derivative_x)
	testing.expect_value(t, storage_a.derivative_y[index], sample.derivative_y)
	testing.expect_value(t, storage_a.biomes[index], sample.biomes)
}

@(test)
terrain_v2_rejects_capacity_without_publication :: proc(t: ^testing.T) {
	storage: Terrain_V2_Test_Storage
	for &height in storage.heights do height = 777
	buffer := _terrain_v2_test_buffer(&storage)
	buffer.biomes = buffer.biomes[:len(buffer.biomes) - 1]
	recipe := terrain_default_recipe_v2(7)
	request := Terrain_Field_Request_V2{0, 0, 1, TERRAIN_V2_TEST_EDGE, TERRAIN_V2_TEST_EDGE}
	testing.expect(t, !terrain_generate_field_v2(&recipe, request, buffer))
	for height in storage.heights do testing.expect_value(t, height, f32(777))
}

@(test)
terrain_v2_centered_derivatives_are_continuous_across_fields :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_V2_Test_Storage
	buffer_a := _terrain_v2_test_buffer(&storage_a)
	buffer_b := _terrain_v2_test_buffer(&storage_b)
	recipe := terrain_default_recipe_v2(99)
	request_a := Terrain_Field_Request_V2{-64, -32, 2, TERRAIN_V2_TEST_EDGE, TERRAIN_V2_TEST_EDGE}
	request_b := Terrain_Field_Request_V2{0, -32, 2, TERRAIN_V2_TEST_EDGE, TERRAIN_V2_TEST_EDGE}
	testing.expect(t, terrain_generate_field_v2(&recipe, request_a, buffer_a))
	testing.expect(t, terrain_generate_field_v2(&recipe, request_b, buffer_b))
	for row in 0 ..< TERRAIN_V2_TEST_EDGE {
		left := row * TERRAIN_V2_TEST_EDGE + TERRAIN_V2_TEST_EDGE - 1
		right := row * TERRAIN_V2_TEST_EDGE
		testing.expect_value(t, storage_a.heights[left], storage_b.heights[right])
		testing.expect_value(t, storage_a.derivative_x[left], storage_b.derivative_x[right])
		testing.expect_value(t, storage_a.derivative_y[left], storage_b.derivative_y[right])
		testing.expect_value(t, storage_a.biomes[left], storage_b.biomes[right])
	}
}

@(test)
terrain_v2_biome_blends_are_normalized_and_stable :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(3)
	blend_a, ok_a := terrain_biome_blend_v2(&recipe, 4, 0.7, 0.6, 0.1)
	blend_b, ok_b := terrain_biome_blend_v2(&recipe, 4, 0.7, 0.6, 0.1)
	testing.expect(t, ok_a && ok_b)
	testing.expect_value(t, blend_a, blend_b)
	testing.expect(t, blend_a.primary_weight >= 0 && blend_a.primary_weight <= 1)
	recipe.biome_profiles[1].id = recipe.biome_profiles[0].id
	testing.expect(t, !terrain_recipe_validate_v2(&recipe))
}

@(test)
terrain_v2_seed_suite_has_usable_variability :: proc(t: ^testing.T) {
	fingerprints: [8]u64
	for seed in 0 ..< len(fingerprints) {
		storage: Terrain_V2_Test_Storage
		buffer := _terrain_v2_test_buffer(&storage)
		recipe := terrain_default_recipe_v2(u64(seed + 1))
		request := Terrain_Field_Request_V2 {
			-128,
			-128,
			8,
			TERRAIN_V2_TEST_EDGE,
			TERRAIN_V2_TEST_EDGE,
		}
		testing.expect(t, terrain_generate_field_v2(&recipe, request, buffer))
		minimum, maximum := storage.heights[0], storage.heights[0]
		fingerprint := u64(1469598103934665603)
		for height, index in storage.heights {
			minimum = min(minimum, height)
			maximum = max(maximum, height)
			fingerprint ~= u64(i64(height * 1024)) + u64(index)
			fingerprint *= 1099511628211
		}
		testing.expect(t, maximum - minimum > 0.5)
		fingerprints[seed] = fingerprint
	}
	different := false
	for index in 1 ..< len(fingerprints) do different = different || fingerprints[index] != fingerprints[0]
	testing.expect(t, different)
}

@(private)
_terrain_v2_test_buffer :: proc(storage: ^Terrain_V2_Test_Storage) -> Terrain_Field_Buffer_V2 {
	assert(storage != nil, "_terrain_v2_test_buffer: nil storage")
	return {
		height_halo = storage.height_halo[:],
		heights = storage.heights[:],
		moisture = storage.moisture[:],
		temperature = storage.temperature[:],
		continentalness = storage.continentalness[:],
		ruggedness = storage.ruggedness[:],
		derivative_x = storage.derivative_x[:],
		derivative_y = storage.derivative_y[:],
		slope = storage.slope[:],
		biomes = storage.biomes[:],
	}
}
