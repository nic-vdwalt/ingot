package main

import shared "../shared"
import "core:math"
import ecs "ingot:ecs"
import rl "ingot:gfx"

SELECTION_GRID_SUBDIV :: 4
SELECTION_GRID_MAX_FOOTPRINT :: 3
SELECTION_GRID_MAX_SEGMENTS ::
	2 * (SELECTION_GRID_MAX_FOOTPRINT + 1) * SELECTION_GRID_MAX_FOOTPRINT * SELECTION_GRID_SUBDIV
SELECTION_GRID_VERTICES :: SELECTION_GRID_MAX_SEGMENTS * 2
SELECTION_GRID_LIFT :: f32(0.10)
SELECTION_BRACKET_FRACTION :: DEBUG_MARKER_BRACKET_FRACTION
SELECTION_BRACKET_SEGMENTS :: DEBUG_MARKER_BRACKET_SEGMENTS
SELECTION_BRACKET_VERTICES :: DEBUG_MARKER_BRACKET_VERTICES

Selection_Frame_Key :: struct {
	entity:           ecs.Entity,
	heights_revision: u64,
}

Selection_Frame :: struct {
	grid_mesh:    rl.Gpu_Mesh,
	bracket_mesh: rl.Gpu_Mesh,
	grid_scratch: [SELECTION_GRID_VERTICES]rl.Gpu_3D_Vertex,
	key:          Selection_Frame_Key,
	cached:       bool,
}

selection_grid_segment_count :: proc(width, height: i32) -> int {
	assert(width > 0 && width <= SELECTION_GRID_MAX_FOOTPRINT, "selection grid: invalid width")
	assert(height > 0 && height <= SELECTION_GRID_MAX_FOOTPRINT, "selection grid: invalid height")
	return int(((width + 1) * height + (height + 1) * width) * SELECTION_GRID_SUBDIV)
}

selection_bracket_vertices :: proc() -> [SELECTION_BRACKET_VERTICES]rl.Gpu_3D_Vertex {
	return marker_corner_vertices()
}

selection_frame_init :: proc(frame: ^Selection_Frame) -> bool {
	assert(frame != nil, "selection frame init: nil frame")
	if frame.grid_mesh.id == 0 {
		indices: [SELECTION_GRID_VERTICES]u32
		for &index, cursor in indices do index = u32(cursor)
		mesh, ok := rl.create_gpu_mesh(frame.grid_scratch[:], indices[:], .Lines)
		if !ok do return false
		frame.grid_mesh = mesh
	}
	if frame.bracket_mesh.id == 0 {
		vertices := selection_bracket_vertices()
		indices: [SELECTION_BRACKET_VERTICES]u32
		for &index, cursor in indices do index = u32(cursor)
		mesh, ok := rl.create_gpu_mesh(vertices[:], indices[:], .Lines)
		if !ok do return false
		frame.bracket_mesh = mesh
	}
	return true
}

selection_surface_point :: proc(
	world: ^shared.World,
	anchor, east, north: [3]f32,
	x, y: f32,
) -> [3]f32 {
	assert(world != nil, "selection surface point: nil world")
	direction := anchor + east * x + north * y
	length := math.sqrt(
		direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
	)
	assert(length > 0, "selection surface point: zero direction")
	direction /= length
	height := shared.terrain_height_at_direction(world, direction)
	return shared.planet_position(direction, height + SELECTION_GRID_LIFT)
}

selection_grid_write_segment :: proc(
	frame: ^Selection_Frame,
	write: ^int,
	world: ^shared.World,
	transform: ^shared.Transform,
	from_x, from_y, to_x, to_y: f32,
) {
	assert(
		frame != nil && write != nil && transform != nil,
		"selection grid segment: invalid argument",
	)
	assert(write^ >= 0 && write^ + 1 < SELECTION_GRID_VERTICES, "selection grid segment: capacity")
	from := selection_surface_point(
		world,
		transform.position,
		transform.east,
		transform.north,
		from_x,
		from_y,
	)
	to := selection_surface_point(
		world,
		transform.position,
		transform.east,
		transform.north,
		to_x,
		to_y,
	)
	frame.grid_scratch[write^ + 0] = {
		position = from,
		normal   = transform.up,
	}
	frame.grid_scratch[write^ + 1] = {
		position = to,
		normal   = transform.up,
	}
	write^ += 2
}

