package shared

import ecs "ingot:ecs"

ECOLOGY_MOVE_INTERVAL_TICKS :: u64(8)
ECOLOGY_IDLE_INTERVALS_MIN :: u64(1)
ECOLOGY_IDLE_INTERVALS_MAX :: u64(2)
ECOLOGY_GRAZE_INTERVALS_MIN :: u64(2)
ECOLOGY_GRAZE_INTERVALS_MAX :: u64(4)
ECOLOGY_WANDER_DIRECTIONS := [8][2]i32 {
	{1, 0},
	{1, 1},
	{0, 1},
	{-1, 1},
	{-1, 0},
	{-1, -1},
	{0, -1},
	{1, -1},
}

ECOLOGY_BEHAVIOR_DOMAIN :: u64(0x632be59bd9b4e019)
ECOLOGY_DURATION_DOMAIN :: u64(0x8cb92baa3f3d8dd7)
ECOLOGY_DIRECTION_DOMAIN :: u64(0x9e3779b97f4a7c15)

ecology_decision_hash :: proc(seed: u64, net_id: Net_Id, serial: u32, domain: u64) -> u64 {
	return ecology_hash_mix(seed ~ u64(net_id) * 0x9e3779b97f4a7c15 ~ u64(serial) ~ domain)
}

ecology_behavior_choice :: proc(seed: u64, net_id: Net_Id, serial: u32) -> Creature_Behavior {
	roll := ecology_decision_hash(seed, net_id, serial, ECOLOGY_BEHAVIOR_DOMAIN) % 100
	if roll < 30 do return .Walk
	if roll < 55 do return .Idle
	return .Graze
}

ecology_behavior_duration :: proc(
	seed: u64,
	net_id: Net_Id,
	serial: u32,
	behavior: Creature_Behavior,
) -> u64 {
	if behavior == .Walk do return ECOLOGY_MOVE_INTERVAL_TICKS
	minimum := ECOLOGY_IDLE_INTERVALS_MIN
	maximum := ECOLOGY_IDLE_INTERVALS_MAX
	if behavior == .Graze {
		minimum = ECOLOGY_GRAZE_INTERVALS_MIN
		maximum = ECOLOGY_GRAZE_INTERVALS_MAX
	}
	intervals :=
		minimum +
		ecology_decision_hash(seed, net_id, serial, ECOLOGY_DURATION_DOMAIN) %
			(maximum - minimum + 1)
	return intervals * ECOLOGY_MOVE_INTERVAL_TICKS
}

ecology_wander_heading :: proc(seed: u64, net_id: Net_Id, serial: u32) -> (i32, i32) {
	hash := ecology_decision_hash(seed, net_id, serial, ECOLOGY_DIRECTION_DOMAIN)
	side := hash & 3
	along := i64((hash >> 2) % u64(2 * PLANET_VECTOR_SCALE + 1)) - i64(PLANET_VECTOR_SCALE)
	scale := i64(PLANET_VECTOR_SCALE)
	east, north: i64
	switch side {
	case 0:
		east, north = scale, along
	case 1:
		east, north = -along, scale
	case 2:
		east, north = -scale, -along
	case:
		east, north = along, -scale
	}
	return planet_vector_normalize(east, north)
}

ecology_direction_score :: proc(direction: [2]i32, heading_east, heading_north: i32) -> i64 {
	east := i64(direction.x) * i64(PLANET_VECTOR_SCALE)
	north := i64(direction.y) * i64(PLANET_VECTOR_SCALE)
	if direction.x != 0 && direction.y != 0 {
		east = i64(direction.x) * 707_107
		north = i64(direction.y) * 707_107
	}
	return east * i64(heading_east) + north * i64(heading_north)
}

ecology_movement_step :: proc(world: ^World, tick: u64) {
	assert(world != nil, "ecology movement: nil world")
	scratch := &world.ecology_collision
	ecology_collision_begin(scratch)
	for index in 0 ..< ecs.set_len(&world.movements) {
		entity := world.movements.header.entities[index]
		movement := &world.movements.items[index]
		if movement.speed_mm_step == 0 || tick < movement.next_move_tick do continue
		_, located := ecs.get(&world.transforms, entity)
		net_id, identified := ecs.get(&world.net_ids, entity)
		if !located || !identified do continue
		ecology_collision_add_intent(scratch, entity, net_id^)
	}
	for index in 0 ..< scratch.intent_count {
		_ecology_movement_resolve(world, scratch, scratch.intents[index], tick)
	}
	ecology_collision_begin(scratch)
}

_ecology_movement_resolve :: proc(
	world: ^World,
	scratch: ^Ecology_Collision_Scratch,
	intent: Ecology_Move_Intent,
	tick: u64,
) {
	movement, moving := ecs.get(&world.movements, intent.entity)
	transform, located := ecs.get(&world.transforms, intent.entity)
	assert(moving && located, "ecology movement resolve: incomplete entity")
	coord := planet_canonical({transform.face, transform.grid_x, transform.grid_y})
	movement.prior = coord
	movement.destination = coord
	behavior := ecology_behavior_choice(world.foundation.seed, intent.net_id, movement.decision_serial)
	movement.behavior = behavior
	if behavior == .Walk {
		heading_east, heading_north := ecology_wander_heading(
			world.foundation.seed,
			intent.net_id,
			movement.decision_serial,
		)
		tried: [len(ECOLOGY_WANDER_DIRECTIONS)]bool
		for _ in 0 ..< len(ECOLOGY_WANDER_DIRECTIONS) {
			best := _ecology_movement_best_direction(tried, heading_east, heading_north)
			tried[best] = true
			direction := ECOLOGY_WANDER_DIRECTIONS[best]
			next := planet_neighbour(coord, direction.x, direction.y)
			if !ecology_collision_path_allowed(world, scratch, intent.entity, coord, next, direction) {
				continue
			}
			ecology_collision_reserve(scratch, next)
			movement.prior = coord
			movement.destination = next
			movement.heading_east = heading_east
			movement.heading_north = heading_north
			transform^ = planet_transform_make(next, terrain_height_at_coord(world, next))
			break
		}
		if movement.destination == coord do movement.behavior = .Idle
	}
	movement.next_move_tick = tick + ecology_behavior_duration(
		world.foundation.seed,
		intent.net_id,
		movement.decision_serial,
		movement.behavior,
	)
	movement.decision_serial += 1
}

_ecology_movement_best_direction :: proc(
	tried: [len(ECOLOGY_WANDER_DIRECTIONS)]bool,
	heading_east, heading_north: i32,
) -> int {
	best := -1
	best_score := min(i64)
	for direction, candidate in ECOLOGY_WANDER_DIRECTIONS {
		if tried[candidate] do continue
		score := ecology_direction_score(direction, heading_east, heading_north)
		if score > best_score {
			best = candidate
			best_score = score
		}
	}
	assert(best >= 0, "ecology movement: no untried wander direction")
	return best
}
