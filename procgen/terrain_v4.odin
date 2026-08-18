package procgen

import "core:math"

TERRAIN_RECIPE_VERSION_V4 :: u32(1)

Terrain_Preset_V4 :: enum u8 {
	Normal,
	Custom,
}

Terrain_Parameters_V4 :: struct {
	radius:                       f32,
	height_scale:                 f32,
	minimum_radius:               f32,
	maximum_radius:               f32,
	derivative_step:              f32,
	minimum_upward_normal:        f32,
	latitude_offset_radians:      f32,
	latitude_half_extent_radians: f32,
}

Terrain_Recipe_V4 :: struct {
	version:    u32,
	preset:     Terrain_Preset_V4,
	seed:       u64,
	surface:    Terrain_Recipe_V2,
	parameters: Terrain_Parameters_V4,
}

Terrain_Height_Terms_V4 :: struct {
	height:          f32,
	landform:        f32,
	continentalness: f32,
	ruggedness:      f32,
}

Terrain_Surface_V4 :: struct {
	radius:          f32,
	height:          f32,
	landform:        f32,
	slope:           f32,
	landform_slope:  f32,
	upward_normal:   f32,
	latitude:        f32,
	continentalness: f32,
	ruggedness:      f32,
	moisture:        f32,
	temperature:     f32,
	buildable:       bool,
	biomes:          Terrain_Biome_Blend_V2,
}

Terrain_Face_V4 :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

terrain_normal_recipe_v4 :: proc(seed: u64) -> Terrain_Recipe_V4 {
	surface := terrain_default_recipe_v2(seed)
	return Terrain_Recipe_V4 {
		version = TERRAIN_RECIPE_VERSION_V4,
		preset = .Normal,
		seed = seed,
		surface = surface,
		parameters = {
			radius = 1080,
			height_scale = 1,
			minimum_radius = 1024,
			maximum_radius = 1152,
			derivative_step = 2,
			minimum_upward_normal = 0.55,
			latitude_offset_radians = 0,
			latitude_half_extent_radians = math.PI / 2,
		},
	}
}

terrain_custom_recipe_v4 :: proc(
	seed: u64,
	parameters: Terrain_Parameters_V4,
) -> (
	Terrain_Recipe_V4,
	bool,
) {
	recipe := Terrain_Recipe_V4 {
		version    = TERRAIN_RECIPE_VERSION_V4,
		preset     = .Custom,
		seed       = seed,
		surface    = terrain_default_recipe_v2(seed),
		parameters = parameters,
	}
	return recipe, terrain_recipe_validate_v4(&recipe)
}

terrain_recipe_validate_v4 :: proc(recipe: ^Terrain_Recipe_V4) -> bool {
	if recipe == nil || recipe.version != TERRAIN_RECIPE_VERSION_V4 do return false
	if recipe.surface.seed != recipe.seed do return false
	if !terrain_recipe_validate_v2(&recipe.surface) do return false
	p := recipe.parameters
	values := [?]f32 {
		p.radius,
		p.height_scale,
		p.minimum_radius,
		p.maximum_radius,
		p.derivative_step,
		p.minimum_upward_normal,
		p.latitude_offset_radians,
		p.latitude_half_extent_radians,
	}
	for value in values do if !_terrain_finite_v2(value) do return false
	if p.radius <= 0 || p.height_scale <= 0 do return false
	if p.minimum_radius <= 0 || p.minimum_radius >= p.maximum_radius do return false
	if p.radius < p.minimum_radius || p.radius > p.maximum_radius do return false
	if p.derivative_step <= 0 || p.derivative_step >= p.radius do return false
	if p.minimum_upward_normal < 0 || p.minimum_upward_normal > 1 do return false
	if abs(p.latitude_offset_radians) > math.PI / 2 do return false
	half := p.latitude_half_extent_radians
	if half <= 0 || half > math.PI / 2 do return false
	if recipe.surface.latitude_offset != 0 do return false
	return true
}

