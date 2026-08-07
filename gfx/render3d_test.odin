#+build !js
package gfx

import "core:math"
import "core:testing"

@(test)
billboard_corners_use_explicit_camera_in_pro_geometry :: proc(t: ^testing.T) {
	camera := camera_test_value()
	corners, ok := _billboard_world_corners(camera, {0, 0, 0}, CAMERA_WORLD_UP, {4, 2}, {2, 1}, 0)
	testing.expect(t, ok)
	camera_test_vector_near(t, corners[0], {0, 2, 1}, 1e-5)
	camera_test_vector_near(t, corners[1], {0, -2, 1}, 1e-5)
	camera_test_vector_near(t, corners[2], {0, -2, -1}, 1e-5)
	camera_test_vector_near(t, corners[3], {0, 2, -1}, 1e-5)
}

@(test)
billboard_corners_honor_origin_and_rotation :: proc(t: ^testing.T) {
	camera := camera_test_value()
	corners, ok := _billboard_world_corners(camera, {0, 0, 0}, CAMERA_WORLD_UP, {2, 2}, {0, 0}, 90)
	testing.expect(t, ok)
	camera_test_vector_near(t, corners[0], {}, 1e-5)
	camera_test_vector_near(t, corners[1], {0, 0, 2}, 1e-5)
	camera_test_vector_near(t, corners[2], {0, -2, 2}, 1e-5)
	camera_test_vector_near(t, corners[3], {0, -2, 0}, 1e-5)
}

@(test)
billboard_corners_reject_parallel_up :: proc(t: ^testing.T) {
	camera := camera_test_value()
	_, ok := _billboard_world_corners(camera, {}, CAMERA_WORLD_FORWARD, {1, 1}, {0.5, 0.5}, 0)
	testing.expect(t, !ok)
}

@(test)
billboard_rotation_remains_finite :: proc(t: ^testing.T) {
	camera := camera_test_value()
	corners, ok := _billboard_world_corners(
		camera,
		{},
		CAMERA_WORLD_UP,
		{3, 5},
		{1, 2},
		f32(math.PI),
	)
	testing.expect(t, ok)
	for corner in corners do testing.expect(t, _camera_vector_is_finite(corner))
}
