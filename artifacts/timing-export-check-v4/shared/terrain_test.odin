package shared

import "core:testing"
import "core:fmt"
import procgen "ingot:procgen"

_test_expect_slice_equal :: proc(t: ^testing.T, a, b: []$T) {
	testing.expect_value(t, len(a), len(b))
	for value, index in a do testing.expect_value(t, value, b[index])
}

_test_expect_foundation_equal :: proc(t: ^testing.T, a, b: ^Foundation_Field) {
	testing.expect_value(t, a.version, b.version)
	testing.expect_value(t, a.profile_id, b.profile_id)
	testing.expect_value(t, a.seed, b.seed)
	_test_expect_slice_equal(t, a.base_height, b.base_height)
	_test_expect_slice_equal(t, a.primary_biome, b.primary_biome)
	_test_expect_slice_equal(t, a.buildable, b.buildable)
}

_test_expect_planet_foundation_equal :: proc(t: ^testing.T, a, b: ^Planet_Foundation) {
	testing.expect_value(t, a.seed, b.seed)
	testing.expect_value(t, a.sea_level, b.sea_level)
	testing.expect_value(t, a.snow_level, b.snow_level)
	_test_expect_slice_equal(t, a.base_height, b.base_height)
	_test_expect_slice_equal(t, a.moisture, b.moisture)
	_test_expect_slice_equal(t, a.temperature, b.temperature)
	_test_expect_slice_equal(t, a.continentalness, b.continentalness)
	_test_expect_slice_equal(t, a.ruggedness, b.ruggedness)
	_test_expect_slice_equal(t, a.slope, b.slope)
	_test_expect_slice_equal(t, a.primary_biome, b.primary_biome)
	_test_expect_slice_equal(t, a.secondary_biome, b.secondary_biome)
	_test_expect_slice_equal(t, a.primary_weight, b.primary_weight)
	_test_expect_slice_equal(t, a.river_strength, b.river_strength)
	_test_expect_slice_equal(t, a.chasm_strength, b.chasm_strength)
	_test_expect_slice_equal(t, a.buildable, b.buildable)
}

@(test)
runtime_surface_snow_depends_on_temperature_elevation_and_storage :: proc(t: ^testing.T) {
	warm_low := terrain_surface_snow_cover(0, 10, 290 * PLANET_TEMPERATURE_SCALE, 0)
	cold_high := terrain_surface_snow_cover(12, 10, 265 * PLANET_TEMPERATURE_SCALE, 0)
	stored := terrain_surface_snow_cover(0, 10, 280 * PLANET_TEMPERATURE_SCALE, 500_000)
	testing.expect_value(t, warm_low, f32(0))
	testing.expect(t, cold_high >= 0.5)
	testing.expect(t, stored >= 0.5)
}

@(test)
terrain_environmental_lapse_is_six_point_five_kelvin_per_kilometre :: proc(t: ^testing.T) {
	sea_level := f32(25)
	sea_lapse := i32(max(sea_level - sea_level, f32(0)) * TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M)
	below_lapse := i32(max(f32(10) - sea_level, f32(0)) * TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M)
	kilometre_lapse := i32(max(f32(1025) - sea_level, f32(0)) * TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M)
	testing.expect_value(t, sea_lapse, i32(0))
	testing.expect_value(t, below_lapse, i32(0))
	testing.expect_value(t, kilometre_lapse, i32(6500))
}

TERRAIN_SOURCE_SURVEY_EDGE :: 192
TERRAIN_SOURCE_SURVEY_CELLS :: TERRAIN_SOURCE_SURVEY_EDGE * TERRAIN_SOURCE_SURVEY_EDGE
TERRAIN_SOURCE_SURVEY_STEP :: WORLD_SIZE / f32(TERRAIN_SOURCE_SURVEY_EDGE)
TERRAIN_SOURCE_SURVEY_MINIMUM :: TERRAIN_BIOME_MINIMUM_CELLS / 100

Terrain_Source_Survey :: struct {
	land_cells:               int,
	meaningful_land_biomes:   int,
	area_weighted_component:  f32,
	tiny_component_share:     f32,
	mean_run:                 f32,
	resolver_reassigned_share: f32,
}

@(private)
_terrain_test_archetype_seeds :: proc() -> [Terrain_Archetype]u64 {
	seeds: [Terrain_Archetype]u64
	seen: [Terrain_Archetype]bool
	found := 0
	for seed in u64(0) ..< 512 {
		archetype := terrain_archetype(seed)
		if seen[archetype] do continue
		seen[archetype] = true
		seeds[archetype] = seed
		found += 1
		if found == len(Terrain_Archetype) do break
	}
	assert(found == len(Terrain_Archetype), "terrain test archetype seed coverage")
	return seeds
}

