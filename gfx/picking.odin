package gfx

import "core:math"
import "core:math/linalg"

RAY_DIRECTION_LENGTH_TOLERANCE :: 1e-3
RAY_PARALLEL_EPSILON :: 1e-6

Ray_3D :: struct {
	origin:    Vector3,
	direction: Vector3,
}

Plane_3D :: struct {
	point:  Vector3,
	normal: Vector3,
}

Sphere_3D :: struct {
	center: Vector3,
	radius: f32,
}

Bounds_3D :: struct {
	minimum: Vector3,
	maximum: Vector3,
}

Ray_Hit :: struct {
	position: Vector3,
	normal:   Vector3,
	distance: f32,
}

screen_to_world_ray :: proc(
	position: Vector2,
	camera: Camera3D,
	viewport_width, viewport_height: i32,
) -> Ray_3D {
	assert(_f32_is_finite(position.x), "screen_to_world_ray: non-finite position x")
	assert(_f32_is_finite(position.y), "screen_to_world_ray: non-finite position y")
	assert(viewport_width > 0, "screen_to_world_ray: non-positive viewport width")
	assert(viewport_height > 0, "screen_to_world_ray: non-positive viewport height")
	assert(_f32_is_finite(camera.fovy), "screen_to_world_ray: non-finite fovy")
	assert(camera.fovy > 0, "screen_to_world_ray: non-positive fovy")
	if camera.projection == .PERSPECTIVE {
		assert(camera.fovy < 180, "screen_to_world_ray: perspective fovy outside range")
	}
	forward := GetCameraForward(camera)
	right := GetCameraRight(camera)
	up := GetCameraUp(camera)
	assert(forward != (Vector3{}), "screen_to_world_ray: coincident position and target")
	assert(right != (Vector3{}), "screen_to_world_ray: forward and up are parallel")
	assert(up != (Vector3{}), "screen_to_world_ray: invalid camera basis")
	width := f32(viewport_width)
	height := f32(viewport_height)
	normalized_x := position.x / width * 2 - 1
	normalized_y := 1 - position.y / height * 2
	aspect := width / height
	half_height := camera.fovy / 2
	ray: Ray_3D
	if camera.projection == .ORTHOGRAPHIC {
		ray.origin =
			camera.position +
			right * normalized_x * half_height * aspect +
			up * normalized_y * half_height
		ray.direction = forward
	} else {
		half_tangent := f32(math.tan(f64(half_height * math.PI / 180)))
		direction :=
			forward +
			right * normalized_x * half_tangent * aspect +
			up * normalized_y * half_tangent
		ray.origin = camera.position
		ray.direction, _ = _camera_vector_normalize(direction)
	}
	assert(_ray_3d_valid(ray), "screen_to_world_ray: produced invalid ray")
	return ray
}

intersect_plane :: proc(ray: Ray_3D, plane: Plane_3D) -> (Ray_Hit, bool) {
	assert(_ray_3d_valid(ray), "intersect_plane: invalid ray")
	assert(_camera_vector_is_finite(plane.point), "intersect_plane: non-finite point")
	normal, normal_ok := _camera_vector_normalize(plane.normal)
	assert(normal_ok, "intersect_plane: invalid normal")
	denominator := linalg.dot(ray.direction, normal)
	distance_to_plane := linalg.dot(plane.point - ray.origin, normal)
	if abs(denominator) <= RAY_PARALLEL_EPSILON {
		if abs(distance_to_plane) > RAY_PARALLEL_EPSILON do return {}, false
		return {position = ray.origin, normal = normal}, true
	}
	distance := distance_to_plane / denominator
	if distance < 0 do return {}, false
	hit := _ray_hit(ray, distance, normal)
	assert(_ray_hit_valid(hit), "intersect_plane: produced invalid hit")
	return hit, true
}

intersect_sphere :: proc(ray: Ray_3D, sphere: Sphere_3D) -> (Ray_Hit, bool) {
	assert(_ray_3d_valid(ray), "intersect_sphere: invalid ray")
	assert(_camera_vector_is_finite(sphere.center), "intersect_sphere: non-finite center")
	assert(_f32_is_finite(sphere.radius), "intersect_sphere: non-finite radius")
	assert(sphere.radius > 0, "intersect_sphere: non-positive radius")
	offset := [3]f64 {
		f64(ray.origin.x - sphere.center.x),
		f64(ray.origin.y - sphere.center.y),
		f64(ray.origin.z - sphere.center.z),
	}
	direction := [3]f64{f64(ray.direction.x), f64(ray.direction.y), f64(ray.direction.z)}
	projection := offset[0] * direction[0] + offset[1] * direction[1] + offset[2] * direction[2]
	offset_squared := offset[0] * offset[0] + offset[1] * offset[1] + offset[2] * offset[2]
	radius := f64(sphere.radius)
	discriminant := projection * projection - (offset_squared - radius * radius)
	if discriminant < 0 do return {}, false
	root := math.sqrt(discriminant)
	distance := -projection - root
	if distance < 0 do distance = -projection + root
	if distance < 0 do return {}, false
	normal64 := [3]f64 {
		offset[0] + direction[0] * distance,
		offset[1] + direction[1] * distance,
		offset[2] + direction[2] * distance,
	}
	normal_length := math.sqrt(
		normal64[0] * normal64[0] + normal64[1] * normal64[1] + normal64[2] * normal64[2],
	)
	assert(normal_length > 0, "intersect_sphere: invalid hit normal")
	hit := Ray_Hit {
		position = ray.origin + ray.direction * f32(distance),
		normal   = {
			f32(normal64[0] / normal_length),
			f32(normal64[1] / normal_length),
			f32(normal64[2] / normal_length),
		},
		distance = f32(distance),
	}
	assert(_ray_hit_valid(hit), "intersect_sphere: produced invalid hit")
	return hit, true
}

