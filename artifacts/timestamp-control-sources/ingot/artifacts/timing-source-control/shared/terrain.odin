package shared

import procgen "ingot:procgen"

TERRAIN_PROFILE_ID :: u32(6)
// Relief, climate and the land/sea split are all archetype-driven now; what
// remains here is the shape of the V3 mountain transform, which is a
// rendering decision rather than a world-kind one. The scale is what makes a
// peak read as a peak rather than a hill, and it multiplies the archetype's
// mountain height, so the two are bounded together against maximum_z.
TERRAIN_MOUNTAIN_SCALE :: f32(1.8)
TERRAIN_MOUNTAIN_SHARPNESS :: f32(1.35)
TERRAIN_FLOATING_SPACING :: f32(112)
TERRAIN_FLOATING_RADIUS :: f32(8)
TERRAIN_FLOATING_THICKNESS :: f32(5)
TERRAIN_FLOATING_BREAKUP :: f32(0.5)

// Cave/volumetric tuning on the sphere. The abstract recipe's density
// function is agnostic to what its third axis means: terraforger reads it as
// world-vertical Z, planetforger reads it as *radial depth* — signed height
// above (positive) or below (negative) the planet's mean surface, in world
// units, exactly the axis the heightfield's base_height already lives on. So
// caves carve a radial shell around the surface and the recipe's volume band
// is a radial band, mirroring terraforger's flat volume with Z reinterpreted
// as the surface normal. Values track terraforger's proven cave shape; the
// ceiling stays above the tallest shaped peak so summits are not clipped —
// with PLANET_MOUNTAIN_BOOST peaks reach ~72 units before the terraform
// delta, so the ceiling carries that plus headroom.
TERRAIN_CAVE_STRENGTH :: f32(10)
TERRAIN_CAVE_THRESHOLD :: f32(0.52)
TERRAIN_CAVE_RADIAL_MIN :: f32(-36)
TERRAIN_CAVE_RADIAL_MAX :: f32(36)
TERRAIN_CAVE_TUNNEL_SCALE :: f32(1.3)
TERRAIN_CAVE_CHAMBER_SCALE :: f32(1.2)
TERRAIN_CAVE_WARP :: f32(12)
TERRAIN_VOLUME_RADIAL_MIN :: f32(-56)
TERRAIN_VOLUME_RADIAL_MAX :: f32(112)
TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M :: f32(6.5)

// _terrain_recipe_model_tune maps the abstract recipe's third axis onto the
// planet's radial depth: caves carve the RADIAL_MIN..RADIAL_MAX shell and the
// volume/search band spans TERRAIN_VOLUME_RADIAL_MIN..MAX around the mean
// surface. This unifies the world-model recipe with terraforger's flat volume
// (Z reinterpreted as the radial axis). The V4 surface renderer draws the
// analytic skin; displaying the carved shell radially is a scoped follow-up
// once the engine grows a spherical volume sampler (see AGENTS.md).
_terrain_recipe_model_tune :: proc(parameters: ^procgen.Terrain_Parameters_V3) {
	parameters.cave_strength = TERRAIN_CAVE_STRENGTH
	parameters.cave_threshold = TERRAIN_CAVE_THRESHOLD
	parameters.cave_altitude_min = TERRAIN_CAVE_RADIAL_MIN
	parameters.cave_altitude_max = TERRAIN_CAVE_RADIAL_MAX
	parameters.cave_tunnel_scale = TERRAIN_CAVE_TUNNEL_SCALE
	parameters.cave_chamber_scale = TERRAIN_CAVE_CHAMBER_SCALE
	parameters.cave_warp = TERRAIN_CAVE_WARP
	// Fissures are explicitly disabled: the abstract recipe ships them on
	// by default, and an ingot pin bump must never be able to switch a
	// worldgen feature on silently.
	parameters.fissure_strength = 0
	parameters.minimum_z = TERRAIN_VOLUME_RADIAL_MIN
	parameters.maximum_z = TERRAIN_VOLUME_RADIAL_MAX
	parameters.surface_search_min = TERRAIN_VOLUME_RADIAL_MIN
	parameters.surface_search_max = TERRAIN_VOLUME_RADIAL_MAX
}