@(private)
_terrain_source_survey :: proc(seed: u64) -> (Terrain_Source_Survey, bool) {
	recipe, recipe_ok := terrain_resolved_recipe(seed)
	if !recipe_ok do return {}, false
	raw := make([]procgen.Terrain_Biome_Blend_V2, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(raw)
	half := WORLD_SIZE / 2
	for row in 0 ..< TERRAIN_SOURCE_SURVEY_EDGE {
		world_y := (f32(row) + 0.5) * TERRAIN_SOURCE_SURVEY_STEP - half
		for column in 0 ..< TERRAIN_SOURCE_SURVEY_EDGE {
			world_x := (f32(column) + 0.5) * TERRAIN_SOURCE_SURVEY_STEP - half
			sample, ok := procgen.terrain_primary_surface_prevalidated_v3(
				&recipe,
				world_x,
				world_y,
				GRID_CELL_SIZE,
			)
			if !ok do return {}, false
			raw[row * TERRAIN_SOURCE_SURVEY_EDGE + column] = sample.biomes
		}
	}

	labels := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(labels)
	queue := make([]int, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(queue)
	component_sizes := make([]int, TERRAIN_SOURCE_SURVEY_CELLS + 1)
	defer delete(component_sizes)
	land_counts: [Biome_Id]int
	land_cells, components := 0, 0
	for origin in 0 ..< TERRAIN_SOURCE_SURVEY_CELLS {
		biome := Biome_Id(raw[origin].primary_id)
		if _terrain_biome_is_water(biome) do continue
		land_counts[biome] += 1
		land_cells += 1
		if labels[origin] != 0 do continue
		components += 1
		label := u32(components)
		labels[origin] = label
		head, tail := 0, 1
		queue[0] = origin
		for head < tail {
			index := queue[head]
			head += 1
			x, y := index % TERRAIN_SOURCE_SURVEY_EDGE, index / TERRAIN_SOURCE_SURVEY_EDGE
			neighbors := [?][2]int{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}
			for offset in neighbors {
				next_x, next_y := x + offset[0], y + offset[1]
				if next_x < 0 || next_x >= TERRAIN_SOURCE_SURVEY_EDGE ||
				   next_y < 0 || next_y >= TERRAIN_SOURCE_SURVEY_EDGE {
					continue
				}
				next := next_y * TERRAIN_SOURCE_SURVEY_EDGE + next_x
				if labels[next] != 0 || raw[next].primary_id != raw[origin].primary_id do continue
				labels[next] = label
				queue[tail] = next
				tail += 1
			}
		}
		component_sizes[components] = tail
	}
	if land_cells == 0 do return {}, false
	meaningful := 0
	for count in land_counts do if count >= TERRAIN_SOURCE_SURVEY_MINIMUM do meaningful += 1
	weighted, tiny := 0, 0
	for component in 1 ..= components {
		size := component_sizes[component]
		weighted += size * size
		if size < TERRAIN_SOURCE_SURVEY_MINIMUM do tiny += size
	}
	crossings := 0
	for row in 0 ..< TERRAIN_SOURCE_SURVEY_EDGE {
		previous := raw[row * TERRAIN_SOURCE_SURVEY_EDGE].primary_id
		for column in 1 ..< TERRAIN_SOURCE_SURVEY_EDGE {
			biome := raw[row * TERRAIN_SOURCE_SURVEY_EDGE + column].primary_id
			if biome != previous do crossings += 1
			previous = biome
		}
	}

	resolved := make([]procgen.Terrain_Biome_Blend_V2, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(resolved)
	patches := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(patches)
	region_labels := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(region_labels)
	region_queue := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(region_queue)
	region_sizes := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(region_sizes)
	region_ids := make([]u16, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(region_ids)
	merge_targets := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(merge_targets)
	component_offsets := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS + 1)
	defer delete(component_offsets)
	component_cells := make([]u32, TERRAIN_SOURCE_SURVEY_CELLS)
	defer delete(component_cells)
	protected := [?]u16{u16(Biome_Id.Ocean), u16(Biome_Id.Lake), u16(Biome_Id.Coast)}
	request := procgen.Terrain_Biome_Region_Request {
		TERRAIN_SOURCE_SURVEY_EDGE,
		TERRAIN_SOURCE_SURVEY_EDGE,
		TERRAIN_SOURCE_SURVEY_MINIMUM,
		protected[:],
	}
	output := procgen.Terrain_Biome_Region_Output{resolved, patches}
	scratch := procgen.Terrain_Biome_Region_Scratch {
		region_labels,
		region_queue,
		region_sizes,
		region_ids,
		merge_targets,
		component_offsets,
		component_cells,
	}
	if !procgen.terrain_resolve_biome_regions(&recipe.surface, request, raw, output, scratch) {
		return {}, false
	}
	reassigned := 0
	for biome, index in raw {
		if _terrain_biome_is_water(Biome_Id(biome.primary_id)) do continue
		if resolved[index].primary_id != biome.primary_id do reassigned += 1
	}
	return {
		land_cells = land_cells,
		meaningful_land_biomes = meaningful,
		area_weighted_component = f32(weighted) / f32(land_cells),
		tiny_component_share = f32(tiny) / f32(land_cells),
		mean_run = WORLD_SIZE * f32(TERRAIN_SOURCE_SURVEY_EDGE) /
			f32(crossings + TERRAIN_SOURCE_SURVEY_EDGE),
		resolver_reassigned_share = f32(reassigned) / f32(land_cells),
	}, true
}

@(test)
terrain_source_biomes_are_province_scale_before_resolution :: proc(t: ^testing.T) {
	seeds := _terrain_test_archetype_seeds()
	for seed, archetype in seeds {
		survey, ok := _terrain_source_survey(seed)
		testing.expectf(t, ok, "%v source survey failed", archetype)
		testing.expectf(
			t,
			survey.meaningful_land_biomes >= 2,
			"%v has only %d meaningful source land biomes",
			archetype,
			survey.meaningful_land_biomes,
		)
		testing.expectf(
			t,
			survey.area_weighted_component >= f32(TERRAIN_SOURCE_SURVEY_MINIMUM),
			"%v area-weighted source component %f below %d",
			archetype,
			survey.area_weighted_component,
			TERRAIN_SOURCE_SURVEY_MINIMUM,
		)
		testing.expectf(
			t,
			survey.tiny_component_share <= 0.45,
			"%v tiny source components cover %f of land",
			archetype,
			survey.tiny_component_share,
		)
		testing.expectf(t, survey.mean_run >= 80, "%v source mean run is only %f", archetype, survey.mean_run)
		testing.expectf(
			t,
			survey.resolver_reassigned_share <= 0.4,
			"%v resolver reassigns %f of source land",
			archetype,
			survey.resolver_reassigned_share,
		)
	}
}

@(test)
terrain_foundation_is_seed_deterministic :: proc(t: ^testing.T) {
	field_a, field_b: Foundation_Field
	foundation_init(&field_a)
	defer foundation_deinit(&field_a)
	foundation_init(&field_b)
	defer foundation_deinit(&field_b)
	testing.expect(t, foundation_generate(&field_a, 12345))
	testing.expect(t, foundation_generate(&field_b, 12345))
	_test_expect_foundation_equal(t, &field_a, &field_b)
}

@(test)
terrain_foundation_biomes_are_hard_connected_patches :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	testing.expect(t, foundation_generate(&field, 12345))
	patch_count := u32(0)
	for biome, index in field.primary_biome {
		testing.expect_value(t, field.secondary_biome[index], biome)
		testing.expect_value(t, field.primary_weight[index], u8(255))
		testing.expect(t, field.biome_patch_id[index] > 0)
		patch_count = max(patch_count, field.biome_patch_id[index])
	}
	testing.expect(t, patch_count > 0)
}

// Spawn is no longer "seed % 12 selects the centre biome". That rule selected
// hard on one narrow condition while leaving every other property of the world
// identical, which homogenised worlds rather than diversifying them. What must
// hold now is weaker and more useful: the centre is a biome this kind of world
// can plausibly start a player in.
@(test)
terrain_seed_center_is_a_spawn_biome :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	center := _terrain_index(i32(HEIGHTFIELD_RESOLUTION / 2), i32(HEIGHTFIELD_RESOLUTION / 2))
	for seed in 0 ..< 16 {
		allowed := terrain_archetype_spawn_biomes(terrain_archetype(u64(seed)))
		field: Foundation_Field
		foundation_init(&field)
		defer foundation_deinit(&field)
		testing.expect(t, foundation_generate(&field, u64(seed)))
		testing.expect_value(t, field.seed, u64(seed))
		spawn := field.primary_biome[center]
		testing.expectf(
			t,
			spawn in allowed,
			"seed %d spawned in %v, outside the %v roster for %v",
			seed,
			spawn,
			allowed,
			terrain_archetype(u64(seed)),
		)
		recipe, recipe_ok := terrain_resolved_recipe(u64(seed))
		testing.expect(t, recipe_ok)
		sample, sample_ok := procgen.terrain_primary_surface_v3(&recipe, 0, 0, GRID_CELL_SIZE)
		testing.expect(t, sample_ok)
		testing.expect_value(t, field.base_height[center], height_to_fixed(sample.height))
		testing.expect_value(t, field.moisture[center], _terrain_unit_to_u8(sample.moisture))
		testing.expect_value(t, field.temperature[center], _terrain_unit_to_u8(sample.temperature))
	}
}

@(test)
terrain_seed_resolution_is_bounded_and_deterministic :: proc(t: ^testing.T) {
	for seed in 0 ..< 256 {
		resolved_a, ok_a := terrain_resolved_seed(u64(seed))
		resolved_b, ok_b := terrain_resolved_seed(u64(seed))
		testing.expectf(t, ok_a && ok_b, "seed %d found no spawn within the search limit", seed)
		testing.expect_value(t, resolved_a, resolved_b)
		archetype := terrain_archetype(u64(seed))
		recipe := terrain_recipe_for(archetype, resolved_a)
		sample, sample_ok := procgen.terrain_primary_surface_v3(&recipe, 0, 0, GRID_CELL_SIZE)
		testing.expect(t, sample_ok)
		allowed := terrain_archetype_spawn_biomes(archetype)
		testing.expect(t, Biome_Id(sample.biomes.primary_id) in allowed)
	}
}

// The archetype must survive the spawn search. If rejecting a candidate could
// change what kind of world the seed asked for, the search would quietly steer
// every seed toward whichever archetypes spawn most easily -- which is the
// homogenising failure it exists to avoid.
@(test)
terrain_seed_resolution_preserves_the_archetype :: proc(t: ^testing.T) {
	seen: [Terrain_Archetype]int
	for seed in 0 ..< 128 {
		archetype := terrain_archetype(u64(seed))
		testing.expect_value(t, terrain_archetype(u64(seed)), archetype)
		resolved, ok := terrain_resolved_seed(u64(seed))
		testing.expect(t, ok)
		recipe, recipe_ok := terrain_resolved_recipe(u64(seed))
		testing.expect(t, recipe_ok)
		expected := terrain_recipe_for(archetype, resolved)
		testing.expect_value(t, recipe.surface.coast_threshold, expected.surface.coast_threshold)
		testing.expect_value(t, recipe.surface.moisture_bias, expected.surface.moisture_bias)
		testing.expect_value(t, recipe.surface.temperature_bias, expected.surface.temperature_bias)
		seen[archetype] += 1
	}
	for count, archetype in seen {
		testing.expectf(
			t,
			count > 0,
			"archetype %v unreachable from the first 128 seeds",
			archetype,
		)
	}
}

@(test)
terrain_foundation_seed_changes_layout_and_covers_profiles :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field_a, field_b: Foundation_Field
	foundation_init(&field_a)
	defer foundation_deinit(&field_a)
	foundation_init(&field_b)
	defer foundation_deinit(&field_b)
	testing.expect(t, foundation_generate(&field_a, 1))
	testing.expect(t, foundation_generate(&field_b, 2))
	different := false
	seen: [Biome_Id]bool
	for height, index in field_a.base_height {
		different = different || height != field_b.base_height[index]
		seen[field_a.primary_biome[index]] = true
	}
	biome_count := 0
	for present in seen do if present do biome_count += 1
	testing.expect(t, different)
	// A province-scale world genuinely holds fewer biomes than a mottled one:
	// the merge pass now erases anything below a 350-unit patch, so a count
	// that used to be inflated by slivers is not the metric it once was. Four
	// is still what a generator that only knows grass and ocean would score.
	testing.expectf(t, biome_count >= 4, "seed 1 covers only %d biomes", biome_count)
}

