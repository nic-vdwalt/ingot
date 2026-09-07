package shared

import procgen "ingot:procgen"

// A seed used to permute noise lattice hashes and nothing else. Every world
// therefore shared one land fraction, one climate distribution and one
// mountain share: the seed moved the coastline around but could not change
// what kind of world it was. An archetype is the missing layer -- it drives
// the macro parameters the recipe used to hold as compile-time constants, so
// two seeds can disagree about whether the world is a continent or an
// archipelago, a desert or a taiga.
Terrain_Archetype :: enum u8 {
	Pangaea,
	Archipelago,
	Highlands,
	Lake_Plateau,
	Dust_Bowl,
	Boreal,
	Rainforest_Belt,
	Rift_Valleys,
}

// Wavelengths are authored in world units rather than frequencies because
// that is the axis the failure was on: a biome is too small or large relative
// to the world, and a frequency hides that relationship behind a reciprocal.
Terrain_Archetype_Profile :: struct {
	continental_wavelength: f32,
	continental_contrast:   f32,
	coast_threshold:        f32,
	coast_jitter:           f32,
	ocean_depth:            f32,
	land_height:            f32,
	mountain_wavelength:    f32,
	mountain_threshold:     f32,
	mountain_fade:          f32,
	mountain_height:        f32,
	ridge_power:            f32,
	basin_wavelength:       f32,
	basin_threshold:        f32,
	basin_depth:            f32,
	climate_wavelength:     f32,
	climate_contrast:       f32,
	moisture_bias:          f32,
	temperature_bias:       f32,
	latitude_weight:        f32,
}

// Two octaves, not the four this stack used to run. In a world this size the
// third and fourth continental octaves sit at roughly 300 and 150 units and
// carry nearly half the signal energy, which is what shredded every coastline
// into the same archipelago. The high octaves only dither boundaries; they
// never decide where a landmass is.
TERRAIN_ARCHETYPE_CONTINENTAL_OCTAVES :: u8(2)
TERRAIN_ARCHETYPE_CLIMATE_OCTAVES :: u8(2)
TERRAIN_ARCHETYPE_BASIN_OCTAVES :: u8(2)
TERRAIN_ARCHETYPE_MOUNTAIN_OCTAVES :: u8(3)
TERRAIN_ARCHETYPE_MACRO_GAIN :: f32(0.35)
// Warp is a fraction of the wavelength it perturbs. Held proportional so a
// profile that widens its provinces does not accidentally flatten their
// outlines into circles.
TERRAIN_ARCHETYPE_CONTINENTAL_WARP :: f32(0.12)
TERRAIN_ARCHETYPE_CLIMATE_WARP :: f32(0.08)
TERRAIN_ARCHETYPE_RELIEF_WARP :: f32(0.1)
// Temperature provinces are deliberately wider than moisture ones: a world
// whose two climate axes share a wavelength produces biomes that are all
// corners of the same grid.
TERRAIN_ARCHETYPE_TEMPERATURE_STRETCH :: f32(1.35)
// Per-seed jitter. Without it every Pangaea seed would be the same continent
// with the noise reshuffled -- the archetype would have replaced one
// homogeneity with eight.
TERRAIN_ARCHETYPE_WAVELENGTH_JITTER :: f32(0.15)
TERRAIN_ARCHETYPE_THRESHOLD_JITTER :: f32(0.05)
// The V3 mountain transform roughly doubles a peak's height above
// land_height, so a profile's mountain_height must leave room for it under
// Terrain_Parameters_V3.maximum_z. A peak that clips the volume ceiling is a
// flat-topped mesa, not a summit.
TERRAIN_ARCHETYPE_MOUNTAIN_HEIGHT_MAX :: f32(24)

