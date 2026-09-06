package main

import shared "../shared"
import "core:math"
import "core:math/linalg"
import ecs "ingot:ecs"
import rl "ingot:gfx"

NODE_VARIANT_COUNT :: 3
NODE_COMPONENT_MAX :: 3
NODE_ARC_COUNT :: 3
NODE_ARC_FLICKER_HZ :: f32(12)

NODE_ROCK_SLATE :: rl.Color{88, 82, 74, 255}
NODE_ORE_NUGGET :: rl.Color{224, 158, 72, 255}
NODE_BASALT :: rl.Color{70, 74, 82, 255}
NODE_VENT_THROAT :: rl.Color{30, 34, 40, 255}
NODE_VENT_RIM :: rl.Color{86, 210, 202, 255}
NODE_ELECTRIC :: rl.Color{140, 240, 255, 255}

Node_Component :: struct {
	mesh:  Structure_Mesh_Id,
	color: rl.Color,
}

Node_Variant :: struct {
	components:      [NODE_COMPONENT_MAX]Node_Component,
	component_count: int,
	mouth_height:    f32,
}

NODE_VARIANTS := [shared.Resource_Kind][NODE_VARIANT_COUNT]Node_Variant {
	.Ore = {
		0 = {components = {0 = {mesh = .Ore_A_Rock, color = NODE_ROCK_SLATE}, 1 = {mesh = .Ore_A_Ore, color = NODE_ORE_NUGGET}}, component_count = 2},
		1 = {components = {0 = {mesh = .Ore_B_Rock, color = NODE_ROCK_SLATE}, 1 = {mesh = .Ore_B_Ore, color = NODE_ORE_NUGGET}}, component_count = 2},
		2 = {components = {0 = {mesh = .Ore_C_Rock, color = NODE_ROCK_SLATE}, 1 = {mesh = .Ore_C_Ore, color = NODE_ORE_NUGGET}}, component_count = 2},
	},
	.Energy = {
		0 = {components = {0 = {mesh = .Energy_A_Basalt, color = NODE_BASALT}, 1 = {mesh = .Energy_A_Throat, color = NODE_VENT_THROAT}, 2 = {mesh = .Energy_A_Rim, color = NODE_VENT_RIM}}, component_count = 3, mouth_height = 1.02},
		1 = {components = {0 = {mesh = .Energy_B_Basalt, color = NODE_BASALT}, 1 = {mesh = .Energy_B_Throat, color = NODE_VENT_THROAT}, 2 = {mesh = .Energy_B_Rim, color = NODE_VENT_RIM}}, component_count = 3, mouth_height = 1.02},
		2 = {components = {0 = {mesh = .Energy_C_Basalt, color = NODE_BASALT}, 1 = {mesh = .Energy_C_Throat, color = NODE_VENT_THROAT}, 2 = {mesh = .Energy_C_Rim, color = NODE_VENT_RIM}}, component_count = 3, mouth_height = 1.02},
	},
}

_node_hash01 :: proc(grid_x, grid_y: i32, salt: u32) -> f32 {
	hash := (u64(u32(grid_x)) * 0x9E3779B97F4A7C15) ~ (u64(u32(grid_y)) * 0xBF58476D1CE4E5B9)
	hash ~= u64(salt) * 0x94D049BB133111EB
	hash = (hash ~ (hash >> 30)) * 0x94D049BB133111EB
	hash ~= hash >> 27
	return f32(hash & 0xFFFF) / 65535
}

_node_variant_index :: proc(grid_x, grid_y: i32) -> int {
	return min(int(_node_hash01(grid_x, grid_y, 1) * NODE_VARIANT_COUNT), NODE_VARIANT_COUNT - 1)
}

_node_cluster_scale :: proc(richness_percent: u32) -> f32 {
	return 0.85 + 0.3 * f32(richness_percent) / 400
}

// Node_Seat caches one node's probed seat. A node's seat only changes when
// its transform moves or the collision geometry under it is replaced, so the
// key is the transform position plus terrain_seat_revision; everything else
// about the probe is deterministic.
Node_Seat :: struct {
	source:   [3]f32,
	revision: u64,
	ready:    bool,
	seat:     f32,
}