// The roster only earns its size if the worlds actually use it -- but that is
// a claim about the archetype table, not about any single world. A
// province-scale world holds five to ten biomes, because the merge pass erases
// everything below a 350-unit patch; demanding the full roster from one world
// would be demanding the mottle back.
//
// Dominance is measured over land rather than the whole world on purpose. An
// ocean-heavy seed is a legitimate archipelago, not a defect, so capping the
// ocean share would reject exactly the seed-to-seed variety this work adds.
// The cap is per-archetype because a Dust_Bowl legitimately has a dominant
// land biome -- that is what makes it a dust bowl -- while a balanced world
// that collapses onto one biome is the failure being guarded against.
@(test)
terrain_foundation_covers_the_roster_without_a_dominant_biome :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	// A seed per archetype, so the extreme profiles are exercised under
	// their own cap rather than excused by a single balanced sample.
	seeds: [Terrain_Archetype]u64
	found := 0
	for seed in u64(0) ..< 512 {
		archetype := terrain_archetype(seed)
		if seeds[archetype] != 0 do continue
		seeds[archetype] = seed
		found += 1
		if found == len(Terrain_Archetype) do break
	}
	testing.expect_value(t, found, len(Terrain_Archetype))
	across: [Biome_Id]bool
	for seed, archetype in seeds {
		testing.expect(t, foundation_generate(&field, seed))
		counts: [Biome_Id]int
		for biome in field.primary_biome do counts[biome] += 1
		present, land_max, land_total := 0, 0, 0
		for count, biome in counts {
			if count > 0 {
				present += 1
				across[biome] = true
			}
			if _terrain_biome_is_water(biome) do continue
			land_total += count
			land_max = max(land_max, count)
		}
		testing.expectf(t, present >= 5, "%v covers only %d of 12 biomes", archetype, present)
		testing.expect(t, land_total > 0)
		share := f32(land_max) / f32(land_total)
		limit := _terrain_dominance_limit(archetype)
		testing.expectf(
			t,
			share <= limit,
			"%v dominant land biome share %f above %f",
			archetype,
			share,
			limit,
		)
	}
	union_count := 0
	for present in across do if present do union_count += 1
	testing.expectf(
		t,
		union_count >= 10,
		"the archetype roster only ever produces %d of 12 biomes",
		union_count,
	)
}

