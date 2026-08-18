package procgen

import "core:math"

// Bumped from 5 when the V2 surface recipe gained climate bias, a movable
// equator and a tunable coast jitter, and biome classification moved onto the
// landform height. The embedded V2 recipe changes both the classification and
// the height a seed produces, so worlds persisted against version 5 must be
// regenerated rather than reinterpreted.
TERRAIN_RECIPE_VERSION_V3 :: u32(6)
TERRAIN_VOLUME_MAX_EDGE_V3 :: 64
TERRAIN_VOLUME_MAX_SAMPLES_V3 :: 300_000
// The terrace blend cannot reach 1 or a terraced slope would become a
// staircase of exactly vertical risers, which marching tetrahedra cannot
// represent without degenerate triangles.
TERRAIN_TERRACE_MAX_BLEND_V3 :: f32(0.45)

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
	mountain_terrace_step:     f32,
	floating_strength:         f32,
	floating_altitude_min:     f32,
	floating_altitude_max:     f32,
	floating_spacing:          f32,
	floating_radius:           f32,
	floating_thickness:        f32,
	floating_taper:            f32,
	floating_breakup:          f32,
	floating_jitter:           f32,
	floating_shape_strength:   f32,
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
	surface_uv_scale:          f32,
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
	landform:        f32,
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
		minimum_z               = -40,
		maximum_z               = 48,
		cell_size               = 2,
		ground_strength         = 1,
		surface_softness        = 1,
		mountain_scale          = 1,
		mountain_sharpness      = 1,
		mountain_terrace_step   = 4,
		floating_spacing        = 72,
		floating_radius         = 24,
		floating_thickness      = 10,
		floating_taper          = 1.5,
		floating_jitter         = 0.7,
		floating_shape_strength = 0.22,
		cave_threshold          = 0.62,
		cave_altitude_min       = -24,
		cave_altitude_max       = 24,
		cave_tunnel_scale       = 1,
		cave_chamber_scale      = 1,
		minimum_upward_normal   = 0.55,
		surface_search_min      = -40,
		surface_search_max      = 48,
		surface_uv_scale        = 32,
		overhang_noise          = {seed ~ 0x243F6A8885A308D3, 0.018, 4, 2, 0.5, 12},
		floating_shape_noise    = {seed ~ 0x13198A2E03707344, 0.012, 4, 2, 0.5, 18},
		floating_breakup_noise  = {seed ~ 0xA4093822299F31D0, 0.031, 3, 2, 0.5, 8},
		cave_tunnel_noise       = {seed ~ 0x082EFA98EC4E6C89, 0.035, 4, 2, 0.5, 10},
		cave_chamber_noise      = {seed ~ 0x452821E638D01377, 0.016, 3, 2, 0.5, 16},
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
	if recipe.surface.seed != recipe.seed do return false
	if !terrain_recipe_validate_v2(&recipe.surface) do return false
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
		p.mountain_terrace_step,
		p.floating_strength,
		p.floating_altitude_min,
		p.floating_altitude_max,
		p.floating_spacing,
		p.floating_radius,
		p.floating_thickness,
		p.floating_taper,
		p.floating_breakup,
		p.floating_jitter,
		p.floating_shape_strength,
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
		p.surface_uv_scale,
	}
	for value in values do if !_terrain_finite_v2(value) do return false
	if p.minimum_z >= p.maximum_z || p.cell_size <= 0 do return false
	if (p.maximum_z - p.minimum_z) / p.cell_size > TERRAIN_VOLUME_MAX_EDGE_V3 do return false
	if p.ground_strength <= 0 || p.surface_softness <= 0 do return false
	if p.overhang_strength < 0 || p.mountain_scale <= 0 || p.mountain_sharpness <= 0 do return false
	if p.mountain_terrace_strength < 0 || p.floating_strength < 0 do return false
	if p.mountain_terrace_step <= 0 do return false
	if p.floating_altitude_min > p.floating_altitude_max do return false
	if p.floating_spacing <= 0 || p.floating_radius <= 0 || p.floating_thickness <= 0 do return false
	if p.floating_taper <= 0 || p.floating_breakup < 0 || p.floating_breakup > 1 do return false
	if p.floating_jitter < 0 || p.floating_jitter > 1 do return false
	if p.floating_shape_strength < 0 do return false
	if p.cave_strength < 0 || p.cave_threshold < 0 || p.cave_threshold > 1 do return false
	if p.cave_altitude_min > p.cave_altitude_max do return false
	if p.cave_tunnel_scale <= 0 || p.cave_chamber_scale <= 0 || p.cave_warp < 0 do return false
	if p.minimum_upward_normal < 0 || p.minimum_upward_normal > 1 do return false
	if p.surface_search_min >= p.surface_search_max do return false
	if p.surface_uv_scale <= 0 do return false
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
	return terrain_density_prevalidated_v3(recipe, x, y, z)
}

