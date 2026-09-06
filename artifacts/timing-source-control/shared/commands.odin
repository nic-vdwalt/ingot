package shared

import ecs "ingot:ecs"
import procgen "ingot:procgen"

// Commands are the only way player intent enters the simulation. Both client
// (locally, for the embedded prototype) and server (later, from the network)
// validate and apply them through the same code path, so cheating reduces to
// sending commands the validator rejects.

Command_Kind :: enum u8 {
	Place_Building,
	Upgrade_Building,
	Set_Efficiency,
	Terraform,
}

Command :: struct {
	kind:               Command_Kind,
	player:             u32,
	target:             Net_Id,
	building:           Building_Kind,
	face:               procgen.Terrain_Face_V4,
	grid_x:             i32,
	grid_y:             i32,
	efficiency_percent: u8,
	direction:          i8,
	terraform_radius:   i8,
}

command_coord :: proc(command: Command) -> Planet_Coord {
	return {command.face, command.grid_x, command.grid_y}
}

// apply_command validates and executes one command against the world.
// Returns false when the command is invalid (unknown player, insufficient
// resources, bad target); invalid commands leave the world untouched.
apply_command :: proc(world: ^World, command: Command) -> bool {
	assert(world != nil, "apply_command: nil world")
	assert(world.pool.capacity > 0, "apply_command: world not initialised")
	if command.player >= MAX_PLAYERS do return false
	player_entity := world.players[command.player]
	if !ecs.is_alive(&world.pool, player_entity) do return false
	switch command.kind {
	case .Place_Building:
		return _apply_place(world, command, player_entity)
	case .Upgrade_Building:
		return _apply_upgrade(world, command, player_entity)
	case .Set_Efficiency:
		return _apply_efficiency(world, command)
	case .Terraform:
		return _apply_terraform(world, command, player_entity)
	}
	return false
}

_apply_place :: proc(world: ^World, command: Command, player_entity: ecs.Entity) -> bool {
	assert(world != nil, "_apply_place: nil world")
	assert(ecs.is_alive(&world.pool, player_entity), "_apply_place: dead player entity")
	coord := command_coord(command)
	if !_planet_footprint_allowed(world, command.building, coord) do return false
	if !_charge(world, player_entity, building_cost(command.building, 1)) do return false
	entity, ok := ecs.create_entity(&world.pool)
	if !ok do return false
	height := terrain_height_at_coord(world, coord)
	added := ecs.add(
		&world.transforms,
		entity,
		planet_transform_make(coord, height),
	)
	building := Building {
		kind               = command.building,
		level              = 0,
		efficiency_percent = DEFAULT_EFFICIENCY,
	}
	added = added && ecs.add(&world.buildings, entity, building)
	construction := Construction {
		ticks_remaining = building_build_ticks(command.building, 1),
		target_level    = 1,
	}
	added = added && ecs.add(&world.constructions, entity, construction)
	added = added && ecs.add(&world.owners, entity, Owner{player = command.player})
	net_id := _allocate_net_id(world)
	added = added && ecs.add(&world.net_ids, entity, net_id)
	if !added {
		_ = ecs.destroy_entity(&world.pool, entity)
		_refund(world, player_entity, building_cost(command.building, 1))
		return false
	}
	world_net_index_add(world, entity, net_id)
	_planet_footprint_flatten(world, command.building, coord)
	_link_covered_node(world, entity, command.building, coord)
	if transform, has_transform := ecs.get(&world.transforms, entity); has_transform {
		transform.position = planet_position(planet_direction(coord), terrain_height_at_coord(world, coord))
	}
	return true
}

