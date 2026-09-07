package shared

import ecs "ingot:ecs"

COLLISION_FLORA_SEARCH_RADIUS :: i32(2)
COLLISION_NODE_CLEARANCE_CELLS :: i32(2)

Collision_Blocker_Kind :: enum u8 {
	None,
	Building,
	Resource_Node,
	Hydrothermal_Vent,
	Flora,
	Creature,
	Reservation,
}

Collision_Blocker :: struct {
	kind:   Collision_Blocker_Kind,
	entity: ecs.Entity,
}

collision_static_blocker_at :: proc(world: ^World, coord: Planet_Coord) -> (Collision_Blocker, bool) {
	assert(world != nil, "collision_static_blocker_at: nil world")
	assert(planet_coord_valid(coord), "collision_static_blocker_at: invalid coordinate")
	canonical := planet_canonical(coord)
	if entity, found := building_at_cell(world, canonical.u, canonical.v, canonical.face); found {
		return {kind = .Building, entity = entity}, true
	}
	if entity, found := node_at_cell(world, canonical.u, canonical.v, canonical.face); found {
		return {kind = .Resource_Node, entity = entity}, true
	}
	if entity, found := hydrothermal_vent_at_coord(world, canonical); found {
		return {kind = .Hydrothermal_Vent, entity = entity}, true
	}
	if collision_flora_at(world, canonical) do return {kind = .Flora}, true
	return {}, false
}

collision_creature_at :: proc(
	world: ^World,
	coord: Planet_Coord,
	exclude := ecs.ENTITY_NIL,
) -> (ecs.Entity, bool) {
	assert(world != nil, "collision_creature_at: nil world")
	assert(planet_coord_valid(coord), "collision_creature_at: invalid coordinate")
	canonical := planet_canonical(coord)
	for index in 0 ..< ecs.set_len(&world.creatures) {
		entity := world.creatures.header.entities[index]
		if entity == exclude do continue
		transform, located := ecs.get(&world.transforms, entity)
		if !located do continue
		other := planet_canonical({transform.face, transform.grid_x, transform.grid_y})
		if other == canonical do return entity, true
	}
	return ecs.ENTITY_NIL, false
}

collision_spawn_allowed :: proc(world: ^World, coord: Planet_Coord) -> bool {
	assert(world != nil, "collision_spawn_allowed: nil world")
	if !planet_placement_allowed(world, coord) do return false
	if _, blocked := collision_static_blocker_at(world, coord); blocked do return false
	_, occupied := collision_creature_at(world, coord)
	return !occupied
}

collision_flora_at :: proc(world: ^World, coord: Planet_Coord) -> bool {
	assert(world != nil, "collision_flora_at: nil world")
	assert(planet_coord_valid(coord), "collision_flora_at: invalid coordinate")
	canonical := planet_canonical(coord)
	large_x := canonical.u / 2
	large_y := canonical.v / 2
	for offset_y in -COLLISION_FLORA_SEARCH_RADIUS ..= COLLISION_FLORA_SEARCH_RADIUS {
		for offset_x in -COLLISION_FLORA_SEARCH_RADIUS ..= COLLISION_FLORA_SEARCH_RADIUS {
			cell_x := large_x + offset_x
			cell_y := large_y + offset_y
			if cell_x < 0 || cell_y < 0 do continue
			if cell_x >= PLANET_FACE_CELLS / 2 || cell_y >= PLANET_FACE_CELLS / 2 do continue
			seed := world.foundation.seed ~ (u64(canonical.face) + 1) * 0x9E3779B97F4A7C15
			hash := flora_logical_hash(seed, cell_x, cell_y)
			jitter_u := 77 + i32(flora_logical_channel(hash, 0)) * 358 / 511
			jitter_v := 77 + i32(flora_logical_channel(hash, 1)) * 358 / 511
			candidate_u := cell_x * 2 + (jitter_u * 2 + 256) / 512
			candidate_v := cell_y * 2 + (jitter_v * 2 + 256) / 512
			candidate := planet_canonical({canonical.face, candidate_u, candidate_v})
			if candidate != canonical do continue
			if !planet_placement_allowed(world, candidate) do continue
			if collision_flora_suppressed(world, candidate) do continue
			sample := collision_flora_sample(world, candidate)
			if flora_logical_solid(seed, hash, sample).kind != .None do return true
		}
	}
	return false
}

collision_flora_sample :: proc(world: ^World, coord: Planet_Coord) -> Flora_Logical_Sample {
	assert(world != nil, "collision_flora_sample: nil world")
	assert(planet_coord_valid(coord), "collision_flora_sample: invalid coordinate")
	index := planet_index(coord)
	return {
		height_fixed = terrain_height_fixed_at_coord(world, coord),
		sea_fixed    = i32(world.foundation.sea_level),
		snow_fixed   = i32(world.foundation.snow_level),
		moisture     = world.foundation.moisture[index],
		slope        = world.foundation.slope[index],
		biome        = world.foundation.primary_biome[index],
	}
}

collision_flora_suppressed :: proc(world: ^World, coord: Planet_Coord) -> bool {
	assert(world != nil, "collision_flora_suppressed: nil world")
	if _, found := building_at_cell(world, coord.u, coord.v, coord.face); found do return true
	for offset_v in -COLLISION_NODE_CLEARANCE_CELLS ..= COLLISION_NODE_CLEARANCE_CELLS {
		for offset_u in -COLLISION_NODE_CLEARANCE_CELLS ..= COLLISION_NODE_CLEARANCE_CELLS {
			if offset_u * offset_u + offset_v * offset_v > 4 do continue
			nearby := planet_neighbour(coord, offset_u, offset_v)
			if _, found := node_at_cell(world, nearby.u, nearby.v, nearby.face); found do return true
		}
	}
	return false
}
