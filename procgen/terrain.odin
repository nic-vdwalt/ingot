package procgen

import "core:math"
import "ingot:asset"

TERRAIN_CHUNK_QUADS :: 32
TERRAIN_CHUNK_VERTICES :: (TERRAIN_CHUNK_QUADS + 1) * (TERRAIN_CHUNK_QUADS + 1)
TERRAIN_CHUNK_INDICES :: TERRAIN_CHUNK_QUADS * TERRAIN_CHUNK_QUADS * 6
TERRAIN_MAX_PLACEMENTS :: 256

Biome :: enum u8 {
	Water,
	Beach,
	Grassland,
	Forest,
	Rock,
	Snow,
}

Terrain_Config :: struct {
	seed:              u64,
	chunk_world_size:  f32,
	height_scale:      f32,
	sea_level:         f32,
	snow_level:        f32,
	placement_spacing: f32,
	height_noise:      Noise_Config,
	moisture_noise:    Noise_Config,
	temperature_noise: Noise_Config,
}

Terrain_Sample :: struct {
	height:      f32,
	moisture:    f32,
	temperature: f32,
	slope:       f32,
	biome:       Biome,
}

Placement :: struct {
	position: [3]f32,
	normal:   [3]f32,
	scale:    f32,
	rotation: f32,
	biome:    Biome,
	variant:  u16,
}

Terrain_Chunk :: struct {
	mesh:            asset.Mesh_Buffer,
	placements:      [TERRAIN_MAX_PLACEMENTS]Placement,
	placement_count: u16,
	chunk_x:         i32,
	chunk_y:         i32,
	lod:             u8,
}

terrain_default_config :: proc(seed: u64) -> Terrain_Config {
	return {
		seed = seed,
		chunk_world_size = 64,
		height_scale = 18,
		sea_level = -2,
		snow_level = 12,
		placement_spacing = 4,
		height_noise = {seed, 0.006, 6, 2, 0.5, 18},
		moisture_noise = {seed ~ 0xA0761D6478BD642F, 0.004, 4, 2, 0.5, 8},
		temperature_noise = {seed ~ 0xE7037ED1A0B428DB, 0.002, 3, 2, 0.5, 4},
	}
}

terrain_sample :: proc(config: Terrain_Config, world_x, world_y: f32) -> Terrain_Sample {
	assert(config.height_scale > 0, "terrain_sample: non-positive height scale")
	height := warped_fractal_2d(config.height_noise, world_x, world_y) * config.height_scale
	moisture := _terrain_unit(fractal_2d(config.moisture_noise, world_x, world_y))
	temperature := _terrain_unit(fractal_2d(config.temperature_noise, world_x, world_y))
	step := config.chunk_world_size / f32(TERRAIN_CHUNK_QUADS)
	height_x :=
		warped_fractal_2d(config.height_noise, world_x + step, world_y) * config.height_scale
	height_y :=
		warped_fractal_2d(config.height_noise, world_x, world_y + step) * config.height_scale
	slope :=
		math.sqrt(
			(height_x - height) * (height_x - height) + (height_y - height) * (height_y - height),
		) /
		step
	biome := terrain_biome(config, height, moisture, temperature, slope)
	return {height, moisture, temperature, slope, biome}
}

terrain_generate_chunk :: proc(config: Terrain_Config, chunk: ^Terrain_Chunk) -> bool {
	assert(chunk != nil, "terrain_generate_chunk: nil chunk")
	assert(config.chunk_world_size > 0, "terrain_generate_chunk: invalid chunk size")
	if len(chunk.mesh.vertices) < TERRAIN_CHUNK_VERTICES do return false
	if len(chunk.mesh.indices) < TERRAIN_CHUNK_INDICES do return false
	asset.mesh_reset(&chunk.mesh)
	chunk.placement_count = 0
	step := config.chunk_world_size / f32(TERRAIN_CHUNK_QUADS)
	origin_x := f32(chunk.chunk_x) * config.chunk_world_size
	origin_y := f32(chunk.chunk_y) * config.chunk_world_size
	minimum := asset.Vec3{origin_x, origin_y, f32(3.402823466e+38)}
	maximum := asset.Vec3 {
		origin_x + config.chunk_world_size,
		origin_y + config.chunk_world_size,
		f32(-3.402823466e+38),
	}
	for row in 0 ..= TERRAIN_CHUNK_QUADS {
		for column in 0 ..= TERRAIN_CHUNK_QUADS {
			world_x := origin_x + f32(column) * step
			world_y := origin_y + f32(row) * step
			sample := terrain_sample(config, world_x, world_y)
			normal := _terrain_normal(config, world_x, world_y, step)
			index := row * (TERRAIN_CHUNK_QUADS + 1) + column
			chunk.mesh.vertices[index] = {
				position = {world_x, world_y, sample.height},
				normal   = normal,
				scalar   = biome_scalar(sample.biome),
				uv       = {f32(column) / TERRAIN_CHUNK_QUADS, f32(row) / TERRAIN_CHUNK_QUADS},
			}
			minimum[2] = min(minimum[2], sample.height)
			maximum[2] = max(maximum[2], sample.height)
		}
	}
	index_count := 0
	for row in 0 ..< TERRAIN_CHUNK_QUADS {
		for column in 0 ..< TERRAIN_CHUNK_QUADS {
			a := u32(row * (TERRAIN_CHUNK_QUADS + 1) + column)
			b := a + 1
			c := a + u32(TERRAIN_CHUNK_QUADS + 1)
			d := c + 1
			chunk.mesh.indices[index_count + 0] = a
			chunk.mesh.indices[index_count + 1] = b
			chunk.mesh.indices[index_count + 2] = c
			chunk.mesh.indices[index_count + 3] = b
			chunk.mesh.indices[index_count + 4] = d
			chunk.mesh.indices[index_count + 5] = c
			index_count += 6
		}
	}
	chunk.mesh.vertex_count = TERRAIN_CHUNK_VERTICES
	chunk.mesh.index_count = u32(index_count)
	chunk.mesh.primitive = .Triangles
	chunk.mesh.bounds = {minimum, maximum}
	_terrain_generate_placements(config, chunk, origin_x, origin_y)
	view, ok := asset.mesh_view(&chunk.mesh)
	return ok && asset.mesh_validate(view)
}