terrain_base_height_fixed_at_coord :: proc(world: ^World, coord: Planet_Coord) -> i16 {
	assert(world != nil, "terrain_base_height_fixed_at_coord: nil world")
	assert(planet_coord_valid(coord), "terrain_base_height_fixed_at_coord: invalid coordinate")
	index := planet_index(coord)
	return i16(clamp(
		i32(world.foundation.base_height[index]) + i32(world.foundation.tectonic_delta[index]),
		i32(min(i16)),
		i32(max(i16)),
	))
}

terrain_height_fixed_at_coord :: proc(world: ^World, coord: Planet_Coord) -> i32 {
	assert(world != nil, "terrain_height_fixed_at_coord: nil world")
	assert(planet_coord_valid(coord), "terrain_height_fixed_at_coord: invalid coordinate")
	index := planet_index(coord)
	return i32(world.foundation.base_height[index]) +
		i32(world.foundation.tectonic_delta[index]) +
		i32(world.heightfield.deltas[index])
}

terrain_sample_at_coord :: proc(world: ^World, coord: Planet_Coord) -> Terrain_Sample {
	assert(world != nil, "terrain_sample_at_coord: nil world")
	assert(planet_coord_valid(coord), "terrain_sample_at_coord: invalid coordinate")
	index := planet_index(coord)
	climate_index := planetary_sample_index(planet_direction(coord))
	return {
		height = f32(terrain_height_fixed_at_coord(world, coord)) / f32(HEIGHT_DELTA_SCALE),
		moisture = f32(world.planetary.climate.vapour[climate_index]) / f32(CLIMATE_MAX_WATER),
		temperature = clamp(
			(f32(world.planetary.climate.temperature[climate_index]) /
					f32(PLANET_TEMPERATURE_SCALE) -
				220) /
			110,
			0,
			1,
		),
		continentalness = f32(world.foundation.continentalness[index]) / 255,
		ruggedness = f32(world.foundation.ruggedness[index]) / 255,
		slope = f32(world.foundation.slope[index]) / TERRAIN_SLOPE_SCALE,
		primary_biome = world.foundation.primary_biome[index],
		secondary_biome = world.foundation.secondary_biome[index],
		primary_weight = f32(world.foundation.primary_weight[index]) / 255,
	}
}

Terrain_Surface_Class :: enum u8 {
	Biome,
	Rock,
	Snow,
	Sea_Ice,
}

Terrain_Surface_State :: struct {
	sim_index:             int,
	latitude_microdegrees: i32,
	base_biome:            Biome_Id,
	air_temperature_mk:    i32,
	surface_temperature_mk: i32,
	precipitation:         u32,
	stored_snow:           u32,
	sea_ice:               u32,
	snow_cover:            f32,
	surface_class:         Terrain_Surface_Class,
	revision:              u64,
}

terrain_surface_snow_cover :: proc(
	height: f32,
	snow_level: f32,
	surface_temperature_mk: i32,
	stored_snow: u32,
) -> f32 {
	elevation_cover := clamp((height - snow_level + 1.5) / 3, 0, 1)
	cold_cover := clamp(f32(276 * PLANET_TEMPERATURE_SCALE - surface_temperature_mk) / 12_000, 0, 1)
	stored_cover := clamp(f32(stored_snow) / 500_000, 0, 1)
	return clamp(max(stored_cover, elevation_cover * cold_cover), 0, 1)
}

terrain_surface_state_at_coord :: proc(world: ^World, coord: Planet_Coord) -> Terrain_Surface_State {
	assert(world != nil, "terrain_surface_state_at_coord: nil world")
	assert(planet_coord_valid(coord), "terrain_surface_state_at_coord: invalid coordinate")
	terrain_index := planet_index(coord)
	direction := planet_direction(coord)
	sim_index := planetary_sample_index(direction)
	height := terrain_height_at_coord(world, coord)
	air_temperature := world.planetary.climate.temperature[sim_index]
	sea_level := f32(world.foundation.sea_level) / f32(HEIGHT_DELTA_SCALE)
	altitude_m := max(height - sea_level, f32(0))
	lapse_mk := i32(altitude_m * TERRAIN_ENVIRONMENTAL_LAPSE_MK_PER_M)
	surface_temperature := clamp(
		air_temperature - lapse_mk,
		PLANET_MIN_TEMPERATURE,
		PLANET_MAX_TEMPERATURE,
	)
	snow_level := f32(world.foundation.snow_level) / f32(HEIGHT_DELTA_SCALE)
	snow_cover := terrain_surface_snow_cover(
		height,
		snow_level,
		surface_temperature,
		world.planetary.climate.snow[sim_index],
	)
	sea_ice := world.planetary.climate.sea_ice[sim_index]
	surface_class := Terrain_Surface_Class.Biome
	if sea_ice > 100_000 && world.planetary.ocean.mean_depth_mm[sim_index] > 0 {
		surface_class = .Sea_Ice
	} else if snow_cover >= 0.5 {
		surface_class = .Snow
	} else if world.foundation.primary_biome[terrain_index] == .Mountain {
		surface_class = .Rock
	}
	return {
		sim_index = sim_index,
		latitude_microdegrees = world.planetary.grid.latitude_microdegrees[sim_index],
		base_biome = world.foundation.primary_biome[terrain_index],
		air_temperature_mk = air_temperature,
		surface_temperature_mk = surface_temperature,
		precipitation = world.planetary.climate.precipitation[sim_index],
		stored_snow = world.planetary.climate.snow[sim_index],
		sea_ice = sea_ice,
		snow_cover = snow_cover,
		surface_class = surface_class,
		revision = world.planetary.climate.surface_revision,
	}
}

