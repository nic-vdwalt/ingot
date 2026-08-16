package procgen

import "core:math"

TERRAIN_RECIPE_VERSION_V3 :: u32(3)
TERRAIN_VOLUME_MAX_EDGE_V3 :: 64
TERRAIN_VOLUME_MAX_SAMPLES_V3 :: 300_000

Terrain_Preset_V3 :: enum u8 {
	Normal,
	Abstract,
	Custom,
}

Terrain_Parameters_V3 :: struct {
	minimum_z:                 f32,
	maximum_z:                 f32,
	cell_size:                 f32,
	ground_strength:           f32,
	surface_softness:          f32,
	overhang_strength:         f32,
	mountain_scale:            f32,
	mountain_sharpness:        f32,
	mountain_terrace_strength: f32,
	floating_strength:         f32,
	floating_altitude_min:     f32,
	floating_altitude_max:     f32,
	floating_spacing:          f32,
	floating_radius:           f32,
	floating_thickness:        f32,
	floating_taper:            f32,
	floating_breakup:          f32,
	cave_strength:             f32,
	cave_threshold:            f32,
	cave_altitude_min:         f32,
	cave_altitude_max:         f32,
	cave_tunnel_scale:         f32,
	cave_chamber_scale:        f32,
	cave_warp:                 f32,
	minimum_upward_normal:     f32,
	surface_search_min:        f32,
	surface_search_max:        f32,
	overhang_noise:            Noise_Config,
	floating_shape_noise:      Noise_Config,
	floating_breakup_noise:    Noise_Config,
	cave_tunnel_noise:         Noise_Config,
	cave_chamber_noise:        Noise_Config,
}

Terrain_Recipe_V3 :: struct {
	version:    u32,
	preset:     Terrain_Preset_V3,
	seed:       u64,
	surface:    Terrain_Recipe_V2,
	parameters: Terrain_Parameters_V3,
}

Terrain_Surface_V3 :: struct {
	height:          f32,
	moisture:        f32,
	temperature:     f32,
	continentalness: f32,
	ruggedness:      f32,
	slope:           f32,
	upward_normal:   f32,
	biomes:          Terrain_Biome_Blend_V2,
	buildable:       bool,
}

terrain_normal_recipe_v3 :: proc(seed: u64) -> Terrain_Recipe_V3 {
	parameters := Terrain_Parameters_V3 {
		minimum_z              = -40,
		maximum_z              = 48,
		cell_size              = 2,
		ground_strength        = 1,
		surface_softness       = 1,
		mountain_scale         = 1,
		mountain_sharpness     = 1,
		floating_spacing       = 72,
		floating_radius        = 24,
		floating_thickness     = 10,
		floating_taper         = 1.5,
		cave_threshold         = 0.62,
		cave_altitude_min      = -24,
		cave_altitude_max      = 24,
		cave_tunnel_scale      = 1,
		cave_chamber_scale     = 1,
		minimum_upward_normal  = 0.55,
		surface_search_min     = -40,
		surface_search_max     = 48,
		overhang_noise         = {seed ~ 0x243F6A8885A308D3, 0.018, 4, 2, 0.5, 12},
		floating_shape_noise   = {seed ~ 0x13198A2E03707344, 0.012, 4, 2, 0.5, 18},
		floating_breakup_noise = {seed ~ 0xA4093822299F31D0, 0.031, 3, 2, 0.5, 8},
		cave_tunnel_noise      = {seed ~ 0x082EFA98EC4E6C89, 0.035, 4, 2, 0.5, 10},
		cave_chamber_noise     = {seed ~ 0x452821E638D01377, 0.016, 3, 2, 0.5, 16},
	}
	return {TERRAIN_RECIPE_VERSION_V3, .Normal, seed, terrain_default_recipe_v2(seed), parameters}
}

