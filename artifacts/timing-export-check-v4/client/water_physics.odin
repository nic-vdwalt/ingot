package main

import "core:math"

WATER_PHYSICS_GRAVITY :: f32(10)
WATER_PHYSICS_BUOYANCY_GAIN :: f32(1.6)
WATER_PHYSICS_DRAG :: f32(3)
WATER_PHYSICS_FORCE_MAX :: f32(4_000)

Water_Physics_Sample :: struct {
	surface:      [3]f32,
	normal:       [3]f32,
	velocity:     [3]f32,
	acceleration: [3]f32,
	depth:        f32,
	breaking:     f32,
	whitewater:   f32,
	flow_drag:    f32,
	wet:          bool,
}

water_physics_finite :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value, 0)
}

water_physics_vector_finite :: proc(value: [3]f32) -> bool {
	for component in value do if !water_physics_finite(component) do return false
	return true
}

water_physics_radial_gravity_force :: proc(
	position: [3]f32,
	mass, gravity_scale: f32,
	world_gravity: [3]f32,
) -> [3]f32 {
	if mass <= 0 || !water_physics_finite(mass) || !water_physics_finite(gravity_scale) do return {}
	if !water_physics_vector_finite(position) || !water_physics_vector_finite(world_gravity) do return {}
	length := math.sqrt(
		position.x * position.x + position.y * position.y + position.z * position.z,
	)
	if length <= WATER_PHYSICS_EPSILON do return {}
	radial := position / length
	desired_acceleration := -radial * WATER_PHYSICS_GRAVITY
	return (desired_acceleration - world_gravity * gravity_scale) * mass
}

water_physics_submerged_fraction :: proc(
	center: [3]f32,
	half_height: f32,
	sample: Water_Physics_Sample,
) -> f32 {
	if !sample.wet || half_height <= 0 do return 0
	if !water_physics_vector_finite(center) || !water_physics_vector_finite(sample.surface) do return 0
	up := sample.normal
	length := math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
	if length <= 0.0001 do return 0
	up /= length
	distance :=
		(sample.surface.x - center.x) * up.x +
		(sample.surface.y - center.y) * up.y +
		(sample.surface.z - center.z) * up.z
	return clamp((distance + half_height) / (2 * half_height), 0, 1)
}

water_physics_force :: proc(
	center: [3]f32,
	half_height, mass: f32,
	velocity: [3]f32,
	sample: Water_Physics_Sample,
) -> [3]f32 {
	if mass <= 0 || !water_physics_finite(mass) do return {}
	if !water_physics_vector_finite(velocity) || !water_physics_vector_finite(sample.velocity) do return {}
	submerged := water_physics_submerged_fraction(center, half_height, sample)
	if submerged <= 0 do return {}
	up := sample.normal
	length := math.sqrt(up.x * up.x + up.y * up.y + up.z * up.z)
	if length <= 0.0001 do return {}
	up /= length
	buoyancy := up * (submerged * mass * WATER_PHYSICS_GRAVITY * WATER_PHYSICS_BUOYANCY_GAIN)
	drag := -(velocity - sample.velocity) * (WATER_PHYSICS_DRAG * mass * submerged)
	force := buoyancy + drag
	for &component in force {
		component = clamp(component, -WATER_PHYSICS_FORCE_MAX, WATER_PHYSICS_FORCE_MAX)
	}
	if !water_physics_vector_finite(force) do return {}
	return force
}

water_physics_acceleration_force :: proc(
	sample: Water_Physics_Sample,
	mass: f32,
	immersion: f32 = 1,
) -> [3]f32 {
	if !sample.wet || mass <= 0 || !water_physics_finite(mass) || !water_physics_finite(immersion) do return {}
	if !water_physics_vector_finite(sample.acceleration) do return {}
	force := sample.acceleration * mass * clamp(immersion, f32(0), f32(1))
	return water_physics_clamp_vector(force, WATER_PHYSICS_FORCE_MAX)
}

water_physics_hull_immersion :: proc(
	points: []Water_Physics_Hull_Point,
	states: []Water_Physics_Point_State,
) -> f32 {
	count := min(len(points), min(len(states), WATER_PHYSICS_HULL_POINT_MAX))
	if count <= 0 do return 0
	share_total := f32(0)
	immersed_total := f32(0)
	for index in 0 ..< count {
		share := max(points[index].displacement_share, f32(0))
		share_total += share
		immersed_total += share * clamp(states[index].submerged_fraction, f32(0), f32(1))
	}
	if share_total <= WATER_PHYSICS_EPSILON do return 0
	return clamp(immersed_total / share_total, f32(0), f32(1))
}

WATER_PHYSICS_HULL_POINT_MAX :: 16
WATER_PHYSICS_EPSILON :: f32(0.0001)

Water_Physics_Hull_Point :: struct {
	local_position:     [3]f32,
	displacement_share: f32,
	area:               f32,
	immersion_radius:   f32,
	drag:               [3]f32,
	planing:            f32,
	rail:               f32,
	fin:                f32,
	slamming:           f32,
	ventilation_depth:  f32,
}