terrain_height_at_coord :: proc(world: ^World, coord: Planet_Coord) -> f32 {
	assert(world != nil, "terrain_height_at_coord: nil world")
	assert(planet_coord_valid(coord), "terrain_height_at_coord: invalid coordinate")
	return f32(terrain_height_fixed_at_coord(world, coord)) / f32(HEIGHT_DELTA_SCALE)
}

planet_placement_allowed :: proc(world: ^World, coord: Planet_Coord) -> bool {
	assert(world != nil, "planet_placement_allowed: nil world")
	if !planet_coord_valid(coord) do return false
	index := planet_index(coord)
	if world.waterfield.depths[index] >= WATER_WET_THRESHOLD do return false
	if !world.foundation.buildable[index] do return false
	height := i64(terrain_height_fixed_at_coord(world, coord))
	neighbour_u := planet_neighbour(coord, 1, 0)
	neighbour_v := planet_neighbour(coord, 0, 1)
	diff_u := i64(terrain_height_fixed_at_coord(world, neighbour_u)) - height
	diff_v := i64(terrain_height_fixed_at_coord(world, neighbour_v)) - height
	rise_squared := diff_u * diff_u + diff_v * diff_v
	run := f32(GRID_CELL_SIZE * f32(HEIGHT_DELTA_SCALE))
	limit_squared := i64(PLACEMENT_MAX_SLOPE * run * PLACEMENT_MAX_SLOPE * run)
	return rise_squared <= limit_squared
}

