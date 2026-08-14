// ingot:gfx - camera + matrix helpers (raylib-named). 3D is CPU-projected: a
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
cam3d_projection_available: bool

CAMERA_DEFAULT_NEAR_PLANE :: f32(0.01)
CAMERA_DEFAULT_FAR_PLANE :: f32(1000.0)

// _camera_clip_planes resolves the camera's clip planes, substituting the
// historical defaults for zero fields so zero-initialised cameras keep their
// long-standing behaviour.
@(private)
_camera_clip_planes :: proc(camera: Camera3D) -> (f32, f32) {
	near := camera.near_plane
	far := camera.far_plane
	if near == 0 do near = CAMERA_DEFAULT_NEAR_PLANE
	if far == 0 do far = CAMERA_DEFAULT_FAR_PLANE
	assert(_f32_is_finite(near), "camera: non-finite near plane")
	assert(_f32_is_finite(far), "camera: non-finite far plane")
	assert(near > 0, "camera: non-positive near plane")
	assert(far > near, "camera: far plane not beyond near plane")
	return near, far
}

@(private)
_camera_matrices :: proc(camera: Camera3D, width, height: i32) -> (Matrix, Matrix, Matrix) {
	aspect := f32(max(width, 1)) / f32(max(height, 1))
	view := linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
	near, far := _camera_clip_planes(camera)
	projection: Matrix
	if camera.projection == .ORTHOGRAPHIC {
		top := camera.fovy / 2.0
		right := top * aspect
		projection = linalg.matrix_ortho3d_f32(-right, right, -top, top, near, far)
	} else {
		projection = linalg.matrix4_perspective_f32(
			camera.fovy * math.PI / 180.0,
			aspect,
			near,
			far,
		)
	}
	return view, projection, projection * view
}

@(private)
_camera_vector_is_finite :: proc(value: Vector3) -> bool {
	return _f32_is_finite(value.x) && _f32_is_finite(value.y) && _f32_is_finite(value.z)
}

@(private)
_camera_matrix_is_finite :: proc(value: Matrix) -> bool {
	for row in 0 ..< 4 {
		for column in 0 ..< 4 {
			if !_f32_is_finite(value[row, column]) do return false
		}
	}
	return true
}

@(private)
_camera_motion_is_finite :: proc(motion: Camera3D_Motion) -> bool {
	return(
		_camera_vector_is_finite(motion.linear_velocity) &&
		_camera_vector_is_finite(motion.angular_velocity) &&
		_f32_is_finite(motion.zoom_velocity) \
	)
}

@(private)
_camera_vector_normalize :: proc(value: Vector3) -> (Vector3, bool) {
	if !_camera_vector_is_finite(value) do return {}, false
	length_squared := linalg.dot(value, value)
	if !_f32_is_finite(length_squared) || length_squared <= 1e-12 do return {}, false
	return value / math.sqrt(length_squared), true
}

GetCameraForward :: proc(camera: Camera3D) -> Vector3 {
	forward, _ := _camera_vector_normalize(camera.target - camera.position)
	return forward
}

GetCameraRight :: proc(camera: Camera3D) -> Vector3 {
	forward, forward_ok := _camera_vector_normalize(camera.target - camera.position)
	if !forward_ok do return {}
	right, _ := _camera_vector_normalize(linalg.cross(forward, camera.up))
	return right
}

GetCameraUp :: proc(camera: Camera3D) -> Vector3 {
	forward := GetCameraForward(camera)
	right := GetCameraRight(camera)
	up, _ := _camera_vector_normalize(linalg.cross(right, forward))
	return up
}

@(private)
_camera_rotate_axis :: proc(value, axis: Vector3, angle: f32) -> Vector3 {
	cosine := f32(math.cos(f64(angle)))
	sine := f32(math.sin(f64(angle)))
	return(
		value * cosine +
		linalg.cross(axis, value) * sine +
		axis * linalg.dot(axis, value) * (1 - cosine) \
	)
}

