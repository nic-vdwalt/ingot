#+build !js
// Frustum helper coverage: plane extraction from a hand-built identity
// matrix (convention-independent - clip space equals world space), scale
// invariance of plane normalization, and behavioral containment/culling
// checks through camera_frustum with the same cameras the render fixture
// uses. Positive and negative space are both exercised per Tiger Style.
package gfx

import "core:testing"

@(test)
test_frustum_from_identity_matrix :: proc(t: ^testing.T) {
	frustum := frustum_from_matrix(1)
	// Identity clip volume: |x| <= 1, |y| <= 1, |z| <= 1 (GL-style near).
	testing.expect_value(t, frustum.planes[0].normal, Vector3{1, 0, 0})
	testing.expect_value(t, frustum.planes[0].distance, f32(1))
	testing.expect_value(t, frustum.planes[1].normal, Vector3{-1, 0, 0})
	testing.expect_value(t, frustum.planes[1].distance, f32(1))
	testing.expect_value(t, frustum.planes[2].normal, Vector3{0, 1, 0})
	testing.expect_value(t, frustum.planes[3].normal, Vector3{0, -1, 0})
	testing.expect_value(t, frustum.planes[4].normal, Vector3{0, 0, 1})
	testing.expect_value(t, frustum.planes[5].normal, Vector3{0, 0, -1})

	testing.expect(t, frustum_contains_point(frustum, {0, 0, 0}))
	testing.expect(t, frustum_contains_point(frustum, {0.99, 0.99, 0.99}))
	testing.expect(t, frustum_contains_point(frustum, {1, 0, 0})) // on-boundary accepted
	testing.expect(t, !frustum_contains_point(frustum, {2, 0, 0}))
	testing.expect(t, !frustum_contains_point(frustum, {0, -1.01, 0}))
}

@(test)
test_frustum_plane_normalize_is_scale_invariant :: proc(t: ^testing.T) {
	plane, ok := _frustum_plane_normalize({2, 0, 0, 6})
	testing.expect(t, ok)
	testing.expect_value(t, plane.normal, Vector3{1, 0, 0})
	testing.expect_value(t, plane.distance, f32(3))
	// A zero row cannot form a plane; rejected, not asserted, because the
	// caller decides whether the source matrix was a programmer error.
	_, zero_ok := _frustum_plane_normalize({0, 0, 0, 1})
	testing.expect(t, !zero_ok)
}

@(test)
test_camera_frustum_perspective_containment :: proc(t: ^testing.T) {
	// Same camera as examples/render_fixture: at x=-5 looking toward +X.
	camera := Camera3D {
		position   = {-5, 0, 0},
		target     = {0, 0, 0},
		up         = CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	frustum := camera_frustum(camera, 640, 480)
	testing.expect(t, frustum_contains_point(frustum, {-2, 0, 0}), "point ahead culled")
	testing.expect(t, frustum_contains_point(frustum, {-4.9, 0, 0}), "point near camera culled")
	testing.expect(t, !frustum_contains_point(frustum, {-7, 0, 0}), "point behind visible")
	testing.expect(t, !frustum_contains_point(frustum, {1500, 0, 0}), "point past far visible")
	testing.expect(t, !frustum_contains_point(frustum, {0, 200, 0}), "point far off-axis visible")
}

@(test)
test_camera_frustum_bounds_culling :: proc(t: ^testing.T) {
	camera := Camera3D {
		position   = {-5, 0, 0},
		target     = {0, 0, 0},
		up         = CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	frustum := camera_frustum(camera, 640, 480)
	// Box ahead of the camera: visible.
	testing.expect(t, frustum_intersects_bounds(frustum, {{-1, -1, -1}, {1, 1, 1}}))
	// Box straddling the near plane (contains the camera): conservative true.
	testing.expect(t, frustum_intersects_bounds(frustum, {{-6, -1, -1}, {-4, 1, 1}}))
	// Box fully behind the camera: culled.
	testing.expect(t, !frustum_intersects_bounds(frustum, {{-20, -1, -1}, {-10, 1, 1}}))
	// Box past the hardcoded 1000-unit far plane: culled.
	testing.expect(t, !frustum_intersects_bounds(frustum, {{1500, -1, -1}, {1600, 1, 1}}))
	// Box far off the vertical axis: culled.
	testing.expect(t, !frustum_intersects_bounds(frustum, {{-1, -1, 300}, {1, 1, 400}}))
}

@(test)
test_camera_frustum_orthographic_containment :: proc(t: ^testing.T) {
	// Orthographic fovy is the vertical world-unit height: top = fovy / 2.
	camera := Camera3D {
		position   = {-5, 0, 0},
		target     = {0, 0, 0},
		up         = CAMERA_WORLD_UP,
		fovy       = 10,
		projection = .ORTHOGRAPHIC,
	}
	frustum := camera_frustum(camera, 640, 480)
	testing.expect(t, frustum_contains_point(frustum, {0, 0, 4}), "point inside ortho culled")
	testing.expect(t, !frustum_contains_point(frustum, {0, 0, 20}), "point above ortho visible")
}

@(test)
test_camera_frustum_agrees_with_screen_ray :: proc(t: ^testing.T) {
	camera := Camera3D {
		position   = {-5, 0, 0},
		target     = {0, 0, 0},
		up         = CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
	}
	frustum := camera_frustum(camera, 640, 480)
	ray := screen_to_world_ray({320, 240}, camera, 640, 480)
	// Points along the center ray inside the depth range must be visible.
	testing.expect(t, frustum_contains_point(frustum, ray.origin + ray.direction * 1))
	testing.expect(t, frustum_contains_point(frustum, ray.origin + ray.direction * 10))
	testing.expect(t, frustum_contains_point(frustum, ray.origin + ray.direction * 500))
}
