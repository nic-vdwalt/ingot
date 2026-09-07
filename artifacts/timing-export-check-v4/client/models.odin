package main

import shared "../shared"
import "core:math"
import ecs "ingot:ecs"
import rl "ingot:gfx"

MODEL_LEVEL_SCALE_BASE :: f32(0.85)
MODEL_LEVEL_SCALE_STEP :: f32(0.15)
MODEL_LEVEL_SCALE_MAX :: f32(1.75)
MODEL_SCAFFOLD_HEIGHT :: f32(0.4)
MODEL_COMPONENT_COUNT :: 3

Bounds_3D :: struct {
	min: [3]f32,
	max: [3]f32,
}

Building_Component :: struct {
	mesh:  Structure_Mesh_Id,
	color: rl.Color,
}

Building_Model :: struct {
	components:      [MODEL_COMPONENT_COUNT]Building_Component,
	component_count: int,
	socket_radius:   f32,
}

HULL_LIGHT :: rl.Color{200, 204, 212, 255}
HULL_MID :: rl.Color{136, 143, 154, 255}
PANEL_BLUE :: rl.Color{58, 88, 158, 255}
EDGE_DARK :: rl.Color{24, 28, 36, 255}

BUILDING_MODELS := [shared.Building_Kind]Building_Model {
	.Headquarters = {
		components = {
			0 = {mesh = .Headquarters_Hull, color = HULL_LIGHT},
			1 = {mesh = .Headquarters_Structure, color = EDGE_DARK},
			2 = {mesh = .Headquarters_Accent, color = {223, 126, 214, 255}},
		},
		component_count = 3,
		socket_radius = 2.7,
	},
	.Mine = {
		components = {
			0 = {mesh = .Mine_Hull, color = {106, 109, 116, 255}},
			1 = {mesh = .Mine_Structure, color = EDGE_DARK},
			2 = {mesh = .Mine_Accent, color = {255, 151, 92, 255}},
		},
		component_count = 3,
		socket_radius = 0.92,
	},
	.Solar_Array = {
		components = {
			0 = {mesh = .Solar_Array_Hull, color = HULL_MID},
			1 = {mesh = .Solar_Array_Structure, color = EDGE_DARK},
			2 = {mesh = .Solar_Array_Accent, color = PANEL_BLUE},
		},
		component_count = 3,
		socket_radius = 1.78,
	},
	.Habitat = {
		components = {0 = {mesh = .Habitat_Hull, color = {214, 226, 218, 255}}},
		component_count = 1,
		socket_radius = 1.7,
	},
}

model_level_scale :: proc(level: u8) -> f32 {
	assert(level > 0, "model_level_scale: level 0 has no model")
	return min(MODEL_LEVEL_SCALE_BASE + MODEL_LEVEL_SCALE_STEP * f32(level), MODEL_LEVEL_SCALE_MAX)
}

// _frame_matrix builds the rotation whose columns map model-local X/Y/Z onto
// the supplied world-space axes. Odin matrix literals are written row-major,
// so the basis vectors appear transposed below.
_frame_matrix :: proc(local_x, local_y, local_z: [3]f32) -> rl.Matrix {
	return {
		local_x.x, local_y.x, local_z.x, 0,
		local_x.y, local_y.y, local_z.y, 0,
		local_x.z, local_y.z, local_z.z, 0,
		0, 0, 0, 1,
	}
}

// surface_frame returns the rotation aligning model axes with the sim
// transform's local surface frame from planet_transform_make.
surface_frame :: proc(transform: ^shared.Transform) -> rl.Matrix {
	assert(transform != nil, "surface_frame: nil transform")
	return _frame_matrix(transform.east, transform.north, transform.up)
}

// building_anchor_center offsets the min-corner anchor to the footprint
// center along the surface tangents instead of world X/Y.
building_anchor_center :: proc(transform: ^shared.Transform, foot_w, foot_h: i32) -> [3]f32 {
	assert(transform != nil, "building_anchor_center: nil transform")
	cell := shared.GRID_CELL_SIZE
	return(
		transform.position +
		transform.east * (f32(foot_w - 1) * cell / 2) +
		transform.north * (f32(foot_h - 1) * cell / 2) \
	)
}