@(private)
_camera_motion_displacement :: proc(velocity, axis: Vector3, speed, dt: f32) -> Vector3 {
	angle := speed * dt
	angle_squared := angle * angle
	cosine_coefficient: f32
	sine_coefficient: f32
	// The series avoids cancellation while preserving curved translation when a
	// small angular speed accumulates into a meaningful turn over a large step.
	if abs(angle) <= 1e-3 {
		cosine_coefficient = dt * (angle / 2 - angle * angle_squared / 24)
		sine_coefficient = dt * (angle_squared / 6 - angle_squared * angle_squared / 120)
	} else {
		cosine_coefficient = (1 - f32(math.cos(f64(angle)))) / speed
		sine_coefficient = (angle - f32(math.sin(f64(angle)))) / speed
	}
	axis_cross_velocity := linalg.cross(axis, velocity)
	axis_cross_twice := linalg.cross(axis, axis_cross_velocity)
	return(
		velocity * dt +
		axis_cross_velocity * cosine_coefficient +
		axis_cross_twice * sine_coefficient \
	)
}

UpdateCamera :: proc(camera: ^Camera3D, motion: Camera3D_Motion, dt: f32) {
	assert(camera != nil, "UpdateCamera: nil camera")
	assert(_f32_is_finite(dt), "UpdateCamera: non-finite delta time")
	assert(dt >= 0, "UpdateCamera: negative delta time")
	assert(_camera_motion_is_finite(motion), "UpdateCamera: non-finite motion")
	assert(_camera_vector_is_finite(camera.position), "UpdateCamera: non-finite position")
	assert(_camera_vector_is_finite(camera.target), "UpdateCamera: non-finite target")
	assert(_camera_vector_is_finite(camera.up), "UpdateCamera: non-finite up")
	if dt == 0 do return
	forward := GetCameraForward(camera^)
	right := GetCameraRight(camera^)
	up := GetCameraUp(camera^)
	assert(forward != (Vector3{}), "UpdateCamera: coincident position and target")
	assert(right != (Vector3{}), "UpdateCamera: forward and up are parallel")
	assert(up != (Vector3{}), "UpdateCamera: invalid camera basis")
	left := -right
	distance := math.sqrt(
		linalg.dot(camera.target - camera.position, camera.target - camera.position),
	)
	world_velocity :=
		forward * motion.linear_velocity.x +
		left * motion.linear_velocity.y +
		up * motion.linear_velocity.z
	world_angular :=
		forward * motion.angular_velocity.x +
		left * motion.angular_velocity.y +
		up * motion.angular_velocity.z
	angular_speed := math.sqrt(linalg.dot(world_angular, world_angular))
	rotating := angular_speed > 0
	axis: Vector3
	if rotating do axis = world_angular / angular_speed
	if rotating {
		camera.position += _camera_motion_displacement(world_velocity, axis, angular_speed, dt)
		forward = _camera_rotate_axis(forward, axis, angular_speed * dt)
		up = _camera_rotate_axis(up, axis, angular_speed * dt)
	} else {
		camera.position += world_velocity * dt
	}
	distance = max(distance - motion.zoom_velocity * dt, 1e-4)
	camera.target = camera.position + forward * distance
	camera.up, _ = _camera_vector_normalize(up)
	assert(_camera_vector_is_finite(camera.position), "UpdateCamera: produced non-finite position")
	assert(_camera_vector_is_finite(camera.target), "UpdateCamera: produced non-finite target")
	assert(_camera_vector_is_finite(camera.up), "UpdateCamera: produced non-finite up")
}

orbit_camera_config_default :: proc() -> Orbit_Camera_Config {
	return {
		world_up = CAMERA_WORLD_UP,
		rotate_speed = math.PI / 2,
		zoom_speed = 10,
		drag_radians_per_pixel = 0.01,
		scroll_distance = 2,
		min_distance = 1,
		max_distance = 1000,
		min_pitch = -math.PI / 2 + 0.01,
		max_pitch = math.PI / 2 - 0.01,
	}
}

