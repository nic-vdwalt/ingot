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
@(private) cam3d_proj: Matrix
@(private) cam3d_view: Matrix
@(private) cam3d: Camera3D
@(private) cam3d_right: Vector3
@(private) cam3d_up: Vector3
@(private) cam3d_fwd: Vector3
@(private) depth_mask_on: bool = true

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
	cam3d_proj = proj
	cam3d_view = view
	return proj * view
}

// GetProjectionMatrix returns the last 3D projection matrix (rlgl parity for
// GetMatrixProjection). Identity before any BeginMode3D.
GetProjectionMatrix :: proc() -> Matrix {
	if cam3d_proj == (Matrix{}) do return Matrix(1)
	return cam3d_proj
}

// SetDepthMask records the rlgl depth-mask state (no visual effect in the
// CPU-projected 2D approximation, kept for API parity).
SetDepthMask :: proc(on: bool) { depth_mask_on = on }

BeginMode3D :: proc(camera: Camera3D) {
	cam3d_vp = _vp_from(camera)
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
_target_dims :: proc() -> (f32, f32) {
	if g.frame.rt != 0 do return f32(g.frame.rt_w), f32(g.frame.rt_h)
	return f32(g.width), f32(g.height)
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
	vp := _vp_from(camera)
	s, _ := _project_dims(vp, position, f32(g.width), f32(g.height))
	return s
}

GetCameraMatrix :: proc(camera: Camera3D) -> Matrix {
	return linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
}

MatrixTranslate :: proc(x, y, z: f32) -> Matrix { return linalg.matrix4_translate_f32({x, y, z}) }
MatrixScale :: proc(x, y, z: f32) -> Matrix { return linalg.matrix4_scale_f32({x, y, z}) }
