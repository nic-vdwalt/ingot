package main

import shared "../shared"
import "core:math"
import rl "ingot:gfx"
import procgen "ingot:procgen"

WIND_CLOSE_EDGE :: 31
WIND_REGIONAL_EDGE :: 41
WIND_OVERVIEW_STRIDE :: 4
WIND_VERTICES_PER_ARROW :: 7
WIND_INDICES_PER_ARROW :: 9
WIND_CALM_CUTOFF_MPS :: f32(0.35)
WIND_CLOSE_CAPACITY :: WIND_CLOSE_EDGE * WIND_CLOSE_EDGE
WIND_REGIONAL_CAPACITY :: WIND_REGIONAL_EDGE * WIND_REGIONAL_EDGE
WIND_OVERVIEW_FACE_EDGE :: shared.PLANET_SIM_FACE_CELLS / WIND_OVERVIEW_STRIDE
WIND_OVERVIEW_CAPACITY ::
	WIND_OVERVIEW_FACE_EDGE * WIND_OVERVIEW_FACE_EDGE * shared.PLANET_SIM_FACE_COUNT
WIND_ARROWS_PER_PAGE :: 64
WIND_BUILD_ARROWS_PER_UPDATE :: 128

Wind_Visual_Geometry_Settings :: struct {
	proof:           Sim_Proof_Type,
	density_scale:   f32,
	length_scale:    f32,
	lift:            f32,
	reference_speed: f32,
}

Wind_Visual_Layer :: struct {
	vertices:    []rl.Gpu_3D_Vertex,
	indices:     []u32,
	gpu_mesh:    rl.Gpu_Mesh,
	arrow_count: int,
	ready:       bool,
}

Wind_Visual :: struct {
	close:                 Wind_Visual_Layer,
	regional:              Wind_Visual_Layer,
	overview:              Wind_Visual_Layer,
	deep_close:            Wind_Visual_Layer,
	deep_regional:         Wind_Visual_Layer,
	deep_overview:         Wind_Visual_Layer,
	staging_close:         Wind_Visual_Layer,
	staging_regional:      Wind_Visual_Layer,
	staging_overview:      Wind_Visual_Layer,
	staging_deep_close:    Wind_Visual_Layer,
	staging_deep_regional: Wind_Visual_Layer,
	staging_deep_overview: Wind_Visual_Layer,
	shader:                rl.Gpu_3D_Shader,
	last_tick:             u64,
	last_heights_revision: u64,
	last_water_revision:   u64,
	last_focus_cell:       int,
	geometry_settings:     Wind_Visual_Geometry_Settings,
	build_settings:        Sim_Proof_Settings,
	pending_settings:      Sim_Proof_Settings,
	generation:            u64,
	published_generation:  u64,
	build_layer:           int,
	build_arrow:           int,
	build_focus:           [3]f32,
	pending_focus:         [3]f32,
	building:              bool,
	pending:               bool,
	dirty:                 bool,
	ready:                 bool,
}

wind_vector_length :: proc(value: [3]f32) -> f32 {
	return math.sqrt(value.x * value.x + value.y * value.y + value.z * value.z)
}

wind_vector_normalize :: proc(value: [3]f32) -> [3]f32 {
	length := wind_vector_length(value)
	if length <= 0.000001 do return {}
	return value / length
}

wind_vector_dot :: proc(a, b: [3]f32) -> f32 {
	return a.x * b.x + a.y * b.y + a.z * b.z
}

wind_vector_cross :: proc(a, b: [3]f32) -> [3]f32 {
	return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x}
}

sim_proof_cell_world_vector :: proc(
	world: ^shared.World,
	coord: shared.Planet_Sim_Coord,
	proof: Sim_Proof_Type,
	deep: bool,
) -> [3]f32 {
	assert(world != nil, "sim proof cell vector: nil world")
	index := shared.planet_sim_index(coord)
	east_value, north_value: i32
	#partial switch proof {
	case .Wind:
		east_value = world.planetary.climate.wind_east[index]
		north_value = world.planetary.climate.wind_north[index]
	case .Currents:
		if world.planetary.ocean.mean_depth_mm[index] == 0 do return {}
		if deep {
			east_value = world.planetary.ocean.deep_transport_east[index]
			north_value = world.planetary.ocean.deep_transport_north[index]
		} else {
			east_value = world.planetary.ocean.transport_east[index]
			north_value = world.planetary.ocean.transport_north[index]
		}
	case:
		return {}
	}
	direction := shared.planet_sim_direction(coord)
	_, east, north := shared.planet_basis(direction)
	scale := f32(shared.PLANET_VELOCITY_SCALE)
	return east * (f32(east_value) / scale) + north * (f32(north_value) / scale)
}