Node_Seat_Cache :: struct {
	seats:  map[ecs.Entity]Node_Seat,
	hits:   u64,
	misses: u64,
}

node_seat_cache_deinit :: proc(cache: ^Node_Seat_Cache) {
	assert(cache != nil, "node_seat_cache_deinit: nil cache")
	delete(cache.seats)
	cache^ = {}
}

// Nodes are seated onto the rendered isosurface with the same radial probe
// flora uses (terrain_surface_height_at_direction): the analytic sim height
// baked into the transform can sit below the marching-cubes surface, burying
// the node. Probing along the node's own radial reseats it on the visible
// terrain; pending/far patches fall back to the cached analytic height. The
// probe is a Box3D ray cast, so the result is cached per node (see
// Node_Seat) and re-probed only when the key changes.
_node_seated_position :: proc(
	value: ^Client_State,
	entity: ecs.Entity,
	transform: ^shared.Transform,
) -> [3]f32 {
	direction := linalg.normalize(transform.position)
	return shared.planet_position(direction, _node_seat_height(value, entity, transform, direction))
}

_node_seat_height :: proc(
	value: ^Client_State,
	entity: ecs.Entity,
	transform: ^shared.Transform,
	direction: [3]f32,
) -> f32 {
	revision := terrain_seat_revision(&value.terrain, shared.planet_coord_from_direction(direction))
	cache := &value.node_seats
	if entity != ecs.ENTITY_NIL {
		if seat, found := cache.seats[entity]; found {
			if seat.source == transform.position && seat.revision == revision && seat.ready == value.terrain.ready {
				cache.hits += 1
				return seat.seat
			}
		}
	}
	cache.misses += 1
	seat := terrain_surface_height_at_direction(&value.terrain, direction)
	if entity != ecs.ENTITY_NIL {
		cache.seats[entity] = {
			source   = transform.position,
			revision = revision,
			ready    = value.terrain.ready,
			seat     = seat,
		}
	}
	return seat
}

_node_transform :: proc(transform: ^shared.Transform, position: [3]f32, yaw, scale: f32) -> rl.Matrix {
	assert(transform != nil, "_node_transform: nil transform")
	anchor := position - transform.up * (SOCKET_SINK * 0.18)
	return rl.MatrixTranslate(anchor.x, anchor.y, anchor.z) * surface_frame(transform) * linalg.matrix4_rotate_f32(yaw, {0, 0, 1}) * rl.MatrixScale(scale, scale, scale)
}

