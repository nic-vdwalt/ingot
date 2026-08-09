// Pure-CPU view-frustum helpers for visibility culling. A frustum is
// extracted from a view-projection matrix with the Gribb-Hartmann row
// method, producing six inward-facing planes in normal-plus-distance form.
// Containment tests are conservative: a bounds test may report visible for a
// box that only straddles a frustum corner, but it never reports culled for
// visible geometry - callers cull draws, so false positives cost a draw
// while false negatives would drop geometry.
package gfx

import "core:math"
import "core:math/linalg"

FRUSTUM_PLANE_COUNT :: 6

Frustum_Plane :: struct {
	normal:   Vector3, // unit normal pointing into the frustum
	distance: f32, // plane equation: dot(normal, p) + distance >= 0 inside
}

Frustum_3D :: struct {
	planes: [FRUSTUM_PLANE_COUNT]Frustum_Plane, // left, right, bottom, top, near, far
}

// frustum_from_matrix extracts the six clip planes from a view-projection
// matrix. The near plane uses the GL-style row3 + row2 combination, which is
// exact for [-1, 1] clip depth and slightly looser for the [0, 1] convention
// - looser is safe here because the contract is conservative culling.
frustum_from_matrix :: proc(view_projection: Matrix) -> Frustum_3D {
	assert(_camera_matrix_is_finite(view_projection), "frustum_from_matrix: non-finite matrix")
	row0 := _frustum_matrix_row(view_projection, 0)
	row1 := _frustum_matrix_row(view_projection, 1)
	row2 := _frustum_matrix_row(view_projection, 2)
	row3 := _frustum_matrix_row(view_projection, 3)
	combined := [FRUSTUM_PLANE_COUNT][4]f32 {
		row3 + row0, // left
		row3 - row0, // right
		row3 + row1, // bottom
		row3 - row1, // top
		row3 + row2, // near
		row3 - row2, // far
	}
	frustum: Frustum_3D
	for plane_row, index in combined {
		plane, ok := _frustum_plane_normalize(plane_row)
		assert(ok, "frustum_from_matrix: degenerate frustum plane")
		frustum.planes[index] = plane
	}
	return frustum
}

// camera_frustum builds the visibility frustum for a camera and viewport,
// matching the projection used by begin_gpu_3d for the same camera.
camera_frustum :: proc(camera: Camera3D, viewport_width, viewport_height: i32) -> Frustum_3D {
	assert(viewport_width > 0, "camera_frustum: non-positive viewport width")
	assert(viewport_height > 0, "camera_frustum: non-positive viewport height")
	assert(_f32_is_finite(camera.fovy), "camera_frustum: non-finite fovy")
	assert(camera.fovy > 0, "camera_frustum: non-positive fovy")
	if camera.projection == .PERSPECTIVE {
		assert(camera.fovy < 180, "camera_frustum: perspective fovy outside range")
	}
	_, _, view_projection := _camera_matrices(camera, viewport_width, viewport_height)
	return frustum_from_matrix(view_projection)
}

frustum_contains_point :: proc(frustum: Frustum_3D, point: Vector3) -> bool {
	assert(_camera_vector_is_finite(point), "frustum_contains_point: non-finite point")
	for plane in frustum.planes {
		assert(_camera_vector_is_finite(plane.normal), "frustum_contains_point: invalid plane")
		if linalg.dot(plane.normal, point) + plane.distance < 0 do return false
	}
	return true
}

// frustum_intersects_bounds tests an axis-aligned box with the p-vertex
// method: per plane, only the corner farthest along the plane normal is
// tested - if even that corner is outside, the whole box is. Conservative
// per the package contract above: never a false negative.
frustum_intersects_bounds :: proc(frustum: Frustum_3D, bounds: Bounds_3D) -> bool {
	assert(_bounds_3d_valid(bounds), "frustum_intersects_bounds: invalid bounds")
	for plane in frustum.planes {
		assert(_camera_vector_is_finite(plane.normal), "frustum_intersects_bounds: invalid plane")
		farthest := Vector3 {
			bounds.maximum.x if plane.normal.x >= 0 else bounds.minimum.x,
			bounds.maximum.y if plane.normal.y >= 0 else bounds.minimum.y,
			bounds.maximum.z if plane.normal.z >= 0 else bounds.minimum.z,
		}
		if linalg.dot(plane.normal, farthest) + plane.distance < 0 do return false
	}
	return true
}

@(private)
_frustum_matrix_row :: proc(value: Matrix, row: int) -> [4]f32 {
	assert(row >= 0, "_frustum_matrix_row: negative row")
	assert(row < 4, "_frustum_matrix_row: row out of range")
	return {value[row, 0], value[row, 1], value[row, 2], value[row, 3]}
}

// _frustum_plane_normalize scales a raw clip-row plane to a unit normal so
// signed distances are in world units - split out for headless testing.
@(private)
_frustum_plane_normalize :: proc(row: [4]f32) -> (Frustum_Plane, bool) {
	normal := Vector3{row[0], row[1], row[2]}
	length_squared := linalg.dot(normal, normal)
	if !_f32_is_finite(length_squared) || length_squared <= 1e-12 do return {}, false
	length := math.sqrt(length_squared)
	return {normal = normal / length, distance = row[3] / length}, true
}