// The extreme archetypes exist to be extreme: a desert world whose desert is
// capped at the same share as a temperate world's grassland is not a desert
// world. What no archetype may do is classify everything as one thing.
@(private)
_terrain_dominance_limit :: proc(archetype: Terrain_Archetype) -> f32 {
	#partial switch archetype {
	case .Dust_Bowl, .Boreal, .Rainforest_Belt:
		return 0.85
	}
	return 0.65
}

@(test)
terrain_archetype_is_seed_deterministic_and_covers_the_roster :: proc(t: ^testing.T) {
	seen: [Terrain_Archetype]int
	for seed in 0 ..< 128 {
		first := terrain_archetype(u64(seed))
		testing.expect_value(t, terrain_archetype(u64(seed)), first)
		seen[first] += 1
	}
	for count, archetype in seen {
		testing.expectf(
			t,
			count > 0,
			"archetype %v unreachable from the first 128 seeds",
			archetype,
		)
	}
	// A hash, not seed % 8: consecutive seeds are how a player actually
	// explores the space, and walking the roster in order makes the
	// selection feel like a menu rather than a world.
	ordered := 0
	for seed in 0 ..< 32 {
		expected := Terrain_Archetype(u64(seed) % u64(len(Terrain_Archetype)))
		if terrain_archetype(u64(seed)) == expected do ordered += 1
	}
	testing.expectf(t, ordered < 24, "archetype selection follows seed order in %d of 32", ordered)
}

@(test)
terrain_archetype_macro_noise_stays_at_province_scale :: proc(t: ^testing.T) {
	layout_seeds := [?]u64{1, 17, 31337}
	for archetype in Terrain_Archetype {
		profile := terrain_archetype_profile(archetype)
		for layout_seed in layout_seeds {
			recipe := terrain_surface_recipe_for(archetype, layout_seed)
			testing.expect_value(
				t,
				recipe.continental_noise.octaves,
				TERRAIN_ARCHETYPE_CONTINENTAL_OCTAVES,
			)
			testing.expect_value(t, recipe.moisture_noise.octaves, TERRAIN_ARCHETYPE_CLIMATE_OCTAVES)
			testing.expect_value(t, recipe.temperature_noise.octaves, TERRAIN_ARCHETYPE_CLIMATE_OCTAVES)
			testing.expect_value(t, recipe.continental_noise.gain, TERRAIN_ARCHETYPE_MACRO_GAIN)
			testing.expect_value(t, recipe.moisture_noise.gain, TERRAIN_ARCHETYPE_MACRO_GAIN)
			testing.expect_value(t, recipe.temperature_noise.gain, TERRAIN_ARCHETYPE_MACRO_GAIN)
			testing.expectf(t, TERRAIN_ARCHETYPE_MACRO_GAIN < 0.5, "macro gain no longer damps octave two")
			continental := 1 / recipe.continental_noise.frequency
			moisture := 1 / recipe.moisture_noise.frequency
			temperature := 1 / recipe.temperature_noise.frequency
			testing.expectf(
				t,
				continental >= profile.continental_wavelength *
					(1 - TERRAIN_ARCHETYPE_WAVELENGTH_JITTER),
				"%v continental wavelength %f below authored range",
				archetype,
				continental,
			)
			testing.expectf(
				t,
				continental <= profile.continental_wavelength *
					(1 + TERRAIN_ARCHETYPE_WAVELENGTH_JITTER),
				"%v continental wavelength %f above authored range",
				archetype,
				continental,
			)
			testing.expectf(
				t,
				moisture >= profile.climate_wavelength * (1 - TERRAIN_ARCHETYPE_WAVELENGTH_JITTER),
				"%v moisture wavelength %f below authored range",
				archetype,
				moisture,
			)
			testing.expectf(
				t,
				moisture <= profile.climate_wavelength * (1 + TERRAIN_ARCHETYPE_WAVELENGTH_JITTER),
				"%v moisture wavelength %f above authored range",
				archetype,
				moisture,
			)
			testing.expectf(t, temperature > moisture, "%v temperature provinces are not broader", archetype)
			testing.expectf(
				t,
				abs(temperature / moisture - TERRAIN_ARCHETYPE_TEMPERATURE_STRETCH) < 0.0001,
				"%v temperature stretch is %f",
				archetype,
				temperature / moisture,
			)
		}
	}
}

