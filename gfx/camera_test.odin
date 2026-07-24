#+build !js
package gfx

import "core:testing"

camera_test_value :: proc(projection: CameraProjection = .PERSPECTIVE) -> Camera3D {
	return {
		position = {0, 0, 10},
		target = {0, 0, 0},
		up = {0, 1, 0},
		fovy = 60,
		projection = projection,
	}
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
	defer {
		g.width, g.height = old_width, old_height
		cam3d_proj, cam3d_view, cam3d_vp = old_projection, old_view, old_vp
	}

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
gpu_camera_setup_preserves_window_and_active_camera :: proc(t: ^testing.T) {
	old_width, old_height := g.width, g.height
	old_projection, old_view, old_vp := cam3d_proj, cam3d_view, cam3d_vp
	defer {
		g.width, g.height = old_width, old_height
		cam3d_proj, cam3d_view, cam3d_vp = old_projection, old_view, old_vp
	}

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