orbit_camera_from_camera :: proc(camera: Camera3D) -> (Orbit_Camera_State, bool) {
	if !_camera_vector_is_finite(camera.position) || !_camera_vector_is_finite(camera.target) {
		return {}, false
	}
	offset := camera.position - camera.target
	distance_squared := linalg.dot(offset, offset)
	if !_f32_is_finite(distance_squared) || distance_squared <= 1e-12 do return {}, false
	distance := math.sqrt(distance_squared)
	return {
			target = camera.target,
			yaw = math.atan2(offset.y, offset.x),
			pitch = math.asin(clamp(offset.z / distance, -1, 1)),
			distance = distance,
		},
		true
}

update_orbit_camera :: proc(
	state: ^Orbit_Camera_State,
	input: Orbit_Camera_Input,
	config: Orbit_Camera_Config,
	dt: f32,
) {
	assert(state != nil, "update_orbit_camera: nil state")
	assert(_f32_is_finite(dt) && dt >= 0, "update_orbit_camera: invalid delta time")
	assert(_camera_vector_is_finite(state.target), "update_orbit_camera: invalid target")
	assert(_camera_vector_is_finite(config.world_up), "update_orbit_camera: invalid world up")
	assert(config.world_up == CAMERA_WORLD_UP, "update_orbit_camera: unsupported world up")
	assert(config.min_distance > 0, "update_orbit_camera: invalid minimum distance")
	assert(
		config.max_distance >= config.min_distance,
		"update_orbit_camera: invalid distance range",
	)
	assert(config.max_pitch >= config.min_pitch, "update_orbit_camera: invalid pitch range")
	assert(_f32_is_finite(input.rotate_rate.x), "update_orbit_camera: invalid rotation input")
	assert(_f32_is_finite(input.rotate_rate.y), "update_orbit_camera: invalid rotation input")
	assert(_f32_is_finite(input.pointer_drag.x), "update_orbit_camera: invalid drag input")
	assert(_f32_is_finite(input.pointer_drag.y), "update_orbit_camera: invalid drag input")
	assert(_f32_is_finite(input.zoom_rate), "update_orbit_camera: invalid zoom input")
	assert(_f32_is_finite(input.scroll), "update_orbit_camera: invalid scroll input")
	assert(_camera_vector_is_finite(input.pan), "update_orbit_camera: invalid pan input")
	assert(_f32_is_finite(input.pan_rate.x), "update_orbit_camera: invalid pan rate")
	assert(_f32_is_finite(input.pan_rate.y), "update_orbit_camera: invalid pan rate")
	assert(_f32_is_finite(config.pan_speed), "update_orbit_camera: invalid pan speed")
	state.target += input.pan
	state.yaw += input.rotate_rate.x * config.rotate_speed * dt
	state.yaw += input.pointer_drag.x * config.drag_radians_per_pixel
	// Yaw limits are opt-in: they only clamp when the range is non-empty, so
	// zero-initialised configs keep the historical free-orbit behaviour.
	if config.max_yaw > config.min_yaw {
		state.yaw = clamp(state.yaw, config.min_yaw, config.max_yaw)
	}
	state.pitch += input.rotate_rate.y * config.rotate_speed * dt
	state.pitch += input.pointer_drag.y * config.drag_radians_per_pixel
	state.pitch = clamp(state.pitch, config.min_pitch, config.max_pitch)
	state.distance += input.zoom_rate * config.zoom_speed * dt
	state.distance -= input.scroll * config.scroll_distance
	state.distance = clamp(state.distance, config.min_distance, config.max_distance)
	// Keyboard pan is camera-relative: forward is the ground-projected view
	// direction, right is its clockwise perpendicular. Speed scales with
	// distance so the world moves at constant screen speed at any zoom.
	if config.pan_speed > 0 && (input.pan_rate.x != 0 || input.pan_rate.y != 0) {
		forward := Vector2{-f32(math.cos(f64(state.yaw))), -f32(math.sin(f64(state.yaw)))}
		right := Vector2{forward.y, -forward.x}
		movement := right * input.pan_rate.x + forward * input.pan_rate.y
		scale := config.pan_speed * state.distance * dt
		state.target += Vector3{movement.x * scale, movement.y * scale, 0}
	}
	assert(
		_camera_vector_is_finite(state.target),
		"update_orbit_camera: pan produced invalid target",
	)
	assert(_f32_is_finite(state.yaw) && _f32_is_finite(state.pitch))
	assert(_f32_is_finite(state.distance) && state.distance > 0)
}