wind_cell_world_vector :: proc(world: ^shared.World, coord: shared.Planet_Sim_Coord) -> [3]f32 {
	return sim_proof_cell_world_vector(world, coord, .Wind, false)
}

sim_proof_world_vector :: proc(
	world: ^shared.World,
	direction: [3]f32,
	proof: Sim_Proof_Type,
	deep: bool,
) -> (
	vector: [3]f32,
	speed_mps: f32,
) {
	assert(world != nil, "wind_world_vector: nil world")
	radial := wind_vector_normalize(direction)
	if wind_vector_length(radial) <= 0 do return
	center_index := shared.planetary_sample_index(radial)
	center := shared.planet_sim_coord_for_index(center_index)
	coords := [5]shared.Planet_Sim_Coord {
		center,
		shared.planet_sim_neighbour(center, -1, 0),
		shared.planet_sim_neighbour(center, 1, 0),
		shared.planet_sim_neighbour(center, 0, -1),
		shared.planet_sim_neighbour(center, 0, 1),
	}
	weight_sum := f32(0)
	for coord in coords {
		sample_direction := shared.planet_sim_direction(coord)
		distance := max(1 - wind_vector_dot(radial, sample_direction), f32(0.000001))
		weight := 1 / distance
		vector += sim_proof_cell_world_vector(world, coord, proof, deep) * weight
		weight_sum += weight
	}
	if weight_sum > 0 do vector /= weight_sum
	vector -= radial * wind_vector_dot(vector, radial)
	speed_mps = wind_vector_length(vector)
	return
}

wind_world_vector :: proc(world: ^shared.World, direction: [3]f32) -> ([3]f32, f32) {
	return sim_proof_world_vector(world, direction, .Wind, false)
}

wind_display_strength :: proc(speed_mps, reference_mps: f32) -> f32 {
	if reference_mps <= 0 do return 0
	normalized := clamp((speed_mps - WIND_CALM_CUTOFF_MPS) / reference_mps, f32(0), f32(1))
	return math.sqrt(normalized)
}

wind_surface_height :: proc(world: ^shared.World, direction: [3]f32) -> f32 {
	assert(world != nil, "wind_surface_height: nil world")
	face, u, v := shared.planet_locate(direction)
	coord := shared.Planet_Coord {
		face,
		clamp(i32(u), 0, i32(shared.PLANET_FACE_CELLS)),
		clamp(i32(v), 0, i32(shared.PLANET_FACE_CELLS)),
	}
	ground := shared.terrain_height_at_coord(world, coord)
	depth := shared.waterfield_depth_at_coord(world, coord)
	surface, _, coverage := water_render_sample(ground, depth)
	if coverage <= 0 do return ground
	index := shared.planetary_sample_index(direction)
	if index < len(world.planetary.ocean.surface_mm) {
		surface += shared.planet_render_height_from_mm(world.planetary.ocean.surface_mm[index])
	}
	return max(ground, surface)
}

wind_layer_init_storage :: proc(
	layer: ^Wind_Visual_Layer,
	capacity: int,
	allocator := context.allocator,
) {
	assert(layer != nil && capacity > 0, "wind_layer_init_storage: invalid input")
	layer.vertices = make([]rl.Gpu_3D_Vertex, capacity * WIND_VERTICES_PER_ARROW, allocator)
	layer.indices = make([]u32, capacity * WIND_INDICES_PER_ARROW, allocator)
	for arrow in 0 ..< capacity {
		vertex := u32(arrow * WIND_VERTICES_PER_ARROW)
		index := arrow * WIND_INDICES_PER_ARROW
		layer.indices[index + 0] = vertex + 0
		layer.indices[index + 1] = vertex + 2
		layer.indices[index + 2] = vertex + 1
		layer.indices[index + 3] = vertex + 1
		layer.indices[index + 4] = vertex + 2
		layer.indices[index + 5] = vertex + 3
		layer.indices[index + 6] = vertex + 4
		layer.indices[index + 7] = vertex + 5
		layer.indices[index + 8] = vertex + 6
	}
}