intersect_bounds :: proc(ray: Ray_3D, bounds: Bounds_3D) -> (Ray_Hit, bool) {
	assert(_ray_3d_valid(ray), "intersect_bounds: invalid ray")
	assert(_bounds_3d_valid(bounds), "intersect_bounds: invalid bounds")
	distance_near := math.inf_f32(-1)
	distance_far := math.inf_f32(1)
	normal_near: Vector3
	normal_far: Vector3
	if !_intersect_bounds_axis(
		ray.origin.x,
		ray.direction.x,
		bounds.minimum.x,
		bounds.maximum.x,
		{-1, 0, 0},
		{1, 0, 0},
		&distance_near,
		&distance_far,
		&normal_near,
		&normal_far,
	) {
		return {}, false
	}
	if !_intersect_bounds_axis(
		ray.origin.y,
		ray.direction.y,
		bounds.minimum.y,
		bounds.maximum.y,
		{0, -1, 0},
		{0, 1, 0},
		&distance_near,
		&distance_far,
		&normal_near,
		&normal_far,
	) {
		return {}, false
	}
	if !_intersect_bounds_axis(
		ray.origin.z,
		ray.direction.z,
		bounds.minimum.z,
		bounds.maximum.z,
		{0, 0, -1},
		{0, 0, 1},
		&distance_near,
		&distance_far,
		&normal_near,
		&normal_far,
	) {
		return {}, false
	}
	if distance_far < 0 do return {}, false
	distance := distance_near
	normal := normal_near
	if distance < 0 {
		distance = distance_far
		normal = normal_far
	}
	hit := _ray_hit(ray, distance, normal)
	assert(_ray_hit_valid(hit), "intersect_bounds: produced invalid hit")
	return hit, true
}

@(private)
_ray_3d_valid :: proc(ray: Ray_3D) -> bool {
	if !_camera_vector_is_finite(ray.origin) do return false
	if !_camera_vector_is_finite(ray.direction) do return false
	length_squared := linalg.dot(ray.direction, ray.direction)
	return abs(length_squared - 1) <= RAY_DIRECTION_LENGTH_TOLERANCE
}

@(private)
_bounds_3d_valid :: proc(bounds: Bounds_3D) -> bool {
	if !_camera_vector_is_finite(bounds.minimum) do return false
	if !_camera_vector_is_finite(bounds.maximum) do return false
	return(
		bounds.minimum.x <= bounds.maximum.x &&
		bounds.minimum.y <= bounds.maximum.y &&
		bounds.minimum.z <= bounds.maximum.z \
	)
}

@(private)
_ray_hit :: proc(ray: Ray_3D, distance: f32, normal: Vector3) -> Ray_Hit {
	assert(_ray_3d_valid(ray), "_ray_hit: invalid ray")
	assert(_f32_is_finite(distance), "_ray_hit: non-finite distance")
	assert(distance >= 0, "_ray_hit: negative distance")
	assert(_camera_vector_is_finite(normal), "_ray_hit: non-finite normal")
	return {position = ray.origin + ray.direction * distance, normal = normal, distance = distance}
}

@(private)
_ray_hit_valid :: proc(hit: Ray_Hit) -> bool {
	return(
		_camera_vector_is_finite(hit.position) &&
		_camera_vector_is_finite(hit.normal) &&
		_f32_is_finite(hit.distance) &&
		hit.distance >= 0 \
	)
}

@(private)
_intersect_bounds_axis :: proc(
	origin, direction, minimum, maximum: f32,
	normal_minimum, normal_maximum: Vector3,
	distance_near, distance_far: ^f32,
	normal_near, normal_far: ^Vector3,
) -> bool {
	assert(distance_near != nil, "_intersect_bounds_axis: nil near distance")
	assert(distance_far != nil, "_intersect_bounds_axis: nil far distance")
	assert(normal_near != nil, "_intersect_bounds_axis: nil near normal")
	assert(normal_far != nil, "_intersect_bounds_axis: nil far normal")
	if abs(direction) <= RAY_PARALLEL_EPSILON {
		return origin >= minimum && origin <= maximum
	}
	distance_minimum := (minimum - origin) / direction
	distance_maximum := (maximum - origin) / direction
	axis_normal_near := normal_minimum
	axis_normal_far := normal_maximum
	if distance_minimum > distance_maximum {
		distance_minimum, distance_maximum = distance_maximum, distance_minimum
		axis_normal_near, axis_normal_far = axis_normal_far, axis_normal_near
	}
	if distance_minimum > distance_near^ {
		distance_near^ = distance_minimum
		normal_near^ = axis_normal_near
	}
	if distance_maximum < distance_far^ {
		distance_far^ = distance_maximum
		normal_far^ = axis_normal_far
	}
	return distance_near^ <= distance_far^
}
