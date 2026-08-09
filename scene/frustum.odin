package scene

import "core:math"
import "ingot:asset"

FRUSTUM_PLANE_COUNT :: 6

Plane :: struct {
	normal:   asset.Vec3,
	distance: f32,
}

Frustum :: struct {
	planes: [FRUSTUM_PLANE_COUNT]Plane,
}

frustum_from_matrix :: proc(view_projection: Matrix_4) -> (Frustum, bool) {
	rows := [4][4]f32 {
		{view_projection[0], view_projection[4], view_projection[8], view_projection[12]},
		{view_projection[1], view_projection[5], view_projection[9], view_projection[13]},
		{view_projection[2], view_projection[6], view_projection[10], view_projection[14]},
		{view_projection[3], view_projection[7], view_projection[11], view_projection[15]},
	}
	combined := [FRUSTUM_PLANE_COUNT][4]f32 {
		rows[3] + rows[0],
		rows[3] - rows[0],
		rows[3] + rows[1],
		rows[3] - rows[1],
		rows[3] + rows[2],
		rows[3] - rows[2],
	}
	result: Frustum
	for row, index in combined {
		plane, ok := _scene_plane_normalize(row)
		if !ok do return {}, false
		result.planes[index] = plane
	}
	return result, true
}

frustum_intersects_bounds :: proc(frustum: Frustum, bounds: asset.Bounds_3D) -> bool {
	assert(asset.bounds_valid(bounds), "frustum_intersects_bounds: invalid bounds")
	for plane in frustum.planes {
		farthest := asset.Vec3 {
			bounds.maximum[0] if plane.normal[0] >= 0 else bounds.minimum[0],
			bounds.maximum[1] if plane.normal[1] >= 0 else bounds.minimum[1],
			bounds.maximum[2] if plane.normal[2] >= 0 else bounds.minimum[2],
		}
		distance :=
			plane.normal[0] * farthest[0] +
			plane.normal[1] * farthest[1] +
			plane.normal[2] * farthest[2] +
			plane.distance
		if distance < 0 do return false
	}
	return true
}

@(private)
_scene_plane_normalize :: proc(row: [4]f32) -> (Plane, bool) {
	for component in row {
		if math.is_nan(component) || math.is_inf(component, 0) do return {}, false
	}
	length_squared := row[0] * row[0] + row[1] * row[1] + row[2] * row[2]
	if length_squared <= 1e-12 do return {}, false
	length := math.sqrt(length_squared)
	return {{row[0] / length, row[1] / length, row[2] / length}, row[3] / length}, true
}