wind_layer_deinit_storage :: proc(layer: ^Wind_Visual_Layer, allocator := context.allocator) {
	assert(layer != nil, "wind_layer_deinit_storage: nil layer")
	delete(layer.indices, allocator)
	delete(layer.vertices, allocator)
	layer^ = {}
}

wind_arrow_degenerate :: proc(layer: ^Wind_Visual_Layer, arrow: int) {
	assert(layer != nil, "wind_arrow_degenerate: nil layer")
	base := arrow * WIND_VERTICES_PER_ARROW
	assert(
		base >= 0 && base + WIND_VERTICES_PER_ARROW <= len(layer.vertices),
		"wind_arrow_degenerate: capacity",
	)
	position := layer.vertices[base].position
	for index in 0 ..< WIND_VERTICES_PER_ARROW {
		layer.vertices[base + index] = {
			position = position,
		}
	}
}

wind_layer_degenerate_from :: proc(layer: ^Wind_Visual_Layer, first_arrow: int) {
	assert(layer != nil, "wind_layer_degenerate_from: nil layer")
	capacity := len(layer.vertices) / WIND_VERTICES_PER_ARROW
	for arrow in clamp(first_arrow, 0, capacity) ..< capacity {
		wind_arrow_degenerate(layer, arrow)
	}
	layer.arrow_count = clamp(first_arrow, 0, capacity)
}

wind_surface_position :: proc(world: ^shared.World, direction: [3]f32, lift: f32) -> [3]f32 {
	radial := wind_vector_normalize(direction)
	return shared.planet_position(radial, wind_surface_height(world, radial) + lift)
}

wind_arrow_fill :: proc(
	layer: ^Wind_Visual_Layer,
	arrow: int,
	world: ^shared.World,
	direction, wind: [3]f32,
	display_strength, base_length, width, lift: f32,
) -> bool {
	assert(layer != nil && world != nil, "wind_arrow_fill: nil input")
	base := arrow * WIND_VERTICES_PER_ARROW
	if base < 0 || base + WIND_VERTICES_PER_ARROW > len(layer.vertices) do return false
	radial := wind_vector_normalize(direction)
	flow := wind - radial * wind_vector_dot(wind, radial)
	flow = wind_vector_normalize(flow)
	if display_strength <= 0 || wind_vector_length(flow) <= 0 {
		wind_arrow_degenerate(layer, arrow)
		return false
	}
	length := base_length * (0.3 + 0.7 * display_strength)
	angular := length / shared.PLANET_RADIUS
	tail_direction := wind_vector_normalize(
		radial * math.cos(angular * 0.5) - flow * math.sin(angular * 0.5),
	)
	head_direction := wind_vector_normalize(
		radial * math.cos(angular * 0.5) + flow * math.sin(angular * 0.5),
	)
	neck_direction := wind_vector_normalize(
		radial * math.cos(angular * 0.2) + flow * math.sin(angular * 0.2),
	)
	tail := wind_surface_position(world, tail_direction, lift)
	neck := wind_surface_position(world, neck_direction, lift)
	head := wind_surface_position(world, head_direction, lift)
	tail_side := wind_vector_normalize(wind_vector_cross(tail_direction, flow)) * width
	neck_side := wind_vector_normalize(wind_vector_cross(neck_direction, flow)) * width
	head_side := wind_vector_normalize(wind_vector_cross(head_direction, flow)) * width * 2.2
	layer.vertices[base + 0] = {
		position = tail - tail_side,
		normal   = tail_direction,
		scalar   = display_strength,
		uv       = {0, -1},
	}
	layer.vertices[base + 1] = {
		position = tail + tail_side,
		normal   = tail_direction,
		scalar   = display_strength,
		uv       = {0, 1},
	}
	layer.vertices[base + 2] = {
		position = neck - neck_side,
		normal   = neck_direction,
		scalar   = display_strength,
		uv       = {0.72, -1},
	}
	layer.vertices[base + 3] = {
		position = neck + neck_side,
		normal   = neck_direction,
		scalar   = display_strength,
		uv       = {0.72, 1},
	}
	layer.vertices[base + 4] = {
		position = neck - head_side,
		normal   = neck_direction,
		scalar   = display_strength,
		uv       = {0.68, -1},
	}
	layer.vertices[base + 5] = {
		position = neck + head_side,
		normal   = neck_direction,
		scalar   = display_strength,
		uv       = {0.68, 1},
	}
	layer.vertices[base + 6] = {
		position = head,
		normal   = head_direction,
		scalar   = display_strength,
		uv       = {1, 0},
	}
	layer.arrow_count = max(layer.arrow_count, arrow + 1)
	return true
}

