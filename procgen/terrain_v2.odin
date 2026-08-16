package procgen

import "core:math"

TERRAIN_RECIPE_VERSION_V2 :: u32(2)
TERRAIN_FIELD_MAX_EDGE_V2 :: 512
TERRAIN_BIOME_PROFILE_MAX_V2 :: 16
TERRAIN_FIELD_HALO_V2 :: 1

Terrain_Range_V2 :: struct {
	minimum: f32,
	maximum: f32,
	fade:    f32,
}

Terrain_Biome_Profile_V2 :: struct {
	id:          u16,
	priority:    u8,
	weight:      f32,
	height:      Terrain_Range_V2,
	moisture:    Terrain_Range_V2,
	temperature: Terrain_Range_V2,
	slope:       Terrain_Range_V2,
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
	elevation_lapse:        f32,
	latitude_weight:        f32,
	latitude_half_extent:   f32,
	continental_noise:      Noise_Config,
	mountain_noise:         Noise_Config,
	ridge_noise:            Noise_Config,
	hill_noise:             Noise_Config,
	detail_noise:           Noise_Config,
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
		elevation_lapse        = 0.012,
		latitude_weight        = 0.35,
		latitude_half_extent   = 128,
		continental_noise      = {seed ~ 0xA0761D6478BD642F, 0.0035, 5, 2, 0.5, 70},
		mountain_noise         = {seed ~ 0xE7037ED1A0B428DB, 0.006, 4, 2, 0.5, 32},
		ridge_noise            = {seed ~ 0x8EBC6AF09C88C6E3, 0.0075, 5, 2, 0.5, 18},
		hill_noise             = {seed ~ 0x589965CC75374CC3, 0.014, 4, 2, 0.5, 8},
		detail_noise           = {seed ~ 0x1D8E4E27C47D124F, 0.045, 3, 2, 0.5, 2},
		moisture_noise         = {seed ~ 0xEB44ACCAB455D165, 0.0038, 4, 2, 0.5, 24},
		temperature_noise      = {seed ~ 0xC6BC279692B5CC83, 0.0021, 3, 2, 0.5, 12},
		biome_profile_count    = 6,
		fallback_profile_index = 2,
	}
	wide := Terrain_Range_V2{-10000, 10000, 1}
	unit := Terrain_Range_V2{0, 1, 0.2}
	recipe.biome_profiles[0] = {0, 6, 4, {-10000, -2, 1.5}, unit, unit, wide}
	recipe.biome_profiles[1] = {1, 5, 2.5, {-2, 0.5, 1.5}, unit, {0.2, 1, 0.2}, {0, 0.5, 0.2}}
	recipe.biome_profiles[2] = {
		2,
		1,
		1,
		{0, 16, 5},
		{0.1, 0.7, 0.2},
		{0.25, 1, 0.2},
		{0, 0.65, 0.3},
	}
	recipe.biome_profiles[3] = {
		3,
		2,
		1.3,
		{0, 18, 5},
		{0.5, 1, 0.2},
		{0.25, 0.9, 0.2},
		{0, 0.55, 0.3},
	}
	recipe.biome_profiles[4] = {4, 4, 1.6, {1, 10000, 5}, unit, unit, {0.45, 10000, 0.3}}
	recipe.biome_profiles[5] = {5, 5, 2, {10, 10000, 5}, unit, {0, 0.55, 0.25}, wide}
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
		recipe.elevation_lapse,
		recipe.latitude_weight,
		recipe.latitude_half_extent,
	}
	for value in values do if !_terrain_finite_v2(value) do return false
	if recipe.ocean_depth <= 0 || recipe.land_height <= 0 || recipe.mountain_height < 0 do return false
	if recipe.hill_height < 0 || recipe.detail_height < 0 || recipe.coast_fade <= 0 do return false
	if recipe.mountain_fade <= 0 || recipe.ridge_power <= 0 do return false
	if recipe.elevation_lapse < 0 || recipe.latitude_weight < 0 || recipe.latitude_weight > 1 do return false
	if recipe.latitude_half_extent <= 0 || recipe.biome_profile_count == 0 do return false
	if int(recipe.biome_profile_count) > TERRAIN_BIOME_PROFILE_MAX_V2 do return false
	if recipe.fallback_profile_index >= recipe.biome_profile_count do return false
	noises := [?]Noise_Config {
		recipe.continental_noise,
		recipe.mountain_noise,
		recipe.ridge_noise,
		recipe.hill_noise,
		recipe.detail_noise,
		recipe.moisture_noise,
		recipe.temperature_noise,
	}
	for noise in noises do if !_terrain_noise_validate_v2(noise) do return false
	for index in 0 ..< int(recipe.biome_profile_count) {
		profile := recipe.biome_profiles[index]
		if !_terrain_finite_v2(profile.weight) || profile.weight <= 0 do return false
		if !_terrain_range_validate_v2(profile.height) do return false
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
	if !_terrain_finite_v2(world_x) || !_terrain_finite_v2(world_y) do return 0, 0, 0, false
	continentalness = _terrain_unit(fractal_2d(recipe.continental_noise, world_x, world_y))
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
	ruggedness = clamp(uplift * 0.7 + ridge * 0.3, 0, 1)
	return height, continentalness, ruggedness, true
}

