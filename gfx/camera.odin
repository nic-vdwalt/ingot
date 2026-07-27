// ingot:gfx — camera + matrix helpers (raylib-named). 3D is CPU-projected: a
// Camera3D view-projection maps world points to screen space so DrawLine3D and
// GetWorldToScreen work without a dedicated 3D pipeline. This covers the light
// 3D use (axis lines, world->screen anchors); a full mesh/material/instanced 3D
// renderer is a separate WebGPU effort (see README status notes).
package gfx

import "core:math"
import "core:math/linalg"

Matrix :: matrix[4, 4]f32

@(private)
cam3d_active: bool
@(private)
cam3d_vp: Matrix
@(private)
cam3d_proj: Matrix
@(private)
cam3d_view: Matrix
@(private)
cam3d: Camera3D
@(private)
cam3d_right: Vector3
@(private)
cam3d_up: Vector3
@(private)
cam3d_fwd: Vector3

@(private)
_camera_matrices :: proc(camera: Camera3D, width, height: i32) -> (Matrix, Matrix, Matrix) {
	aspect := f32(max(width, 1)) / f32(max(height, 1))
	view := linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
	projection: Matrix
	if camera.projection == .ORTHOGRAPHIC {
		top := camera.fovy / 2.0
		right := top * aspect
		projection = linalg.matrix_ortho3d_f32(-right, right, -top, top, 0.01, 1000.0)
	} else {
		projection = linalg.matrix4_perspective_f32(
			camera.fovy * math.PI / 180.0,
			aspect,
			0.01,
			1000.0,
		)
	}
	return view, projection, projection * view
}

// GetProjectionMatrix returns the last 3D projection matrix (rlgl parity for
// GetMatrixProjection). Identity before any BeginMode3D.
GetProjectionMatrix :: proc() -> Matrix {
	if cam3d_proj == (Matrix{}) do return Matrix(1)
	return cam3d_proj
}

// --- 2D camera -------------------------------------------------------------

@(private)
cam2d_active: bool
@(private)
cam2d_saved: Affine
@(private)
cam2d: Camera2D

// BeginMode2D applies `camera` to every 2D draw until EndMode2D, by installing
// its affine as the batch model transform. Unlike the CPU-projected 3D path
// this is exact: a Camera2D is an affine, and the batch already transforms
// every vertex it emits.
//
// The mode does not nest (raylib's does not either). The previous transform is
// saved so a camera composed on top of an rlgl matrix-stack offset restores
// that offset rather than resetting to identity.
//
// The batch is flushed on entry and exit, matching the .Matrix flush the rlgl
// matrix stack already performs, so a camera change is a visible draw-call
// boundary in the renderer stats.
BeginMode2D :: proc(camera: Camera2D) {
	assert(!cam2d_active, "BeginMode2D: already inside a 2D camera mode")
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Matrix)
	cam2d_saved = g.rend.model_xf
	cam2d = camera
	g.rend.model_xf = _affine_from_camera_2d(camera)
	cam2d_active = true
}

EndMode2D :: proc() {
	assert(cam2d_active, "EndMode2D: no active 2D camera mode")
	if _active_pass_begun() do renderer_flush(&g.rend, active_pass(), .Matrix)
	g.rend.model_xf = cam2d_saved
	cam2d_saved = {}
	cam2d = {}
	cam2d_active = false
}

// GetCameraMatrix2D returns the active-camera transform as a 4x4, matching
// raylib's rlgl-facing accessor. The 2D affine occupies the upper-left block.
GetCameraMatrix2D :: proc(camera: Camera2D) -> Matrix {
	m := _affine_from_camera_2d(camera)
	result := Matrix(1)
	result[0, 0] = m.a
	result[1, 0] = m.b
	result[0, 1] = m.c
	result[1, 1] = m.d
	result[0, 3] = m.tx
	result[1, 3] = m.ty
	return result
}