wind_layer_gpu_init :: proc(layer: ^Wind_Visual_Layer) -> bool {
	assert(layer != nil, "wind_layer_gpu_init: nil layer")
	mesh, ok := rl.create_gpu_mesh(layer.vertices, layer.indices, .Triangles)
	if !ok do return false
	if layer.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&layer.gpu_mesh)
	layer.gpu_mesh = mesh
	layer.ready = true
	return true
}

wind_visual_init :: proc(value: ^Wind_Visual) -> bool {
	assert(value != nil, "wind_visual_init: nil visual")
	if value.ready do return true
	wind_visual_deinit(value)
	wind_layer_init_storage(&value.close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&value.regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&value.overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&value.deep_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&value.deep_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&value.deep_overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&value.staging_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&value.staging_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&value.staging_overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_init_storage(&value.staging_deep_close, WIND_CLOSE_CAPACITY)
	wind_layer_init_storage(&value.staging_deep_regional, WIND_REGIONAL_CAPACITY)
	wind_layer_init_storage(&value.staging_deep_overview, WIND_OVERVIEW_CAPACITY)
	wind_layer_degenerate_from(&value.close, 0)
	wind_layer_degenerate_from(&value.regional, 0)
	wind_layer_degenerate_from(&value.overview, 0)
	wind_layer_degenerate_from(&value.deep_close, 0)
	wind_layer_degenerate_from(&value.deep_regional, 0)
	wind_layer_degenerate_from(&value.deep_overview, 0)
	wind_layer_degenerate_from(&value.staging_close, 0)
	wind_layer_degenerate_from(&value.staging_regional, 0)
	wind_layer_degenerate_from(&value.staging_overview, 0)
	wind_layer_degenerate_from(&value.staging_deep_close, 0)
	wind_layer_degenerate_from(&value.staging_deep_regional, 0)
	wind_layer_degenerate_from(&value.staging_deep_overview, 0)
	shader, shader_ok := rl.create_gpu_3d_shader(WIND_VISUAL_SHADER)
	if !shader_ok {
		wind_visual_deinit(value)
		return false
	}
	value.shader = shader
	if !wind_layer_gpu_init(&value.close) ||
	   !wind_layer_gpu_init(&value.regional) ||
	   !wind_layer_gpu_init(&value.overview) ||
	   !wind_layer_gpu_init(&value.deep_close) ||
	   !wind_layer_gpu_init(&value.deep_regional) ||
	   !wind_layer_gpu_init(&value.deep_overview) ||
	   !wind_layer_gpu_init(&value.staging_close) ||
	   !wind_layer_gpu_init(&value.staging_regional) ||
	   !wind_layer_gpu_init(&value.staging_overview) ||
	   !wind_layer_gpu_init(&value.staging_deep_close) ||
	   !wind_layer_gpu_init(&value.staging_deep_regional) ||
	   !wind_layer_gpu_init(&value.staging_deep_overview) {
		wind_visual_deinit(value)
		return false
	}
	value.last_focus_cell = -1
	value.dirty = true
	value.ready = true
	return true
}

wind_visual_deinit :: proc(value: ^Wind_Visual) {
	assert(value != nil, "wind_visual_deinit: nil visual")
	if value.close.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.close.gpu_mesh)
	if value.regional.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.regional.gpu_mesh)
	if value.overview.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.overview.gpu_mesh)
	if value.deep_close.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.deep_close.gpu_mesh)
	if value.deep_regional.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.deep_regional.gpu_mesh)
	if value.deep_overview.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.deep_overview.gpu_mesh)
	if value.staging_close.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_close.gpu_mesh)
	if value.staging_regional.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_regional.gpu_mesh)
	if value.staging_overview.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_overview.gpu_mesh)
	if value.staging_deep_close.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_deep_close.gpu_mesh)
	if value.staging_deep_regional.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_deep_regional.gpu_mesh)
	if value.staging_deep_overview.gpu_mesh.id != 0 do rl.destroy_gpu_mesh(&value.staging_deep_overview.gpu_mesh)
	if value.shader.id != 0 do rl.destroy_gpu_3d_shader(&value.shader)
	wind_layer_deinit_storage(&value.close)
	wind_layer_deinit_storage(&value.regional)
	wind_layer_deinit_storage(&value.overview)
	wind_layer_deinit_storage(&value.deep_close)
	wind_layer_deinit_storage(&value.deep_regional)
	wind_layer_deinit_storage(&value.deep_overview)
	wind_layer_deinit_storage(&value.staging_close)
	wind_layer_deinit_storage(&value.staging_regional)
	wind_layer_deinit_storage(&value.staging_overview)
	wind_layer_deinit_storage(&value.staging_deep_close)
	wind_layer_deinit_storage(&value.staging_deep_regional)
	wind_layer_deinit_storage(&value.staging_deep_overview)
	value^ = {}
}