terrain_abstract_recipe_v3 :: proc(seed: u64) -> Terrain_Recipe_V3 {
	recipe := terrain_normal_recipe_v3(seed)
	recipe.preset = .Abstract
	recipe.parameters.minimum_z = -48
	recipe.parameters.maximum_z = 72
	recipe.parameters.cell_size = 4
	recipe.parameters.overhang_strength = 8
	recipe.parameters.mountain_scale = 1.8
	recipe.parameters.mountain_sharpness = 1.7
	recipe.parameters.mountain_terrace_strength = 1.5
	recipe.parameters.floating_strength = 1
	recipe.parameters.floating_altitude_min = 18
	recipe.parameters.floating_altitude_max = 58
	recipe.parameters.floating_spacing = 68
	recipe.parameters.floating_radius = 25
	recipe.parameters.floating_thickness = 12
	recipe.parameters.floating_taper = 1.7
	recipe.parameters.floating_breakup = 0.28
	recipe.parameters.cave_strength = 7
	recipe.parameters.cave_threshold = 0.58
	recipe.parameters.cave_altitude_min = -18
	recipe.parameters.cave_altitude_max = 30
	recipe.parameters.cave_tunnel_scale = 1.25
	recipe.parameters.cave_chamber_scale = 1.1
	recipe.parameters.cave_warp = 9
	recipe.parameters.surface_search_min = -48
	recipe.parameters.surface_search_max = 72
	return recipe
}

terrain_custom_recipe_v3 :: proc(
	seed: u64,
	parameters: Terrain_Parameters_V3,
) -> (
	Terrain_Recipe_V3,
	bool,
) {
	recipe := Terrain_Recipe_V3 {
		version    = TERRAIN_RECIPE_VERSION_V3,
		preset     = .Custom,
		seed       = seed,
		surface    = terrain_default_recipe_v2(seed),
		parameters = parameters,
	}
	return recipe, terrain_recipe_validate_v3(&recipe)
}

terrain_recipe_validate_v3 :: proc(recipe: ^Terrain_Recipe_V3) -> bool {
	if recipe == nil || recipe.version != TERRAIN_RECIPE_VERSION_V3 do return false
	if recipe.surface.seed != recipe.seed || !terrain_recipe_validate_v2(&recipe.surface) do return false
	p := recipe.parameters
	values := [?]f32 {
		p.minimum_z,
		p.maximum_z,
		p.cell_size,
		p.ground_strength,
		p.surface_softness,
		p.overhang_strength,
		p.mountain_scale,
		p.mountain_sharpness,
		p.mountain_terrace_strength,
		p.floating_strength,
		p.floating_altitude_min,
		p.floating_altitude_max,
		p.floating_spacing,
		p.floating_radius,
		p.floating_thickness,
		p.floating_taper,
		p.floating_breakup,
		p.cave_strength,
		p.cave_threshold,
		p.cave_altitude_min,
		p.cave_altitude_max,
		p.cave_tunnel_scale,
		p.cave_chamber_scale,
		p.cave_warp,
		p.minimum_upward_normal,
		p.surface_search_min,
		p.surface_search_max,
	}
	for value in values do if !_terrain_finite_v2(value) do return false
	if p.minimum_z >= p.maximum_z || p.cell_size <= 0 do return false
	if (p.maximum_z - p.minimum_z) / p.cell_size > TERRAIN_VOLUME_MAX_EDGE_V3 do return false
	if p.ground_strength <= 0 || p.surface_softness <= 0 do return false
	if p.overhang_strength < 0 || p.mountain_scale <= 0 || p.mountain_sharpness <= 0 do return false
	if p.mountain_terrace_strength < 0 || p.floating_strength < 0 do return false
	if p.floating_altitude_min > p.floating_altitude_max do return false
	if p.floating_spacing <= 0 || p.floating_radius <= 0 || p.floating_thickness <= 0 do return false
	if p.floating_taper <= 0 || p.floating_breakup < 0 || p.floating_breakup > 1 do return false
	if p.cave_strength < 0 || p.cave_threshold < 0 || p.cave_threshold > 1 do return false
	if p.cave_altitude_min > p.cave_altitude_max do return false
	if p.cave_tunnel_scale <= 0 || p.cave_chamber_scale <= 0 || p.cave_warp < 0 do return false
	if p.minimum_upward_normal < 0 || p.minimum_upward_normal > 1 do return false
	if p.surface_search_min >= p.surface_search_max do return false
	noises := [?]Noise_Config {
		p.overhang_noise,
		p.floating_shape_noise,
		p.floating_breakup_noise,
		p.cave_tunnel_noise,
		p.cave_chamber_noise,
	}
	for noise in noises do if !_terrain_noise_validate_v2(noise) do return false
	return true
}