// terrain_density_prevalidated_v3 skips the per-call recipe validation --
// which walks 31 floats, 16 biome profiles and 5 noise configs -- for callers
// that validate once and then sample millions of points. The recipe must
// already have passed `terrain_recipe_validate_v3`.
terrain_density_prevalidated_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y, z: f32) -> (f32, bool) {
	assert(recipe != nil, "terrain_density_prevalidated_v3: nil recipe")
	assert(recipe.parameters.cell_size > 0, "terrain_density_prevalidated_v3: unvalidated recipe")
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

// _terrain_shape_height_v3 applies the V3 mountain transform to a V2 base
// height. Three call sites need it -- the density column, the primary
// surface, and the surface's finite-difference neighbours -- and if they ever
// disagree the published `buildable` flag would describe a surface the volume
// mesh does not have.
@(private)
_terrain_shape_height_v3 :: proc(recipe: ^Terrain_Recipe_V3, base_height: f32) -> f32 {
	assert(recipe != nil, "_terrain_shape_height_v3: nil recipe")
	assert(recipe.parameters.mountain_terrace_step > 0, "_terrain_shape_height_v3: terrace step")
	p := recipe.parameters
	mountain := max(base_height - recipe.surface.land_height, 0)
	mountain = math.pow(mountain / max(recipe.surface.mountain_height, 1), p.mountain_sharpness)
	height := base_height + mountain * recipe.surface.mountain_height * (p.mountain_scale - 1)
	if p.mountain_terrace_strength > 0 && mountain > 0 {
		step := p.mountain_terrace_step
		terrace := math.floor(height / step + 0.5) * step
		blend := clamp(p.mountain_terrace_strength / step, 0, TERRAIN_TERRACE_MAX_BLEND_V3)
		height += (terrace - height) * blend
	}
	return height
}

@(private)
_terrain_ground_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	x, y: f32,
) -> (
	ground: _Terrain_Ground_V3,
	ok: bool,
) {
	assert(recipe != nil, "_terrain_ground_v3: nil recipe")
	base_height, _, ruggedness, height_ok := terrain_height_prevalidated_v2(&recipe.surface, x, y)
	if !height_ok do return {}, false
	return {_terrain_shape_height_v3(recipe, base_height), ruggedness}, true
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
	assert(recipe != nil, "_terrain_density_from_ground_v3: nil recipe")
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
	overhang := fractal_3d(p.overhang_noise, x, y, z)
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
	if !terrain_recipe_validate_v3(recipe) do return {}, false
	if step <= 0 || !_terrain_finite_v2(step) do return {}, false
	return terrain_primary_surface_prevalidated_v3(recipe, x, y, step)
}