wind_visual_mark_dirty :: proc(value: ^Wind_Visual) {
	assert(value != nil, "wind_visual_mark_dirty: nil visual")
	value.dirty = true
}

wind_visual_active_count :: proc(value: ^Wind_Visual) -> int {
	if value == nil do return 0
	return(
		value.close.arrow_count +
		value.regional.arrow_count +
		value.overview.arrow_count +
		value.deep_close.arrow_count +
		value.deep_regional.arrow_count +
		value.deep_overview.arrow_count \
	)
}

wind_layer_fill_cap_range :: proc(
	layer: ^Wind_Visual_Layer,
	world: ^shared.World,
	focus: [3]f32,
	edge: int,
	spacing: f32,
	settings: Sim_Proof_Settings,
	deep: bool,
	first, count: int,
) -> int {
	assert(layer != nil && world != nil, "wind_layer_fill_cap_range: nil input")
	radial := wind_vector_normalize(focus)
	_, east, north := shared.planet_basis(radial)
	bucket := clamp(i32(math.round(settings.density_scale * 4)), i32(1), i32(8))
	step := 4 / f32(bucket)
	half := f32(edge - 1) * 0.5
	end := min(first + count, edge * edge)
	for arrow in first ..< end {
		row := arrow / edge
		column := arrow % edge
		x := (f32(column) - half) * spacing * step
		y := (f32(row) - half) * spacing * step
		direction := ocean_clipmap_direction(radial, east, north, x, y)
		vector, speed := sim_proof_world_vector(world, direction, settings.proof, deep)
		reference_speed := settings.reference_speed
		if settings.proof == .Currents do reference_speed *= 0.1
		strength := wind_display_strength(speed, reference_speed)
		lift := settings.lift
		if deep do lift = max(settings.lift * 0.35, f32(0.25))
		_ = wind_arrow_fill(
			layer,
			arrow,
			world,
			direction,
			vector,
			strength,
			spacing * 0.72 * settings.length_scale,
			max(spacing * 0.055, f32(0.6)),
			lift,
		)
	}
	return end
}

wind_layer_fill_overview_range :: proc(
	layer: ^Wind_Visual_Layer,
	world: ^shared.World,
	settings: Sim_Proof_Settings,
	deep: bool,
	first, count: int,
) -> int {
	assert(layer != nil && world != nil, "wind_layer_fill_overview_range: nil input")
	face_capacity := WIND_OVERVIEW_FACE_EDGE * WIND_OVERVIEW_FACE_EDGE
	end := min(first + count, WIND_OVERVIEW_CAPACITY)
	for arrow in first ..< end {
		face_index := arrow / face_capacity
		local := arrow % face_capacity
		row := local / WIND_OVERVIEW_FACE_EDGE
		column := local % WIND_OVERVIEW_FACE_EDGE
		coord := shared.Planet_Sim_Coord {
			procgen.Terrain_Face_V4(face_index),
			i32(column * WIND_OVERVIEW_STRIDE + WIND_OVERVIEW_STRIDE / 2),
			i32(row * WIND_OVERVIEW_STRIDE + WIND_OVERVIEW_STRIDE / 2),
		}
		direction := shared.planet_sim_direction(coord)
		vector, speed := sim_proof_world_vector(world, direction, settings.proof, deep)
		reference_speed := settings.reference_speed
		if settings.proof == .Currents do reference_speed *= 0.1
		strength := wind_display_strength(speed, reference_speed)
		lift := settings.lift
		if deep do lift = max(settings.lift * 0.35, f32(0.25))
		_ = wind_arrow_fill(
			layer,
			arrow,
			world,
			direction,
			vector,
			strength,
			26 * settings.length_scale,
			1.6,
			lift,
		)
	}
	return end
}

