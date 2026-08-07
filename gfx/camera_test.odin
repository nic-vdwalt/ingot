#+build !js
package gfx

import "core:math"
import "core:math/linalg"
import "core:testing"

camera_test_value :: proc(projection: CameraProjection = .PERSPECTIVE) -> Camera3D {
	return {
		position = {-10, 0, 0},
		target = {0, 0, 0},
		up = CAMERA_WORLD_UP,
		fovy = 60,
		projection = projection,
	}
}

camera_test_vector_near :: proc(t: ^testing.T, got, want: Vector3, tolerance: f32) {
	testing.expect(t, abs(got.x - want.x) < tolerance)
	testing.expect(t, abs(got.y - want.y) < tolerance)
	testing.expect(t, abs(got.z - want.z) < tolerance)
}

@(test)
camera_basis_uses_ros_world_axes :: proc(t: ^testing.T) {
	camera := camera_test_value()
	testing.expect_value(t, GetCameraForward(camera), CAMERA_WORLD_FORWARD)
	testing.expect_value(t, GetCameraRight(camera), CAMERA_WORLD_RIGHT)
	testing.expect_value(t, GetCameraUp(camera), CAMERA_WORLD_UP)
}

@(test)
camera_update_is_frame_rate_independent :: proc(t: ^testing.T) {
	one_step := camera_test_value()
	many_steps := one_step
	motion := Camera3D_Motion {
		linear_velocity  = {4, 2, 1},
		angular_velocity = {0.1, -0.2, 0.3},
		zoom_velocity    = 2,
	}
	UpdateCamera(&one_step, motion, 1)
	for _ in 0 ..< 100 do UpdateCamera(&many_steps, motion, 0.01)
	camera_test_vector_near(t, many_steps.position, one_step.position, 1e-3)
	camera_test_vector_near(t, many_steps.target, one_step.target, 1e-3)
	camera_test_vector_near(t, many_steps.up, one_step.up, 1e-4)
}

@(test)
camera_update_translates_on_local_axes :: proc(t: ^testing.T) {
	cases := [?]struct {
		velocity: Vector3,
		want:     Vector3,
	}{{{2, 0, 0}, {-8, 0, 0}}, {{0, 2, 0}, {-10, 2, 0}}, {{0, 0, 2}, {-10, 0, 2}}}
	for test_case in cases {
		camera := camera_test_value()
		UpdateCamera(&camera, {linear_velocity = test_case.velocity}, 1)
		camera_test_vector_near(t, camera.position, test_case.want, 1e-5)
	}
}

@(test)
camera_update_rotates_about_local_axes :: proc(t: ^testing.T) {
	roll := camera_test_value()
	pitch := roll
	yaw := roll
	UpdateCamera(&roll, {angular_velocity = {math.PI / 2, 0, 0}}, 1)
	UpdateCamera(&pitch, {angular_velocity = {0, math.PI / 2, 0}}, 1)
	UpdateCamera(&yaw, {angular_velocity = {0, 0, math.PI / 2}}, 1)
	camera_test_vector_near(t, roll.up, CAMERA_WORLD_LEFT * -1, 1e-5)
	camera_test_vector_near(t, GetCameraForward(pitch), CAMERA_WORLD_UP * -1, 1e-5)
	camera_test_vector_near(t, GetCameraForward(yaw), CAMERA_WORLD_LEFT, 1e-5)
}

@(test)
camera_update_dolly_clamps_target_distance :: proc(t: ^testing.T) {
	camera := camera_test_value()
	UpdateCamera(&camera, {zoom_velocity = 100}, 1)
	distance := camera.target - camera.position
	testing.expect(t, abs(math.sqrt(linalg.dot(distance, distance)) - 1e-4) < 1e-6)
}

@(test)
camera_update_zero_delta_is_noop :: proc(t: ^testing.T) {
	camera := camera_test_value()
	want := camera
	UpdateCamera(&camera, {}, 0)
	testing.expect_value(t, camera, want)
}

@(test)
camera_update_small_speed_large_angle_is_frame_rate_independent :: proc(t: ^testing.T) {
	one_step := camera_test_value()
	many_steps := one_step
	motion := Camera3D_Motion {
		linear_velocity  = {1e-3, 2e-3, 0},
		angular_velocity = {0, 0, 5e-7},
	}
	dt: f32 = 2e6
	UpdateCamera(&one_step, motion, dt)
	for _ in 0 ..< 100 do UpdateCamera(&many_steps, motion, dt / 100)
	camera_test_vector_near(t, many_steps.position, one_step.position, 2)
	camera_test_vector_near(t, many_steps.target, one_step.target, 2)
}

@(test)
camera_update_rejects_parallel_up :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "UpdateCamera: forward and up are parallel")
	camera := camera_test_value()
	camera.up = CAMERA_WORLD_FORWARD
	UpdateCamera(&camera, {}, 1)
	testing.fail_now(t, "UpdateCamera accepted a parallel up vector")
}