// Ordered to match Terrain_Archetype. Every profile is a whole world, not a
// tweak: the entries differ in land fraction, province size, relief and
// climate centre at once, because a seed that only differs in one of those
// still reads as the same place.
@(private)
_TERRAIN_ARCHETYPE_PROFILES :: [Terrain_Archetype]Terrain_Archetype_Profile {
	// One dominant continent with a dry interior. The coast threshold sits
	// well below the distribution midpoint, which is what makes land the
	// default rather than the exception.
	.Pangaea = {
		continental_wavelength = 1400,
		continental_contrast = 1.7,
		coast_threshold = 0.22,
		coast_jitter = 0.05,
		ocean_depth = 10,
		land_height = 9,
		mountain_wavelength = 620,
		mountain_threshold = 0.62,
		mountain_fade = 0.16,
		mountain_height = 24,
		ridge_power = 1.9,
		basin_wavelength = 700,
		basin_threshold = 0.82,
		basin_depth = 5,
		climate_wavelength = 1250,
		climate_contrast = 1.9,
		moisture_bias = -0.1,
		temperature_bias = 0.04,
		latitude_weight = 0.16,
	},
	// Many mid-size islands. Short continental wavelength and heavy jitter
	// are the whole recipe; the shallow ocean keeps the straits crossable.
	.Archipelago = {
		continental_wavelength = 460,
		continental_contrast = 2.0,
		coast_threshold = 0.62,
		coast_jitter = 0.22,
		ocean_depth = 7,
		land_height = 7,
		mountain_wavelength = 340,
		mountain_threshold = 0.70,
		mountain_fade = 0.14,
		mountain_height = 19,
		ridge_power = 2.1,
		basin_wavelength = 420,
		basin_threshold = 0.86,
		basin_depth = 3,
		climate_wavelength = 1100,
		climate_contrast = 1.8,
		moisture_bias = 0.16,
		temperature_bias = 0.08,
		latitude_weight = 0.12,
	},
	// Cold and tall. A low mountain threshold with a tight fade is what
	// makes ranges cover ground instead of appearing as isolated cones.
	.Highlands = {
		continental_wavelength = 1000,
		continental_contrast = 1.7,
		coast_threshold = 0.37,
		coast_jitter = 0.08,
		ocean_depth = 11,
		land_height = 10,
		mountain_wavelength = 520,
		mountain_threshold = 0.48,
		mountain_fade = 0.14,
		mountain_height = 24,
		ridge_power = 1.7,
		basin_wavelength = 600,
		basin_threshold = 0.84,
		basin_depth = 5,
		climate_wavelength = 1300,
		climate_contrast = 1.9,
		moisture_bias = 0.02,
		temperature_bias = -0.16,
		latitude_weight = 0.18,
	},
	// Low, wet and pitted. The basin threshold is the lowest in the table
	// and the depth the greatest, which is what turns depressions into
	// lakes large enough to navigate rather than puddles.
	.Lake_Plateau = {
		continental_wavelength = 1200,
		continental_contrast = 1.6,
		coast_threshold = 0.27,
		coast_jitter = 0.06,
		ocean_depth = 9,
		land_height = 7,
		mountain_wavelength = 700,
		mountain_threshold = 0.74,
		mountain_fade = 0.12,
		mountain_height = 18,
		ridge_power = 2.2,
		basin_wavelength = 520,
		basin_threshold = 0.74,
		basin_depth = 8,
		climate_wavelength = 1200,
		climate_contrast = 1.8,
		moisture_bias = 0.18,
		temperature_bias = 0,
		latitude_weight = 0.15,
	},
	// Hot and strongly dry. The bias is large enough to push the moisture
	// distribution's bulk into the desert window, so the world has a desert
	// core rather than desert speckle.
	.Dust_Bowl = {
		continental_wavelength = 1100,
		continental_contrast = 1.7,
		coast_threshold = 0.32,
		coast_jitter = 0.07,
		ocean_depth = 9,
		land_height = 8,
		mountain_wavelength = 640,
		mountain_threshold = 0.72,
		mountain_fade = 0.12,
		mountain_height = 21,
		ridge_power = 2.2,
		basin_wavelength = 760,
		basin_threshold = 0.88,
		basin_depth = 4,
		climate_wavelength = 1500,
		climate_contrast = 1.7,
		moisture_bias = -0.3,
		temperature_bias = 0.22,
		latitude_weight = 0.14,
	},
	// Strongly cold. Paired with a moderate moisture bias so the cold lands
	// split into taiga and tundra rather than collapsing onto one of them.
	.Boreal = {
		continental_wavelength = 1000,
		continental_contrast = 1.7,
		coast_threshold = 0.37,
		coast_jitter = 0.09,
		ocean_depth = 10,
		land_height = 8,
		mountain_wavelength = 560,
		mountain_threshold = 0.62,
		mountain_fade = 0.16,
		mountain_height = 23,
		ridge_power = 1.9,
		basin_wavelength = 640,
		basin_threshold = 0.8,
		basin_depth = 5,
		climate_wavelength = 1350,
		climate_contrast = 1.8,
		moisture_bias = 0.06,
		temperature_bias = -0.3,
		latitude_weight = 0.2,
	},
	// Hot and strongly wet, with the flattest relief in the table so the
	// forest is unbroken rather than cut into valleys.
	.Rainforest_Belt = {
		continental_wavelength = 1200,
		continental_contrast = 1.6,
		coast_threshold = 0.32,
		coast_jitter = 0.07,
		ocean_depth = 9,
		land_height = 7,
		mountain_wavelength = 680,
		mountain_threshold = 0.76,
		mountain_fade = 0.12,
		mountain_height = 18,
		ridge_power = 2.3,
		basin_wavelength = 560,
		basin_threshold = 0.8,
		basin_depth = 6,
		climate_wavelength = 1400,
		climate_contrast = 1.7,
		moisture_bias = 0.3,
		temperature_bias = 0.2,
		latitude_weight = 0.12,
	},
	// Two or three landmasses split by deep straits. The mid coast threshold
	// with a short wavelength and a deep ocean is what makes the water
	// between them read as a rift rather than a bay.
	.Rift_Valleys = {
		continental_wavelength = 800,
		continental_contrast = 1.9,
		coast_threshold = 0.42,
		coast_jitter = 0.12,
		ocean_depth = 14,
		land_height = 9,
		mountain_wavelength = 420,
		mountain_threshold = 0.54,
		mountain_fade = 0.13,
		mountain_height = 24,
		ridge_power = 1.6,
		basin_wavelength = 480,
		basin_threshold = 0.78,
		basin_depth = 7,
		climate_wavelength = 1150,
		climate_contrast = 2.0,
		moisture_bias = -0.04,
		temperature_bias = -0.06,
		latitude_weight = 0.17,
	},
}

