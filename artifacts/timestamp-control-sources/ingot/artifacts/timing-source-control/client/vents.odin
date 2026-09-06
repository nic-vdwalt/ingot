package main

import ecs "ingot:ecs"
import rl "ingot:gfx"

VENT_PICK_RADIUS :: f32(1.2)
VENT_PICK_MIN_HEIGHT :: f32(0.8)

vent_world_bounds :: proc(value: ^Client_State, entity: ecs.Entity) -> (Bounds_3D, bool) {
	vent, has_vent := ecs.get(&value.world.hydrothermal_vents, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_vent || !has_transform do return {}, false
	height := max(f32(vent.chimney_mm) / 1_000, VENT_PICK_MIN_HEIGHT)
	center := transform.position + transform.up * (height * 0.5)
	extent := [3]f32{VENT_PICK_RADIUS, VENT_PICK_RADIUS, height * 0.5}
	return {min = center - extent, max = center + extent}, true
}

vent_mesh_outline_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	scale: f32,
	color: rl.Color,
) -> bool {
	vent, has_vent := ecs.get(&value.world.hydrothermal_vents, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_vent || !has_transform do return false
	height := max(f32(vent.chimney_mm) / 1_000, VENT_PICK_MIN_HEIGHT)
	center := transform.position + transform.up * (height * 0.5)
	matrix_value :=
		rl.MatrixTranslate(center.x, center.y, center.z) *
		surface_frame(transform) *
		rl.MatrixScale(0.35 * scale, 0.35 * scale, height * scale)
	rl.draw_gpu_mesh(pass, value.cube, matrix_value, {color = color, style = .Silhouette_Outline})
	return true
}

vents_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil && pass != nil, "vents_draw: invalid argument")
	for index in 0 ..< ecs.set_len(&value.world.hydrothermal_vents) {
		entity := value.world.hydrothermal_vents.header.entities[index]
		vent := &value.world.hydrothermal_vents.items[index]
		transform, ok := ecs.get(&value.world.transforms, entity)
		if !ok do continue
		height := max(f32(vent.chimney_mm) / 1_000, VENT_PICK_MIN_HEIGHT)
		center := transform.position + transform.up * (height * 0.5)
		matrix_value :=
			rl.MatrixTranslate(center.x, center.y, center.z) *
			surface_frame(transform) *
			rl.MatrixScale(0.35, 0.35, height)
		rl.draw_gpu_mesh(pass, value.cube, matrix_value, {color = UI_DEBUG_SCOPE})
	}
}