// The direct oracle for "biomes feel minimal". A patch smaller than a
// settlement is visual noise; what the player should meet is a province they
// can spend time inside.
@(test)
terrain_foundation_biome_patches_are_province_scale :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	seeds := _terrain_test_archetype_seeds()
	for seed, archetype in seeds {
		testing.expect(t, foundation_generate(&field, seed))
		sizes := make([]int, TERRAIN_FIELD_CELLS + 1)
		land_total := 0
		for patch, index in field.biome_patch_id {
			if _terrain_biome_is_water(field.primary_biome[index]) do continue
			sizes[patch] += 1
			land_total += 1
		}
		testing.expectf(t, land_total > 0, "%v has no land", archetype)
		// Area-weighted, not a plain mean over patches: an average over patches
		// is dominated by whatever slivers survive, while what the player
		// experiences is the size of the patch they are standing in.
		weighted, largest := 0, 0
		for size in sizes {
			if size == 0 do continue
			weighted += size * size
			largest = max(largest, size)
		}
		mean := f32(weighted) / f32(land_total)
		testing.expectf(
			t,
			mean >= f32(TERRAIN_BIOME_MINIMUM_CELLS),
			"%v area-weighted mean land patch %f below the %d province minimum",
			archetype,
			mean,
			TERRAIN_BIOME_MINIMUM_CELLS,
		)
		share := f32(largest) / f32(land_total)
		testing.expectf(t, share >= 0.08, "%v largest land patch covers only %f", archetype, share)
		delete(sizes)
	}
}

// The direct oracle for "every seed looks the same". Before the archetype
// layer the recipe was entirely compile-time constants, so land fraction and
// climate centre were identical for every seed however different the noise.
@(test)
terrain_foundation_seeds_differ_in_land_share_and_climate :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	seeds := [?]u64{1, 2, 3, 5, 8, 13, 21, 34}
	land_min, land_max := f32(1), f32(0)
	temperature_min, temperature_max := f32(1), f32(0)
	dominant: [len(seeds)]Biome_Id
	for seed, slot in seeds {
		testing.expect(t, foundation_generate(&field, seed))
		counts: [Biome_Id]int
		temperature_total := 0
		for biome, index in field.primary_biome {
			counts[biome] += 1
			temperature_total += int(field.temperature[index])
		}
		land, best := 0, 0
		dominant[slot] = .Grassland
		for count, biome in counts {
			if _terrain_biome_is_water(biome) do continue
			land += count
			if count <= best do continue
			best = count
			dominant[slot] = biome
		}
		land_share := f32(land) / f32(TERRAIN_FIELD_CELLS)
		land_min = min(land_min, land_share)
		land_max = max(land_max, land_share)
		temperature := f32(temperature_total) / f32(TERRAIN_FIELD_CELLS) / 255
		temperature_min = min(temperature_min, temperature)
		temperature_max = max(temperature_max, temperature)
	}
	testing.expectf(
		t,
		land_max - land_min >= 0.25,
		"land share spread %f (%f..%f) below 0.25",
		land_max - land_min,
		land_min,
		land_max,
	)
	testing.expectf(
		t,
		temperature_max - temperature_min >= 0.15,
		"mean temperature spread %f (%f..%f) below 0.15",
		temperature_max - temperature_min,
		temperature_min,
		temperature_max,
	)
	distinct_dominant: [Biome_Id]bool
	for biome in dominant do distinct_dominant[biome] = true
	kinds := 0
	for present in distinct_dominant do if present do kinds += 1
	testing.expectf(t, kinds >= 3, "only %d distinct dominant land biomes across 8 seeds", kinds)
}

// The terraforger-side pin on the landform split, expressed as the thing the
// player actually experiences: how far you walk between biome changes.
//
// The mean over scanlines is the honest statistic. A single worst row is
// dominated by whichever line happens to graze an island chain or a lake
// shore, both of which are legitimately busy; before the split it was the
// typical row that flipped dozens of times, inside one climate zone, purely
// because hill noise moved the height and slope the classifier read.
@(test)
terrain_foundation_hill_noise_does_not_relabel_ground :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	seeds := _terrain_test_archetype_seeds()
	for seed, archetype in seeds {
		testing.expect(t, foundation_generate(&field, seed))
		crossings, rows := 0, 0
		for row := i32(0); row < HEIGHTFIELD_RESOLUTION; row += 64 {
			previous := field.primary_biome[_terrain_index(0, row)]
			for column in i32(1) ..< i32(HEIGHTFIELD_RESOLUTION) {
				biome := field.primary_biome[_terrain_index(column, row)]
				if biome != previous do crossings += 1
				previous = biome
			}
			rows += 1
		}
		testing.expect(t, rows > 0)
		run := WORLD_SIZE * f32(rows) / f32(crossings + rows)
		testing.expectf(
			t,
			run >= 150,
			"%v mean run between biome changes is %f units, below a walkable 150",
			archetype,
			run,
		)
	}
}

@(private)
_terrain_biome_is_water :: proc(biome: Biome_Id) -> bool {
	return biome == .Ocean || biome == .Lake || biome == .Coast
}