terrain_height_terms_prevalidated_v4 :: proc(
	recipe: ^Terrain_Recipe_V4,
	direction: [3]f32,
) -> (
	Terrain_Height_Terms_V4,
	bool,
) {
	assert(recipe != nil, "terrain_height_terms_prevalidated_v4: nil recipe")
	if !_terrain_direction_valid_v4(direction) do return {}, false
	surface := &recipe.surface
	position := direction * recipe.parameters.radius
	continentalness := _terrain_contrast_v2(
		_terrain_unit(fractal_3d(surface.continental_noise, position.x, position.y, position.z)),
		surface.continental_contrast,
	)
	land := _terrain_smoothstep_v2(
		surface.coast_threshold - surface.coast_fade,
		surface.coast_threshold + surface.coast_fade,
		continentalness,
	)
	coast := fractal_3d(surface.hill_noise, position.x, position.y, position.z)
	land = clamp(land + coast * surface.coast_jitter, 0, 1)
	mountain := _terrain_unit(
		warped_fractal_3d(surface.mountain_noise, position.x, position.y, position.z),
	)
	uplift :=
		_terrain_smoothstep_v2(
			surface.mountain_threshold - surface.mountain_fade,
			surface.mountain_threshold + surface.mountain_fade,
			mountain,
		) *
		land
	ridge_noise := warped_fractal_3d(surface.ridge_noise, position.x, position.y, position.z)
	ridge := math.pow(clamp(1 - abs(ridge_noise), 0, 1), surface.ridge_power)
	hills := warped_fractal_3d(surface.hill_noise, position.x, position.y, position.z)
	detail := fractal_3d(surface.detail_noise, position.x, position.y, position.z)
	base := -surface.ocean_depth + (surface.ocean_depth + surface.land_height) * land
	relief := surface.base_height + base + ridge * uplift * surface.mountain_height
	basin := _terrain_basin_blend_v4(surface, position, land, uplift)
	lake_floor := surface.sea_level - surface.basin_depth
	height := relief + hills * surface.hill_height * land + detail * surface.detail_height * land
	height += (lake_floor - height) * basin
	landform := relief + (lake_floor - relief) * basin
	scale := recipe.parameters.height_scale
	ruggedness := clamp(uplift * 0.7 + ridge * 0.3, 0, 1)
	return {height * scale, landform * scale, continentalness, ruggedness}, true
}

terrain_primary_surface_v4 :: proc(
	recipe: ^Terrain_Recipe_V4,
	direction: [3]f32,
) -> (
	Terrain_Surface_V4,
	bool,
) {
	if !terrain_recipe_validate_v4(recipe) do return {}, false
	return terrain_primary_surface_prevalidated_v4(recipe, direction)
}