wind_visual_geometry_settings :: proc(
	settings: Sim_Proof_Settings,
) -> Wind_Visual_Geometry_Settings {
	return {
		proof = settings.proof,
		density_scale = settings.density_scale,
		length_scale = settings.length_scale,
		lift = settings.lift,
		reference_speed = settings.reference_speed,
	}
}

wind_visual_geometry_settings_equal :: proc(a, b: Wind_Visual_Geometry_Settings) -> bool {
	return a == b
}

wind_visual_required_layer_count :: proc(proof: Sim_Proof_Type) -> int {
	return 6 if proof == .Currents else 3
}

wind_visual_generation_begin :: proc(
	visual: ^Wind_Visual,
	focus: [3]f32,
	settings: Sim_Proof_Settings,
) {
	visual.generation += 1
	visual.build_layer = 0
	visual.build_arrow = 0
	visual.build_focus = focus
	visual.build_settings = settings
	visual.building = true
	wind_layer_degenerate_from(&visual.staging_close, 0)
	wind_layer_degenerate_from(&visual.staging_regional, 0)
	wind_layer_degenerate_from(&visual.staging_overview, 0)
	if settings.proof == .Currents {
		wind_layer_degenerate_from(&visual.staging_deep_close, 0)
		wind_layer_degenerate_from(&visual.staging_deep_regional, 0)
		wind_layer_degenerate_from(&visual.staging_deep_overview, 0)
	}
}

wind_visual_generation_request :: proc(
	visual: ^Wind_Visual,
	focus: [3]f32,
	settings: Sim_Proof_Settings,
) {
	visual.geometry_settings = wind_visual_geometry_settings(settings)
	if visual.building {
		visual.pending_focus = focus
		visual.pending_settings = settings
		visual.pending = true
		return
	}
	wind_visual_generation_begin(visual, focus, settings)
}

wind_visual_generation_advance :: proc(visual: ^Wind_Visual, count: int) {
	if visual == nil || !visual.building || count <= 0 do return
	visual.build_arrow += count
}

wind_visual_generation_step :: proc(
	visual: ^Wind_Visual,
	world: ^shared.World,
	settings: Sim_Proof_Settings,
	arrow_budget: int,
) {
	assert(visual != nil && world != nil, "wind visual generation: nil input")
	_ = settings
	remaining := arrow_budget
	required := wind_visual_required_layer_count(visual.build_settings.proof)
	for visual.building && remaining > 0 {
		layer: ^Wind_Visual_Layer
		capacity, edge: int
		spacing: f32
		overview, deep := false, false
		switch visual.build_layer {
		case 0:
			layer, capacity, edge, spacing =
				&visual.staging_close, WIND_CLOSE_CAPACITY, WIND_CLOSE_EDGE, 24
		case 1:
			layer, capacity, edge, spacing =
				&visual.staging_regional, WIND_REGIONAL_CAPACITY, WIND_REGIONAL_EDGE, 56
		case 2:
			layer, capacity, overview = &visual.staging_overview, WIND_OVERVIEW_CAPACITY, true
		case 3:
			layer, capacity, edge, spacing, deep =
				&visual.staging_deep_close, WIND_CLOSE_CAPACITY, WIND_CLOSE_EDGE, 24, true
		case 4:
			layer, capacity, edge, spacing, deep =
				&visual.staging_deep_regional, WIND_REGIONAL_CAPACITY, WIND_REGIONAL_EDGE, 56, true
		case 5:
			layer, capacity, overview, deep =
				&visual.staging_deep_overview, WIND_OVERVIEW_CAPACITY, true, true
		}
		count := min(remaining, min(WIND_ARROWS_PER_PAGE, capacity - visual.build_arrow))
		if overview {
			visual.build_arrow = wind_layer_fill_overview_range(
				layer,
				world,
				visual.build_settings,
				deep,
				visual.build_arrow,
				count,
			)
		} else {
			visual.build_arrow = wind_layer_fill_cap_range(
				layer,
				world,
				visual.build_focus,
				edge,
				spacing,
				visual.build_settings,
				deep,
				visual.build_arrow,
				count,
			)
		}
		remaining -= count
		if visual.build_arrow < capacity do continue
		_ = rl.update_gpu_mesh_vertices(layer.gpu_mesh, layer.vertices)
		visual.build_layer += 1
		visual.build_arrow = 0
		if visual.build_layer >= required {
			visual.close, visual.staging_close = visual.staging_close, visual.close
			visual.regional, visual.staging_regional = visual.staging_regional, visual.regional
			visual.overview, visual.staging_overview = visual.staging_overview, visual.overview
			if visual.build_settings.proof == .Currents {
				visual.deep_close, visual.staging_deep_close =
					visual.staging_deep_close, visual.deep_close
				visual.deep_regional, visual.staging_deep_regional =
					visual.staging_deep_regional, visual.deep_regional
				visual.deep_overview, visual.staging_deep_overview =
					visual.staging_deep_overview, visual.deep_overview
			}
			visual.published_generation = visual.generation
			visual.building = false
			if visual.pending {
				focus := visual.pending_focus
				pending_settings := visual.pending_settings
				visual.pending = false
				wind_visual_generation_begin(visual, focus, pending_settings)
			}
		}
	}
}