// _footprint_flatten levels the heightfield under a footprint to the anchor
// cell's effective height. The target is quantised once to quarter-unit
// fixed point, and each cell's delta is the integer difference from its base
// height, so identical command streams write identical deltas everywhere.
_planet_footprint_flatten :: proc(world: ^World, kind: Building_Kind, anchor: Planet_Coord) {
	assert(world != nil, "_planet_footprint_flatten: nil world")
	assert(planet_coord_valid(anchor), "_planet_footprint_flatten: invalid anchor")
	target_fixed := i16(terrain_height_fixed_at_coord(world, anchor))
	width, height := building_footprint(kind)
	for offset_v in 0 ..< height {
		for offset_u in 0 ..< width {
			target := planet_neighbour(anchor, offset_u, offset_v)
			index := planet_index(target)
			base_fixed := terrain_base_height_fixed_at_coord(world, target)
			delta := clamp(target_fixed - base_fixed, -TERRAFORM_MAX_DELTA, TERRAFORM_MAX_DELTA)
			world.heightfield.deltas[index] = delta
			if delta != 0 do world.heightfield.modified = true
			planet_heightfield_mirror(&world.heightfield, target)
		}
	}
	waterfield_terrain_changed_rect(world, anchor, max(width, height))
}

_planet_footprint_allowed :: proc(
	world: ^World,
	kind: Building_Kind,
	anchor: Planet_Coord,
) -> bool {
	assert(world != nil, "_planet_footprint_allowed: nil world")
	if !planet_coord_valid(anchor) do return false
	width, height := building_footprint(kind)
	harvest_kind, harvests := building_harvests(kind)
	for offset_v in 0 ..< height {
		for offset_u in 0 ..< width {
			cell := planet_neighbour(anchor, offset_u, offset_v)
			if !planet_placement_allowed(world, cell) do return false
			if _tile_occupied(world, cell.u, cell.v, cell.face) do return false
			if node_entity, node_found := node_at_cell(world, cell.u, cell.v, cell.face); node_found {
				node, has_node := ecs.get(&world.nodes, node_entity)
				if !has_node do return false
				if !harvests || node.kind != harvest_kind do return false
			}
		}
	}
	return true
}

// _link_covered_node records the first matching node's stable identity on the
// building so production can resolve live richness without conflating the two
// entity kinds. Non-matching nodes are impossible after footprint validation.
_link_covered_node :: proc(
	world: ^World,
	entity: ecs.Entity,
	kind: Building_Kind,
	anchor: Planet_Coord,
) {
	assert(world != nil, "_link_covered_node: nil world")
	harvest_kind, harvests := building_harvests(kind)
	if !harvests do return
	width, height := building_footprint(kind)
	for offset_v in 0 ..< height {
		for offset_u in 0 ..< width {
			cell := planet_neighbour(anchor, offset_u, offset_v)
			node_entity, node_found := node_at_cell(
				world,
				cell.u,
				cell.v,
				cell.face,
			)
			if !node_found do continue
			node, has_node := ecs.get(&world.nodes, node_entity)
			if !has_node || node.kind != harvest_kind do continue
			net_id, has_id := world_net_id_for_entity(world, node_entity)
			if !has_id do continue
			_ = ecs.add(&world.harvest_links, entity, Harvest_Link{node = net_id})
			return
		}
	}
}

_apply_upgrade :: proc(world: ^World, command: Command, player_entity: ecs.Entity) -> bool {
	assert(world != nil, "_apply_upgrade: nil world")
	assert(ecs.is_alive(&world.pool, player_entity), "_apply_upgrade: dead player entity")
	entity, found := world_entity_by_net_id(world, command.target)
	if !found do return false
	building, has_building := ecs.get(&world.buildings, entity)
	if !has_building do return false
	if !_owned_by(world, entity, command.player) do return false
	if ecs.has(&world.constructions, entity) do return false
	if building.level >= MAX_BUILDING_LEVEL do return false
	target_level := building.level + 1
	if !_charge(world, player_entity, building_cost(building.kind, target_level)) do return false
	construction := Construction {
		ticks_remaining = building_build_ticks(building.kind, target_level),
		target_level    = target_level,
	}
	if !ecs.add(&world.constructions, entity, construction) {
		_refund(world, player_entity, building_cost(building.kind, target_level))
		return false
	}
	return true
}