_model_transform :: proc(position: [3]f32, frame: rl.Matrix, level_scale: f32) -> rl.Matrix {
	return(
		rl.MatrixTranslate(position.x, position.y, position.z) *
		frame *
		rl.MatrixScale(1, 1, level_scale) \
	)
}

bounds_transform :: proc(bounds: Bounds_3D, transform: rl.Matrix) -> Bounds_3D {
	first := transform * [4]f32{bounds.min.x, bounds.min.y, bounds.min.z, 1}
	result := Bounds_3D {
		min = first.xyz,
		max = first.xyz,
	}
	for corner in 1 ..< 8 {
		local := [4]f32 {
			bounds.max.x if corner & 1 != 0 else bounds.min.x,
			bounds.max.y if corner & 2 != 0 else bounds.min.y,
			bounds.max.z if corner & 4 != 0 else bounds.min.z,
			1,
		}
		point := transform * local
		result.min = {
			min(result.min.x, point.x),
			min(result.min.y, point.y),
			min(result.min.z, point.z),
		}
		result.max = {
			max(result.max.x, point.x),
			max(result.max.y, point.y),
			max(result.max.z, point.z),
		}
	}
	return result
}

bounds_from_unit_transform :: proc(transform: rl.Matrix) -> Bounds_3D {
	return bounds_transform({min = {-0.5, -0.5, -0.5}, max = {0.5, 0.5, 0.5}}, transform)
}

bounds_union :: proc(a, b: Bounds_3D) -> Bounds_3D {
	return {
		min = {min(a.min.x, b.min.x), min(a.min.y, b.min.y), min(a.min.z, b.min.z)},
		max = {max(a.max.x, b.max.x), max(a.max.y, b.max.y), max(a.max.z, b.max.z)},
	}
}

bounds_center :: proc(value: Bounds_3D) -> [3]f32 {
	return (value.min + value.max) * 0.5
}

bounds_size :: proc(value: Bounds_3D) -> [3]f32 {
	return value.max - value.min
}

_structure_bounds :: proc(value: ^Client_State, mesh: Structure_Mesh_Id) -> Bounds_3D {
	bounds := value.structures.bounds[mesh]
	return {min = bounds.minimum, max = bounds.maximum}
}

building_local_bounds :: proc(
	value: ^Client_State,
	kind: shared.Building_Kind,
	level: u8,
) -> Bounds_3D {
	if level == 0 {
		width, height := shared.building_footprint(kind)
		return bounds_from_unit_transform(
			rl.MatrixTranslate(0, 0, MODEL_SCAFFOLD_HEIGHT / 2) *
			rl.MatrixScale(
				f32(width) * shared.GRID_CELL_SIZE * 0.8,
				f32(height) * shared.GRID_CELL_SIZE * 0.8,
				MODEL_SCAFFOLD_HEIGHT,
			),
		)
	}
	model := &BUILDING_MODELS[kind]
	transform := _model_transform({}, rl.Matrix(1), model_level_scale(level))
	result := bounds_transform(_structure_bounds(value, model.components[0].mesh), transform)
	for index in 1 ..< model.component_count {
		result = bounds_union(
			result,
			bounds_transform(_structure_bounds(value, model.components[index].mesh), transform),
		)
	}
	return result
}