Water_Physics_Body_State :: struct {
	position:         [3]f32,
	forward:          [3]f32,
	right:            [3]f32,
	up:               [3]f32,
	linear_velocity:  [3]f32,
	angular_velocity: [3]f32,
	mass:             f32,
}

Water_Physics_Point_State :: struct {
	submerged_fraction: f32,
}

Water_Physics_Point_Load :: struct {
	position: [3]f32,
	force:    [3]f32,
}

Water_Physics_Hull_Result :: struct {
	force:  [3]f32,
	torque: [3]f32,
	count:  int,
}

water_physics_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

water_physics_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

water_physics_clamp_vector :: proc(value: [3]f32, maximum: f32) -> [3]f32 {
	if !water_physics_vector_finite(value) do return {}
	length := math.sqrt(water_physics_dot(value, value))
	if length <= maximum do return value
	return value * maximum / max(length, WATER_PHYSICS_EPSILON)
}

water_physics_hull_point_position :: proc(
	body: Water_Physics_Body_State,
	point: Water_Physics_Hull_Point,
) -> [3]f32 {
	return(
		body.position +
		body.forward * point.local_position.x +
		body.right * point.local_position.y +
		body.up * point.local_position.z \
	)
}

water_physics_axis_drag :: proc(
	axis, relative: [3]f32,
	coefficient, area, submerged: f32,
) -> [3]f32 {
	speed := water_physics_dot(relative, axis)
	return -axis * speed * abs(speed) * max(coefficient, 0) * max(area, 0) * submerged
}

water_physics_hull_step :: proc(
	body: Water_Physics_Body_State,
	points: []Water_Physics_Hull_Point,
	samples: []Water_Physics_Sample,
	states: []Water_Physics_Point_State,
	dt: f32,
	loads: []Water_Physics_Point_Load,
) -> (
	result: Water_Physics_Hull_Result,
) {
	count := min(len(points), min(len(samples), min(len(states), len(loads))))
	count = min(count, WATER_PHYSICS_HULL_POINT_MAX)
	if count <= 0 || body.mass <= 0 || dt <= 0 do return
	share_total := f32(0)
	for index in 0 ..< count do share_total += max(points[index].displacement_share, f32(0))
	if share_total <= WATER_PHYSICS_EPSILON do return
	for index in 0 ..< count {
		point := points[index]
		sample := samples[index]
		position := water_physics_hull_point_position(body, point)
		radius := position - body.position
		point_velocity := body.linear_velocity + water_physics_cross(body.angular_velocity, radius)
		relative := point_velocity - sample.velocity
		submerged := water_physics_submerged_fraction(position, point.immersion_radius, sample)
		previous_submerged := states[index].submerged_fraction
		states[index].submerged_fraction = submerged
		if submerged <= 0 do continue
		normal := sample.normal
		normal_length := math.sqrt(water_physics_dot(normal, normal))
		if normal_length <= WATER_PHYSICS_EPSILON do continue
		normal /= normal_length
		share := max(point.displacement_share, f32(0)) / share_total
		area := max(point.area, f32(0))
		force :=
			normal *
			submerged *
			body.mass *
			WATER_PHYSICS_GRAVITY *
			WATER_PHYSICS_BUOYANCY_GAIN *
			share
		force += water_physics_axis_drag(body.forward, relative, point.drag.x, area, submerged)
		force += water_physics_axis_drag(
			body.right,
			relative,
			point.drag.y + point.rail,
			area,
			submerged,
		)
		force += water_physics_axis_drag(body.up, relative, point.drag.z, area, submerged)
		ventilation := f32(1)
		if point.ventilation_depth > WATER_PHYSICS_EPSILON {
			ventilation = clamp(sample.depth / point.ventilation_depth, f32(0), f32(1))
		}
		force += water_physics_axis_drag(
			body.right,
			relative,
			point.fin * ventilation,
			area,
			submerged,
		)
		normal_speed := water_physics_dot(relative, normal)
		tangent := relative - normal * normal_speed
		tangent_speed_squared := water_physics_dot(tangent, tangent)
		near_surface := 1 - submerged
		force +=
			normal *
			max(point.planing, f32(0)) *
			area *
			tangent_speed_squared *
			near_surface *
			ventilation
		immersion_rate := max(submerged - previous_submerged, f32(0)) / dt
		force +=
			normal *
			max(point.slamming, f32(0)) *
			body.mass *
			share *
			immersion_rate *
			max(-normal_speed, f32(0))
		if sample.whitewater > 0 {
			force +=
				-relative *
				body.mass *
				max(sample.flow_drag, f32(0)) *
				sample.whitewater *
				submerged *
				share
		}
		force = water_physics_clamp_vector(force, WATER_PHYSICS_FORCE_MAX)
		if water_physics_dot(force, force) <= WATER_PHYSICS_EPSILON do continue
		loads[result.count] = {
			position = position,
			force    = force,
		}
		result.force += force
		result.torque += water_physics_cross(radius, force)
		result.count += 1
	}
	result.force = water_physics_clamp_vector(result.force, WATER_PHYSICS_FORCE_MAX * f32(count))
	result.torque = water_physics_clamp_vector(result.torque, WATER_PHYSICS_FORCE_MAX * f32(count))
	return
}