terrain_density_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y, z: f32) -> (f32, bool) {
	if !terrain_recipe_validate_v3(recipe) do return 0, false
	if !_terrain_finite_v2(x) || !_terrain_finite_v2(y) || !_terrain_finite_v2(z) do return 0, false
	ground, ok := _terrain_ground_v3(recipe, x, y)
	if !ok do return 0, false
	return _terrain_density_from_ground_v3(recipe, ground, x, y, z), true
}

// _Terrain_Ground_V3 caches the per-column surface terms so a vertical run
// of density samples pays for the 2D noise stack exactly once.
_Terrain_Ground_V3 :: struct {
	height:     f32,
	ruggedness: f32,
}

@(private)
_terrain_ground_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	x, y: f32,
) -> (
	ground: _Terrain_Ground_V3,
	ok: bool,
) {
	base_height, _, ruggedness, height_ok := terrain_height_v2(&recipe.surface, x, y)
	if !height_ok do return {}, false
	p := recipe.parameters
	mountain := max(base_height - recipe.surface.land_height, 0)
	mountain = math.pow(mountain / max(recipe.surface.mountain_height, 1), p.mountain_sharpness)
	height := base_height + mountain * recipe.surface.mountain_height * (p.mountain_scale - 1)
	if p.mountain_terrace_strength > 0 && mountain > 0 {
		terrace := math.floor(height / 4 + 0.5) * 4
		height += (terrace - height) * clamp(p.mountain_terrace_strength / 4, 0, 0.45)
	}
	return {height, ruggedness}, true
}

// _terrain_density_from_ground_v3 evaluates the volumetric terms for one
// sample. Far from every reachable surface the noise cannot flip the sign,
// so those samples return the linear base term without running any fractal:
// overhang is bounded by overhang_strength, cave carving by
// (1 - cave_threshold) * cave_strength, and floating islands both cap at
// floating_strength * floating_thickness and live inside their altitude
// band padded by floating_thickness.
@(private)
_terrain_density_from_ground_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	ground: _Terrain_Ground_V3,
	x, y, z: f32,
) -> f32 {
	p := recipe.parameters
	base := (ground.height - z) * p.ground_strength / p.surface_softness
	carve_max := max(1 - p.cave_threshold, 0) * p.cave_strength
	floating_max := p.floating_strength * p.floating_thickness
	if base > p.overhang_strength + carve_max && base >= floating_max do return base
	if base < -p.overhang_strength {
		floating_possible :=
			p.floating_strength > 0 &&
			z >= p.floating_altitude_min - p.floating_thickness &&
			z <= p.floating_altitude_max + p.floating_thickness
		if !floating_possible do return base
	}
	overhang := fractal_2d(p.overhang_noise, x + z * 0.31, y - z * 0.23)
	density := base + overhang * p.overhang_strength * ground.ruggedness
	if p.floating_strength > 0 {
		density = max(density, _terrain_floating_density_v3(recipe, x, y, z))
	}
	if p.cave_strength > 0 && z >= p.cave_altitude_min && z <= p.cave_altitude_max {
		cave := _terrain_cave_signal_v3(recipe, x, y, z)
		carve := max(cave - p.cave_threshold, 0) * p.cave_strength
		density -= carve
	}
	return density
}

terrain_primary_surface_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	x, y, step: f32,
) -> (
	Terrain_Surface_V3,
	bool,
) {
	if !terrain_recipe_validate_v3(recipe) || step <= 0 || !_terrain_finite_v2(step) do return {}, false
	sample, ok := terrain_sample_v2(&recipe.surface, x, y, step)
	if !ok do return {}, false
	p := recipe.parameters
	mountain := max(sample.height - recipe.surface.land_height, 0)
	mountain = math.pow(mountain / max(recipe.surface.mountain_height, 1), p.mountain_sharpness)
	height := sample.height + mountain * recipe.surface.mountain_height * (p.mountain_scale - 1)
	if p.mountain_terrace_strength > 0 && mountain > 0 {
		terrace := math.floor(height / 4 + 0.5) * 4
		height += (terrace - height) * clamp(p.mountain_terrace_strength / 4, 0, 0.45)
	}
	left, left_ok := _terrain_primary_height_v3(recipe, x - step, y)
	right, right_ok := _terrain_primary_height_v3(recipe, x + step, y)
	down, down_ok := _terrain_primary_height_v3(recipe, x, y - step)
	up, up_ok := _terrain_primary_height_v3(recipe, x, y + step)
	if !left_ok || !right_ok || !down_ok || !up_ok do return {}, false
	dx := (right - left) / (2 * step)
	dy := (up - down) / (2 * step)
	slope := math.sqrt(dx * dx + dy * dy)
	upward := 1 / math.sqrt(1 + slope * slope)
	biomes, biome_ok := terrain_biome_blend_v2(
		&recipe.surface,
		height,
		sample.moisture,
		sample.temperature,
		slope,
	)
	if !biome_ok do return {}, false
	return {
			height = height,
			moisture = sample.moisture,
			temperature = sample.temperature,
			continentalness = sample.continentalness,
			ruggedness = sample.ruggedness,
			slope = slope,
			upward_normal = upward,
			biomes = biomes,
			buildable = height >= p.surface_search_min &&
			height <= p.surface_search_max &&
			upward >= p.minimum_upward_normal,
		},
		true
}

