// ingot:gfx — camera + matrix helpers (raylib-named). 3D is CPU-projected: a
// Camera3D view-projection maps world points to screen space so DrawLine3D and
// GetWorldToScreen work without a dedicated 3D pipeline. This covers the light
// 3D use (axis lines, world->screen anchors); a full mesh/material/instanced 3D
// renderer is a separate WebGPU effort (see README status notes).
package gfx

import "core:math"
import "core:math/linalg"

Matrix :: matrix[4, 4]f32

@(private) cam3d_active: bool
@(private) cam3d_vp: Matrix

@(private)
_vp_from :: proc(camera: Camera3D) -> Matrix {
	aspect := f32(max(g.width, 1)) / f32(max(g.height, 1))
	view := linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
	proj: Matrix
	if camera.projection == .ORTHOGRAPHIC {
		top := camera.fovy / 2.0
		right := top * aspect
		proj = linalg.matrix_ortho3d_f32(-right, right, -top, top, 0.01, 1000.0)
	} else {
		proj = linalg.matrix4_perspective_f32(camera.fovy * math.PI / 180.0, aspect, 0.01, 1000.0)
	}
	return proj * view
}

BeginMode3D :: proc(camera: Camera3D) {
	cam3d_vp = _vp_from(camera)
	cam3d_active = true
}

EndMode3D :: proc() { cam3d_active = false }

@(private)
_project :: proc(vp: Matrix, p: Vector3) -> (Vector2, bool) {
	clip := vp * [4]f32{p.x, p.y, p.z, 1}
	if clip.w <= 0.0001 do return {}, false
	nx := clip.x / clip.w
	ny := clip.y / clip.w
	sx := (nx * 0.5 + 0.5) * f32(g.width)
	sy := (1.0 - (ny * 0.5 + 0.5)) * f32(g.height)
	return {sx, sy}, true
}

DrawLine3D :: proc(startPos, endPos: Vector3, color: Color) {
	if !cam3d_active do return
	a, oka := _project(cam3d_vp, startPos)
	b, okb := _project(cam3d_vp, endPos)
	if oka && okb do DrawLineEx(a, b, 1, color)
}

GetWorldToScreen :: proc(position: Vector3, camera: Camera3D) -> Vector2 {
	vp := _vp_from(camera)
	s, _ := _project(vp, position)
	return s
}

GetCameraMatrix :: proc(camera: Camera3D) -> Matrix {
	return linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
}

MatrixTranslate :: proc(x, y, z: f32) -> Matrix { return linalg.matrix4_translate_f32({x, y, z}) }
MatrixScale :: proc(x, y, z: f32) -> Matrix { return linalg.matrix4_scale_f32({x, y, z}) }