_apply_efficiency :: proc(world: ^World, command: Command) -> bool {
	assert(world != nil, "_apply_efficiency: nil world")
	assert(command.player < MAX_PLAYERS, "_apply_efficiency: player id out of range")
	entity, found := world_entity_by_net_id(world, command.target)
	if !found do return false
	building, has_building := ecs.get(&world.buildings, entity)
	if !has_building do return false
	if !_owned_by(world, entity, command.player) do return false
	// Buildings under construction cannot be tuned.
	if ecs.has(&world.constructions, entity) do return false
	clamped := clamp(command.efficiency_percent, MIN_EFFICIENCY, MAX_EFFICIENCY)
	building.efficiency_percent = clamped
	return true
}

// _apply_terraform raises or drops a linear-falloff mound, or levels the
// brush extent to the center height. Validation keeps the brush in bounds,
// within the selectable size range, and away from buildings. Cost scales
// with brush area and is charged only after validation passes.
_apply_terraform :: proc(world: ^World, command: Command, player_entity: ecs.Entity) -> bool {
	assert(world != nil, "_apply_terraform: nil world")
	assert(ecs.is_alive(&world.pool, player_entity), "_apply_terraform: dead player entity")
	if command.direction < -1 || command.direction > 1 do return false
	radius := i32(command.terraform_radius)
	if !terraform_radius_valid(radius) do return false
	coord := command_coord(command)
	if !planet_coord_valid(coord) do return false
	center_index := planet_index(coord)
	center := world.heightfield.deltas[center_index]
	if command.direction > 0 && center >= TERRAFORM_MAX_DELTA do return false
	if command.direction < 0 && center <= -TERRAFORM_MAX_DELTA do return false
	for offset_v in -radius ..= radius {
		for offset_u in -radius ..= radius {
			target := planet_neighbour(coord, offset_u, offset_v)
			if _tile_occupied(world, target.u, target.v, target.face) do return false
		}
	}
	cost: [Resource_Kind]u64
	cost[.Ore] = terraform_cost_ore(radius)
	if !_charge(world, player_entity, cost) do return false
	if command.direction == 0 {
		target_fixed := i16(terrain_height_fixed_at_coord(world, coord))
		for offset_v in -radius ..= radius {
			for offset_u in -radius ..= radius {
				target := planet_neighbour(coord, offset_u, offset_v)
				index := planet_index(target)
				base := terrain_base_height_fixed_at_coord(world, target)
				delta := clamp(target_fixed - base, -TERRAFORM_MAX_DELTA, TERRAFORM_MAX_DELTA)
				world.heightfield.deltas[index] = delta
				if delta != 0 do world.heightfield.modified = true
				planet_heightfield_mirror(&world.heightfield, target)
			}
		}
	} else {
		planet_heightfield_apply(&world.heightfield, coord, i16(command.direction), radius)
	}
	waterfield_terrain_changed_rect(world, coord, radius)
	return true
}

_owned_by :: proc(world: ^World, entity: ecs.Entity, player: u32) -> bool {
	assert(world != nil, "_owned_by: nil world")
	assert(player < MAX_PLAYERS, "_owned_by: player id out of range")
	owner, has_owner := ecs.get(&world.owners, entity)
	if !has_owner do return false
	return owner.player == player
}

