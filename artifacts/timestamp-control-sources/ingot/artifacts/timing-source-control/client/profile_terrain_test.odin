package main

import "core:strings"
import "core:testing"

@(test)
profile_terrain_identity_digest :: proc(t: ^testing.T) {
	digest := profile_terrain_digest("abc")
	testing.expect_value(t, string(digest[:]),
		"ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
	identity: Profile_Terrain_Identity
	when !PROFILE_ENABLED {
		testing.expect_value(t, profile_terrain_prepare(&identity), TERRAIN_SHADER)
		testing.expect_value(t, identity.variant, "")
	} else {
		identity.variant = "reference"
		first := profile_terrain_prepare(&identity)
		second := profile_terrain_prepare(&identity)
		testing.expect_value(t, first, TERRAIN_SHADER)
		testing.expect_value(t, second, first)
		testing.expect_value(t, identity.sha256, profile_terrain_digest(first))
	}
}

@(test)
profile_terrain_variants_preserve_reference :: proc(t: ^testing.T) {
	testing.expect(t, profile_terrain_shader_variant(TERRAIN_SHADER, "reference") == TERRAIN_SHADER)
	testing.expect(t, profile_terrain_shader_variant(TERRAIN_SHADER, "unknown") == TERRAIN_SHADER)
	variants := []string{"no-bump", "no-strata", "no-mapped-detail"}
	for variant in variants {
		source := profile_terrain_shader_variant(TERRAIN_SHADER, variant)
		testing.expect(t, source != TERRAIN_SHADER)
		testing.expect(t, strings.contains(source, "color = atmosphere_apply(color, in.world_position, dist, view, light);"))
		testing.expect(t, strings.count(source, "@fragment") == 1)
	}
	when !PROFILE_ENABLED {
		testing.expect(t, profile_terrain_shader() == TERRAIN_SHADER)
	}
}