// orbit_camera_zoom_toward dollies the orbit toward a world-space focus point
// instead of the orbit target: distance shrinks (or grows) exactly as plain
// scroll zoom would, and the target slides toward the focus by the same
// proportion, so with the camera direction unchanged the focus point keeps
// its screen position. Callers typically pass the picked world point under
// the cursor and fall back to plain scroll zoom when nothing is hit. The
// scroll channel is consumed so the same value cannot also reach
// update_orbit_camera and double-apply.
orbit_camera_zoom_toward :: proc(
	state: ^Orbit_Camera_State,
	focus: Vector3,
	scroll: ^f32,
	config: Orbit_Camera_Config,
) {
	assert(state != nil, "orbit_camera_zoom_toward: nil state")
	assert(scroll != nil, "orbit_camera_zoom_toward: nil scroll")
	assert(_camera_vector_is_finite(state.target), "orbit_camera_zoom_toward: invalid target")
	assert(_camera_vector_is_finite(focus), "orbit_camera_zoom_toward: invalid focus")
	assert(_f32_is_finite(scroll^), "orbit_camera_zoom_toward: invalid scroll")
	assert(_f32_is_finite(state.distance) && state.distance > 0)
	assert(config.min_distance > 0, "orbit_camera_zoom_toward: invalid minimum distance")
	assert(
		config.max_distance >= config.min_distance,
		"orbit_camera_zoom_toward: invalid distance range",
	)
	if scroll^ == 0 do return
	old_distance := state.distance
	new_distance := clamp(
		old_distance - scroll^ * config.scroll_distance,
		config.min_distance,
		config.max_distance,
	)
	// The channel is consumed even when clamping absorbs the change, so the
	// caller can never double-apply it through update_orbit_camera.
	scroll^ = 0
	if new_distance == old_distance do return
	// Sliding the target by the fractional distance change keeps the ray from
	// the camera through the focus fixed, which is what makes the point under
	// the cursor appear stationary while zooming.
	fraction := 1 - new_distance / old_distance
	state.target += (focus - state.target) * fraction
	state.distance = new_distance
	assert(
		_camera_vector_is_finite(state.target),
		"orbit_camera_zoom_toward: produced invalid target",
	)
	assert(state.distance >= config.min_distance && state.distance <= config.max_distance)
}

// orbit_camera_grab_pan_begin anchors the pan at a picked world point. A
// begin while a grab is already active means the caller lost the matching
// end (a missed release), so the state machine traps rather than silently
// re-anchoring mid-gesture.
orbit_camera_grab_pan_begin :: proc(pan: ^Orbit_Camera_Grab_Pan, anchor: Vector3) {
	assert(pan != nil, "orbit_camera_grab_pan_begin: nil state")
	assert(pan.active == false, "orbit_camera_grab_pan_begin: grab pan already active")
	assert(_camera_vector_is_finite(anchor), "orbit_camera_grab_pan_begin: invalid anchor")
	pan.active = true
	pan.anchor = anchor
}