// building_at_cell finds the building whose footprint covers a cell on one
// face. Linear over the dense building array; bounded by MAX_BUILDINGS.
// Shared with the client so picking and sim validation agree on coverage.
building_at_cell :: proc(
	world: ^World,
	grid_x: i32,
	grid_y: i32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> (
	ecs.Entity,
	bool,
) {
	assert(world != nil, "building_at_cell: nil world")
	assert(ecs.set_len(&world.buildings) <= MAX_BUILDINGS, "building_at_cell: set over capacity")
	for index in 0 ..< ecs.set_len(&world.buildings) {
		entity := world.buildings.header.entities[index]
		building, has_building := ecs.get(&world.buildings, entity)
		if !has_building do continue
		transform, has_transform := ecs.get(&world.transforms, entity)
		if !has_transform do continue
		if transform.face != face do continue
		width, height := building_footprint(building.kind)
		if grid_x >= transform.grid_x &&
		   grid_x < transform.grid_x + width &&
		   grid_y >= transform.grid_y &&
		   grid_y < transform.grid_y + height {
			return entity, true
		}
	}
	return ecs.ENTITY_NIL, false
}

// _tile_occupied reports whether any building footprint covers the cell.
_tile_occupied :: proc(
	world: ^World,
	grid_x: i32,
	grid_y: i32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> bool {
	assert(world != nil, "_tile_occupied: nil world")
	_, occupied := building_at_cell(world, grid_x, grid_y, face)
	return occupied
}

// node_at_cell finds the bare resource node on a cell; buildings that copied
// a Resource_Node component are skipped (they are not map tiles).
node_at_cell :: proc(
	world: ^World,
	grid_x: i32,
	grid_y: i32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> (
	ecs.Entity,
	bool,
) {
	assert(world != nil, "node_at_cell: nil world")
	for index in 0 ..< ecs.set_len(&world.nodes) {
		entity := world.nodes.header.entities[index]
		if ecs.has(&world.buildings, entity) do continue
		transform, has_transform := ecs.get(&world.transforms, entity)
		if !has_transform do continue
		if transform.face != face do continue
		if transform.grid_x == grid_x && transform.grid_y == grid_y do return entity, true
	}
	return ecs.ENTITY_NIL, false
}

// placement_footprint_allowed validates every cell of kind's footprint from
// the min-corner anchor: in-world, above water, slope within limit,
// unoccupied, and node cells only under a matching harvester.
placement_footprint_allowed :: proc(
	world: ^World,
	kind: Building_Kind,
	anchor_x: i32,
	anchor_y: i32,
	face := procgen.Terrain_Face_V4.Pos_X,
) -> bool {
	assert(world != nil, "placement_footprint_allowed: nil world")
	width, height := building_footprint(kind)
	harvest_kind, harvests := building_harvests(kind)
	for offset_y in 0 ..< height {
		for offset_x in 0 ..< width {
			cell_x := anchor_x + offset_x
			cell_y := anchor_y + offset_y
			if !placement_allowed(world, cell_x, cell_y, face) do return false
			if _tile_occupied(world, cell_x, cell_y, face) do return false
			if node_entity, node_found := node_at_cell(world, cell_x, cell_y, face); node_found {
				node, has_node := ecs.get(&world.nodes, node_entity)
				if !has_node do return false
				if !harvests || node.kind != harvest_kind do return false
			}
		}
	}
	return true
}

_charge :: proc(world: ^World, player_entity: ecs.Entity, cost: [Resource_Kind]u64) -> bool {
	assert(world != nil, "_charge: nil world")
	stockpile, has_stockpile := ecs.get(&world.stockpiles, player_entity)
	if !has_stockpile do return false
	for kind in Resource_Kind {
		if stockpile.amounts[kind] < cost[kind] do return false
	}
	for kind in Resource_Kind {
		stockpile.amounts[kind] -= cost[kind]
	}
	return true
}

_refund :: proc(world: ^World, player_entity: ecs.Entity, cost: [Resource_Kind]u64) {
	assert(world != nil, "_refund: nil world")
	stockpile, has_stockpile := ecs.get(&world.stockpiles, player_entity)
	assert(has_stockpile, "_refund: player entity lost its stockpile mid-command")
	if !has_stockpile do return
	for kind in Resource_Kind {
		assert(stockpile.amounts[kind] <= max(u64) - cost[kind], "_refund: overflow")
		stockpile.amounts[kind] += cost[kind]
	}
}