// A lake is an inland cell below sea level whose four neighbours are all below
// it too -- a genuine enclosed depression rather than a stretch of open coast.
@(test)
terrain_foundation_carves_enclosed_inland_basins :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	testing.expect(t, foundation_generate(&field, 2026))
	enclosed := 0
	for row in i32(1) ..< i32(HEIGHTFIELD_RESOLUTION - 1) {
		for column in i32(1) ..< i32(HEIGHTFIELD_RESOLUTION - 1) {
			index := _terrain_index(column, row)
			if field.primary_biome[index] != .Lake do continue
			if field.base_height[index] > field.sea_level do continue
			neighbors := [?]i16 {
				field.base_height[_terrain_index(column - 1, row)],
				field.base_height[_terrain_index(column + 1, row)],
				field.base_height[_terrain_index(column, row - 1)],
				field.base_height[_terrain_index(column, row + 1)],
			}
			rim := 0
			for neighbor in neighbors do if neighbor > field.sea_level do rim += 1
			if rim > 0 do enclosed += 1
		}
	}
	testing.expectf(t, enclosed > 0, "no lake cell borders land above sea level")
}

@(test)
terrain_foundation_uses_abstract_v3_profile :: proc(t: ^testing.T) {
	when !BENCH_ENABLED do return
	field: Foundation_Field
	foundation_init(&field)
	defer foundation_deinit(&field)
	testing.expect(t, foundation_generate(&field, 99))
	testing.expect_value(t, field.version, procgen.TERRAIN_RECIPE_VERSION_V3)
	testing.expect_value(t, field.profile_id, TERRAIN_PROFILE_ID)
	buildable_count := 0
	for buildable in field.buildable do if buildable do buildable_count += 1
	testing.expect(t, buildable_count > TERRAIN_FIELD_CELLS / 8)
}

@(test)
terrain_abstract_profile_uses_compact_islands_and_strong_mountains :: proc(t: ^testing.T) {
	// Relief is archetype-derived now, so the assertion is on the bounds the
	// table can produce rather than on one constant. What must hold for every
	// archetype is that peaks are tall enough to read as mountains and short
	// enough to clear the volume ceiling.
	for archetype in Terrain_Archetype {
		recipe := terrain_recipe_for(archetype, TERRAIN_SEED)
		testing.expect(t, procgen.terrain_recipe_validate_v3(&recipe))
		surface := recipe.surface
		testing.expectf(
			t,
			surface.mountain_height >= 18 &&
			surface.mountain_height <= TERRAIN_ARCHETYPE_MOUNTAIN_HEIGHT_MAX,
			"%v mountain height %f outside the authored band",
			archetype,
			surface.mountain_height,
		)
		// The shaped peak must clear the volume ceiling with room to spare, or
		// summits become flat-topped mesas.
		relief := surface.base_height + surface.land_height + surface.mountain_height
		shaped := relief + surface.mountain_height * (TERRAIN_MOUNTAIN_SCALE - 1)
		testing.expectf(
			t,
			shaped <= recipe.parameters.maximum_z - 4,
			"%v shaped peak %f clips the %f volume ceiling",
			archetype,
			shaped,
			recipe.parameters.maximum_z,
		)
		testing.expect(t, surface.mountain_fade > 0 && surface.mountain_fade <= 0.2)
		testing.expect(t, surface.ridge_power >= 1.5 && surface.ridge_power <= 2.5)
	}
	recipe := terrain_recipe(TERRAIN_SEED)
	testing.expect_value(t, recipe.parameters.mountain_scale, TERRAIN_MOUNTAIN_SCALE)
	testing.expect_value(t, recipe.parameters.mountain_sharpness, TERRAIN_MOUNTAIN_SHARPNESS)
	testing.expect_value(t, recipe.parameters.mountain_terrace_strength, f32(0))
	testing.expect_value(t, recipe.parameters.floating_spacing, TERRAIN_FLOATING_SPACING)
	testing.expect_value(t, recipe.parameters.floating_radius, TERRAIN_FLOATING_RADIUS)
	testing.expect_value(t, recipe.parameters.floating_thickness, TERRAIN_FLOATING_THICKNESS)
	testing.expect_value(t, recipe.parameters.floating_breakup, TERRAIN_FLOATING_BREAKUP)
	testing.expect(t, recipe.parameters.floating_radius * 10 < TERRAIN_FLOATING_SPACING)
	testing.expect(t, recipe.parameters.floating_radius <= 8)
}

@(test)
terrain_runtime_seed_has_visible_mountain_relief :: proc(t: ^testing.T) {
	recipe := terrain_recipe(TERRAIN_SEED)
	minimum_height, maximum_height := f32(10000), f32(-10000)
	mountain_count, buildable_count := 0, 0
	// The scan covers half the world per axis rather than a 256-unit patch.
	// Terrain features are province-scale, so a window narrower than one
	// province can legitimately be flat and would make this a coin flip on
	// where the seed happens to put its ranges. The sample count is
	// unchanged; only the spacing grew to match the feature size.
	step := f32(20)
	for y in -32 ..= 32 {
		for x in -32 ..= 32 {
			sample, ok := procgen.terrain_primary_surface_v3(
				&recipe,
				f32(x) * step,
				f32(y) * step,
				4,
			)
			testing.expect(t, ok)
			minimum_height = min(minimum_height, sample.height)
			maximum_height = max(maximum_height, sample.height)
			if sample.height >= 24 do mountain_count += 1
			if sample.buildable do buildable_count += 1
		}
	}
	testing.expect(t, maximum_height >= 36)
	testing.expect(t, maximum_height <= recipe.parameters.maximum_z - 4)
	testing.expect(t, maximum_height - minimum_height >= 32)
	testing.expect(t, mountain_count >= 8)
	testing.expect(t, buildable_count > 64 * 64 / 8)
}