node_world_bounds :: proc(value: ^Client_State, entity: ecs.Entity) -> (Bounds_3D, bool) {
	node, has_node := ecs.get(&value.world.nodes, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_node || !has_transform do return {}, false
	position := _node_seated_position(value, entity, transform)
	variant := &NODE_VARIANTS[node.kind][_node_variant_index(transform.grid_x, transform.grid_y)]
	world_transform := _node_transform(transform, position, _node_hash01(transform.grid_x, transform.grid_y, 0) * 2 * math.PI, _node_cluster_scale(node.richness_percent))
	result := bounds_transform(_structure_bounds(value, variant.components[0].mesh), world_transform)
	for index in 1 ..< variant.component_count {
		result = bounds_union(result, bounds_transform(_structure_bounds(value, variant.components[index].mesh), world_transform))
	}
	return result, true
}

// node_oriented_bounds returns the surface-frame oriented box of a node
// cluster: world center, local (unrotated) size, and the frame rotation,
// for outline draws that should hug the rotated cluster.
node_oriented_bounds :: proc(
	value: ^Client_State,
	entity: ecs.Entity,
) -> (
	center: [3]f32,
	size: [3]f32,
	frame: rl.Matrix,
	ok: bool,
) {
	node, has_node := ecs.get(&value.world.nodes, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_node || !has_transform do return
	variant := &NODE_VARIANTS[node.kind][_node_variant_index(transform.grid_x, transform.grid_y)]
	yaw := _node_hash01(transform.grid_x, transform.grid_y, 0) * 2 * math.PI
	scale := _node_cluster_scale(node.richness_percent)
	local := linalg.matrix4_rotate_f32(yaw, {0, 0, 1}) * rl.MatrixScale(scale, scale, scale)
	result := bounds_transform(_structure_bounds(value, variant.components[0].mesh), local)
	for index in 1 ..< variant.component_count {
		result = bounds_union(result, bounds_transform(_structure_bounds(value, variant.components[index].mesh), local))
	}
	frame = surface_frame(transform)
	anchor := _node_seated_position(value, entity, transform) - transform.up * (SOCKET_SINK * 0.18)
	local_center := bounds_center(result)
	rotated := frame * [4]f32{local_center.x, local_center.y, local_center.z, 0}
	center = anchor + rotated.xyz
	size = bounds_size(result)
	ok = true
	return
}

node_mesh_outline_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	scale: f32,
	color: rl.Color,
) -> bool {
	node, has_node := ecs.get(&value.world.nodes, entity)
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	if !has_node || !has_transform do return false
	position := _node_seated_position(value, entity, transform)
	variant := &NODE_VARIANTS[node.kind][_node_variant_index(transform.grid_x, transform.grid_y)]
	matrix_value := _node_transform(
		transform,
		position,
		_node_hash01(transform.grid_x, transform.grid_y, 0) * 2 * math.PI,
		_node_cluster_scale(node.richness_percent),
	) * rl.MatrixScale(scale, scale, scale)
	for component_index in 0 ..< variant.component_count {
		component := variant.components[component_index]
		rl.draw_gpu_mesh(
			pass,
			structure_mesh(value, component.mesh),
			matrix_value,
			{color = color, style = .Silhouette_Outline},
		)
	}
	return true
}

nodes_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass, time: f32) {
	nodes := &value.world.nodes
	// One pass over the node set: variant classification, occupancy, and the
	// world transform are computed once per node instead of once per
	// (kind, variant) rescan, so building_at_cell runs once per node and
	// empty groups submit no draws.
	Node_Draw :: struct {
		position:  [3]f32,
		scale:     f32,
		grid:      [2]i32,
		transform: rl.Matrix,
		up:        [3]f32,
		east:      [3]f32,
		north:     [3]f32,
		kind:      shared.Resource_Kind,
		variant:   u8,
	}
	entries: [MAX_DRAW_INSTANCES]Node_Draw = ---
	entry_count := 0
	// Nodes exist on every cube face (thousands globe-wide) but the draw cap
	// is MAX_BUILDINGS, so collecting in raw ECS/spawn order would fill the
	// buffer with one face's corner and never reach the nodes under the
	// camera. Cull to the same resident window flora uses so only nodes on
	// the visible ground are gathered, keeping the count well under the cap.
	focus_center := flora_world_tile(value.camera.target)
	for index in 0 ..< ecs.set_len(nodes) {
		entity := nodes.header.entities[index]
		node := &nodes.items[index]
		if ecs.has(&value.world.buildings, entity) do continue
		transform, ok := ecs.get(&value.world.transforms, entity)
		if !ok do continue
		if !flora_node_window_contains(focus_center, transform.position) do continue
		if _, covered := shared.building_at_cell(&value.world, transform.grid_x, transform.grid_y, transform.face); covered do continue
		if entry_count >= MAX_DRAW_INSTANCES do break
		scale := _node_cluster_scale(node.richness_percent)
		position := _node_seated_position(value, entity, transform)
		entries[entry_count] = {
			position  = position,
			scale     = scale,
			grid      = {transform.grid_x, transform.grid_y},
			transform = _node_transform(transform, position, _node_hash01(transform.grid_x, transform.grid_y, 0) * 2 * math.PI, scale),
			up        = transform.up,
			east      = transform.east,
			north     = transform.north,
			kind      = node.kind,
			variant   = u8(_node_variant_index(transform.grid_x, transform.grid_y)),
		}
		entry_count += 1
	}
	for kind in shared.Resource_Kind {
		for variant_index in 0 ..< NODE_VARIANT_COUNT {
			variant := &NODE_VARIANTS[kind][variant_index]
			positions: [MAX_DRAW_INSTANCES][3]f32 = ---
			scales: [MAX_DRAW_INSTANCES]f32 = ---
			grids: [MAX_DRAW_INSTANCES][2]i32 = ---
			ups: [MAX_DRAW_INSTANCES][3]f32 = ---
			easts: [MAX_DRAW_INSTANCES][3]f32 = ---
			norths: [MAX_DRAW_INSTANCES][3]f32 = ---
			count := 0
			for entry_index in 0 ..< entry_count {
				entry := &entries[entry_index]
				if entry.kind != kind || int(entry.variant) != variant_index do continue
				positions[count] = entry.position
				scales[count] = entry.scale
				grids[count] = entry.grid
				ups[count] = entry.up
				easts[count] = entry.east
				norths[count] = entry.north
				value.draw_transforms[count] = entry.transform
				count += 1
			}
			if count == 0 do continue
			for component_index in 0 ..< variant.component_count {
				component := variant.components[component_index]
				rl.draw_gpu_mesh_instanced(&pass^, structure_mesh(value, component.mesh), value.draw_transforms[:count], {color = component.color, style = .Opaque, shader = value.atmosphere.object_shader})
			}
			if kind == .Energy do _energy_arcs_draw(value, pass, positions[:count], scales[:count], grids[:count], ups[:count], easts[:count], norths[:count], variant.mouth_height, time)
		}
	}
}

