package procgen

import "core:math"

// Bumped from 2 when biome profiles gained a continentalness axis, the
// climate stack gained contrast shaping, and the height stack gained inland
// basin carving. All three change the classification a seed produces, so
// worlds persisted against version 2 must be regenerated rather than
// reinterpreted.
TERRAIN_RECIPE_VERSION_V2 :: u32(3)
TERRAIN_FIELD_MAX_EDGE_V2 :: 512
TERRAIN_BIOME_PROFILE_MAX_V2 :: 16
TERRAIN_FIELD_HALO_V2 :: 1
// Contrast below 1 would compress an already narrow climate distribution
// further, which is the defect these parameters exist to correct.
TERRAIN_CONTRAST_MIN_V2 :: f32(1)

Terrain_Range_V2 :: struct {
	minimum: f32,
	maximum: f32,
	fade:    f32,
}

// Axes read outermost first: where the sample sits vertically, how far it is
// from open ocean, then its climate, then the local surface itself.
Terrain_Biome_Profile_V2 :: struct {
	id:              u16,
	priority:        u8,
	weight:          f32,
	height:          Terrain_Range_V2,
	continentalness: Terrain_Range_V2,
	moisture:        Terrain_Range_V2,
	temperature:     Terrain_Range_V2,
	slope:           Terrain_Range_V2,
}

Terrain_Recipe_V2 :: struct {
	version:                u32,
	seed:                   u64,
	sea_level:              f32,
	snow_level:             f32,
	base_height:            f32,
	ocean_depth:            f32,
	land_height:            f32,
	mountain_height:        f32,
	hill_height:            f32,
	detail_height:          f32,
	coast_threshold:        f32,
	coast_fade:             f32,
	mountain_threshold:     f32,
	mountain_fade:          f32,
	ridge_power:            f32,
	basin_threshold:        f32,
	basin_fade:             f32,
	basin_depth:            f32,
	elevation_lapse:        f32,
	latitude_weight:        f32,
	latitude_half_extent:   f32,
	climate_contrast:       f32,
	continental_contrast:   f32,
	continental_noise:      Noise_Config,
	mountain_noise:         Noise_Config,
	ridge_noise:            Noise_Config,
	hill_noise:             Noise_Config,
	detail_noise:           Noise_Config,
	basin_noise:            Noise_Config,
	moisture_noise:         Noise_Config,
	temperature_noise:      Noise_Config,
	biome_profiles:         [TERRAIN_BIOME_PROFILE_MAX_V2]Terrain_Biome_Profile_V2,
	biome_profile_count:    u8,
	fallback_profile_index: u8,
}

Terrain_Biome_Blend_V2 :: struct {
	primary_id:     u16,
	secondary_id:   u16,
	primary_weight: f32,
}

Terrain_Sample_V2 :: struct {
	height:          f32,
	moisture:        f32,
	temperature:     f32,
	continentalness: f32,
	ruggedness:      f32,
	derivative_x:    f32,
	derivative_y:    f32,
	slope:           f32,
	biomes:          Terrain_Biome_Blend_V2,
}

Terrain_Field_Request_V2 :: struct {
	origin_x: f32,
	origin_y: f32,
	step:     f32,
	width:    int,
	height:   int,
}

Terrain_Field_Buffer_V2 :: struct {
	height_halo:     []f32,
	heights:         []f32,
	moisture:        []f32,
	temperature:     []f32,
	continentalness: []f32,
	ruggedness:      []f32,
	derivative_x:    []f32,
	derivative_y:    []f32,
	slope:           []f32,
	biomes:          []Terrain_Biome_Blend_V2,
}

