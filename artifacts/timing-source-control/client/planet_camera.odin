package main

import shared "../shared"
import "core:math"

Planet_Camera_Regime :: enum u8 {
	Surface,
	Blend,
	Orbit,
}

planet_camera_regime :: proc(distance: f32) -> Planet_Camera_Regime {
	if distance <= PLANET_SURFACE_ZOOM do return .Surface
	if distance >= PLANET_SURFACE_ZOOM * 1.5 do return .Orbit
	return .Blend
}

planet_camera_blend :: proc(distance: f32) -> f32 {
	return camera_visual_smoothstep(PLANET_SURFACE_ZOOM, PLANET_SURFACE_ZOOM * 1.5, distance)
}

planet_camera_visual_context :: proc(
	camera_position, camera_target: [3]f32,
	distance, fovy, viewport_height: f32,
) -> Camera_Visual_Context {
	eye_radius := math.sqrt(
		camera_position.x * camera_position.x +
		camera_position.y * camera_position.y +
		camera_position.z * camera_position.z,
	)
	coverage := clamp(shared.PLANET_RADIUS * 2 / max(distance, shared.PLANET_RADIUS * 2), 0, 1)
	return camera_visual_context_make(
		camera_position,
		camera_target,
		distance,
		eye_radius - shared.PLANET_RADIUS,
		fovy,
		viewport_height,
		coverage,
		PLANET_SURFACE_ZOOM * 0.55,
		PLANET_SURFACE_ZOOM,
		PLANET_SURFACE_ZOOM,
		PLANET_SURFACE_ZOOM * 1.5,
	)
}

planet_camera_target :: proc(surface_direction: [3]f32, surface_height, distance: f32) -> [3]f32 {
	length_squared := surface_direction.x * surface_direction.x +
		surface_direction.y * surface_direction.y + surface_direction.z * surface_direction.z
	assert(abs(length_squared - 1) < 0.001, "planet_camera_target: direction not unit")
	surface := shared.planet_position(surface_direction, surface_height)
	return surface * (1 - planet_camera_blend(distance))
}

planet_camera_up :: proc(surface_direction: [3]f32, distance: f32) -> [3]f32 {
	blend := planet_camera_blend(distance)
	up := surface_direction * (1 - blend) + [3]f32{0, 0, 1} * blend
	length := math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
	if length <= 0.0001 do return surface_direction
	return up / length
}

planet_far_view :: proc(distance: f32) -> bool {
	return planet_camera_blend(distance) >= 1
}