@(test)
terrain_runtime_seed_floating_mass_width_is_bounded :: proc(t: ^testing.T) {
	recipe := terrain_recipe(TERRAIN_SEED)
	ground_recipe := recipe
	ground_recipe.parameters.floating_strength = 0
	added_samples, longest_run := 0, 0
	for z in 24 ..= 56 {
		if z % 4 != 0 do continue
		for y in -16 ..= 16 {
			run := 0
			for x in -32 ..= 32 {
				world_x, world_y := f32(x * 4), f32(y * 8)
				density, ok := procgen.terrain_density_v3(&recipe, world_x, world_y, f32(z))
				ground, ground_ok := procgen.terrain_density_v3(
					&ground_recipe,
					world_x,
					world_y,
					f32(z),
				)
				testing.expect(t, ok && ground_ok)
				if density > 0 && ground <= 0 {
					run += 1
					added_samples += 1
					longest_run = max(longest_run, run)
				} else {
					run = 0
				}
			}
		}
	}
	testing.expect(t, added_samples > 0)
	testing.expect(t, longest_run * 4 <= 36)
}

@(test)
terrain_normal_v3_profile_matches_v2_surface :: proc(t: ^testing.T) {
	recipe := procgen.terrain_normal_recipe_v3(42)
	v2, ok_v2 := procgen.terrain_sample_v2(&recipe.surface, 17, -23, GRID_CELL_SIZE)
	v3, ok_v3 := procgen.terrain_primary_surface_v3(&recipe, 17, -23, GRID_CELL_SIZE)
	testing.expect(t, ok_v2 && ok_v3)
	testing.expect_value(t, v3.height, v2.height)
}

@(test)
terrain_sample_interpolates_quantized_foundation :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	coord := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	sample := terrain_sample_at_coord(&world, coord)
	index := planet_index(coord)
	expected := f32(world.foundation.base_height[index]) / f32(HEIGHT_DELTA_SCALE)
	testing.expect_value(t, sample.height, expected)
	testing.expect(t, sample.moisture >= 0 && sample.moisture <= 1)
	testing.expect(t, sample.primary_weight >= 0 && sample.primary_weight <= 1)
}

@(test)
planet_foundation_preserves_authored_relief :: proc(t: ^testing.T) {
	field: Planet_Foundation
	planet_foundation_init(&field)
	defer planet_foundation_deinit(&field)
	seeds := [3]u64{TERRAIN_SEED, 1, 12345}
	for seed in seeds {
		recipe := planet_terrain_recipe(seed)
		lithosphere_generate(&field.lithosphere, seed)
		categories: [3]int
		regression_differences := 0
		for face in procgen.Terrain_Face_V4 {
			for row in 0 ..= 16 {
				for column in 0 ..= 16 {
					coord := Planet_Coord{face, i32(column * PLANET_FACE_CELLS / 16), i32(row * PLANET_FACE_CELLS / 16)}
					index := planet_index(coord)
					radial := planet_direction(coord)
					sample, ok := procgen.terrain_primary_surface_v4(&recipe, radial)
					testing.expect(t, ok)
					fraction := tectonic_genesis_continents(&field.lithosphere, radial)
					category := 1
					if fraction == 0 do category = 0
					if fraction == 1 do category = 2
					categories[category] += 1
					lithosphere := lithosphere_sample(&field.lithosphere, radial)
					physical := tectonic_isostatic_height(f64(fraction), f64(7_000 + fraction * 31_000), f64(tectonic_genesis_ocean_age(lithosphere)) * 1_000, 0)
					offset := f32(physical / 250) + lithosphere.tectonic_relief
					job := Planet_Foundation_Job{field = &field, recipe = &recipe, lithosphere = &field.lithosphere, start = index, end = index + 1}
					_planet_foundation_range(&job)
					testing.expect(t, job.ok)
					testing.expect_value(t, field.base_height[index], height_to_fixed(sample.height + offset))
					testing.expect_value(t, field.landform_height[index], height_to_fixed(sample.landform + offset))
					previous := field.base_height[index]
					_planet_foundation_range(&job)
					testing.expect_value(t, field.base_height[index], previous)
					if previous != height_to_fixed(sample.height * (0.08 + fraction * 0.17) + offset) do regression_differences += 1
				}
			}
		}
		for count in categories do testing.expect(t, count > 0)
		testing.expect(t, regression_differences > 100)
	}
}

