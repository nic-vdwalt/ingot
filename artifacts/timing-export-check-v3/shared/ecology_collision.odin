package shared

import ecs "ingot:ecs"

Ecology_Move_Intent :: struct {
	entity: ecs.Entity,
	net_id: Net_Id,
}

Ecology_Collision_Scratch :: struct {
	intents:      []Ecology_Move_Intent,
	reservations: []Planet_Coord,
	intent_count: int,
	reserve_count: int,
}

ecology_collision_init :: proc(value: ^Ecology_Collision_Scratch, allocator := context.allocator) -> bool {
	assert(value != nil, "ecology_collision_init: nil scratch")
	value^ = {}
	value.intents = make([]Ecology_Move_Intent, MAX_ENTITIES, allocator)
	value.reservations = make([]Planet_Coord, MAX_ENTITIES, allocator)
	return len(value.intents) == int(MAX_ENTITIES) && len(value.reservations) == int(MAX_ENTITIES)
}

ecology_collision_deinit :: proc(value: ^Ecology_Collision_Scratch, allocator := context.allocator) {
	assert(value != nil, "ecology_collision_deinit: nil scratch")
	delete(value.reservations, allocator)
	delete(value.intents, allocator)
	value^ = {}
}

ecology_collision_begin :: proc(value: ^Ecology_Collision_Scratch) {
	assert(value != nil, "ecology_collision_begin: nil scratch")
	value.intent_count = 0
	value.reserve_count = 0
}

ecology_collision_add_intent :: proc(
	value: ^Ecology_Collision_Scratch,
	entity: ecs.Entity,
	net_id: Net_Id,
) {
	assert(value != nil, "ecology_collision_add_intent: nil scratch")
	assert(value.intent_count < len(value.intents), "ecology_collision_add_intent: capacity")
	index := value.intent_count
	for index > 0 && value.intents[index - 1].net_id > net_id {
		value.intents[index] = value.intents[index - 1]
		index -= 1
	}
	value.intents[index] = {entity = entity, net_id = net_id}
	value.intent_count += 1
}

ecology_collision_reserved :: proc(value: ^Ecology_Collision_Scratch, coord: Planet_Coord) -> bool {
	assert(value != nil, "ecology_collision_reserved: nil scratch")
	canonical := planet_canonical(coord)
	for index in 0 ..< value.reserve_count {
		if value.reservations[index] == canonical do return true
	}
	return false
}

ecology_collision_reserve :: proc(value: ^Ecology_Collision_Scratch, coord: Planet_Coord) {
	assert(value != nil, "ecology_collision_reserve: nil scratch")
	assert(value.reserve_count < len(value.reservations), "ecology_collision_reserve: capacity")
	value.reservations[value.reserve_count] = planet_canonical(coord)
	value.reserve_count += 1
}

ecology_collision_path_allowed :: proc(
	world: ^World,
	scratch: ^Ecology_Collision_Scratch,
	entity: ecs.Entity,
	origin, destination: Planet_Coord,
	direction: [2]i32,
) -> bool {
	assert(world != nil, "ecology_collision_path_allowed: nil world")
	assert(scratch != nil, "ecology_collision_path_allowed: nil scratch")
	if !planet_placement_allowed(world, destination) do return false
	if _, blocked := collision_static_blocker_at(world, destination); blocked do return false
	if _, occupied := collision_creature_at(world, destination, entity); occupied do return false
	if ecology_collision_reserved(scratch, destination) do return false
	if direction.x != 0 && direction.y != 0 {
		along_x := planet_neighbour(origin, direction.x, 0)
		along_y := planet_neighbour(origin, 0, direction.y)
		if _, blocked := collision_static_blocker_at(world, along_x); blocked do return false
		if _, blocked := collision_static_blocker_at(world, along_y); blocked do return false
		if _, occupied := collision_creature_at(world, along_x, entity); occupied do return false
		if _, occupied := collision_creature_at(world, along_y, entity); occupied do return false
	}
	return true
}