// terrain_sample / terrain_height are face-local helpers: world_x/world_y
// are face-plane offsets in world units (grid coordinate * GRID_CELL_SIZE).
// Callers that know their face pass it; legacy flat-world systems default
// to the spawn face.
terrain_sample :: proc(
	world: ^World,
	world_x, world_y: f32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> Terrain_Sample {
	assert(world != nil, "terrain_sample: nil world")
	coord := _face_local_to_planet_coord(world_x, world_y, face)
	return terrain_sample_at_coord(world, coord)
}

terrain_height :: proc(
	world: ^World,
	world_x, world_y: f32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> f32 {
	assert(world != nil, "terrain_height: nil world")
	coord := _face_local_to_planet_coord(world_x, world_y, face)
	return terrain_height_at_coord(world, coord)
}

// terrain_sample_at_direction resolves an arbitrary sphere direction to its
// owning cell.
terrain_sample_at_direction :: proc(world: ^World, direction: [3]f32) -> Terrain_Sample {
	assert(world != nil, "terrain_sample_at_direction: nil world")
	return terrain_sample_at_coord(world, planet_coord_from_direction(direction))
}

terrain_height_at_direction :: proc(world: ^World, direction: [3]f32) -> f32 {
	assert(world != nil, "terrain_height_at_direction: nil world")
	return terrain_height_at_coord(world, planet_coord_from_direction(direction))
}

// planet_coord_from_direction snaps a sphere direction to the nearest cell.
planet_coord_from_direction :: proc(direction: [3]f32) -> Planet_Coord {
	face, located_u, located_v := planet_locate(direction)
	limit := f32(PLANET_FACE_CELLS)
	return {face, i32(clamp(located_u + 0.5, 0, limit)), i32(clamp(located_v + 0.5, 0, limit))}
}

placement_allowed :: proc(
	world: ^World,
	grid_x, grid_y: i32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> bool {
	assert(world != nil, "placement_allowed: nil world")
	coord := Planet_Coord{face, grid_x, grid_y}
	return planet_placement_allowed(world, coord)
}

grid_in_world :: proc(grid_x, grid_y: i32) -> bool {
	return(
		grid_x >= 0 &&
		grid_x < PLANET_FACE_RESOLUTION &&
		grid_y >= 0 &&
		grid_y < PLANET_FACE_RESOLUTION \
	)
}

@(private)
_terrain_seed_hash :: proc(seed, attempt: u64) -> u64 {
	value := seed ~ (attempt + 1) * 0x9E3779B185EBCA87
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

@(private)
_face_local_to_planet_coord :: proc(
	world_x, world_y: f32,
	face: procgen.Terrain_Face_V4,
) -> Planet_Coord {
	u := clamp(i32(world_x / GRID_CELL_SIZE), 0, i32(PLANET_FACE_CELLS))
	v := clamp(i32(world_y / GRID_CELL_SIZE), 0, i32(PLANET_FACE_CELLS))
	return {face, u, v}
}

@(private)
_terrain_index :: proc(vertex_x, vertex_y: i32) -> int {
	assert(vertex_x >= 0 && vertex_x < HEIGHTFIELD_RESOLUTION, "terrain index x out of range")
	assert(vertex_y >= 0 && vertex_y < HEIGHTFIELD_RESOLUTION, "terrain index y out of range")
	return int(vertex_y) * HEIGHTFIELD_RESOLUTION + int(vertex_x)
}

@(private)
_terrain_index_safe :: proc(values_len: int, vertex_x, vertex_y: i32) -> int {
	index := int(vertex_y) * HEIGHTFIELD_RESOLUTION + int(vertex_x)
	return clamp(index, 0, values_len - 1)
}

@(private)
_terrain_unit_to_u8 :: proc(value: f32) -> u8 {
	return u8(clamp(value * 255 + 0.5, 0, 255))
}

@(private)
_terrain_bilinear_i16 :: proc(
	values: []i16,
	column, row: i32,
	fraction_x, fraction_y: f32,
) -> f32 {
	assert(
		len(values) == TERRAIN_FIELD_CELLS || len(values) == PLANET_FIELD_CELLS,
		"terrain i16 field size mismatch",
	)
	n := len(values)
	return _terrain_bilinear_values(
		f32(values[_terrain_index_safe(n, column, row)]),
		f32(values[_terrain_index_safe(n, column + 1, row)]),
		f32(values[_terrain_index_safe(n, column, row + 1)]),
		f32(values[_terrain_index_safe(n, column + 1, row + 1)]),
		fraction_x,
		fraction_y,
	)
}

@(private)
_terrain_bilinear_u8 :: proc(values: []u8, column, row: i32, fraction_x, fraction_y: f32) -> f32 {
	assert(
		len(values) == TERRAIN_FIELD_CELLS || len(values) == PLANET_FIELD_CELLS,
		"terrain u8 field size mismatch",
	)
	n := len(values)
	return _terrain_bilinear_values(
		f32(values[_terrain_index_safe(n, column, row)]),
		f32(values[_terrain_index_safe(n, column + 1, row)]),
		f32(values[_terrain_index_safe(n, column, row + 1)]),
		f32(values[_terrain_index_safe(n, column + 1, row + 1)]),
		fraction_x,
		fraction_y,
	)
}

@(private)
_terrain_bilinear_u16 :: proc(
	values: []u16,
	column, row: i32,
	fraction_x, fraction_y: f32,
) -> f32 {
	assert(
		len(values) == TERRAIN_FIELD_CELLS || len(values) == PLANET_FIELD_CELLS,
		"terrain u16 field size mismatch",
	)
	n := len(values)
	return _terrain_bilinear_values(
		f32(values[_terrain_index_safe(n, column, row)]),
		f32(values[_terrain_index_safe(n, column + 1, row)]),
		f32(values[_terrain_index_safe(n, column, row + 1)]),
		f32(values[_terrain_index_safe(n, column + 1, row + 1)]),
		fraction_x,
		fraction_y,
	)
}

@(private)
_terrain_bilinear_values :: proc(
	low_left, low_right, high_left, high_right, fraction_x, fraction_y: f32,
) -> f32 {
	low := low_left * (1 - fraction_x) + low_right * fraction_x
	high := high_left * (1 - fraction_x) + high_right * fraction_x
	return low * (1 - fraction_y) + high * fraction_y
}
