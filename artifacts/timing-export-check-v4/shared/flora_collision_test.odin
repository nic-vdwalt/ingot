package shared

import "core:testing"

@(test)
flora_logical_hash_and_classification_are_deterministic :: proc(t: ^testing.T) {
	hash := flora_logical_hash(TERRAIN_SEED, 18, 27)
	testing.expect_value(t, flora_logical_hash(TERRAIN_SEED, 18, 27), hash)
	sample := Flora_Logical_Sample {
		height_fixed = 16,
		sea_fixed    = -8,
		snow_fixed   = 48,
		moisture     = 220,
		slope        = 24,
		biome        = .Forest,
	}
	first := flora_logical_solid(TERRAIN_SEED, hash, sample)
	second := flora_logical_solid(TERRAIN_SEED, hash, sample)
	testing.expect_value(t, second, first)
}

@(test)
flora_logical_solid_radii_match_kind :: proc(t: ^testing.T) {
	for cell in 0 ..< 4096 {
		hash := flora_logical_hash(TERRAIN_SEED, i32(cell), 53)
		sample := Flora_Logical_Sample {
			height_fixed = 16,
			sea_fixed    = -8,
			snow_fixed   = 48,
			moisture     = 220,
			slope        = 24,
			biome        = .Forest,
		}
		result := flora_logical_solid(TERRAIN_SEED, hash, sample)
		if result.kind == .None do continue
		if result.kind >= .Conifer_A && result.kind <= .Baobab {
			testing.expect_value(t, result.collision_radius_mm, FLORA_LOGICAL_TREE_RADIUS_MM)
		} else {
			testing.expect_value(t, result.collision_radius_mm, FLORA_LOGICAL_BOULDER_RADIUS_MM)
		}
	}
}
