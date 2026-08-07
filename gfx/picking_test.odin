#+build !js
package gfx

import "core:math"
import "core:testing"

picking_test_ray :: proc(origin: Vector3 = {-10, 0, 0}) -> Ray_3D {
	return {origin = origin, direction = CAMERA_WORLD_FORWARD}
}

picking_test_hit_near :: proc(
	t: ^testing.T,
	hit: Ray_Hit,
	position, normal: Vector3,
	distance: f32,
) {
	camera_test_vector_near(t, hit.position, position, 1e-5)
	camera_test_vector_near(t, hit.normal, normal, 1e-5)
	testing.expect(t, abs(hit.distance - distance) < 1e-5)
}

@(test)
screen_to_world_ray_uses_perspective_ros_basis :: proc(t: ^testing.T) {
	camera := camera_test_value()
	center := screen_to_world_ray({400, 300}, camera, 800, 600)
	testing.expect_value(t, center.origin, camera.position)
	camera_test_vector_near(t, center.direction, CAMERA_WORLD_FORWARD, 1e-5)

	top_left := screen_to_world_ray({0, 0}, camera, 800, 600)
	testing.expect(t, top_left.direction.x > 0)
	testing.expect(t, top_left.direction.y > 0)
	testing.expect(t, top_left.direction.z > 0)
}

@(test)
screen_to_world_ray_offsets_orthographic_origin :: proc(t: ^testing.T) {
	camera := camera_test_value(.ORTHOGRAPHIC)
	camera.fovy = 6
	ray := screen_to_world_ray({0, 0}, camera, 800, 600)
	camera_test_vector_near(t, ray.origin, {-10, 4, 3}, 1e-5)
	camera_test_vector_near(t, ray.direction, CAMERA_WORLD_FORWARD, 1e-5)
}

@(test)
intersect_plane_reports_forward_hit :: proc(t: ^testing.T) {
	normal := Vector3{-1, 0, 0}
	hit, ok := intersect_plane(picking_test_ray(), {point = {}, normal = normal})
	testing.expect(t, ok)
	picking_test_hit_near(t, hit, {}, normal, 10)
}

@(test)
intersect_plane_handles_coplanar_and_parallel_rays :: proc(t: ^testing.T) {
	plane := Plane_3D {
		point  = {},
		normal = CAMERA_WORLD_UP,
	}
	hit, coplanar := intersect_plane(picking_test_ray({}), plane)
	testing.expect(t, coplanar)
	picking_test_hit_near(t, hit, {}, CAMERA_WORLD_UP, 0)

	_, parallel := intersect_plane(picking_test_ray({0, 0, 1}), plane)
	testing.expect(t, !parallel)
}

@(test)
intersect_plane_rejects_hits_behind_ray :: proc(t: ^testing.T) {
	_, ok := intersect_plane(
		picking_test_ray(),
		{point = {-20, 0, 0}, normal = CAMERA_WORLD_FORWARD},
	)
	testing.expect(t, !ok)
}

@(test)
intersect_sphere_reports_entry_and_exit_hits :: proc(t: ^testing.T) {
	sphere := Sphere_3D {
		center = {},
		radius = 2,
	}
	entry, entry_ok := intersect_sphere(picking_test_ray(), sphere)
	testing.expect(t, entry_ok)
	picking_test_hit_near(t, entry, {-2, 0, 0}, -CAMERA_WORLD_FORWARD, 8)

	exit, exit_ok := intersect_sphere(picking_test_ray({}), sphere)
	testing.expect(t, exit_ok)
	picking_test_hit_near(t, exit, {2, 0, 0}, CAMERA_WORLD_FORWARD, 2)
}

@(test)
intersect_sphere_reports_tangent_and_miss :: proc(t: ^testing.T) {
	sphere := Sphere_3D {
		center = {},
		radius = 2,
	}
	tangent, tangent_ok := intersect_sphere(picking_test_ray({-10, 2, 0}), sphere)
	testing.expect(t, tangent_ok)
	picking_test_hit_near(t, tangent, {0, 2, 0}, CAMERA_WORLD_LEFT, 10)

	_, miss := intersect_sphere(picking_test_ray({-10, 3, 0}), sphere)
	testing.expect(t, !miss)
}

@(test)
intersect_bounds_reports_entry_and_exit_hits :: proc(t: ^testing.T) {
	bounds := Bounds_3D {
		minimum = {-1, -1, -1},
		maximum = {1, 1, 1},
	}
	entry, entry_ok := intersect_bounds(picking_test_ray(), bounds)
	testing.expect(t, entry_ok)
	picking_test_hit_near(t, entry, {-1, 0, 0}, -CAMERA_WORLD_FORWARD, 9)

	exit, exit_ok := intersect_bounds(picking_test_ray({}), bounds)
	testing.expect(t, exit_ok)
	picking_test_hit_near(t, exit, {1, 0, 0}, CAMERA_WORLD_FORWARD, 1)
}

@(test)
intersect_bounds_handles_parallel_axes_and_misses :: proc(t: ^testing.T) {
	bounds := Bounds_3D {
		minimum = {-1, -1, -1},
		maximum = {1, 1, 1},
	}
	hit, hit_ok := intersect_bounds(picking_test_ray({-10, 1, 1}), bounds)
	testing.expect(t, hit_ok)
	picking_test_hit_near(t, hit, {-1, 1, 1}, -CAMERA_WORLD_FORWARD, 9)

	_, miss := intersect_bounds(picking_test_ray({-10, 2, 0}), bounds)
	testing.expect(t, !miss)
}

@(test)
screen_to_world_ray_rejects_non_positive_viewport :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "screen_to_world_ray: non-positive viewport width")
	_ = screen_to_world_ray({}, camera_test_value(), 0, 600)
	testing.fail_now(t, "screen_to_world_ray accepted a zero-width viewport")
}

@(test)
intersections_reject_non_normalized_ray :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "intersect_sphere: invalid ray")
	ray := Ray_3D {
		direction = {2, 0, 0},
	}
	_, _ = intersect_sphere(ray, {radius = 1})
	testing.fail_now(t, "intersect_sphere accepted a non-normalized ray")
}

@(test)
intersections_reject_reversed_bounds :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "intersect_bounds: invalid bounds")
	bounds := Bounds_3D {
		minimum = {1, 0, 0},
		maximum = {-1, 0, 0},
	}
	_, _ = intersect_bounds(picking_test_ray(), bounds)
	testing.fail_now(t, "intersect_bounds accepted reversed bounds")
}

@(test)
intersections_reject_non_positive_sphere :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "intersect_sphere: non-positive radius")
	_, _ = intersect_sphere(picking_test_ray(), {})
	testing.fail_now(t, "intersect_sphere accepted a zero-radius sphere")
}

@(test)
screen_to_world_ray_stays_finite_at_extreme_fovy :: proc(t: ^testing.T) {
	camera := camera_test_value()
	camera.fovy = 179
	ray := screen_to_world_ray({800, 600}, camera, 800, 600)
	testing.expect(t, _camera_vector_is_finite(ray.origin))
	testing.expect(t, _camera_vector_is_finite(ray.direction))
	length := math.sqrt(
		ray.direction.x * ray.direction.x +
		ray.direction.y * ray.direction.y +
		ray.direction.z * ray.direction.z,
	)
	testing.expect(t, abs(length - 1) < 1e-4)
}
