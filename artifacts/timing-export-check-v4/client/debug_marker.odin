package main

import "core:math"
import rl "ingot:gfx"

DEBUG_MARKER_BRACKET_FRACTION :: f32(0.24)
DEBUG_MARKER_BRACKET_SEGMENTS :: 24
DEBUG_MARKER_BRACKET_VERTICES :: DEBUG_MARKER_BRACKET_SEGMENTS * 2
DEBUG_PIN_HIT_RADIUS :: f32(14)
DEBUG_PIN_WORLD_SCALE :: f32(0.018)
DEBUG_PIN_WORLD_MIN :: f32(0.8)
DEBUG_PIN_WORLD_MAX :: f32(8)

Debug_Terrain_Pin_Geometry :: struct {
	size:        f32,
	stem_center: [3]f32,
	head_center: [3]f32,
}

Debug_Terrain_Axes_Geometry :: struct {
	origin:          [3]f32,
	x_axis:          [3]f32,
	y_axis:          [3]f32,
	z_axis:          [3]f32,
	axis_length:     f32,
	shaft_thickness: f32,
	cap_size:        f32,
}

marker_corner_vertices :: proc() -> [DEBUG_MARKER_BRACKET_VERTICES]rl.Gpu_3D_Vertex {
	corners := [8][3]f32 {
		{-0.5, -0.5, -0.5},
		{0.5, -0.5, -0.5},
		{0.5, 0.5, -0.5},
		{-0.5, 0.5, -0.5},
		{-0.5, -0.5, 0.5},
		{0.5, -0.5, 0.5},
		{0.5, 0.5, 0.5},
		{-0.5, 0.5, 0.5},
	}
	edges := [12][2]int {
		{0, 1},
		{1, 2},
		{2, 3},
		{3, 0},
		{4, 5},
		{5, 6},
		{6, 7},
		{7, 4},
		{0, 4},
		{1, 5},
		{2, 6},
		{3, 7},
	}
	vertices: [DEBUG_MARKER_BRACKET_VERTICES]rl.Gpu_3D_Vertex
	write := 0
	for edge in edges {
		from := corners[edge[0]]
		to := corners[edge[1]]
		delta := to - from
		vertices[write + 0] = {
			position = from,
			normal   = rl.CAMERA_WORLD_UP,
		}
		vertices[write + 1] = {
			position = from + delta * DEBUG_MARKER_BRACKET_FRACTION,
			normal   = rl.CAMERA_WORLD_UP,
		}
		vertices[write + 2] = {
			position = to,
			normal   = rl.CAMERA_WORLD_UP,
		}
		vertices[write + 3] = {
			position = to - delta * DEBUG_MARKER_BRACKET_FRACTION,
			normal   = rl.CAMERA_WORLD_UP,
		}
		write += 4
	}
	assert(write == DEBUG_MARKER_BRACKET_VERTICES)
	return vertices
}

debug_marker_init :: proc(value: ^Debug_Panel) -> bool {
	assert(value != nil, "debug marker init: nil panel")
	if value.marker_mesh.id != 0 do return true
	vertices := marker_corner_vertices()
	indices: [DEBUG_MARKER_BRACKET_VERTICES]u32
	for &index, cursor in indices do index = u32(cursor)
	mesh, ok := rl.create_gpu_mesh(vertices[:], indices[:], .Lines)
	if ok do value.marker_mesh = mesh
	return ok
}

debug_marker_deinit :: proc(value: ^Debug_Panel) {
	assert(value != nil, "debug marker deinit: nil panel")
	if value.marker_mesh.id != 0 do rl.destroy_gpu_mesh(&value.marker_mesh)
	value.marker_mesh = {}
}

debug_pin_world_size :: proc(distance: f32) -> f32 {
	assert(distance >= 0, "debug pin size: negative distance")
	return clamp(distance * DEBUG_PIN_WORLD_SCALE, DEBUG_PIN_WORLD_MIN, DEBUG_PIN_WORLD_MAX)
}

debug_terrain_pin_geometry :: proc(
	point, surface_normal, camera_position: [3]f32,
) -> Debug_Terrain_Pin_Geometry {
	delta := camera_position - point
	distance := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	size := debug_pin_world_size(distance)
	return {
		size        = size,
		stem_center = point + surface_normal * (size * 0.65),
		head_center = point + surface_normal * (size * 1.45),
	}
}

debug_terrain_axes_geometry :: proc(
	point, surface_normal, camera_position: [3]f32,
) -> Debug_Terrain_Axes_Geometry {
	up := surface_normal
	up_length := math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
	if up_length <= 0.0001 do up = {0, 0, 1}
	else do up /= up_length
	reference := [3]f32{0, 1, 0}
	if abs(up.y) > 0.95 do reference = {1, 0, 0}
	east := [3]f32 {
		reference.y * up.z - reference.z * up.y,
		reference.z * up.x - reference.x * up.z,
		reference.x * up.y - reference.y * up.x,
	}
	east_length := math.sqrt(east.x * east.x + east.y * east.y + east.z * east.z)
	assert(east_length > 0.0001, "debug terrain axes: degenerate east")
	east /= east_length
	north := [3]f32 {
		up.y * east.z - up.z * east.y,
		up.z * east.x - up.x * east.z,
		up.x * east.y - up.y * east.x,
	}
	delta := camera_position - point
	distance := math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
	pin_size := debug_pin_world_size(distance)
	axis_length := pin_size * 2.4
	origin := point + up * (pin_size * 0.06)
	return {
		origin          = origin,
		x_axis          = east,
		y_axis          = north,
		z_axis          = up,
		axis_length     = axis_length,
		shaft_thickness = axis_length * 0.055,
		cap_size        = axis_length * 0.16,
	}
}

debug_pin_hit_test :: proc(mouse, pin: rl.Vector2, scale: f32) -> bool {
	assert(scale > 0, "debug pin hit: invalid scale")
	delta := mouse - pin
	radius := DEBUG_PIN_HIT_RADIUS * scale
	return delta.x * delta.x + delta.y * delta.y <= radius * radius
}

debug_surface_frame :: proc(normal: [3]f32) -> rl.Matrix {
	up := normal
	length := math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
	if length <= 0.0001 do up = {0, 0, 1}
	if length > 0.0001 do up /= length
	reference := [3]f32{0, 1, 0}
	if abs(up.y) > 0.95 do reference = {1, 0, 0}
	east := [3]f32 {
		reference.y * up.z - reference.z * up.y,
		reference.z * up.x - reference.x * up.z,
		reference.x * up.y - reference.y * up.x,
	}
	east_length := math.sqrt(east.x * east.x + east.y * east.y + east.z * east.z)
	assert(east_length > 0.0001, "debug surface frame: degenerate east")
	east /= east_length
	north := [3]f32 {
		up.y * east.z - up.z * east.y,
		up.z * east.x - up.x * east.z,
		up.x * east.y - up.y * east.x,
	}
	return {
		east.x,
		north.x,
		up.x,
		0,
		east.y,
		north.y,
		up.y,
		0,
		east.z,
		north.z,
		up.z,
		0,
		0,
		0,
		0,
		1,
	}
}
