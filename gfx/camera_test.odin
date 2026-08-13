#+build !js
package gfx

import "core:math"
import "core:math/linalg"
import "core:sync"
import "core:testing"

@(private = "file")
g_camera_test_guard: sync.Mutex

camera_test_lock :: proc() {
	sync.mutex_lock(&g_camera_test_guard)
}

camera_test_unlock :: proc() {
	sync.mutex_unlock(&g_camera_test_guard)
}

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

// The four world-axis constants must agree with each other, not merely with
// their own names: a swapped pair still reads correctly at each use site and
// only shows up as mirrored geometry much later. linalg.cross is not a
// compile-time expression, so this is a runtime test rather than a #assert.
@(test)
camera_world_axes_are_right_handed :: proc(t: ^testing.T) {
	testing.expect_value(t, linalg.cross(CAMERA_WORLD_FORWARD, CAMERA_WORLD_LEFT), CAMERA_WORLD_UP)
	testing.expect_value(t, CAMERA_WORLD_RIGHT, -CAMERA_WORLD_LEFT)
	// Completing the cycle catches a pair swapped in a way the first identity
	// alone would accept.
	testing.expect_value(t, linalg.cross(CAMERA_WORLD_LEFT, CAMERA_WORLD_UP), CAMERA_WORLD_FORWARD)
	testing.expect_value(t, linalg.cross(CAMERA_WORLD_UP, CAMERA_WORLD_FORWARD), CAMERA_WORLD_LEFT)
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
orbit_camera_round_trips_camera :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, ok := orbit_camera_from_camera(camera)
	testing.expect(t, ok)
	result := camera
	orbit_camera_apply(state, &result)
	camera_test_vector_near(t, result.position, camera.position, 1e-5)
	camera_test_vector_near(t, result.target, camera.target, 1e-5)
}

@(test)
orbit_camera_rates_are_frame_rate_independent :: proc(t: ^testing.T) {
	camera := camera_test_value()
	one_step, _ := orbit_camera_from_camera(camera)
	many_steps := one_step
	config := orbit_camera_config_default()
	input := Orbit_Camera_Input {
		rotate_rate = {0.5, 0.25},
		zoom_rate   = 0.5,
	}
	update_orbit_camera(&one_step, input, config, 1)
	for _ in 0 ..< 100 do update_orbit_camera(&many_steps, input, config, 0.01)
	testing.expect(t, abs(one_step.yaw - many_steps.yaw) < 1e-4)
	testing.expect(t, abs(one_step.pitch - many_steps.pitch) < 1e-4)
	testing.expect(t, abs(one_step.distance - many_steps.distance) < 1e-4)
}

@(test)
orbit_camera_drag_and_scroll_are_frame_deltas :: proc(t: ^testing.T) {
	camera := camera_test_value()
	first, _ := orbit_camera_from_camera(camera)
	second := first
	config := orbit_camera_config_default()
	input := Orbit_Camera_Input {
		pointer_drag = {10, 5},
		scroll       = 0.25,
	}
	update_orbit_camera(&first, input, config, 0)
	update_orbit_camera(&second, input, config, 1)
	testing.expect_value(t, first, second)
	testing.expect(t, first.yaw != 0)
	testing.expect(t, first.pitch != 0)
	testing.expect(t, first.distance == 9.5)
}

@(test)
orbit_camera_clamps_pitch_and_distance :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	config := orbit_camera_config_default()
	input := Orbit_Camera_Input {
		pointer_drag = {0, 10000},
		scroll       = 10000,
	}
	update_orbit_camera(&state, input, config, 1)
	testing.expect_value(t, state.pitch, config.max_pitch)
	testing.expect_value(t, state.distance, config.min_distance)
	input = {
		pointer_drag = {0, -20000},
		scroll       = -10000,
	}
	update_orbit_camera(&state, input, config, 1)
	testing.expect_value(t, state.pitch, config.min_pitch)
	testing.expect_value(t, state.distance, config.max_distance)
}

@(test)
orbit_camera_rejects_coincident_camera :: proc(t: ^testing.T) {
	camera := camera_test_value()
	camera.position = camera.target
	_, ok := orbit_camera_from_camera(camera)
	testing.expect_value(t, ok, false)
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
	camera_test_lock()
	defer camera_test_unlock()
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
	camera_test_lock()
	defer camera_test_unlock()
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
	camera_test_lock()
	defer camera_test_unlock()
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

@(test)
orbit_camera_pan_moves_only_target :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	before := state
	config := orbit_camera_config_default()
	input := Orbit_Camera_Input {
		pan = {3, -2, 1},
	}
	update_orbit_camera(&state, input, config, 0.016)
	camera_test_vector_near(t, state.target, before.target + Vector3{3, -2, 1}, 1e-6)
	testing.expect_value(t, state.yaw, before.yaw)
	testing.expect_value(t, state.pitch, before.pitch)
	testing.expect_value(t, state.distance, before.distance)
}

@(test)
orbit_camera_zoom_toward_keeps_focus_direction :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	config := orbit_camera_config_default()
	focus := Vector3{4, 6, 0}
	applied := camera
	orbit_camera_apply(state, &applied)
	direction_before := linalg.normalize(focus - applied.position)
	scroll := f32(1)
	orbit_camera_zoom_toward(&state, focus, &scroll, config)
	testing.expect(t, state.distance == 8)
	testing.expect_value(t, scroll, f32(0))
	orbit_camera_apply(state, &applied)
	direction_after := linalg.normalize(focus - applied.position)
	camera_test_vector_near(t, direction_after, direction_before, 1e-5)
}