// GetWorldToScreen2D and GetScreenToWorld2D map between a Camera2D's world and
// the screen, for picking and for placing screen-space overlays on world
// anchors. They do not require an active BeginMode2D.
GetWorldToScreen2D :: proc(position: Vector2, camera: Camera2D) -> Vector2 {
	p := _affine_apply(_affine_from_camera_2d(camera), {position.x, position.y})
	return {p.x, p.y}
}

GetScreenToWorld2D :: proc(position: Vector2, camera: Camera2D) -> Vector2 {
	m := _affine_from_camera_2d(camera)
	determinant := m.a * m.d - m.b * m.c
	// A zero-zoom camera collapses the world to a point, so no screen position
	// maps back to a unique world position. raylib produces infinities here;
	// returning the camera target is bounded and obviously wrong to a caller.
	if determinant == 0 do return camera.target
	x := position.x - m.tx
	y := position.y - m.ty
	return {(m.d * x - m.c * y) / determinant, (m.a * y - m.b * x) / determinant}
}

BeginMode3D :: proc(camera: Camera3D) {
	width, height := _target_dims_i32()
	cam3d_view, cam3d_proj, cam3d_vp = _camera_matrices(camera, width, height)
	cam3d = camera
	// camera basis (world space) for CPU-projected billboards
	fwd := linalg.normalize(camera.target - camera.position)
	right := linalg.normalize(linalg.cross(fwd, camera.up))
	up := linalg.cross(right, fwd)
	cam3d_fwd = fwd
	cam3d_right = right
	cam3d_up = up
	cam3d_active = true
	// order any pending 2D geometry before 3D draws in the same pass
	FlushBatch()
}

EndMode3D :: proc() {
	FlushBatch()
	cam3d_active = false
}

// _target_dims returns the pixel dimensions of the pass 3D draws land in: the
// bound render target while one is active, else the logical window.
@(private)
_target_dims_i32 :: proc() -> (i32, i32) {
	if g.frame.rt != 0 do return g.frame.rt_w, g.frame.rt_h
	return g.width, g.height
}

@(private)
_target_dims :: proc() -> (f32, f32) {
	width, height := _target_dims_i32()
	return f32(width), f32(height)
}

@(private)
_project_dims :: proc(vp: Matrix, p: Vector3, w, h: f32) -> (Vector2, bool) {
	clip := vp * [4]f32{p.x, p.y, p.z, 1}
	if clip.w <= 0.0001 do return {}, false
	nx := clip.x / clip.w
	ny := clip.y / clip.w
	sx := (nx * 0.5 + 0.5) * w
	sy := (1.0 - (ny * 0.5 + 0.5)) * h
	return {sx, sy}, true
}

// _project maps a world point into the current 3D pass's pixel space.
@(private)
_project :: proc(vp: Matrix, p: Vector3) -> (Vector2, bool) {
	w, h := _target_dims()
	return _project_dims(vp, p, w, h)
}

DrawLine3D :: proc(startPos, endPos: Vector3, color: Color) {
	if !cam3d_active do return
	a, oka := _project(cam3d_vp, startPos)
	b, okb := _project(cam3d_vp, endPos)
	if oka && okb do DrawLineEx(a, b, 1, color)
}

// GetWorldToScreen projects to the logical window (screen overlays / picking),
// independent of any active render target.
GetWorldToScreen :: proc(position: Vector3, camera: Camera3D) -> Vector2 {
	_, _, vp := _camera_matrices(camera, g.width, g.height)
	s, _ := _project_dims(vp, position, f32(g.width), f32(g.height))
	return s
}

GetCameraMatrix :: proc(camera: Camera3D) -> Matrix {
	return linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
}

MatrixTranslate :: proc(x, y, z: f32) -> Matrix {return linalg.matrix4_translate_f32({x, y, z})}
MatrixScale :: proc(x, y, z: f32) -> Matrix {return linalg.matrix4_scale_f32({x, y, z})}