// terrain_archetype selects a world kind from a seed. A hash rather than
// `seed % 8`, so consecutive seeds -- which is how a player actually explores
// the space -- do not walk the roster in order.
terrain_archetype :: proc(seed: u64) -> Terrain_Archetype {
	count := u64(len(Terrain_Archetype))
	assert(count > 0, "terrain_archetype: empty roster")
	return Terrain_Archetype(_terrain_archetype_hash(seed, 0x415E_7A11) % count)
}

terrain_archetype_profile :: proc(archetype: Terrain_Archetype) -> Terrain_Archetype_Profile {
	profiles := _TERRAIN_ARCHETYPE_PROFILES
	return profiles[archetype]
}

// terrain_archetype_apply rewrites the macro half of a surface recipe. It runs
// after the shared constants so it can override them, and before the biome
// profile table, which reads none of what it writes.
//
// The archetype is passed rather than derived because the spawn search varies
// the layout seed while holding the world's kind fixed. Deriving it here would
// let a rejected candidate change what kind of world the seed asked for, which
// steers every seed toward whichever archetypes happen to spawn most easily.
terrain_archetype_apply :: proc(
	recipe: ^procgen.Terrain_Recipe_V2,
	archetype: Terrain_Archetype,
	layout_seed: u64,
) {
	assert(recipe != nil, "terrain_archetype_apply: nil recipe")
	assert(recipe.seed == layout_seed, "terrain_archetype_apply: recipe seed mismatch")
	profile := terrain_archetype_profile(archetype)
	seed := layout_seed
	continental := _terrain_archetype_wavelength(profile.continental_wavelength, seed, 0x0001)
	mountain := _terrain_archetype_wavelength(profile.mountain_wavelength, seed, 0x0002)
	basin := _terrain_archetype_wavelength(profile.basin_wavelength, seed, 0x0003)
	climate := _terrain_archetype_wavelength(profile.climate_wavelength, seed, 0x0004)
	temperature := climate * TERRAIN_ARCHETYPE_TEMPERATURE_STRETCH
	recipe.continental_noise.frequency = 1 / continental
	recipe.continental_noise.octaves = TERRAIN_ARCHETYPE_CONTINENTAL_OCTAVES
	recipe.continental_noise.gain = TERRAIN_ARCHETYPE_MACRO_GAIN
	recipe.continental_noise.warp = continental * TERRAIN_ARCHETYPE_CONTINENTAL_WARP
	recipe.mountain_noise.frequency = 1 / mountain
	recipe.mountain_noise.octaves = TERRAIN_ARCHETYPE_MOUNTAIN_OCTAVES
	recipe.mountain_noise.warp = mountain * TERRAIN_ARCHETYPE_RELIEF_WARP
	// Ridges ride on the mountain mask, so a shorter wavelength here is what
	// gives a range internal structure instead of one smooth dome.
	recipe.ridge_noise.frequency = 2 / mountain
	recipe.ridge_noise.warp = mountain * TERRAIN_ARCHETYPE_RELIEF_WARP * 0.5
	recipe.basin_noise.frequency = 1 / basin
	recipe.basin_noise.octaves = TERRAIN_ARCHETYPE_BASIN_OCTAVES
	recipe.basin_noise.warp = basin * TERRAIN_ARCHETYPE_RELIEF_WARP
	recipe.moisture_noise.frequency = 1 / climate
	recipe.moisture_noise.octaves = TERRAIN_ARCHETYPE_CLIMATE_OCTAVES
	recipe.moisture_noise.gain = TERRAIN_ARCHETYPE_MACRO_GAIN
	recipe.moisture_noise.warp = climate * TERRAIN_ARCHETYPE_CLIMATE_WARP
	recipe.temperature_noise.frequency = 1 / temperature
	recipe.temperature_noise.octaves = TERRAIN_ARCHETYPE_CLIMATE_OCTAVES
	recipe.temperature_noise.gain = TERRAIN_ARCHETYPE_MACRO_GAIN
	recipe.temperature_noise.warp = temperature * TERRAIN_ARCHETYPE_CLIMATE_WARP
	recipe.continental_contrast = max(profile.continental_contrast, 1)
	recipe.climate_contrast = max(profile.climate_contrast, 1)
	recipe.coast_threshold = _terrain_archetype_threshold(profile.coast_threshold, seed, 0x0005)
	recipe.coast_jitter = max(profile.coast_jitter, 0)
	recipe.ocean_depth = profile.ocean_depth
	recipe.land_height = profile.land_height
	recipe.mountain_threshold = _terrain_archetype_threshold(
		profile.mountain_threshold,
		seed,
		0x0006,
	)
	recipe.mountain_fade = profile.mountain_fade
	recipe.mountain_height = min(profile.mountain_height, TERRAIN_ARCHETYPE_MOUNTAIN_HEIGHT_MAX)
	recipe.ridge_power = profile.ridge_power
	recipe.basin_threshold = _terrain_archetype_threshold(profile.basin_threshold, seed, 0x0007)
	recipe.basin_depth = profile.basin_depth
	recipe.moisture_bias = _terrain_archetype_bias(profile.moisture_bias, seed, 0x0008)
	recipe.temperature_bias = _terrain_archetype_bias(profile.temperature_bias, seed, 0x0009)
	recipe.latitude_weight = clamp(profile.latitude_weight, 0, 1)
	// The equator lands anywhere in the world rather than on the x axis, so
	// two seeds of one archetype do not share a north-south gradient.
	recipe.latitude_offset = _terrain_archetype_unit(seed, 0x000A) * WORLD_HALF_SIZE
}