@(test)
camera_update_rejects_non_finite_input :: proc(t: ^testing.T) {
	testing.expect_assert_message(t, "UpdateCamera: non-finite delta time")
	camera := camera_test_value()
	UpdateCamera(&camera, {}, math.inf_f32(1))
	testing.fail_now(t, "UpdateCamera accepted non-finite delta time")
}

@(test)
camera_matrices_use_explicit_dimensions :: proc(t: ^testing.T) {
	camera := camera_test_value()
	view_square, projection_square, vp_square := _camera_matrices(camera, 800, 800)
	view_wide, projection_wide, vp_wide := _camera_matrices(camera, 1600, 800)
	testing.expect_value(t, view_square, view_wide)
	testing.expect(t, projection_square != projection_wide)
	testing.expect(t, vp_square != vp_wide)

	ortho := camera_test_value(.ORTHOGRAPHIC)
	_, ortho_square, _ := _camera_matrices(ortho, 800, 800)
	_, ortho_wide, _ := _camera_matrices(ortho, 1600, 800)
	testing.expect(t, ortho_square != ortho_wide)

	view_clamped, projection_clamped, vp_clamped := _camera_matrices(camera, 0, -4)
	view_one, projection_one, vp_one := _camera_matrices(camera, 1, 1)
	testing.expect_value(t, view_clamped, view_one)
	testing.expect_value(t, projection_clamped, projection_one)
	testing.expect_value(t, vp_clamped, vp_one)
}

@(test)
world_to_screen_does_not_mutate_active_projection :: proc(t: ^testing.T) {
	old_width, old_height := g.width, g.height
	old_projection, old_view, old_vp := cam3d_proj, cam3d_view, cam3d_vp
	old_available := cam3d_projection_available
	defer {
		g.width, g.height = old_width, old_height
		cam3d_proj, cam3d_view, cam3d_vp = old_projection, old_view, old_vp
		cam3d_projection_available = old_available
	}
	cam3d_projection_available = true

	g.width, g.height = 800, 600
	cam3d_proj = Matrix(2)
	cam3d_view = Matrix(3)
	cam3d_vp = Matrix(4)
	point := GetWorldToScreen({0, 0, 0}, camera_test_value())
	testing.expect(t, abs(point.x - 400) < 1e-4)
	testing.expect(t, abs(point.y - 300) < 1e-4)
	testing.expect_value(t, cam3d_proj, Matrix(2))
	testing.expect_value(t, cam3d_view, Matrix(3))
	testing.expect_value(t, cam3d_vp, Matrix(4))
}

@(test)
world_to_screen_pro_uses_arbitrary_matrix :: proc(t: ^testing.T) {
	old_width, old_height := g.width, g.height
	old_projection, old_view, old_vp := cam3d_proj, cam3d_view, cam3d_vp
	old_available := cam3d_projection_available
	defer {
		g.width, g.height = old_width, old_height
		cam3d_proj, cam3d_view, cam3d_vp = old_projection, old_view, old_vp
		cam3d_projection_available = old_available
	}
	cam3d_projection_available = true
	g.width, g.height = 800, 600
	cam3d_proj = Matrix(2)
	cam3d_view = Matrix(3)
	cam3d_vp = Matrix(4)
	view_projection := Matrix(1)
	view_projection[0, 3] = 0.5
	view_projection[1, 3] = -0.5
	point := GetWorldToScreenPro({0, 0, 0}, view_projection)
	testing.expect_value(t, point, Vector2{600, 450})
	testing.expect_value(t, cam3d_proj, Matrix(2))
	testing.expect_value(t, cam3d_view, Matrix(3))
	testing.expect_value(t, cam3d_vp, Matrix(4))
}

@(test)
gpu_camera_setup_preserves_window_and_active_camera :: proc(t: ^testing.T) {
	old_width, old_height := g.width, g.height
	old_projection, old_view, old_vp := cam3d_proj, cam3d_view, cam3d_vp
	old_available := cam3d_projection_available
	defer {
		g.width, g.height = old_width, old_height
		cam3d_proj, cam3d_view, cam3d_vp = old_projection, old_view, old_vp
		cam3d_projection_available = old_available
	}
	cam3d_projection_available = true

	g.width, g.height = 640, 480
	cam3d_proj = Matrix(2)
	cam3d_view = Matrix(3)
	cam3d_vp = Matrix(4)
	target: Gpu_3D_Target
	target.texture.texture.width = 1920
	target.texture.texture.height = 1080
	pass := Gpu_3D_Pass {
		target = &target,
	}
	camera := camera_test_value()
	_gpu_3d_set_camera(&pass, camera)
	_, _, expected := _camera_matrices(camera, 1920, 1080)
	testing.expect_value(t, pass.view_projection, expected)
	testing.expect_value(t, g.width, i32(640))
	testing.expect_value(t, g.height, i32(480))
	testing.expect_value(t, cam3d_proj, Matrix(2))
	testing.expect_value(t, cam3d_view, Matrix(3))
	testing.expect_value(t, cam3d_vp, Matrix(4))
}