orbit_camera_grab_pan_end :: proc(pan: ^Orbit_Camera_Grab_Pan) {
	assert(pan != nil, "orbit_camera_grab_pan_end: nil state")
	pan^ = {}
}

// orbit_camera_grab_pan_delta returns the world-space pan that keeps the
// anchor under the given cursor ray. The plane is horizontal at the anchor
// height, which keeps the drag stable across ridges and valleys. Feed the
// result to Orbit_Camera_Input.pan.
orbit_camera_grab_pan_delta :: proc(pan: Orbit_Camera_Grab_Pan, ray: Ray_3D) -> (Vector3, bool) {
	assert(_camera_vector_is_finite(pan.anchor), "orbit_camera_grab_pan_delta: invalid anchor")
	if !pan.active do return {}, false
	plane := Plane_3D {
		point  = pan.anchor,
		normal = CAMERA_WORLD_UP,
	}
	hit, ok := intersect_plane(ray, plane)
	if !ok do return {}, false
	delta := Vector3{pan.anchor.x - hit.position.x, pan.anchor.y - hit.position.y, 0}
	assert(_camera_vector_is_finite(delta), "orbit_camera_grab_pan_delta: invalid delta")
	return delta, true
}

orbit_camera_apply :: proc(state: Orbit_Camera_State, camera: ^Camera3D) {
	assert(camera != nil, "orbit_camera_apply: nil camera")
	assert(_camera_vector_is_finite(state.target), "orbit_camera_apply: invalid target")
	assert(_f32_is_finite(state.yaw) && _f32_is_finite(state.pitch))
	assert(_f32_is_finite(state.distance) && state.distance > 0)
	horizontal := state.distance * f32(math.cos(f64(state.pitch)))
	camera.target = state.target
	camera.position =
		state.target +
		Vector3 {
				horizontal * f32(math.cos(f64(state.yaw))),
				horizontal * f32(math.sin(f64(state.yaw))),
				state.distance * f32(math.sin(f64(state.pitch))),
			}
	camera.up = CAMERA_WORLD_UP
	assert(_camera_vector_is_finite(camera.position), "orbit_camera_apply: invalid position")
}

// GetProjectionMatrix returns the last 3D projection matrix (rlgl parity for
// GetMatrixProjection). Identity before any BeginMode3D.
GetProjectionMatrix :: proc() -> Matrix {
	assert(cam3d_projection_available, "GetProjectionMatrix: unavailable in matrix-only Pro mode")
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
	assert(g != nil, "BeginMode2D: nil context")
	if _active_pass_begun() do renderer_flush(default_context(), &g.rend, active_pass(), .Matrix)
	cam2d_saved = g.rend.model_xf
	cam2d = camera
	g.rend.model_xf = _affine_from_camera_2d(camera)
	cam2d_active = true
	assert(cam2d_active)
}

EndMode2D :: proc() {
	assert(cam2d_active, "EndMode2D: no active 2D camera mode")
	assert(g != nil, "EndMode2D: nil context")
	if _active_pass_begun() do renderer_flush(default_context(), &g.rend, active_pass(), .Matrix)
	g.rend.model_xf = cam2d_saved
	cam2d_saved = {}
	cam2d = {}
	cam2d_active = false
	assert(!cam2d_active)
}

// GetCameraMatrix2D returns the active-camera transform as a 4x4, matching
// raylib's rlgl-facing accessor. The 2D affine occupies the upper-left block
// and the translation column; z passes through unchanged.
GetCameraMatrix2D :: proc(camera: Camera2D) -> Matrix {
	m := _affine_from_camera_2d(camera)
	return Matrix{m.a, m.c, 0, m.tx, m.b, m.d, 0, m.ty, 0, 0, 1, 0, 0, 0, 0, 1}
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
	// A zoom animation can legitimately pass through zero, so this is handled
	// rather than asserted.
	if determinant == 0 do return camera.target
	x := position.x - m.tx
	y := position.y - m.ty
	world := Vector2{(m.d * x - m.c * y) / determinant, (m.a * y - m.b * x) / determinant}
	// Postcondition: picking feeds layout and hit-testing, so a NaN escaping
	// here would surface far from its cause.
	assert(world.x == world.x, "GetScreenToWorld2D: produced NaN x")
	assert(world.y == world.y, "GetScreenToWorld2D: produced NaN y")
	return world
}