// terrain_archetype_spawn_biomes is where a world of this kind may start a
// player. It replaces the old rule that seed % 12 selected the spawn biome
// outright: forcing an arbitrary biome under the player selected hard on one
// narrow condition and left everything else identical, which homogenised
// worlds rather than diversifying them.
terrain_archetype_spawn_biomes :: proc(archetype: Terrain_Archetype) -> bit_set[Biome_Id] {
	switch archetype {
	case .Pangaea:
		return {.Grassland, .Savannah, .Forest}
	case .Archipelago:
		return {.Coast, .Forest, .Grassland}
	case .Highlands:
		return {.Taiga, .Forest, .Grassland}
	case .Lake_Plateau:
		return {.Wetland, .Grassland, .Forest}
	case .Dust_Bowl:
		return {.Desert, .Savannah, .Grassland}
	case .Boreal:
		return {.Taiga, .Tundra, .Snowlands}
	case .Rainforest_Belt:
		return {.Forest, .Wetland, .Grassland}
	case .Rift_Valleys:
		return {.Grassland, .Savannah, .Forest}
	}
	return {.Grassland}
}

@(private)
_terrain_archetype_wavelength :: proc(wavelength: f32, seed: u64, salt: u64) -> f32 {
	assert(wavelength > 0, "_terrain_archetype_wavelength: non-positive wavelength")
	scaled :=
		wavelength *
		(1 + _terrain_archetype_unit(seed, salt) * TERRAIN_ARCHETYPE_WAVELENGTH_JITTER)
	assert(scaled > 0, "_terrain_archetype_wavelength: jitter collapsed the wavelength")
	return scaled
}