terrain_default_recipe_v2 :: proc(seed: u64) -> Terrain_Recipe_V2 {
	recipe := Terrain_Recipe_V2 {
		version                = TERRAIN_RECIPE_VERSION_V2,
		seed                   = seed,
		sea_level              = -2,
		snow_level             = 13,
		base_height            = -1,
		ocean_depth            = 9,
		land_height            = 8,
		mountain_height        = 19,
		hill_height            = 5,
		detail_height          = 1.25,
		coast_threshold        = 0.58,
		coast_fade             = 0.12,
		mountain_threshold     = 0.56,
		mountain_fade          = 0.22,
		ridge_power            = 2.4,
		basin_threshold        = 0.62,
		basin_fade             = 0.08,
		basin_depth            = 4,
		elevation_lapse        = 0.012,
		latitude_weight        = 0.35,
		latitude_half_extent   = 128,
		climate_contrast       = 2.6,
		continental_contrast   = 2.2,
		// Climate and continental frequencies set biome extent: at these
		// wavelengths (~625, ~900, ~1250 world units) a few provinces span a
		// world instead of a fine-grained mottle. Their octave counts are
		// deliberately low because the high octaves only dither boundaries.
		continental_noise      = {seed ~ 0xA0761D6478BD642F, 0.0016, 4, 2, 0.5, 110},
		mountain_noise         = {seed ~ 0xE7037ED1A0B428DB, 0.006, 4, 2, 0.5, 32},
		ridge_noise            = {seed ~ 0x8EBC6AF09C88C6E3, 0.0075, 5, 2, 0.5, 18},
		hill_noise             = {seed ~ 0x589965CC75374CC3, 0.014, 4, 2, 0.5, 8},
		detail_noise           = {seed ~ 0x1D8E4E27C47D124F, 0.045, 3, 2, 0.5, 2},
		basin_noise            = {seed ~ 0x2545F4914F6CDD1D, 0.0026, 3, 2, 0.5, 40},
		moisture_noise         = {seed ~ 0xEB44ACCAB455D165, 0.0011, 2, 2, 0.5, 140},
		temperature_noise      = {seed ~ 0xC6BC279692B5CC83, 0.0008, 2, 2, 0.5, 180},
		biome_profile_count    = 6,
		fallback_profile_index = 2,
	}
	wide := Terrain_Range_V2{-10000, 10000, 1}
	unit := Terrain_Range_V2{0, 1, 0.2}
	recipe.biome_profiles[0] = {0, 6, 4, {-10000, -2, 1.5}, wide, unit, unit, wide}
	recipe.biome_profiles[1] = {
		1,
		5,
		2.5,
		{-2, 0.5, 1.5},
		wide,
		unit,
		{0.2, 1, 0.2},
		{0, 0.5, 0.2},
	}
	recipe.biome_profiles[2] = {
		2,
		1,
		1,
		{0, 16, 5},
		wide,
		{0.1, 0.7, 0.2},
		{0.25, 1, 0.2},
		{0, 0.65, 0.3},
	}
	recipe.biome_profiles[3] = {
		3,
		2,
		1.3,
		{0, 18, 5},
		wide,
		{0.5, 1, 0.2},
		{0.25, 0.9, 0.2},
		{0, 0.55, 0.3},
	}
	recipe.biome_profiles[4] = {4, 4, 1.6, {1, 10000, 5}, wide, unit, unit, {0.45, 10000, 0.3}}
	recipe.biome_profiles[5] = {5, 5, 2, {10, 10000, 5}, wide, unit, {0, 0.55, 0.25}, wide}
	return recipe
}

terrain_recipe_validate_v2 :: proc(recipe: ^Terrain_Recipe_V2) -> bool {
	if recipe == nil || recipe.version != TERRAIN_RECIPE_VERSION_V2 do return false
	values := [?]f32 {
		recipe.sea_level,
		recipe.snow_level,
		recipe.base_height,
		recipe.ocean_depth,
		recipe.land_height,
		recipe.mountain_height,
		recipe.hill_height,
		recipe.detail_height,
		recipe.coast_threshold,
		recipe.coast_fade,
		recipe.mountain_threshold,
		recipe.mountain_fade,
		recipe.ridge_power,
		recipe.basin_threshold,
		recipe.basin_fade,
		recipe.basin_depth,
		recipe.elevation_lapse,
		recipe.latitude_weight,
		recipe.latitude_half_extent,
		recipe.climate_contrast,
		recipe.continental_contrast,
	}
	for value in values do if !_terrain_finite_v2(value) do return false
	if recipe.ocean_depth <= 0 || recipe.land_height <= 0 || recipe.mountain_height < 0 do return false
	if recipe.hill_height < 0 || recipe.detail_height < 0 || recipe.coast_fade <= 0 do return false
	if recipe.mountain_fade <= 0 || recipe.ridge_power <= 0 do return false
	if recipe.basin_fade <= 0 || recipe.basin_depth < 0 do return false
	if recipe.climate_contrast < TERRAIN_CONTRAST_MIN_V2 do return false
	if recipe.continental_contrast < TERRAIN_CONTRAST_MIN_V2 do return false
	if recipe.elevation_lapse < 0 || recipe.latitude_weight < 0 do return false
	if recipe.latitude_weight > 1 do return false
	if recipe.latitude_half_extent <= 0 || recipe.biome_profile_count == 0 do return false
	if int(recipe.biome_profile_count) > TERRAIN_BIOME_PROFILE_MAX_V2 do return false
	if recipe.fallback_profile_index >= recipe.biome_profile_count do return false
	noises := [?]Noise_Config {
		recipe.continental_noise,
		recipe.mountain_noise,
		recipe.ridge_noise,
		recipe.hill_noise,
		recipe.detail_noise,
		recipe.basin_noise,
		recipe.moisture_noise,
		recipe.temperature_noise,
	}
	for noise in noises do if !_terrain_noise_validate_v2(noise) do return false
	for index in 0 ..< int(recipe.biome_profile_count) {
		profile := recipe.biome_profiles[index]
		if !_terrain_finite_v2(profile.weight) || profile.weight <= 0 do return false
		if !_terrain_range_validate_v2(profile.height) do return false
		if !_terrain_range_validate_v2(profile.continentalness) do return false
		if !_terrain_range_validate_v2(profile.moisture) do return false
		if !_terrain_range_validate_v2(profile.temperature) do return false
		if !_terrain_range_validate_v2(profile.slope) do return false
		for previous in 0 ..< index do if recipe.biome_profiles[previous].id == profile.id do return false
	}
	return true
}

