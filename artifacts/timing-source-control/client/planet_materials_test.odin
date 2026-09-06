package main

import "core:testing"
import "../shared"

@(test)
planet_material_controls_preserve_bare_habitat :: proc(t: ^testing.T) {
	for biome in shared.Biome_Id {
		value := planet_material_controls(biome, 0, 0, 0.7, 0)
		testing.expect(t, value.living == 0 && value.organic == 0)
		packed := planet_material_pack(value)
		testing.expect(t, u32(packed[0]) + u32(packed[1]) + u32(packed[2]) <= 255)
	}
	soil := planet_material_controls(.Grassland, 0, 0, 0.5, 0)
	sand := planet_material_controls(.Desert, 0, 0, 0.5, 0)
	testing.expect(t, soil.sediment == 0 && sand.sediment > 0.8)
	forest := planet_material_controls(.Forest, 0, 0.8, 0.7, 0)
	testing.expect(t, forest.living == 0 && forest.organic > 0)
	grass := planet_material_controls(.Grassland, 0.8, 0, 0.7, 0)
	testing.expect(t, grass.living == 0.8 && grass.organic == 0)
}

@(test)
planet_material_controls_normalize_cover :: proc(t: ^testing.T) {
	ground_values := [4]f32{0, 0.25, 1, 2}
	for ground in ground_values {
		value := planet_material_controls(.Wetland, ground, 1, 1, 1)
		packed := planet_material_pack(value)
		testing.expect(t, u32(packed[0]) + u32(packed[1]) + u32(packed[2]) <= 255)
	}
}