// Thresholds stay clear of 0 and 1: a smoothstep whose band runs off the end
// of the unit range is a step function, and a world with a step coastline has
// no shoreline at all.
@(private)
_terrain_archetype_threshold :: proc(threshold: f32, seed: u64, salt: u64) -> f32 {
	jittered :=
		threshold + _terrain_archetype_unit(seed, salt) * TERRAIN_ARCHETYPE_THRESHOLD_JITTER
	return clamp(jittered, 0.05, 0.95)
}

@(private)
_terrain_archetype_bias :: proc(bias: f32, seed: u64, salt: u64) -> f32 {
	jittered := bias + _terrain_archetype_unit(seed, salt) * TERRAIN_ARCHETYPE_THRESHOLD_JITTER
	return clamp(jittered, -1, 1)
}

// _terrain_archetype_unit returns a deterministic value in [-1, 1].
@(private)
_terrain_archetype_unit :: proc(seed: u64, salt: u64) -> f32 {
	hash := _terrain_archetype_hash(seed, salt)
	return f32(hash & 0xFFFFFF) / f32(0xFFFFFF) * 2 - 1
}

@(private)
_terrain_archetype_hash :: proc(seed: u64, salt: u64) -> u64 {
	value := seed ~ (salt + 1) * 0xD6E8_FEB8_6659_FD93
	value ~= value >> 32
	value *= 0xBF58_476D_1CE4_E5B9
	value ~= value >> 29
	value *= 0x94D0_49BB_1331_11EB
	return value ~ (value >> 32)
}