terrain_field_requirements_v2 :: proc(
	width, height: int,
) -> (
	sample_count, height_halo_count: int,
	ok: bool,
) {
	if width < 1 || width > TERRAIN_FIELD_MAX_EDGE_V2 do return 0, 0, false
	if height < 1 || height > TERRAIN_FIELD_MAX_EDGE_V2 do return 0, 0, false
	return width * height, (width + 2) * (height + 2), true
}

terrain_height_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y: f32,
) -> (
	height, continentalness, ruggedness: f32,
	ok: bool,
) {
	if !terrain_recipe_validate_v2(recipe) do return 0, 0, 0, false
	return terrain_height_prevalidated_v2(recipe, world_x, world_y)
}

// terrain_height_prevalidated_v2 skips the per-call recipe validation for
// callers that validate once and then sample in bulk; the recipe must
// already be validated.
terrain_height_prevalidated_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y: f32,
) -> (
	height, continentalness, ruggedness: f32,
	ok: bool,
) {
	assert(recipe != nil, "terrain_height_prevalidated_v2: nil recipe")
	if !_terrain_finite_v2(world_x) || !_terrain_finite_v2(world_y) do return 0, 0, 0, false
	// Contrast is applied before the coast smoothstep so a seed can be an
	// archipelago or a single continent. Without it every seed's
	// continentalness hugs the middle and every coastline looks alike.
	continentalness = _terrain_contrast_v2(
		_terrain_unit(fractal_2d(recipe.continental_noise, world_x, world_y)),
		recipe.continental_contrast,
	)
	land := _terrain_smoothstep_v2(
		recipe.coast_threshold - recipe.coast_fade,
		recipe.coast_threshold + recipe.coast_fade,
		continentalness,
	)
	land = clamp(land + fractal_2d(recipe.hill_noise, world_x, world_y) * 0.08, 0, 1)
	mountain := _terrain_unit(warped_fractal_2d(recipe.mountain_noise, world_x, world_y))
	uplift :=
		_terrain_smoothstep_v2(
			recipe.mountain_threshold - recipe.mountain_fade,
			recipe.mountain_threshold + recipe.mountain_fade,
			mountain,
		) *
		land
	ridge_noise := warped_fractal_2d(recipe.ridge_noise, world_x, world_y)
	ridge := math.pow(clamp(1 - abs(ridge_noise), 0, 1), recipe.ridge_power)
	hills := warped_fractal_2d(recipe.hill_noise, world_x, world_y) * recipe.hill_height * land
	detail := fractal_2d(recipe.detail_noise, world_x, world_y) * recipe.detail_height * land
	base := -recipe.ocean_depth + (recipe.ocean_depth + recipe.land_height) * land
	height = recipe.base_height + base + ridge * uplift * recipe.mountain_height + hills + detail
	height = _terrain_basin_v2(recipe, world_x, world_y, height, land, uplift)
	ruggedness = clamp(uplift * 0.7 + ridge * 0.3, 0, 1)
	return height, continentalness, ruggedness, true
}