building_world_bounds :: proc(value: ^Client_State, entity: ecs.Entity) -> (Bounds_3D, bool) {
	building, has_building := ecs.get(&value.world.buildings, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_building || !has_transform do return {}, false
	width, height := shared.building_footprint(building.kind)
	center := building_anchor_center(transform, width, height)
	bounds := building_local_bounds(value, building.kind, building.level)
	return bounds_transform(
			bounds,
			rl.MatrixTranslate(center.x, center.y, center.z) * surface_frame(transform),
		),
		true
}

entity_tooltip_anchor_from_up :: proc(bounds: Bounds_3D, up: [3]f32) -> [3]f32 {
	center := bounds_center(bounds)
	half_extent :=
		abs(bounds.max.x - center.x) * abs(up.x) +
		abs(bounds.max.y - center.y) * abs(up.y) +
		abs(bounds.max.z - center.z) * abs(up.z)
	return center + up * (half_extent + 0.5)
}

entity_tooltip_anchor :: proc(value: ^Client_State, entity: ecs.Entity, bounds: Bounds_3D) -> ([3]f32, bool) {
	transform, ok := ecs.get(&value.world.transforms, entity)
	if !ok do return {}, false
	return entity_tooltip_anchor_from_up(bounds, transform.up), true
}

// building_oriented_bounds returns the surface-frame oriented box of a
// building: the world center, the local (unrotated) size, and the frame
// rotation, for outline draws that should hug the rotated model.
building_oriented_bounds :: proc(
	value: ^Client_State,
	entity: ecs.Entity,
) -> (
	center: [3]f32,
	size: [3]f32,
	frame: rl.Matrix,
	ok: bool,
) {
	building, has_building := ecs.get(&value.world.buildings, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_building || !has_transform do return
	width, height := shared.building_footprint(building.kind)
	anchor := building_anchor_center(transform, width, height)
	bounds := building_local_bounds(value, building.kind, building.level)
	frame = surface_frame(transform)
	local_center := bounds_center(bounds)
	rotated := frame * [4]f32{local_center.x, local_center.y, local_center.z, 0}
	center = anchor + rotated.xyz
	size = bounds_size(bounds)
	ok = true
	return
}

building_mesh_outline_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	scale: f32,
	color: rl.Color,
) -> bool {
	building, has_building := ecs.get(&value.world.buildings, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_building || !has_transform do return false
	foot_w, foot_h := shared.building_footprint(building.kind)
	center := building_anchor_center(transform, foot_w, foot_h)
	frame := surface_frame(transform)
	if building.level == 0 {
		depth := MODEL_SCAFFOLD_HEIGHT + SOCKET_SINK
		lift := center + transform.up * (MODEL_SCAFFOLD_HEIGHT - depth / 2)
		matrix_value :=
			rl.MatrixTranslate(lift.x, lift.y, lift.z) *
			frame *
			rl.MatrixScale(
				f32(foot_w) * shared.GRID_CELL_SIZE * 0.8 * scale,
				f32(foot_h) * shared.GRID_CELL_SIZE * 0.8 * scale,
				depth * scale,
			)
		rl.draw_gpu_mesh(pass, value.cylinder, matrix_value, {color = color, style = .Silhouette_Outline})
		return true
	}
	model := &BUILDING_MODELS[building.kind]
	matrix_value := _model_transform(center, frame, model_level_scale(building.level)) *
		rl.MatrixScale(scale, scale, scale)
	for component_index in 0 ..< model.component_count {
		component := model.components[component_index]
		rl.draw_gpu_mesh(
			pass,
			structure_mesh(value, component.mesh),
			matrix_value,
			{color = color, style = .Silhouette_Outline},
		)
	}
	return true
}

models_draw_buildings :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	for kind in shared.Building_Kind {
		model := &BUILDING_MODELS[kind]
		foot_w, foot_h := shared.building_footprint(kind)
		cell := shared.GRID_CELL_SIZE
		// Undefined-init scratch: only the written prefix is read, and zeroing
		// ~80KB per kind per frame showed up in the frame profile.
		positions: [MAX_DRAW_INSTANCES][3]f32 = ---
		scales: [MAX_DRAW_INSTANCES]f32 = ---
		frames: [MAX_DRAW_INSTANCES]rl.Matrix = ---
		ups: [MAX_DRAW_INSTANCES][3]f32 = ---
		easts: [MAX_DRAW_INSTANCES][3]f32 = ---
		norths: [MAX_DRAW_INSTANCES][3]f32 = ---
		built_count := 0
		scaffold_count := 0
		scaffolds: [MAX_DRAW_INSTANCES]rl.Matrix = ---
		it := ecs.iter2(&value.world.transforms, &value.world.buildings)
		for {
			_, transform, building, ok := ecs.iter2_next(&it)
			if !ok do break
			if building.kind != kind do continue
			center := building_anchor_center(transform, foot_w, foot_h)
			frame := surface_frame(transform)
			if building.level == 0 {
				if scaffold_count >= MAX_DRAW_INSTANCES do continue
				depth := MODEL_SCAFFOLD_HEIGHT + SOCKET_SINK
				lift := center + transform.up * (MODEL_SCAFFOLD_HEIGHT - depth / 2)
				scaffolds[scaffold_count] =
					rl.MatrixTranslate(lift.x, lift.y, lift.z) *
					frame *
					rl.MatrixScale(f32(foot_w) * cell * 0.8, f32(foot_h) * cell * 0.8, depth)
				scaffold_count += 1
				continue
			}
			if built_count >= MAX_DRAW_INSTANCES do continue
			positions[built_count] = center
			scales[built_count] = model_level_scale(building.level)
			frames[built_count] = frame
			ups[built_count] = transform.up
			easts[built_count] = transform.east
			norths[built_count] = transform.north
			built_count += 1
		}
		if built_count > 0 {
			for index in 0 ..< built_count {
				value.draw_transforms[index] = atmosphere_shadow_transform(
					&value.atmosphere,
					positions[index],
					easts[index],
					norths[index],
					ups[index],
					f32(foot_w) * cell * 0.82,
					f32(foot_h) * cell * 0.82,
				)
			}
			shadow_alpha := u8(104) if value.atmosphere.quality == .Ultra else u8(82)
			rl.draw_gpu_mesh_instanced(
				&pass^,
				value.sphere,
				value.draw_transforms[:built_count],
				{color = {4, 7, 11, shadow_alpha}},
			)
			for component_index in 0 ..< model.component_count {
				component := model.components[component_index]
				for index in 0 ..< built_count do value.draw_transforms[index] = _model_transform(positions[index], frames[index], scales[index])
				rl.draw_gpu_mesh_instanced(
					&pass^,
					structure_mesh(value, component.mesh),
					value.draw_transforms[:built_count],
					{
						color = component.color,
						style = .Opaque,
						shader = value.atmosphere.object_shader,
					},
				)
			}
		}
		if scaffold_count > 0 {
			rl.draw_gpu_mesh_instanced(
				&pass^,
				value.cylinder,
				scaffolds[:scaffold_count],
				{
					color = BUILDING_COLORS[kind],
					style = .Opaque,
					shader = value.atmosphere.object_shader,
				},
			)
			rl.draw_gpu_mesh_instanced(
				&pass^,
				value.cube_edges,
				scaffolds[:scaffold_count],
				{color = EDGE_DARK, style = .Opaque_Outline},
			)
		}
	}
}

_cylinder_mesh_create :: proc() -> (rl.Gpu_Mesh, bool) {
	SIDES :: 12
	vertices: [(SIDES + 1) * 2]rl.Gpu_3D_Vertex
	indices: [SIDES * 6]u32
	for segment in 0 ..= SIDES {
		angle := 2 * math.PI * f32(segment) / f32(SIDES)
		normal := [3]f32{math.cos(angle), math.sin(angle), 0}
		vertices[segment * 2] = {
			position = {normal.x * 0.5, normal.y * 0.5, -0.5},
			normal   = normal,
		}
		vertices[segment * 2 + 1] = {
			position = {normal.x * 0.5, normal.y * 0.5, 0.5},
			normal   = normal,
		}
		if segment < SIDES {
			base := segment * 6
			index := u32(segment * 2)
			indices[base + 0] = index
			indices[base + 1] = index + 2
			indices[base + 2] = index + 3
			indices[base + 3] = index
			indices[base + 4] = index + 3
			indices[base + 5] = index + 1
		}
	}
	return rl.create_gpu_mesh(vertices[:], indices[:], .Triangles)
}

_cone_mesh_create :: proc() -> (rl.Gpu_Mesh, bool) {
	return rl.create_cube_mesh()
}

_wedge_mesh_create :: proc() -> (rl.Gpu_Mesh, bool) {
	return rl.create_cube_mesh()
}