wind_visual_update :: proc(
	visual: ^Wind_Visual,
	world: ^shared.World,
	terrain: ^Terrain,
	focus: [3]f32,
	tick: u64,
	settings: Sim_Proof_Settings,
	settings_revision: u64,
	budget_available := true,
) {
	assert(visual != nil && world != nil && terrain != nil, "wind_visual_update: nil input")
	_ = settings_revision
	if !visual.ready do return
	if settings.proof == .None {
		visual.dirty = true
		return
	}
	focus_cell := shared.planetary_sample_index(wind_vector_normalize(focus))
	dirty :=
		visual.dirty ||
		visual.last_tick != tick ||
		visual.last_heights_revision != terrain.heights_revision ||
		visual.last_water_revision != world.waterfield.revision ||
		visual.last_focus_cell != focus_cell ||
		!wind_visual_geometry_settings_equal(
				visual.geometry_settings,
				wind_visual_geometry_settings(settings),
			)
	if dirty {
		wind_visual_generation_request(visual, focus, settings)
		visual.last_tick = tick
		visual.last_heights_revision = terrain.heights_revision
		visual.last_water_revision = world.waterfield.revision
		visual.last_focus_cell = focus_cell
		visual.dirty = false
	}
	if budget_available {
		wind_visual_generation_step(visual, world, settings, WIND_BUILD_ARROWS_PER_UPDATE)
	}
}

wind_visual_layer_draw :: proc(
	visual: ^Wind_Visual,
	pass: ^rl.Gpu_3D_Pass,
	layer: ^Wind_Visual_Layer,
	opacity: f32,
	settings: Sim_Proof_Settings,
	deep := false,
) {
	if layer == nil || !layer.ready || opacity <= 0 do return
	low := rl.Color(TERRA_PHOSPHOR_DIM)
	high := UI_GLOW
	if deep {
		low = UI_DEBUG_AXIS_Z
		high = UI_AMBER
	}
	material := rl.Gpu_Material {
		color         = low,
		color_high    = high,
		use_scalar    = true,
		style         = .Transparent,
		custom_params = {
			settings.opacity * opacity,
			-settings.pulse_speed if deep else settings.pulse_speed,
			settings.pulse_strength,
			0,
		},
		shader        = visual.shader,
	}
	rl.draw_gpu_mesh(pass, layer.gpu_mesh, rl.Matrix(1), material)
}

wind_visual_draw :: proc(
	visual: ^Wind_Visual,
	pass: ^rl.Gpu_3D_Pass,
	camera_visual: Camera_Visual_Context,
	settings: Sim_Proof_Settings,
) {
	assert(visual != nil && pass != nil, "wind_visual_draw: nil input")
	if settings.proof == .None || !visual.ready do return
	wind_visual_layer_draw(visual, pass, &visual.close, camera_visual.close_weight, settings)
	wind_visual_layer_draw(visual, pass, &visual.regional, camera_visual.regional_weight, settings)
	wind_visual_layer_draw(visual, pass, &visual.overview, camera_visual.overview_weight, settings)
	if settings.proof == .Currents {
		wind_visual_layer_draw(
			visual,
			pass,
			&visual.deep_close,
			camera_visual.close_weight,
			settings,
			true,
		)
		wind_visual_layer_draw(
			visual,
			pass,
			&visual.deep_regional,
			camera_visual.regional_weight,
			settings,
			true,
		)
		wind_visual_layer_draw(
			visual,
			pass,
			&visual.deep_overview,
			camera_visual.overview_weight,
			settings,
			true,
		)
	}
}
