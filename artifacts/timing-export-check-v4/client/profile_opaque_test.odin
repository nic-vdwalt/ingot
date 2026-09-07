package main

import "core:strings"
import "core:testing"

@(test)
terrain_draw_labels_identify_geometry_and_material :: proc(t: ^testing.T) {
	testing.expect(t, profile_terrain_draw_label(0, 0, 0, true) == "terrain.face0.patch0.lod0.baked")
	testing.expect(t, profile_terrain_draw_label(5, 63, 1, false) == "terrain.face5.patch63.lod1.fallback")
	for face in 0 ..< 6 {
		for patch in 0 ..< 64 {
			for lod in 0 ..< TERRAIN_LOD_COUNT {
				baked := profile_terrain_draw_label(face, patch, lod, true)
				fallback := profile_terrain_draw_label(face, patch, lod, false)
				testing.expect(t, baked != fallback)
				testing.expect(t, len(baked) < 64 && len(fallback) < 64)
			}
		}
	}
}

@(test)
opaque_component_labels_are_bounded_and_unique :: proc(t: ^testing.T) {
	names := OPAQUE_COMPONENT_NAMES
	testing.expect(t, len(names) == 9)
	testing.expect(t, names[8] == "split.opaque.marine")
	testing.expect(t, len(names) <= 8*size_of(u32))
	testing.expect(t, MAX_DRAW_INSTANCES >= MARINE_REPRESENTATIVE_LIMIT)
	for name, index in names {
		testing.expect(t, len(name) <= 32)
		testing.expect(t, strings.has_prefix(name, "split.opaque."))
		for previous in 0 ..< index {
			testing.expect(t, names[previous] != name)
		}
	}
}