// terrain_primary_surface_prevalidated_v3 skips the per-call recipe
// validation for callers that validate once and then sample millions of
// points (field bakes); recipe and step must already be validated.
terrain_primary_surface_prevalidated_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	x, y, step: f32,
) -> (
	Terrain_Surface_V3,
	bool,
) {
	assert(recipe != nil, "terrain_primary_surface_prevalidated_v3: nil recipe")
	sample, ok := terrain_sample_prevalidated_v2(&recipe.surface, x, y, step)
	if !ok do return {}, false
	p := recipe.parameters
	height := _terrain_shape_height_v3(recipe, sample.height)
	landform := _terrain_shape_height_v3(recipe, sample.landform)
	left, left_ok := _terrain_primary_height_v3(recipe, x - step, y)
	right, right_ok := _terrain_primary_height_v3(recipe, x + step, y)
	down, down_ok := _terrain_primary_height_v3(recipe, x, y - step)
	up, up_ok := _terrain_primary_height_v3(recipe, x, y + step)
	if !left_ok || !right_ok || !down_ok || !up_ok do return {}, false
	dx := (right.height - left.height) / (2 * step)
	dy := (up.height - down.height) / (2 * step)
	slope := math.sqrt(dx * dx + dy * dy)
	upward := 1 / math.sqrt(1 + slope * slope)
	// The mountain transform is non-linear, so the classification slope has
	// to come from shaped landform neighbours rather than from the V2 sample:
	// scaling a peak changes how steep it reads.
	landform_dx := (right.landform - left.landform) / (2 * step)
	landform_dy := (up.landform - down.landform) / (2 * step)
	landform_slope := math.sqrt(landform_dx * landform_dx + landform_dy * landform_dy)
	// Classification reads landform; slope, upward_normal and buildable stay
	// on the full height because they describe the surface a player walks on.
	biomes, biome_ok := terrain_biome_blend_prevalidated_v2(
		&recipe.surface,
		landform,
		sample.continentalness,
		sample.moisture,
		sample.temperature,
		landform_slope,
	)
	if !biome_ok do return {}, false
	return {
			height = height,
			landform = landform,
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

// _Terrain_Shaped_V3 is the shaped pair a neighbour probe produces. Both come
// from one V2 evaluation, so the landform derivatives the classification needs
// cost no extra noise over the height derivatives that were already taken.
@(private)
_Terrain_Shaped_V3 :: struct {
	height:   f32,
	landform: f32,
}

@(private)
_terrain_primary_height_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	x, y: f32,
) -> (
	_Terrain_Shaped_V3,
	bool,
) {
	assert(recipe != nil, "_terrain_primary_height_v3: nil recipe")
	terms, ok := terrain_height_terms_prevalidated_v2(&recipe.surface, x, y)
	if !ok do return {}, false
	return {
			_terrain_shape_height_v3(recipe, terms.height),
			_terrain_shape_height_v3(recipe, terms.landform),
		},
		true
}

@(private)
_terrain_floating_density_v3 :: proc(recipe: ^Terrain_Recipe_V3, x, y, z: f32) -> f32 {
	assert(recipe != nil, "_terrain_floating_density_v3: nil recipe")
	p := recipe.parameters
	cell_x := i64(math.floor(x / p.floating_spacing))
	cell_y := i64(math.floor(y / p.floating_spacing))
	// The shape fractal does not vary with the neighbour offset, so lifting it
	// here replaces nine four-octave stacks per sample with one. The breakup
	// fractal is equally invariant and the compiler lifts it unaided; lifting
	// it by hand changes which float multiply-adds get contracted, which made
	// optimised and unoptimised builds disagree on the emitted geometry.
	shape_noise := fractal_2d(p.floating_shape_noise, x, y)
	// A legitimate island reaches floating_strength * floating_thickness, so a
	// finite sentinel could be mistaken for one. Only -max(f32) cannot be.
	best := -max(f32)
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
			center_x :=
				(f32(cell_x + i64(offset_x)) + 0.5 + jitter_x * p.floating_jitter) *
				p.floating_spacing
			center_y :=
				(f32(cell_y + i64(offset_y)) + 0.5 + jitter_y * p.floating_jitter) *
				p.floating_spacing
			center_z :=
				p.floating_altitude_min +
				(p.floating_altitude_max - p.floating_altitude_min) * altitude_unit
			dx := (x - center_x) / p.floating_radius
			dy := (y - center_y) / p.floating_radius
			radial := math.sqrt(dx * dx + dy * dy)
			breakup := _terrain_unit(fractal_3d(p.floating_breakup_noise, x, y, z))
			shape := shape_noise * p.floating_shape_strength
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
	assert(recipe != nil, "_terrain_cave_signal_v3: nil recipe")
	p := recipe.parameters
	// Composing three 2D slices made every tunnel extrude along whichever axis
	// its slice omitted, which is the artefact a volumetric format exists to
	// avoid. Two independent 3D fields warp a third, so a tunnel can bend on
	// all three axes at once.
	warp_x := fractal_3d(p.cave_chamber_noise, y, z, x) * p.cave_warp
	warp_y := fractal_3d(p.cave_chamber_noise, z, x, y) * p.cave_warp
	tunnel_a := abs(fractal_3d(p.cave_tunnel_noise, x + warp_x, y, z + warp_y))
	tunnel_b := abs(fractal_3d(p.cave_tunnel_noise, x, y - warp_y, z + warp_x))
	tunnel := 1 - min(tunnel_a, tunnel_b) * p.cave_tunnel_scale
	chamber := _terrain_unit(fractal_3d(p.cave_chamber_noise, x, y, z))
	return clamp(max(tunnel, chamber * p.cave_chamber_scale), 0, 1)
}