terrain_biome_blend_v2 :: proc(
	recipe: ^Terrain_Recipe_V2,
	height, moisture, temperature, slope: f32,
) -> (
	Terrain_Biome_Blend_V2,
	bool,
) {
	if !terrain_recipe_validate_v2(recipe) do return {}, false
	values := [?]f32{height, moisture, temperature, slope}
	for value in values do if !_terrain_finite_v2(value) do return {}, false
	best_index, second_index := -1, -1
	best_score, second_score := f32(0), f32(0)
	for index in 0 ..< int(recipe.biome_profile_count) {
		profile := recipe.biome_profiles[index]
		score := profile.weight * _terrain_range_score_v2(profile.height, height)
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
	if !_terrain_finite_v2(derivative_step) || derivative_step <= 0 do return {}, false
	height, continentalness, ruggedness, ok := terrain_height_v2(recipe, world_x, world_y)
	if !ok do return {}, false
	left, _, _, _ := terrain_height_v2(recipe, world_x - derivative_step, world_y)
	right, _, _, _ := terrain_height_v2(recipe, world_x + derivative_step, world_y)
	down, _, _, _ := terrain_height_v2(recipe, world_x, world_y - derivative_step)
	up, _, _, _ := terrain_height_v2(recipe, world_x, world_y + derivative_step)
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
	biomes, blend_ok := terrain_biome_blend_v2(recipe, height, moisture, temperature, slope)
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
			height, _, _, generated := terrain_height_v2(recipe, world_x, world_y)
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
	height := buffer.height_halo[center]
	derivative_x := (buffer.height_halo[center + 1] - buffer.height_halo[center - 1]) / (2 * step)
	derivative_y :=
		(buffer.height_halo[center + stride] - buffer.height_halo[center - stride]) / (2 * step)
	slope := math.sqrt(derivative_x * derivative_x + derivative_y * derivative_y)
	_, continentalness, ruggedness, ok := terrain_height_v2(recipe, world_x, world_y)
	if !ok do return false
	moisture, temperature := _terrain_climate_v2(
		recipe,
		world_x,
		world_y,
		height,
		continentalness,
		ruggedness,
	)
	biomes, blend_ok := terrain_biome_blend_v2(recipe, height, moisture, temperature, slope)
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
	moisture = _terrain_unit(warped_fractal_2d(recipe.moisture_noise, world_x, world_y))
	coast_bias :=
		1 - abs(continentalness - recipe.coast_threshold) / max(recipe.coast_fade * 3, 0.001)
	moisture = clamp(moisture + clamp(coast_bias, 0, 1) * 0.12 - ruggedness * 0.08, 0, 1)
	noise := _terrain_unit(warped_fractal_2d(recipe.temperature_noise, world_x, world_y))
	latitude := clamp(abs(world_y) / recipe.latitude_half_extent, 0, 1)
	temperature = noise * (1 - recipe.latitude_weight) + (1 - latitude) * recipe.latitude_weight
	temperature = clamp(
		temperature - max(height - recipe.sea_level, 0) * recipe.elevation_lapse,
		0,
		1,
	)
	return
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