BeginMode3D :: proc(camera: Camera3D) {
	assert(!cam3d_active, "BeginMode3D: already inside a 3D camera mode")
	width, height := _target_dims_i32()
	cam3d_view, cam3d_proj, cam3d_vp = _camera_matrices(camera, width, height)
	assert(_camera_matrix_is_finite(cam3d_vp), "BeginMode3D: non-finite camera matrix")
	cam3d = camera
	cam3d_fwd = GetCameraForward(camera)
	cam3d_right = GetCameraRight(camera)
	cam3d_up = GetCameraUp(camera)
	assert(cam3d_fwd != (Vector3{}), "BeginMode3D: coincident position and target")
	assert(cam3d_right != (Vector3{}), "BeginMode3D: forward and up are parallel")
	cam3d_projection_available = true
	cam3d_active = true
	// Ordering pending 2D geometry before 3D makes the camera change a visible
	// draw-call boundary instead of retroactively transforming queued vertices.
	FlushBatch()
	_ = _gpu_3d_compat_begin(&default_context_storage, camera)
	assert(cam3d_active)
}

BeginMode3DPro :: proc(view_projection: Matrix) {
	assert(!cam3d_active, "BeginMode3DPro: already inside a 3D camera mode")
	assert(view_projection != (Matrix{}), "BeginMode3DPro: zero view-projection")
	assert(_camera_matrix_is_finite(view_projection), "BeginMode3DPro: non-finite view-projection")
	cam3d_view = {}
	cam3d_proj = {}
	cam3d_vp = view_projection
	cam3d = {}
	cam3d_fwd = {}
	cam3d_right = {}
	cam3d_up = {}
	cam3d_projection_available = false
	cam3d_active = true
	FlushBatch()
	assert(cam3d_active)
}

EndMode3D :: proc() {
	assert(cam3d_active, "EndMode3D: no active 3D camera mode")
	FlushBatch()
	_gpu_3d_compat_end(&default_context_storage)
	cam3d_active = false
	cam3d_projection_available = false
	assert(!cam3d_active)
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
	return GetWorldToScreenPro(position, _camera_view_projection(camera, g.width, g.height))
}

GetWorldToScreenPro :: proc(position: Vector3, view_projection: Matrix) -> Vector2 {
	assert(_camera_vector_is_finite(position), "GetWorldToScreenPro: non-finite position")
	assert(_camera_matrix_is_finite(view_projection), "GetWorldToScreenPro: non-finite matrix")
	return _world_to_screen_pro(position, view_projection, GetScreenWidth(), GetScreenHeight())
}

@(private)
_camera_view_projection :: proc(camera: Camera3D, width, height: i32) -> Matrix {
	_, _, view_projection := _camera_matrices(camera, width, height)
	return view_projection
}

@(private)
_world_to_screen_pro :: proc(
	position: Vector3,
	view_projection: Matrix,
	width, height: i32,
) -> Vector2 {
	s, _ := _project_dims(view_projection, position, f32(width), f32(height))
	return s
}

GetCameraMatrix :: proc(camera: Camera3D) -> Matrix {
	return linalg.matrix4_look_at_f32(camera.position, camera.target, camera.up)
}

MatrixTranslate :: proc(x, y, z: f32) -> Matrix {return linalg.matrix4_translate_f32({x, y, z})}
MatrixScale :: proc(x, y, z: f32) -> Matrix {return linalg.matrix4_scale_f32({x, y, z})}