terrain_primary_surface_prevalidated_v4 :: proc(
	recipe: ^Terrain_Recipe_V4,
	direction: [3]f32,
) -> (
	Terrain_Surface_V4,
	bool,
) {
	assert(recipe != nil, "terrain_primary_surface_prevalidated_v4: nil recipe")
	center, ok := terrain_height_terms_prevalidated_v4(recipe, direction)
	if !ok do return {}, false
	up, east, north := terrain_face_basis_v4(direction)
	step := recipe.parameters.derivative_step
	angle := step / recipe.parameters.radius
	d_east_neg := _terrain_tangent_step_v4(up, east, -angle)
	d_east_pos := _terrain_tangent_step_v4(up, east, angle)
	d_north_neg := _terrain_tangent_step_v4(up, north, -angle)
	d_north_pos := _terrain_tangent_step_v4(up, north, angle)
	left, left_ok := terrain_height_terms_prevalidated_v4(recipe, d_east_neg)
	right, right_ok := terrain_height_terms_prevalidated_v4(recipe, d_east_pos)
	down, down_ok := terrain_height_terms_prevalidated_v4(recipe, d_north_neg)
	top, top_ok := terrain_height_terms_prevalidated_v4(recipe, d_north_pos)
	if !left_ok || !right_ok || !down_ok || !top_ok do return {}, false
	dx := (right.height - left.height) / (2 * step)
	dy := (top.height - down.height) / (2 * step)
	landform_x := (right.landform - left.landform) / (2 * step)
	landform_y := (top.landform - down.landform) / (2 * step)
	slope := math.sqrt(dx * dx + dy * dy)
	landform_slope := math.sqrt(landform_x * landform_x + landform_y * landform_y)
	moisture, temperature, latitude := _terrain_climate_v4(recipe, direction, center)
	biomes, biome_ok := terrain_biome_blend_prevalidated_v2(
		&recipe.surface,
		center.landform,
		center.continentalness,
		moisture,
		temperature,
		landform_slope,
	)
	if !biome_ok do return {}, false
	upward := 1 / math.sqrt(1 + slope * slope)
	radius := recipe.parameters.radius + center.height
	return {
			radius = radius,
			height = center.height,
			landform = center.landform,
			slope = slope,
			landform_slope = landform_slope,
			upward_normal = upward,
			latitude = latitude,
			continentalness = center.continentalness,
			ruggedness = center.ruggedness,
			moisture = moisture,
			temperature = temperature,
			buildable = radius >= recipe.parameters.minimum_radius &&
			radius <= recipe.parameters.maximum_radius &&
			upward >= recipe.parameters.minimum_upward_normal,
			biomes = biomes,
		},
		true
}

@(private)
_terrain_basin_blend_v4 :: proc(
	recipe: ^Terrain_Recipe_V2,
	position: [3]f32,
	land, uplift: f32,
) -> f32 {
	assert(recipe != nil, "_terrain_basin_blend_v4: nil recipe")
	assert(recipe.basin_fade > 0, "_terrain_basin_blend_v4: non-positive fade")
	if recipe.basin_depth <= 0 do return 0
	gate := land * (1 - uplift)
	if gate <= 0 do return 0
	signal := _terrain_unit(
		warped_fractal_3d(recipe.basin_noise, position.x, position.y, position.z),
	)
	return(
		_terrain_smoothstep_v2(
			recipe.basin_threshold - recipe.basin_fade,
			recipe.basin_threshold + recipe.basin_fade,
			signal,
		) *
		gate \
	)
}

@(private)
_terrain_climate_v4 :: proc(
	recipe: ^Terrain_Recipe_V4,
	direction: [3]f32,
	terms: Terrain_Height_Terms_V4,
) -> (
	moisture, temperature, latitude: f32,
) {
	assert(recipe != nil, "_terrain_climate_v4: nil recipe")
	surface := &recipe.surface
	position := direction * recipe.parameters.radius
	moisture = _terrain_contrast_v2(
		_terrain_unit(
			warped_fractal_3d(surface.moisture_noise, position.x, position.y, position.z),
		),
		surface.climate_contrast,
	)
	coast_dist := abs(terms.continentalness - surface.coast_threshold)
	coast_bias := 1 - coast_dist / max(surface.coast_fade * 3, 0.001)
	moisture = clamp(moisture + clamp(coast_bias, 0, 1) * 0.12 - terms.ruggedness * 0.08, 0, 1)
	moisture = clamp(moisture + surface.moisture_bias, 0, 1)
	noise := _terrain_contrast_v2(
		_terrain_unit(
			warped_fractal_3d(surface.temperature_noise, position.x, position.y, position.z),
		),
		surface.climate_contrast,
	)
	latitude = math.asin(clamp(direction.z, -1, 1))
	latitude_distance := abs(latitude - recipe.parameters.latitude_offset_radians)
	latitude_unit := clamp(
		latitude_distance / recipe.parameters.latitude_half_extent_radians,
		0,
		1,
	)
	temperature =
		noise * (1 - surface.latitude_weight) + (1 - latitude_unit) * surface.latitude_weight
	lapse := max(terms.height - surface.sea_level, 0) * surface.elevation_lapse
	temperature = clamp(temperature - lapse, 0, 1)
	temperature = clamp(temperature + surface.temperature_bias, 0, 1)
	return
}