// _terrain_basin_v2 carves inland depressions that reach below sea level so a
// consumer's water fill produces lakes with no hydrology pass. Interpolating
// toward a floor below sea level, rather than subtracting a fixed depth,
// guarantees the basin actually reaches water however high the surrounding
// land sits, and yields a smooth shoreline for free. The land gate keeps
// basins off the ocean and the uplift gate keeps them out of mountains.
@(private)
_terrain_basin_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y, height, land, uplift: f32,
) -> f32 {
	assert(recipe != nil, "_terrain_basin_v2: nil recipe")
	assert(recipe.basin_fade > 0, "_terrain_basin_v2: non-positive fade")
	if recipe.basin_depth <= 0 do return height
	signal := _terrain_unit(warped_fractal_2d(recipe.basin_noise, world_x, world_y))
	basin :=
		_terrain_smoothstep_v2(
			recipe.basin_threshold - recipe.basin_fade,
			recipe.basin_threshold + recipe.basin_fade,
			signal,
		) *
		land *
		(1 - uplift)
	if basin <= 0 do return height
	lake_floor := recipe.sea_level - recipe.basin_depth
	return height + (lake_floor - height) * basin
}

terrain_biome_blend_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	height, continentalness, moisture, temperature, slope: f32,
) -> (
	Terrain_Biome_Blend_V2,
	bool,
) {
	if !terrain_recipe_validate_v2(recipe) do return {}, false
	return terrain_biome_blend_prevalidated_v2(
		recipe,
		height,
		continentalness,
		moisture,
		temperature,
		slope,
	)
}

// terrain_biome_blend_prevalidated_v2 skips the per-call recipe validation;
// the recipe must already be validated.
terrain_biome_blend_prevalidated_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	height, continentalness, moisture, temperature, slope: f32,
) -> (
	Terrain_Biome_Blend_V2,
	bool,
) {
	assert(recipe != nil, "terrain_biome_blend_prevalidated_v2: nil recipe")
	values := [?]f32{height, continentalness, moisture, temperature, slope}
	for value in values do if !_terrain_finite_v2(value) do return {}, false
	best_index, second_index := -1, -1
	best_score, second_score := f32(0), f32(0)
	for index in 0 ..< int(recipe.biome_profile_count) {
		profile := recipe.biome_profiles[index]
		score := profile.weight * _terrain_range_score_v2(profile.height, height)
		score *= _terrain_range_score_v2(profile.continentalness, continentalness)
		score *= _terrain_range_score_v2(profile.moisture, moisture)
		score *= _terrain_range_score_v2(profile.temperature, temperature)
		score *= _terrain_range_score_v2(profile.slope, slope)
		if _terrain_profile_better_v2(recipe, index, score, best_index, best_score) {
			second_index, second_score = best_index, best_score
			best_index, best_score = index, score
		} else if _terrain_profile_better_v2(recipe, index, score, second_index, second_score) {
			second_index, second_score = index, score
		}
	}
	if best_index < 0 || best_score <= 0 {
		fallback := recipe.biome_profiles[recipe.fallback_profile_index]
		return {fallback.id, fallback.id, 1}, true
	}
	if second_index < 0 || second_score <= 0 {
		id := recipe.biome_profiles[best_index].id
		return {id, id, 1}, true
	}
	total := best_score + second_score
	return {
			recipe.biome_profiles[best_index].id,
			recipe.biome_profiles[second_index].id,
			best_score / total,
		},
		true
}

terrain_sample_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y, derivative_step: f32,
) -> (
	Terrain_Sample_V2,
	bool,
) {
	if !terrain_recipe_validate_v2(recipe) do return {}, false
	return terrain_sample_prevalidated_v2(recipe, world_x, world_y, derivative_step)
}

// terrain_sample_prevalidated_v2 skips the per-call recipe validation for
// bulk sampling; the recipe must already be validated.
terrain_sample_prevalidated_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y, derivative_step: f32,
) -> (
	Terrain_Sample_V2,
	bool,
) {
	assert(recipe != nil, "terrain_sample_prevalidated_v2: nil recipe")
	if !_terrain_finite_v2(derivative_step) || derivative_step <= 0 do return {}, false
	height, continentalness, ruggedness, ok := terrain_height_prevalidated_v2(
		recipe,
		world_x,
		world_y,
	)
	if !ok do return {}, false
	left, _, _, _ := terrain_height_prevalidated_v2(recipe, world_x - derivative_step, world_y)
	right, _, _, _ := terrain_height_prevalidated_v2(recipe, world_x + derivative_step, world_y)
	down, _, _, _ := terrain_height_prevalidated_v2(recipe, world_x, world_y - derivative_step)
	up, _, _, _ := terrain_height_prevalidated_v2(recipe, world_x, world_y + derivative_step)
	derivative_x := (right - left) / (2 * derivative_step)
	derivative_y := (up - down) / (2 * derivative_step)
	slope := math.sqrt(derivative_x * derivative_x + derivative_y * derivative_y)
	moisture, temperature := _terrain_climate_v2(
		recipe,
		world_x,
		world_y,
		height,
		continentalness,
		ruggedness,
	)
	biomes, blend_ok := terrain_biome_blend_prevalidated_v2(
		recipe,
		height,
		continentalness,
		moisture,
		temperature,
		slope,
	)
	if !blend_ok do return {}, false
	return {
			height,
			moisture,
			temperature,
			continentalness,
			ruggedness,
			derivative_x,
			derivative_y,
			slope,
			biomes,
		},
		true
}