@(test)
planet_foundation_final_relief :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	field := &world.foundation
	peak := f32(0)
	lowest_land := max(f32)
	local_relief := f32(0)
	minimum := max(f32)
	maximum := -max(f32)
	for fixed in field.base_height {
		height := f32(fixed) / f32(HEIGHT_DELTA_SCALE)
		minimum = min(minimum, height)
		maximum = max(maximum, height)
		elevation := f32(i32(fixed) - i32(field.sea_level)) / f32(HEIGHT_DELTA_SCALE)
		if elevation > 0 {
			peak = max(peak, elevation)
			lowest_land = min(lowest_land, elevation)
		}
	}
	ocean_area, total_area := f64(0), f64(0)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		coord := planet_sim_coord_for_index(index)
		terrain_coord := planet_sim_terrain_coord(coord)
		terrain_index := planet_index(terrain_coord)
		area := planet_sim_cell_solid_angle(coord)
		total_area += area
		if field.base_height[terrain_index] <= field.sea_level do ocean_area += area
		if field.base_height[terrain_index] > field.sea_level {
			neighbour := planet_index(planet_neighbour(terrain_coord, 8, 0))
			local_relief = max(local_relief, f32(abs(i32(field.landform_height[terrain_index]) - i32(field.landform_height[neighbour]))) / f32(HEIGHT_DELTA_SCALE))
		}
	}
	fmt.printf("relief: peak=%v spread=%v local=%v range=[%v,%v] ocean=%v\n", peak, peak - lowest_land, local_relief, minimum, maximum, ocean_area / total_area)
	testing.expect(t, peak > 45)
	testing.expect(t, peak - lowest_land > 45)
	testing.expect(t, local_relief > 3)
	testing.expect(t, abs(ocean_area / total_area - 0.71) < 0.01)
	recipe := planet_terrain_recipe(TERRAIN_SEED)
	testing.expect(t, PLANET_RADIUS + minimum >= recipe.parameters.minimum_radius)
	testing.expect(t, PLANET_RADIUS + maximum <= recipe.parameters.maximum_radius)
	testing.expect(t, minimum * f32(HEIGHT_DELTA_SCALE) > f32(min(i16)))
	testing.expect(t, maximum * f32(HEIGHT_DELTA_SCALE) < f32(max(i16)))
	for face in procgen.Terrain_Face_V4 {
		for position in i32(0) ..= PLANET_FACE_CELLS {
			edges := [4]Planet_Coord{{face, position, 0}, {face, position, PLANET_FACE_CELLS}, {face, 0, position}, {face, PLANET_FACE_CELLS, position}}
			for coord in edges {
				index := planet_index(coord)
				duplicates, count := planet_duplicates(coord)
				for duplicate in duplicates[:count] {
					other := planet_index(duplicate)
					testing.expect_value(t, field.base_height[index], field.base_height[other])
					testing.expect_value(t, field.landform_height[index], field.landform_height[other])
				}
			}
		}
	}
}

@(test)
planet_terrain_radial_bounds_bracket_authored_relief :: proc(t: ^testing.T) {
	recipe := planet_terrain_recipe(TERRAIN_SEED)
	testing.expect(t, procgen.terrain_recipe_validate_v4(&recipe))
	testing.expect_value(t, recipe.parameters.minimum_radius, PLANET_RADIUS - 56)
	testing.expect_value(t, recipe.parameters.maximum_radius, PLANET_RADIUS + 96)
	minimum_radius := max(f32)
	maximum_radius := min(f32)
	for face in procgen.Terrain_Face_V4 {
		for row in 0 ..= 16 {
			for column in 0 ..= 16 {
				coord := Planet_Coord {
					face,
					i32(column * PLANET_FACE_CELLS / 16),
					i32(row * PLANET_FACE_CELLS / 16),
				}
				sample, ok := procgen.terrain_primary_surface_v4(&recipe, planet_direction(coord))
				testing.expect(t, ok)
				minimum_radius = min(minimum_radius, sample.radius)
				maximum_radius = max(maximum_radius, sample.radius)
			}
		}
	}
	testing.expect(t, minimum_radius >= recipe.parameters.minimum_radius)
	testing.expect(t, maximum_radius <= recipe.parameters.maximum_radius)
}

@(test)
terrain_effective_height_adds_interpolated_delta :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	coord := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	planet_heightfield_apply(&world.heightfield, coord, 1)
	base := terrain_base_height_fixed_at_coord(&world, coord)
	delta := planet_heightfield_delta(&world.heightfield, coord)
	expected := f32(base) / f32(HEIGHT_DELTA_SCALE) + delta
	testing.expect_value(t, terrain_height_at_coord(&world, coord), expected)
}

@(test)
terrain_recipe_carries_radial_cave_band :: proc(t: ^testing.T) {
	recipe := terrain_recipe(TERRAIN_SEED)
	testing.expect(t, recipe.parameters.cave_strength > 0)
	testing.expect_value(t, recipe.parameters.cave_strength, TERRAIN_CAVE_STRENGTH)
	testing.expect_value(t, recipe.parameters.cave_threshold, TERRAIN_CAVE_THRESHOLD)
	testing.expect_value(t, recipe.parameters.cave_altitude_min, TERRAIN_CAVE_RADIAL_MIN)
	testing.expect_value(t, recipe.parameters.cave_altitude_max, TERRAIN_CAVE_RADIAL_MAX)
	testing.expect_value(t, recipe.parameters.minimum_z, TERRAIN_VOLUME_RADIAL_MIN)
	testing.expect_value(t, recipe.parameters.maximum_z, TERRAIN_VOLUME_RADIAL_MAX)
	// The ceiling must clear the tallest shaped peak so summits are not clipped.
	testing.expect(t, recipe.parameters.maximum_z >= 48)
	// Fissures must stay off: the abstract recipe defaults them on, so an
	// ingot pin bump would otherwise re-enable them silently (and change
	// worldgen output plus per-sample density cost).
	testing.expect_value(t, recipe.parameters.fissure_strength, f32(0))
}

@(test)
terrain_runtime_seed_cave_carves_radial_void :: proc(t: ^testing.T) {
	// The recipe's third axis is radial depth on the sphere: negative values
	// descend below the mean surface. Caves must turn solid rock to void as
	// depth descends into the RADIAL_MIN..RADIAL_MAX shell, exactly as
	// terraforger carves along its vertical Z. Sampled with caves off vs on.
	recipe := terrain_recipe(TERRAIN_SEED)
	no_cave := recipe
	no_cave.parameters.cave_strength = 0
	carved := 0
	for y in -32 ..= 32 {
		for x in -32 ..= 32 {
			face_x, face_y := f32(x * 8), f32(y * 8)
			for depth := i32(-32); depth <= 32; depth += 4 {
				with_cave, ok_w := procgen.terrain_density_v3(&recipe, face_x, face_y, f32(depth))
				without_cave, ok_wo := procgen.terrain_density_v3(
					&no_cave,
					face_x,
					face_y,
					f32(depth),
				)
				if ok_w && ok_wo && without_cave > 0 && with_cave <= 0 {
					carved += 1
				}
			}
		}
	}
	testing.expectf(t, carved > 0, "radial cave carved zero samples")
}