@(private)
_terrain_tangent_step_v4 :: proc(direction, tangent: [3]f32, angle: f32) -> [3]f32 {
	assert(_terrain_dot_v4(direction, direction) > 0, "_terrain_tangent_step_v4: zero direction")
	assert(_terrain_dot_v4(tangent, tangent) > 0, "_terrain_tangent_step_v4: zero tangent")
	return _terrain_normalize_v4(direction * math.cos(angle) + tangent * math.sin(angle))
}

@(private)
_terrain_direction_valid_v4 :: proc(direction: [3]f32) -> bool {
	length_squared := _terrain_dot_v4(direction, direction)
	return _terrain_finite_v2(length_squared) && abs(length_squared - 1) <= 0.0001
}

terrain_face_direction_v4 :: proc(face: Terrain_Face_V4, u, v: f32) -> [3]f32 {
	assert(u >= -1 && u <= 1, "terrain_face_direction_v4: u outside face")
	assert(v >= -1 && v <= 1, "terrain_face_direction_v4: v outside face")
	a := math.tan(u * math.PI / 4)
	b := math.tan(v * math.PI / 4)
	direction: [3]f32
	switch face {
	case .Pos_X:
		direction = {1, b, -a}
	case .Neg_X:
		direction = {-1, b, a}
	case .Pos_Y:
		direction = {a, 1, -b}
	case .Neg_Y:
		direction = {a, -1, b}
	case .Pos_Z:
		direction = {a, b, 1}
	case .Neg_Z:
		direction = {-a, b, -1}
	}
	return _terrain_normalize_v4(direction)
}

terrain_face_locate_v4 :: proc(direction: [3]f32) -> (Terrain_Face_V4, f32, f32) {
	length_squared := _terrain_dot_v4(direction, direction)
	if !_terrain_finite_v2(length_squared) || length_squared <= 0 do return .Pos_X, 0, 0
	x, y, z := direction.x, direction.y, direction.z
	ax, ay, az := abs(x), abs(y), abs(z)
	face: Terrain_Face_V4
	a, b: f32
	if ax >= ay && ax >= az {
		if x >= 0 {
			face, a, b = .Pos_X, -z / ax, y / ax
		} else {
			face, a, b = .Neg_X, z / ax, y / ax
		}
	} else if ay >= az {
		if y >= 0 {
			face, a, b = .Pos_Y, x / ay, -z / ay
		} else {
			face, a, b = .Neg_Y, x / ay, z / ay
		}
	} else if z >= 0 {
		face, a, b = .Pos_Z, x / az, y / az
	} else {
		face, a, b = .Neg_Z, -x / az, y / az
	}
	return face, math.atan(a) * 4 / math.PI, math.atan(b) * 4 / math.PI
}

terrain_face_basis_v4 :: proc(direction: [3]f32) -> (up, east, north: [3]f32) {
	length_squared := _terrain_dot_v4(direction, direction)
	assert(length_squared > 0, "terrain_face_basis_v4: zero direction")
	up = _terrain_normalize_v4(direction)
	reference := [3]f32{0, 0, 1}
	if abs(up.z) > 0.9 do reference = {0, 1, 0}
	east = _terrain_normalize_v4(_terrain_cross_v4(reference, up))
	north = _terrain_cross_v4(up, east)
	return
}

@(private)
_terrain_dot_v4 :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

@(private)
_terrain_cross_v4 :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

@(private)
_terrain_normalize_v4 :: proc(value: [3]f32) -> [3]f32 {
	length_squared := _terrain_dot_v4(value, value)
	assert(length_squared > 0, "_terrain_normalize_v4: zero vector")
	inverse_length := 1 / math.sqrt(length_squared)
	return value * inverse_length
}