terrain_generate_field_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	request: Terrain_Field_Request_V2,
	buffer: Terrain_Field_Buffer_V2,
) -> bool {
	if !terrain_recipe_validate_v2(recipe) do return false
	if !_terrain_finite_v2(request.origin_x) || !_terrain_finite_v2(request.origin_y) do return false
	if !_terrain_finite_v2(request.step) || request.step <= 0 do return false
	samples, halo_count, ok := terrain_field_requirements_v2(request.width, request.height)
	if !ok || !_terrain_field_capacity_v2(buffer, samples, halo_count) do return false
	stride := request.width + 2
	for row in 0 ..< request.height + 2 {
		world_y := request.origin_y + f32(row - 1) * request.step
		for column in 0 ..< request.width + 2 {
			world_x := request.origin_x + f32(column - 1) * request.step
			height, _, _, generated := terrain_height_prevalidated_v2(recipe, world_x, world_y)
			if !generated do return false
			buffer.height_halo[row * stride + column] = height
		}
	}
	for row in 0 ..< request.height {
		world_y := request.origin_y + f32(row) * request.step
		for column in 0 ..< request.width {
			world_x := request.origin_x + f32(column) * request.step
			index := row * request.width + column
			center := (row + 1) * stride + column + 1
			generated := _terrain_field_sample_v2(
				recipe,
				request.step,
				world_x,
				world_y,
				center,
				stride,
				index,
				buffer,
			)
			if !generated do return false
		}
	}
	return true
}

@(private)
_terrain_field_sample_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	step, world_x, world_y: f32,
	center, stride, index: int,
	buffer: Terrain_Field_Buffer_V2,
) -> bool {
	assert(recipe != nil, "_terrain_field_sample_v2: nil recipe")
	assert(
		stride > 2 && center - stride >= 0 && center + stride < len(buffer.height_halo),
		"_terrain_field_sample_v2: halo index",
	)
	assert(index >= 0 && index < len(buffer.heights), "_terrain_field_sample_v2: sample index")
	height := buffer.height_halo[center]
	derivative_x := (buffer.height_halo[center + 1] - buffer.height_halo[center - 1]) / (2 * step)
	derivative_y :=
		(buffer.height_halo[center + stride] - buffer.height_halo[center - stride]) / (2 * step)
	slope := math.sqrt(derivative_x * derivative_x + derivative_y * derivative_y)
	_, continentalness, ruggedness, ok := terrain_height_prevalidated_v2(recipe, world_x, world_y)
	if !ok do return false
	moisture, temperature := _terrain_climate_v2(
		recipe,
		world_x,
		world_y,
		height,
		continentalness,
		ruggedness,
	)
	biomes, blend_ok := terrain_biome_blend_prevalidated_v2(
		recipe,
		height,
		continentalness,
		moisture,
		temperature,
		slope,
	)
	if !blend_ok do return false
	buffer.heights[index] = height
	buffer.moisture[index] = moisture
	buffer.temperature[index] = temperature
	buffer.continentalness[index] = continentalness
	buffer.ruggedness[index] = ruggedness
	buffer.derivative_x[index] = derivative_x
	buffer.derivative_y[index] = derivative_y
	buffer.slope[index] = slope
	buffer.biomes[index] = biomes
	return true
}