_energy_arcs_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass, positions: [][3]f32, scales: []f32, grids: [][2]i32, ups, easts, norths: [][3]f32, mouth_height, time: f32) {
	if len(positions) == 0 do return
	arc_count := 0
	for index in 0 ..< len(positions) {
		mouth := positions[index] + ups[index] * (mouth_height * scales[index])
		frame := _frame_matrix(easts[index], norths[index], ups[index])
		for arc in 0 ..< NODE_ARC_COUNT {
			if arc_count >= MAX_DRAW_INSTANCES do break
			phase := u32(math.floor(time * NODE_ARC_FLICKER_HZ)) + u32(arc) * 977
			angle := _node_hash01(grids[index].x, grids[index].y, phase) * 2 * math.PI
			tilt := 0.5 + 0.6 * _node_hash01(grids[index].x, grids[index].y, phase + 1)
			length := (0.5 + 0.5 * _node_hash01(grids[index].x, grids[index].y, phase + 2)) * scales[index]
			local := [3]f32{math.sin(tilt) * math.sin(angle), -math.sin(tilt) * math.cos(angle), math.cos(tilt)}
			direction := easts[index] * local.x + norths[index] * local.y + ups[index] * local.z
			rotation := frame * linalg.matrix4_rotate_f32(angle, {0, 0, 1}) * linalg.matrix4_rotate_f32(tilt, {1, 0, 0})
			arm := mouth + direction * (length / 2)
			value.draw_transforms[arc_count] = rl.MatrixTranslate(arm.x, arm.y, arm.z) * rotation * rl.MatrixScale(0.05 * scales[index], 0.05 * scales[index], length)
			arc_count += 1
		}
	}
	color := NODE_ELECTRIC
	color.a = u8(170 + 60 * math.sin(time * 9))
	rl.draw_gpu_mesh_instanced(&pass^, value.cube, value.draw_transforms[:arc_count], {color = color})
	pulse := 1 + 0.15 * math.sin(time * 3 * 2 * math.PI)
	for index in 0 ..< len(positions) {
		size := 0.3 * scales[index] * pulse
		core := positions[index] + ups[index] * (mouth_height * scales[index])
		value.draw_transforms[index] = rl.MatrixTranslate(core.x, core.y, core.z) * rl.MatrixScale(size, size, size)
	}
	core_color := NODE_ELECTRIC
	core_color.a = 200
	rl.draw_gpu_mesh_instanced(&pass^, value.sphere, value.draw_transforms[:len(positions)], {color = core_color})
}