biome_scalar :: proc(biome: Biome) -> f32 {
	return f32(biome) / f32(len(Biome) - 1)
}

@(private)
_terrain_unit :: proc(value: f32) -> f32 {
	return clamp(value * 0.5 + 0.5, 0, 1)
}

// terrain_biome classifies a point from already-computed climate values, so
// callers that cache height/moisture/temperature (or derive slope from their
// own height grids) can classify without re-running the noise stack.
terrain_biome :: proc(config: Terrain_Config, height, moisture, temperature, slope: f32) -> Biome {
	if height < config.sea_level do return .Water
	if height < config.sea_level + 1.5 do return .Beach
	if height > config.snow_level || temperature < 0.22 do return .Snow
	if slope > 0.7 do return .Rock
	if moisture > 0.55 do return .Forest
	return .Grassland
}

@(private)
_terrain_height :: proc(config: Terrain_Config, world_x, world_y: f32) -> f32 {
	return warped_fractal_2d(config.height_noise, world_x, world_y) * config.height_scale
}

@(private)
_terrain_normal :: proc(config: Terrain_Config, world_x, world_y, step: f32) -> asset.Vec3 {
	height_left := _terrain_height(config, world_x - step, world_y)
	height_right := _terrain_height(config, world_x + step, world_y)
	height_down := _terrain_height(config, world_x, world_y - step)
	height_up := _terrain_height(config, world_x, world_y + step)
	normal := asset.Vec3{height_left - height_right, height_down - height_up, 2 * step}
	length := math.sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2])
	assert(length > 0, "_terrain_normal: degenerate normal")
	return normal / length
}

@(private)
_terrain_generate_placements :: proc(
	config: Terrain_Config,
	chunk: ^Terrain_Chunk,
	origin_x, origin_y: f32,
) {
	assert(chunk != nil, "_terrain_generate_placements: nil chunk")
	assert(config.placement_spacing > 0, "_terrain_generate_placements: non-positive spacing")
	cells := min(int(config.chunk_world_size / config.placement_spacing), 32)
	for row in 0 ..< cells {
		for column in 0 ..< cells {
			if chunk.placement_count >= TERRAIN_MAX_PLACEMENTS do return
			hash := _terrain_hash(config.seed, chunk.chunk_x, chunk.chunk_y, column, row)
			jitter_x := f32(hash & 0xFFFF) / 65535
			jitter_y := f32((hash >> 16) & 0xFFFF) / 65535
			world_x := origin_x + (f32(column) + jitter_x) * config.placement_spacing
			world_y := origin_y + (f32(row) + jitter_y) * config.placement_spacing
			sample := terrain_sample(config, world_x, world_y)
			if sample.biome != .Forest && sample.biome != .Grassland do continue
			if sample.slope > 0.55 || (hash >> 32) % 5 > 1 do continue
			normal := _terrain_normal(config, world_x, world_y, config.placement_spacing)
			index := int(chunk.placement_count)
			chunk.placements[index] = {
				position = {world_x, world_y, sample.height},
				normal   = normal,
				scale    = 0.75 + f32((hash >> 40) & 0xFF) / 512,
				rotation = f32((hash >> 48) & 0xFFFF) / 65535 * 360,
				biome    = sample.biome,
				variant  = u16((hash >> 36) & 3),
			}
			chunk.placement_count += 1
		}
	}
}

@(private)
_terrain_hash :: proc(seed: u64, chunk_x, chunk_y: i32, column, row: int) -> u64 {
	value := seed ~ u64(chunk_x) * 0x9E3779B185EBCA87
	value ~= u64(chunk_y) * 0xC2B2AE3D27D4EB4F
	value ~= u64(column) * 0x165667B19E3779F9 ~ u64(row) * 0x85EBCA77C2B2AE63
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	return value ~ (value >> 31)
}

#assert(TERRAIN_CHUNK_VERTICES < 65536)
#assert(TERRAIN_MAX_PLACEMENTS <= 256)
