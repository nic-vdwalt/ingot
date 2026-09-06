package main

import "core:testing"
import "../shared"
import "ingot:procgen"

@(test)
planet_material_slope_recovers_tangent_gradient :: proc(t: ^testing.T) {
	for face in 0 ..< shared.PLANET_FACE_COUNT {
		for row in ([7]i32{0, 1, 256, 512, 768, 1022, 1023}) {
			for column in ([7]i32{0, 1, 256, 512, 768, 1022, 1023}) {
				material_face := procgen.Terrain_Face_V4(face)
				normal := planet_material_direction(material_face, column, row)
				for axis in ([4][3]f32{{0, 0, 0}, {0.6, 0, 0}, {0, 0.6, 0}, {0.4, -0.3, 0.5}}) {
					gradient := axis - normal * (axis.x * normal.x + axis.y * normal.y + axis.z * normal.z)
					heights: [4]f32
					for offset, index in ([4][2]i32{{-1, 0}, {1, 0}, {0, -1}, {0, 1}}) {
						delta := (planet_material_direction(material_face, column + offset.x, row + offset.y) - normal) * shared.PLANET_RADIUS
						heights[index] = gradient.x * delta.x + gradient.y * delta.y + gradient.z * delta.z
					}
					slope := planet_material_slope(material_face, column, row, heights[0], heights[1], heights[2], heights[3])
					expected_squared := gradient.x * gradient.x + gradient.y * gradient.y + gradient.z * gradient.z
					testing.expect(t, abs(slope * slope - expected_squared) < 0.00001)
					shifted := planet_material_slope(material_face, column, row, heights[0] + 100, heights[1] + 100, heights[2] + 100, heights[3] + 100)
					testing.expect(t, abs(shifted - slope) < 0.0001)
				}
			}
		}
	}
}

@(test)
planet_material_gutters_cross_faces :: proc(t: ^testing.T) {
	source := make([]u8, PLANET_ALBEDO_TEXELS * 3)
	defer delete(source)
	destination := make([]u8, PLANET_MATERIAL_PADDED_SIZE * PLANET_MATERIAL_PADDED_SIZE * 3)
	defer delete(destination)
	for &value, index in source do value = u8(index / (PLANET_ALBEDO_FACE_TEXELS * 3) * 30 + index % 3)
	for face in 0 ..< shared.PLANET_FACE_COUNT {
		planet_material_gutter_fill(destination, source, procgen.Terrain_Face_V4(face))
		for position in ([3]int{0, PLANET_MATERIAL_PADDED_SIZE / 2, PLANET_MATERIAL_PADDED_SIZE - 1}) {
			for edge in 0 ..< 4 {
				column := edge < 2 ? (edge == 0 ? 0 : PLANET_MATERIAL_PADDED_SIZE - 1) : position
				row := edge < 2 ? position : (edge == 2 ? 0 : PLANET_MATERIAL_PADDED_SIZE - 1)
				other, _, _ := shared.planet_locate(planet_material_direction(procgen.Terrain_Face_V4(face), i32(column - 1), i32(row - 1)))
				testing.expect(t, int(other) != face)
				for channel in 0 ..< 3 do testing.expect_value(t, destination[(row * PLANET_MATERIAL_PADDED_SIZE + column) * 3 + channel], u8(int(other) * 30 + channel))
			}
		}
		for channel in 0 ..< 3 do testing.expect_value(t, destination[(PLANET_MATERIAL_PADDED_SIZE + 1) * 3 + channel], u8(face * 30 + channel))
	}
}

@(test)
planet_material_seams_canonical_samples :: proc(t: ^testing.T) {
	state := new(Planet_Surface_Publication)
	defer free(state)
	for &sample, index in state.current {
		direction := shared.planet_direction(shared.planet_sim_terrain_coord(shared.planet_sim_coord_for_index(index)))
		sample = planet_surface_pack(Planet_Surface_Sample {
			color = (direction + [3]f32{1, 1, 1}) * 100,
			ground = 0.25, canopy = 0.5, air_temperature = 273000,
		})
	}
	for face in 0 ..< shared.PLANET_FACE_COUNT {
		for position in ([7]i32{0, 1, 137, shared.PLANET_FACE_CELLS / 2, 631, shared.PLANET_FACE_CELLS - 1, shared.PLANET_FACE_CELLS}) {
		for edge in 0 ..< 4 {
			coord := shared.Planet_Coord{procgen.Terrain_Face_V4(face), edge < 2 ? (edge == 0 ? 0 : shared.PLANET_FACE_CELLS) : position, edge < 2 ? position : (edge == 2 ? 0 : shared.PLANET_FACE_CELLS)}
			duplicates, count := shared.planet_duplicates(coord)
			direction := shared.planet_direction(coord)
			sample := planet_surface_sample(state, direction)
			testing.expect(t, abs(sample.ground - f32(64) / 255) < 0.0001)
			for index in 0 ..< count {
				other_direction := shared.planet_direction(duplicates[index])
				other := planet_surface_sample(state, other_direction)
				for channel in 0 ..< 3 do testing.expect(t, abs(sample.color[channel] - other.color[channel]) < 0.01)
				inset_u := clamp(f32(duplicates[index].u), 0.0001, f32(shared.PLANET_FACE_CELLS) - 0.0001)
				inset_v := clamp(f32(duplicates[index].v), 0.0001, f32(shared.PLANET_FACE_CELLS) - 0.0001)
				inside := planet_surface_sample(state, shared.planet_direction_uv(duplicates[index].face, inset_u, inset_v))
				for channel in 0 ..< 3 do testing.expect(t, abs(sample.color[channel] - inside.color[channel]) < 0.01)
				testing.expect(t, abs(planet_material_noise(direction) - planet_material_noise(other_direction)) < 0.001)
			}
		}
		}
		crossed := planet_material_tap(procgen.Terrain_Face_V4(face), -8, PLANET_ALBEDO_SIZE / 2)
		testing.expect(t, crossed.face != procgen.Terrain_Face_V4(face))
		testing.expect(t, shared.planet_coord_valid(crossed))
		step_u, step_v := planet_material_metric(procgen.Terrain_Face_V4(face), 0, 0)
		testing.expect(t, step_u > 0 && step_v > 0)
	}
}
