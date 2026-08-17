#+build !js
package procgen

import "core:testing"

TERRAIN_V2_TEST_EDGE :: 33
TERRAIN_V2_TEST_SAMPLES :: TERRAIN_V2_TEST_EDGE * TERRAIN_V2_TEST_EDGE
TERRAIN_V2_TEST_HALO :: (TERRAIN_V2_TEST_EDGE + 2) * (TERRAIN_V2_TEST_EDGE + 2)
// The climate survey is deliberately wide: biome extent is set by the base
// climate wavelength, so a grid narrower than one province would report a
// healthy generator as degenerate.
TERRAIN_V2_CLIMATE_EDGE :: 256
TERRAIN_V2_CLIMATE_STEP :: f32(8)
TERRAIN_V2_CLIMATE_CELLS :: TERRAIN_V2_CLIMATE_EDGE * TERRAIN_V2_CLIMATE_EDGE
TERRAIN_V2_CLIMATE_HALF :: f32(TERRAIN_V2_CLIMATE_EDGE) * TERRAIN_V2_CLIMATE_STEP / 2
// Classification costs five height evaluations per sample for the centered
// slope, so the biome survey covers the same extent at a coarser step.
TERRAIN_V2_BIOME_EDGE :: 96
TERRAIN_V2_BIOME_STEP :: f32(20)
TERRAIN_V2_BIOME_CELLS :: TERRAIN_V2_BIOME_EDGE * TERRAIN_V2_BIOME_EDGE
TERRAIN_V2_BIOME_HALF :: f32(TERRAIN_V2_BIOME_EDGE) * TERRAIN_V2_BIOME_STEP / 2
TERRAIN_V2_DECILE_COUNT :: 10

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
	blend_a, ok_a := terrain_biome_blend_v2(&recipe, 4, 0.8, 0.7, 0.6, 0.1)
	blend_b, ok_b := terrain_biome_blend_v2(&recipe, 4, 0.8, 0.7, 0.6, 0.1)
	testing.expect(t, ok_a && ok_b)
	testing.expect_value(t, blend_a, blend_b)
	testing.expect(t, blend_a.primary_weight >= 0 && blend_a.primary_weight <= 1)
	recipe.biome_profiles[1].id = recipe.biome_profiles[0].id
	testing.expect(t, !terrain_recipe_validate_v2(&recipe))
}

// The fractal stack averages octaves, so raw climate occupies roughly the
// middle fifth of the unit range. Every dry and cold biome profile is then
// unreachable and every seed classifies the same way. This test is the oracle
// for that failure: it fails loudly if the contrast shaping is removed or if a
// retune quietly recompresses the distribution.
@(test)
terrain_v2_climate_spans_the_unit_range :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(2026)
	// A consumer sizes the latitude band to its world; matching it to the
	// surveyed extent keeps the north-south term from pinning at one end.
	recipe.latitude_half_extent = TERRAIN_V2_CLIMATE_HALF
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	moisture_deciles, temperature_deciles: [TERRAIN_V2_DECILE_COUNT]int
	sampled := 0
	for row in 0 ..< TERRAIN_V2_CLIMATE_EDGE {
		world_y := f32(row) * TERRAIN_V2_CLIMATE_STEP - TERRAIN_V2_CLIMATE_HALF
		for column in 0 ..< TERRAIN_V2_CLIMATE_EDGE {
			world_x := f32(column) * TERRAIN_V2_CLIMATE_STEP - TERRAIN_V2_CLIMATE_HALF
			height, continentalness, ruggedness, ok := terrain_height_prevalidated_v2(
				&recipe,
				world_x,
				world_y,
			)
			if !ok do continue
			moisture, temperature := _terrain_climate_v2(
				&recipe,
				world_x,
				world_y,
				height,
				continentalness,
				ruggedness,
			)
			moisture_deciles[_terrain_v2_decile(moisture)] += 1
			temperature_deciles[_terrain_v2_decile(temperature)] += 1
			sampled += 1
		}
	}
	testing.expect_value(t, sampled, TERRAIN_V2_CLIMATE_CELLS)
	_terrain_v2_expect_spread(t, moisture_deciles[:], "moisture")
	_terrain_v2_expect_spread(t, temperature_deciles[:], "temperature")
}

@(test)
terrain_v2_default_profiles_are_all_reachable :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(4242)
	recipe.latitude_half_extent = TERRAIN_V2_BIOME_HALF
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	counts: [TERRAIN_BIOME_PROFILE_MAX_V2]int
	sampled := _terrain_v2_survey_biomes(&recipe, counts[:])
	testing.expect_value(t, sampled, TERRAIN_V2_BIOME_CELLS)
	distinct_ids, dominant := 0, 0
	for count in counts {
		if count > 0 do distinct_ids += 1
		dominant = max(dominant, count)
	}
	testing.expectf(t, distinct_ids >= 5, "distinct biomes %d below 5", distinct_ids)
	// A generator that collapses onto one biome still passes a determinism
	// test, so cap the share any single profile may claim.
	share := f32(dominant) / f32(sampled)
	testing.expectf(t, share <= 0.55, "dominant biome share %f above 0.55", share)
}