@(private)
_terrain_climate_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	world_x, world_y, height, continentalness, ruggedness: f32,
) -> (
	moisture, temperature: f32,
) {
	assert(recipe != nil, "_terrain_climate_v2: nil recipe")
	// Contrast first: the fractal stack averages octaves, so its raw output
	// occupies roughly the middle fifth of the unit range. Expanding it about
	// the midpoint is what makes dry and cold profile windows reachable at
	// all, and the clamp is deliberate -- saturating at 0 and 1 is what
	// produces large uniform desert and tundra cores rather than a permanent
	// gradient.
	moisture = _terrain_contrast_v2(
		_terrain_unit(warped_fractal_2d(recipe.moisture_noise, world_x, world_y)),
		recipe.climate_contrast,
	)
	coast_bias :=
		1 - abs(continentalness - recipe.coast_threshold) / max(recipe.coast_fade * 3, 0.001)
	moisture = clamp(moisture + clamp(coast_bias, 0, 1) * 0.12 - ruggedness * 0.08, 0, 1)
	// The latitude term is identical for every seed, so it blends against a
	// contrasted noise signal that can actually move against it.
	noise := _terrain_contrast_v2(
		_terrain_unit(warped_fractal_2d(recipe.temperature_noise, world_x, world_y)),
		recipe.climate_contrast,
	)
	latitude := clamp(abs(world_y) / recipe.latitude_half_extent, 0, 1)
	temperature = noise * (1 - recipe.latitude_weight) + (1 - latitude) * recipe.latitude_weight
	temperature = clamp(
		temperature - max(height - recipe.sea_level, 0) * recipe.elevation_lapse,
		0,
		1,
	)
	return
}

// _terrain_contrast_v2 expands a unit value about its midpoint. A contrast of
// 1 is the identity, so a recipe can opt out.
@(private)
_terrain_contrast_v2 :: proc(value, contrast: f32) -> f32 {
	assert(contrast >= TERRAIN_CONTRAST_MIN_V2, "_terrain_contrast_v2: contrast below minimum")
	return clamp(0.5 + (value - 0.5) * contrast, 0, 1)
}

@(private)
_terrain_field_capacity_v2 :: proc(
	buffer: Terrain_Field_Buffer_V2,
	samples, halo_count: int,
) -> bool {
	if len(buffer.height_halo) < halo_count do return false
	if len(buffer.heights) < samples || len(buffer.moisture) < samples do return false
	if len(buffer.temperature) < samples || len(buffer.continentalness) < samples do return false
	if len(buffer.ruggedness) < samples || len(buffer.derivative_x) < samples do return false
	if len(buffer.derivative_y) < samples || len(buffer.slope) < samples do return false
	return len(buffer.biomes) >= samples
}

@(private)
_terrain_noise_validate_v2 :: proc(config: Noise_Config) -> bool {
	values := [?]f32{config.frequency, config.lacunarity, config.gain, config.warp}
	for value in values do if !_terrain_finite_v2(value) do return false
	return(
		config.frequency > 0 &&
		config.octaves > 0 &&
		config.octaves <= 12 &&
		config.lacunarity > 0 &&
		config.gain > 0 &&
		config.gain <= 1 &&
		config.warp >= 0 \
	)
}

@(private)
_terrain_range_validate_v2 :: proc(value: Terrain_Range_V2) -> bool {
	return(
		_terrain_finite_v2(value.minimum) &&
		_terrain_finite_v2(value.maximum) &&
		_terrain_finite_v2(value.fade) &&
		value.minimum <= value.maximum &&
		value.fade > 0 \
	)
}

@(private)
_terrain_range_score_v2 :: proc(value: Terrain_Range_V2, sample: f32) -> f32 {
	if sample >= value.minimum && sample <= value.maximum do return 1
	distance := value.minimum - sample if sample < value.minimum else sample - value.maximum
	if distance >= value.fade do return 0
	t := distance / value.fade
	return 1 - t * t * (3 - 2 * t)
}

@(private)
_terrain_profile_better_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	candidate: int,
	score: f32,
	current: int,
	current_score: f32,
) -> bool {
	assert(recipe != nil, "_terrain_profile_better_v2: nil recipe")
	if score > current_score do return true
	if score < current_score || score <= 0 do return false
	if current < 0 do return true
	candidate_priority := recipe.biome_profiles[candidate].priority
	current_priority := recipe.biome_profiles[current].priority
	return(
		candidate_priority > current_priority ||
		(candidate_priority == current_priority && candidate < current) \
	)
}

@(private)
_terrain_smoothstep_v2 :: proc(edge_a, edge_b, value: f32) -> f32 {
	assert(edge_b > edge_a, "_terrain_smoothstep_v2: invalid edges")
	t := clamp((value - edge_a) / (edge_b - edge_a), 0, 1)
	return t * t * (3 - 2 * t)
}

@(private)
_terrain_finite_v2 :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value, 0)
}