@(test)
orbit_camera_zoom_toward_respects_clamps_and_zero_scroll :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	config := orbit_camera_config_default()
	before := state
	// Zero scroll is the identity.
	scroll := f32(0)
	orbit_camera_zoom_toward(&state, {5, 5, 0}, &scroll, config)
	testing.expect_value(t, state, before)
	// A huge zoom-in clamps at min_distance and still moves the target only
	// by the clamped fraction.
	scroll = 10000
	orbit_camera_zoom_toward(&state, {5, 5, 0}, &scroll, config)
	testing.expect_value(t, state.distance, config.min_distance)
	testing.expect_value(t, scroll, f32(0))
	// Already at the clamp: further zoom-in is the identity, so the target
	// cannot creep toward the focus without any distance change. The scroll
	// channel is still consumed so it cannot leak into the plain zoom path.
	at_clamp := state
	scroll = 1
	orbit_camera_zoom_toward(&state, {5, 5, 0}, &scroll, config)
	testing.expect_value(t, state, at_clamp)
	testing.expect_value(t, scroll, f32(0))
}

@(test)
orbit_camera_zoom_toward_consumes_scroll :: proc(t: ^testing.T) {
	state := Orbit_Camera_State {
		target   = {0, 0, 0},
		pitch    = 0.5,
		distance = 10,
	}
	config := orbit_camera_config_default()
	scroll := f32(1)
	orbit_camera_zoom_toward(&state, {5, 5, 0}, &scroll, config)
	testing.expect_value(t, scroll, f32(0))
	testing.expect(t, state.distance < 10, "positive scroll must dolly in")
}

@(test)
orbit_camera_grab_pan_keeps_anchor_under_ray :: proc(t: ^testing.T) {
	pan: Orbit_Camera_Grab_Pan
	orbit_camera_grab_pan_begin(&pan, {2, 3, 1})
	// Straight-down ray over (5, 3): world must shift by anchor - hit = (-3, 0).
	delta, ok := orbit_camera_grab_pan_delta(pan, {origin = {5, 3, 10}, direction = {0, 0, -1}})
	testing.expect(t, ok)
	testing.expect_value(t, delta, Vector3{-3, 0, 0})
	orbit_camera_grab_pan_end(&pan)
	_, idle := orbit_camera_grab_pan_delta(pan, {origin = {5, 3, 10}, direction = {0, 0, -1}})
	testing.expect(t, !idle, "inactive grab pan must not produce a delta")
}

@(test)
orbit_camera_grab_pan_rejects_parallel_ray :: proc(t: ^testing.T) {
	pan: Orbit_Camera_Grab_Pan
	orbit_camera_grab_pan_begin(&pan, {0, 0, 2})
	_, ok := orbit_camera_grab_pan_delta(pan, {origin = {0, 0, 10}, direction = {1, 0, 0}})
	testing.expect(t, !ok, "ray parallel to the pan plane must miss")
}

@(test)
orbit_camera_key_pan_moves_target_camera_relative :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	before := state
	config := orbit_camera_config_default()
	config.pan_speed = 2
	// Camera sits at -X looking +X (yaw = pi): forward pans toward +X and
	// right pans toward -Y.
	input := Orbit_Camera_Input {
		pan_rate = {0, 1},
	}
	update_orbit_camera(&state, input, config, 0.5)
	expected := before.target + Vector3{config.pan_speed * before.distance * 0.5, 0, 0}
	camera_test_vector_near(t, state.target, expected, 1e-4)
	testing.expect_value(t, state.yaw, before.yaw)
	testing.expect_value(t, state.distance, before.distance)
	state = before
	input = Orbit_Camera_Input {
		pan_rate = {1, 0},
	}
	update_orbit_camera(&state, input, config, 0.5)
	expected = before.target + Vector3{0, -config.pan_speed * before.distance * 0.5, 0}
	camera_test_vector_near(t, state.target, expected, 1e-4)
}

@(test)
orbit_camera_yaw_clamps_only_when_range_is_set :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	config := orbit_camera_config_default()
	// Default (zero) yaw range never clamps: a full-turn spin accumulates.
	input := Orbit_Camera_Input {
		rotate_rate = {1, 0},
	}
	start_yaw := state.yaw
	update_orbit_camera(&state, input, config, 10)
	testing.expect(t, state.yaw > start_yaw + 6)
	// A finite range clamps at its bounds.
	config.min_yaw = start_yaw - 0.25
	config.max_yaw = start_yaw + 0.25
	update_orbit_camera(&state, input, config, 10)
	testing.expect_value(t, state.yaw, config.max_yaw)
	input.rotate_rate.x = -1
	update_orbit_camera(&state, input, config, 100)
	testing.expect_value(t, state.yaw, config.min_yaw)
}

@(test)
orbit_camera_pan_rate_defaults_are_identity :: proc(t: ^testing.T) {
	camera := camera_test_value()
	state, _ := orbit_camera_from_camera(camera)
	before := state
	config := orbit_camera_config_default()
	// pan_speed defaults to 0, so a pan rate alone must not move the target.
	input := Orbit_Camera_Input {
		pan_rate = {1, 1},
	}
	update_orbit_camera(&state, input, config, 0.5)
	testing.expect_value(t, state, before)
	// A configured pan speed with zero rate is also the identity.
	config.pan_speed = 3
	update_orbit_camera(&state, Orbit_Camera_Input{}, config, 0.5)
	testing.expect_value(t, state, before)
}
