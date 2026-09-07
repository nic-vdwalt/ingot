package main

import "../shared"
import "core:math"
import "ingot:procgen"

PLANET_MATERIAL_PADDED_SIZE :: PLANET_ALBEDO_SIZE + 2

planet_material_gutter_fill :: proc(destination, source: []u8, face: procgen.Terrain_Face_V4) {
	assert(len(destination) == PLANET_MATERIAL_PADDED_SIZE * PLANET_MATERIAL_PADDED_SIZE * 3)
	assert(len(source) == PLANET_ALBEDO_TEXELS * 3)
	for row in 0 ..< PLANET_MATERIAL_PADDED_SIZE {
		if row > 0 && row <= PLANET_ALBEDO_SIZE {
			output := (row * PLANET_MATERIAL_PADDED_SIZE + 1) * 3
			input := (int(face) * PLANET_ALBEDO_FACE_TEXELS + (row - 1) * PLANET_ALBEDO_SIZE) * 3
			copy(destination[output:][:PLANET_ALBEDO_SIZE * 3], source[input:][:PLANET_ALBEDO_SIZE * 3])
		}
		for column := 0; column < PLANET_MATERIAL_PADDED_SIZE; column += 1 {
			output := (row * PLANET_MATERIAL_PADDED_SIZE + column) * 3
			if row > 0 && row <= PLANET_ALBEDO_SIZE && column > 0 && column <= PLANET_ALBEDO_SIZE {
				column = PLANET_ALBEDO_SIZE
				continue
			}
			sample_face, cell_u, cell_v := shared.planet_locate(planet_material_direction(face, i32(column - 1), i32(row - 1)))
			texel_u := clamp(cell_u / PLANET_ALBEDO_CELL_STEP - 0.5, 0, f32(PLANET_ALBEDO_SIZE - 1))
			texel_v := clamp(cell_v / PLANET_ALBEDO_CELL_STEP - 0.5, 0, f32(PLANET_ALBEDO_SIZE - 1))
			low_u, low_v := int(texel_u), int(texel_v)
			blend_u, blend_v := texel_u - f32(low_u), texel_v - f32(low_v)
			for channel in 0 ..< 3 {
				value := f32(0)
				for corner in 0 ..< 4 {
					u := min(low_u + corner % 2, PLANET_ALBEDO_SIZE - 1)
					v := min(low_v + corner / 2, PLANET_ALBEDO_SIZE - 1)
					weight := (corner % 2 == 0 ? 1 - blend_u : blend_u) * (corner / 2 == 0 ? 1 - blend_v : blend_v)
					input := (int(sample_face) * PLANET_ALBEDO_FACE_TEXELS + v * PLANET_ALBEDO_SIZE + u) * 3 + channel
					value += f32(source[input]) * weight
				}
				destination[output + channel] = u8(clamp(math.round(value), 0, 255))
			}
		}
	}
}