@(test)
terrain_v2_seeds_classify_differently :: proc(t: ^testing.T) {
	recipe_a := terrain_default_recipe_v2(11)
	recipe_b := terrain_default_recipe_v2(12)
	recipe_a.latitude_half_extent = TERRAIN_V2_BIOME_HALF
	recipe_b.latitude_half_extent = TERRAIN_V2_BIOME_HALF
	testing.expect(t, terrain_recipe_validate_v2(&recipe_a))
	testing.expect(t, terrain_recipe_validate_v2(&recipe_b))
	differing, sampled := 0, 0
	for row in 0 ..< TERRAIN_V2_BIOME_EDGE {
		world_y := f32(row) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
		for column in 0 ..< TERRAIN_V2_BIOME_EDGE {
			world_x := f32(column) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
			a, ok_a := terrain_sample_prevalidated_v2(&recipe_a, world_x, world_y, 2)
			b, ok_b := terrain_sample_prevalidated_v2(&recipe_b, world_x, world_y, 2)
			if !ok_a || !ok_b do continue
			if a.biomes.primary_id != b.biomes.primary_id do differing += 1
			sampled += 1
		}
	}
	testing.expect_value(t, sampled, TERRAIN_V2_BIOME_CELLS)
	share := f32(differing) / f32(sampled)
	testing.expectf(t, share >= 0.3, "seed divergence %f below 0.3", share)
}

@(test)
terrain_v2_basins_reach_below_sea_level_inland :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(777)
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	flat := recipe
	flat.basin_depth = 0
	testing.expect(t, terrain_recipe_validate_v2(&flat))
	carved := 0
	for row in 0 ..< TERRAIN_V2_BIOME_EDGE {
		world_y := f32(row) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
		for column in 0 ..< TERRAIN_V2_BIOME_EDGE {
			world_x := f32(column) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
			basin, _, _, ok := terrain_height_prevalidated_v2(&recipe, world_x, world_y)
			plain, _, _, plain_ok := terrain_height_prevalidated_v2(&flat, world_x, world_y)
			if !ok || !plain_ok do continue
			// Land that a basin pulled under the waterline is what a
			// consumer's water fill turns into a lake.
			if plain > recipe.sea_level && basin <= recipe.sea_level do carved += 1
		}
	}
	testing.expectf(t, carved > 0, "no inland basin reached sea level")
}

@(test)
terrain_v2_rejects_contrast_below_identity :: proc(t: ^testing.T) {
	recipe := terrain_default_recipe_v2(5)
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	recipe.climate_contrast = 0.5
	testing.expect(t, !terrain_recipe_validate_v2(&recipe))
	recipe.climate_contrast = TERRAIN_CONTRAST_MIN_V2
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	recipe.continental_contrast = 0
	testing.expect(t, !terrain_recipe_validate_v2(&recipe))
	recipe.continental_contrast = TERRAIN_CONTRAST_MIN_V2
	testing.expect(t, terrain_recipe_validate_v2(&recipe))
	recipe.basin_depth = -1
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
	for index in 1 ..< len(fingerprints) {
		different = different || fingerprints[index] != fingerprints[0]
	}
	testing.expect(t, different)
}

@(private)
_terrain_v2_decile :: proc(value: f32) -> int {
	return clamp(int(value * TERRAIN_V2_DECILE_COUNT), 0, TERRAIN_V2_DECILE_COUNT - 1)
}

// _terrain_v2_expect_spread asserts a climate channel both reaches its
// extremes and fills most of the range between them. Reach alone would pass on
// a signal that is bimodal, and occupancy alone would pass on one that never
// leaves the middle.
@(private)
_terrain_v2_expect_spread :: proc(t: ^testing.T, deciles: []int, label: string) {
	assert(len(deciles) == TERRAIN_V2_DECILE_COUNT, "_terrain_v2_expect_spread: decile count")
	occupied := 0
	for count in deciles do if count > 0 do occupied += 1
	testing.expectf(t, deciles[0] > 0, "%s never reaches below 0.1", label)
	testing.expectf(
		t,
		deciles[TERRAIN_V2_DECILE_COUNT - 1] > 0,
		"%s never reaches above 0.9",
		label,
	)
	testing.expectf(t, occupied >= 7, "%s occupies only %d of 10 deciles", label, occupied)
}

@(private)
_terrain_v2_survey_biomes :: proc(recipe: ^Terrain_Recipe_V2, counts: []int) -> int {
	assert(recipe != nil, "_terrain_v2_survey_biomes: nil recipe")
	assert(len(counts) >= TERRAIN_BIOME_PROFILE_MAX_V2, "_terrain_v2_survey_biomes: counts size")
	sampled := 0
	for row in 0 ..< TERRAIN_V2_BIOME_EDGE {
		world_y := f32(row) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
		for column in 0 ..< TERRAIN_V2_BIOME_EDGE {
			world_x := f32(column) * TERRAIN_V2_BIOME_STEP - TERRAIN_V2_BIOME_HALF
			sample, ok := terrain_sample_prevalidated_v2(recipe, world_x, world_y, 2)
			if !ok do continue
			counts[int(sample.biomes.primary_id) % TERRAIN_BIOME_PROFILE_MAX_V2] += 1
			sampled += 1
		}
	}
	return sampled
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