@(private)
_terrain_primary_height_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y: f32) -> (f32, bool) {
	height, _, _, ok := terrain_height_v2(&recipe.surface, x, y)
	if !ok do return 0, false
	p := recipe.parameters
	mountain := max(height - recipe.surface.land_height, 0)
	mountain = math.pow(mountain / max(recipe.surface.mountain_height, 1), p.mountain_sharpness)
	height += mountain * recipe.surface.mountain_height * (p.mountain_scale - 1)
	if p.mountain_terrace_strength > 0 && mountain > 0 {
		terrace := math.floor(height / 4 + 0.5) * 4
		height += (terrace - height) * clamp(p.mountain_terrace_strength / 4, 0, 0.45)
	}
	return height, true
}

@(private)
_terrain_floating_density_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y, z: f32) -> f32 {
	p := recipe.parameters
	cell_x := i64(math.floor(x / p.floating_spacing))
	cell_y := i64(math.floor(y / p.floating_spacing))
	best := f32(-10000)
	for offset_y in -1 ..= 1 {
		for offset_x in -1 ..= 1 {
			hash := _noise_hash(
				recipe.seed ~ 0xBE5466CF34E90C6C,
				cell_x + i64(offset_x),
				cell_y + i64(offset_y),
			)
			jitter_x := f32(hash & 0xffff) / 65535 - 0.5
			jitter_y := f32((hash >> 16) & 0xffff) / 65535 - 0.5
			altitude_unit := f32((hash >> 32) & 0xffff) / 65535
			center_x := (f32(cell_x + i64(offset_x)) + 0.5 + jitter_x * 0.7) * p.floating_spacing
			center_y := (f32(cell_y + i64(offset_y)) + 0.5 + jitter_y * 0.7) * p.floating_spacing
			center_z :=
				p.floating_altitude_min +
				(p.floating_altitude_max - p.floating_altitude_min) * altitude_unit
			dx := (x - center_x) / p.floating_radius
			dy := (y - center_y) / p.floating_radius
			radial := math.sqrt(dx * dx + dy * dy)
			shape := fractal_2d(p.floating_shape_noise, x, y) * 0.22
			breakup := _terrain_unit(fractal_2d(p.floating_breakup_noise, x + z, y - z))
			top := 1 - radial + shape
			vertical := abs(z - center_z) / p.floating_thickness
			island := min(top * p.floating_taper, 1 - vertical)
			island -= max(p.floating_breakup - breakup, 0)
			best = max(best, island * p.floating_strength * p.floating_thickness)
		}
	}
	return best
}

@(private)
_terrain_cave_signal_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y, z: f32) -> f32 {
	p := recipe.parameters
	warp_x := fractal_2d(p.cave_chamber_noise, y, z) * p.cave_warp
	warp_y := fractal_2d(p.cave_chamber_noise, z, x) * p.cave_warp
	tunnel_a := abs(fractal_2d(p.cave_tunnel_noise, x + warp_x, z + warp_y))
	tunnel_b := abs(fractal_2d(p.cave_tunnel_noise, y - warp_y, z + warp_x))
	tunnel := 1 - min(tunnel_a, tunnel_b) * p.cave_tunnel_scale
	chamber := _terrain_unit(fractal_2d(p.cave_chamber_noise, x + z * 0.4, y - z * 0.3))
	return clamp(max(tunnel, chamber * p.cave_chamber_scale), 0, 1)
}