selection_grid_build :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "selection grid build: nil state")
	entity := value.selected
	building, building_ok := ecs.get(&value.world.buildings, entity)
	transform, transform_ok := ecs.get(&value.world.transforms, entity)
	if !building_ok || !transform_ok do return false
	width, height := shared.building_footprint(building.kind)
	assert(width <= SELECTION_GRID_MAX_FOOTPRINT && height <= SELECTION_GRID_MAX_FOOTPRINT)
	cell := shared.GRID_CELL_SIZE
	minimum := -cell / 2
	write := 0
	for line_x in 0 ..= width {
		x := minimum + f32(line_x) * cell
		for cell_y in 0 ..< height {
			for segment in 0 ..< SELECTION_GRID_SUBDIV {
				from_y := minimum + (f32(cell_y) + f32(segment) / SELECTION_GRID_SUBDIV) * cell
				to_y := minimum + (f32(cell_y) + f32(segment + 1) / SELECTION_GRID_SUBDIV) * cell
				selection_grid_write_segment(
					&value.selection_frame,
					&write,
					&value.world,
					transform,
					x,
					from_y,
					x,
					to_y,
				)
			}
		}
	}
	for line_y in 0 ..= height {
		y := minimum + f32(line_y) * cell
		for cell_x in 0 ..< width {
			for segment in 0 ..< SELECTION_GRID_SUBDIV {
				from_x := minimum + (f32(cell_x) + f32(segment) / SELECTION_GRID_SUBDIV) * cell
				to_x := minimum + (f32(cell_x) + f32(segment + 1) / SELECTION_GRID_SUBDIV) * cell
				selection_grid_write_segment(
					&value.selection_frame,
					&write,
					&value.world,
					transform,
					from_x,
					y,
					to_x,
					y,
				)
			}
		}
	}
	assert(write == selection_grid_segment_count(width, height) * 2)
	collapse := selection_surface_point(
		&value.world,
		transform.position,
		transform.east,
		transform.north,
		0,
		0,
	)
	for write < SELECTION_GRID_VERTICES {
		value.selection_frame.grid_scratch[write] = {
			position = collapse,
			normal   = transform.up,
		}
		write += 1
	}
	if !rl.update_gpu_mesh_vertices(
		value.selection_frame.grid_mesh,
		value.selection_frame.grid_scratch[:],
	) {
		return false
	}
	value.selection_frame.key = {entity, value.terrain.heights_revision}
	value.selection_frame.cached = true
	return true
}

selection_bracket_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	center, size: [3]f32,
	frame: rl.Matrix,
	scale: f32,
	color: rl.Color,
) {
	assert(value != nil && pass != nil, "selection bracket draw: invalid argument")
	assert(scale > 1, "selection bracket draw: scale must inflate")
	transform :=
		rl.MatrixTranslate(center.x, center.y, center.z) *
		frame *
		rl.MatrixScale(size.x * scale, size.y * scale, size.z * scale)
	rl.draw_gpu_mesh(pass, value.selection_frame.bracket_mesh, transform, {color = color})
}

selection_frame_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil && pass != nil, "selection frame draw: invalid argument")
	if value.selected == ecs.ENTITY_NIL do return
	if !ecs.has(&value.world.buildings, value.selected) do return
	key := Selection_Frame_Key{value.selected, value.terrain.heights_revision}
	if !value.selection_frame.cached || value.selection_frame.key != key {
		if !selection_grid_build(value) do return
	}
	grid := UI_SELECTED_GRID
	grid.a = u8(145 + 25 * math.sin(value.cursor.time * 3))
	rl.draw_gpu_mesh(pass, value.selection_frame.grid_mesh, rl.Matrix(1), {color = grid})
	center, size, oriented, ok := building_oriented_bounds(value, value.selected)
	if !ok do return
	selection_bracket_draw(value, pass, center, size, oriented, 1.10, UI_SELECTED_OUTLINE)
	pulse_scale := 1.15 + 0.025 * math.sin(value.cursor.time * 3)
	selection_bracket_draw(value, pass, center, size, oriented, pulse_scale, UI_SELECTED_GRID_DIM)
}

selection_frame_deinit :: proc(frame: ^Selection_Frame) {
	assert(frame != nil, "selection frame deinit: nil frame")
	if frame.grid_mesh.id != 0 do rl.destroy_gpu_mesh(&frame.grid_mesh)
	if frame.bracket_mesh.id != 0 do rl.destroy_gpu_mesh(&frame.bracket_mesh)
	frame^ = {}
}
