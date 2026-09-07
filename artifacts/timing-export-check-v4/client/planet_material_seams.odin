package main

import "../shared"
import "core:math"
import "ingot:procgen"

planet_material_tap :: proc(face: procgen.Terrain_Face_V4, column, row: i32) -> shared.Planet_Coord {
	u := i32(math.round(_albedo_texel_cell(column)))
	v := i32(math.round(_albedo_texel_cell(row)))
	anchor := shared.Planet_Coord{face, clamp(u, 0, i32(shared.PLANET_FACE_CELLS)), clamp(v, 0, i32(shared.PLANET_FACE_CELLS))}
	return shared.planet_neighbour(anchor, u - anchor.u, v - anchor.v)
}

planet_material_direction :: proc(face: procgen.Terrain_Face_V4, column, row: i32) -> [3]f32 {
	center := i32(shared.PLANET_FACE_CELLS / 2)
	return shared.planet_neighbour_direction({face, center, center}, _albedo_texel_cell(column) - f32(center), _albedo_texel_cell(row) - f32(center))
}

planet_material_height_tap :: proc(world: ^shared.World, face: procgen.Terrain_Face_V4, column, row: i32) -> f32 {
	sample_face, cell_u, cell_v := shared.planet_locate(planet_material_direction(face, column, row))
	height := (_face_bilinear_i16(world.foundation.base_height, sample_face, cell_u, cell_v) + _face_bilinear_i16(world.foundation.tectonic_delta, sample_face, cell_u, cell_v)) / f32(shared.HEIGHT_DELTA_SCALE)
	if world.heightfield.modified do height += _face_delta_bilinear(world, sample_face, cell_u, cell_v)
	return height
}

planet_material_noise :: proc(direction: [3]f32) -> f32 {
	point := direction * shared.PLANET_RADIUS
	return 0.5 + math.sin(point.x * 0.19 + math.sin(point.z * 0.13)) * 0.125 +
		math.sin(point.y * 0.071 + point.z * 0.053) * 0.225 +
		math.sin(point.x * 0.023 - point.y * 0.031 + point.z * 0.017) * 0.15
}

planet_material_slope :: proc(face: procgen.Terrain_Face_V4, column, row: i32, left, right, down, up: f32) -> f32 {
	normal := planet_material_direction(face, column, row)
	tangent_u := (planet_material_direction(face, column + 1, row) - planet_material_direction(face, column - 1, row)) * (shared.PLANET_RADIUS * 0.5)
	tangent_v := (planet_material_direction(face, column, row + 1) - planet_material_direction(face, column, row - 1)) * (shared.PLANET_RADIUS * 0.5)
	tangent_u -= normal * (normal.x * tangent_u.x + normal.y * tangent_u.y + normal.z * tangent_u.z)
	tangent_v -= normal * (normal.x * tangent_v.x + normal.y * tangent_v.y + normal.z * tangent_v.z)
	metric_u := tangent_u.x * tangent_u.x + tangent_u.y * tangent_u.y + tangent_u.z * tangent_u.z
	metric_v := tangent_v.x * tangent_v.x + tangent_v.y * tangent_v.y + tangent_v.z * tangent_v.z
	metric_cross := tangent_u.x * tangent_v.x + tangent_u.y * tangent_v.y + tangent_u.z * tangent_v.z
	determinant := metric_u * metric_v - metric_cross * metric_cross
	if determinant <= metric_u * metric_v * 0.000001 do return 0
	derivative_u := (right - left) * 0.5
	derivative_v := (up - down) * 0.5
	return math.sqrt(max((metric_v * derivative_u * derivative_u - 2 * metric_cross * derivative_u * derivative_v + metric_u * derivative_v * derivative_v) / determinant, 0))
}

planet_material_metric :: proc(face: procgen.Terrain_Face_V4, column, row: i32) -> (step_u, step_v: f32) {
	cell_u := clamp(_albedo_texel_cell(column), 0, f32(shared.PLANET_FACE_CELLS))
	cell_v := clamp(_albedo_texel_cell(row), 0, f32(shared.PLANET_FACE_CELLS))
	low_u, high_u := max(cell_u - PLANET_ALBEDO_CELL_STEP, 0), min(cell_u + PLANET_ALBEDO_CELL_STEP, f32(shared.PLANET_FACE_CELLS))
	low_v, high_v := max(cell_v - PLANET_ALBEDO_CELL_STEP, 0), min(cell_v + PLANET_ALBEDO_CELL_STEP, f32(shared.PLANET_FACE_CELLS))
	delta_u := shared.planet_direction_uv(face, high_u, cell_v) - shared.planet_direction_uv(face, low_u, cell_v)
	delta_v := shared.planet_direction_uv(face, cell_u, high_v) - shared.planet_direction_uv(face, cell_u, low_v)
	step_u = math.sqrt(delta_u.x * delta_u.x + delta_u.y * delta_u.y + delta_u.z * delta_u.z) * shared.PLANET_RADIUS * PLANET_ALBEDO_CELL_STEP / (high_u - low_u)
	step_v = math.sqrt(delta_v.x * delta_v.x + delta_v.y * delta_v.y + delta_v.z * delta_v.z) * shared.PLANET_RADIUS * PLANET_ALBEDO_CELL_STEP / (high_v - low_v)
	return
}
