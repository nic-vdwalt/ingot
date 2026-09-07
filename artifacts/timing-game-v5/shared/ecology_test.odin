package shared

import "core:testing"
import ecs "ingot:ecs"

@(test)
genome_identity_is_stable_and_trait_sensitive :: proc(t: ^testing.T) {
	genome := Genome {
		metabolism            = 100,
		growth                = 80,
		mobility              = 20,
		thermal_preference_mk = 320_000,
		chemical_preference   = 60_000,
	}
	first := genome_id(genome)
	testing.expect_value(t, genome_id(genome), first)
	genome.mobility += 1
	testing.expect(t, genome_id(genome) != first)
	testing.expect(t, u64(first) > 0)
}

@(test)
founder_lineage_and_species_ids_are_nonzero_and_repeatable :: proc(t: ^testing.T) {
	lineage := lineage_id_founder(TERRAIN_SEED, 42)
	testing.expect_value(t, lineage_id_founder(TERRAIN_SEED, 42), lineage)
	testing.expect(t, u64(lineage) > 0)
	genome := Genome {
		id = Genome_Id(7),
	}
	species := species_id_from_genome(genome.id)
	testing.expect_value(t, species_id_from_genome(genome.id), species)
	testing.expect(t, u64(species) > 0)
}

@(test)
gazelle_wander_headings_are_deterministic_continuous_and_normalized :: proc(t: ^testing.T) {
	quadrants: [4]bool
	non_cardinal := false
	for serial in u32(0) ..< 256 {
		east, north := ecology_wander_heading(TERRAIN_SEED, Net_Id(7), serial)
		repeated_east, repeated_north := ecology_wander_heading(TERRAIN_SEED, Net_Id(7), serial)
		testing.expect_value(t, east, repeated_east)
		testing.expect_value(t, north, repeated_north)
		magnitude := integer_sqrt(u64(i64(east) * i64(east) + i64(north) * i64(north)))
		testing.expect(t, abs(i64(magnitude) - i64(PLANET_VECTOR_SCALE)) <= 2)
		non_cardinal = non_cardinal || east != 0 && north != 0
		quadrant := 0
		if east < 0 do quadrant += 1
		if north < 0 do quadrant += 2
		quadrants[quadrant] = true
	}
	testing.expect(t, non_cardinal)
	for covered in quadrants do testing.expect(t, covered)
}

@(test)
gazelle_spawn_composes_ecs_and_moves_deterministically :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	coord := Planet_Coord{.Pos_X, 384, 384}
	for !planet_placement_allowed(world, coord) do coord = planet_neighbour(coord, 1, 0)
	entity, ok := spawn_gazelle(world, coord, 0)
	testing.expect(t, ok)
	testing.expect(t, ecs.has(&world.organisms, entity))
	testing.expect(t, ecs.has(&world.genomes, entity))
	testing.expect(t, ecs.has(&world.movements, entity))
	creature, has_creature := ecs.get(&world.creatures, entity)
	testing.expect(t, has_creature)
	testing.expect_value(t, creature.kind, Creature_Kind.Gazelle)
	movement, _ := ecs.get(&world.movements, entity)
	testing.expect_value(t, movement.behavior, Creature_Behavior.Idle)
	testing.expect_value(t, movement.speed_mm_step, u32(2_000))
	testing.expect(t, movement.heading_east != 0 || movement.heading_north != 0)
	net_id, _ := ecs.get(&world.net_ids, entity)
	serial: u32
	for ecology_behavior_choice(world.foundation.seed, net_id^, serial) != .Walk do serial += 1
	movement.decision_serial = serial
	movement.next_move_tick = ECOLOGY_MOVE_INTERVAL_TICKS
	before, _ := ecs.get(&world.transforms, entity)
	before_coord := Planet_Coord{before.face, before.grid_x, before.grid_y}
	ecology_movement_step(world, ECOLOGY_MOVE_INTERVAL_TICKS - 1)
	testing.expect_value(t, movement.decision_serial, serial)
	ecology_movement_step(world, ECOLOGY_MOVE_INTERVAL_TICKS)
	after, _ := ecs.get(&world.transforms, entity)
	after_coord := Planet_Coord{after.face, after.grid_x, after.grid_y}
	testing.expect(t, planet_coord_valid(after_coord))
	testing.expect(t, before_coord != after_coord)
	testing.expect_value(t, movement.behavior, Creature_Behavior.Walk)
	testing.expect_value(t, movement.prior, before_coord)
	testing.expect_value(t, movement.destination, after_coord)
	testing.expect_value(t, movement.next_move_tick, ECOLOGY_MOVE_INTERVAL_TICKS * 2)
	testing.expect(t, waterfield_depth_at_coord(world, after_coord) < f32(WATER_WET_THRESHOLD))
	retained_east := movement.heading_east
	retained_north := movement.heading_north
	for direction in ECOLOGY_WANDER_DIRECTIONS {
		blocked := planet_neighbour(after_coord, direction.x, direction.y)
		world.waterfield.depths[planet_index(blocked)] = WATER_WET_THRESHOLD
	}
	serial = movement.decision_serial
	for ecology_behavior_choice(world.foundation.seed, net_id^, serial) != .Walk do serial += 1
	movement.decision_serial = serial
	ecology_movement_step(world, movement.next_move_tick)
	blocked_transform, _ := ecs.get(&world.transforms, entity)
	testing.expect_value(t, blocked_transform^, after^)
	testing.expect_value(t, movement.behavior, Creature_Behavior.Idle)
	testing.expect_value(t, movement.prior, after_coord)
	testing.expect_value(t, movement.destination, after_coord)
	testing.expect_value(t, movement.heading_east, retained_east)
	testing.expect_value(t, movement.heading_north, retained_north)
}

@(test)
gazelle_behavior_choices_cover_stationary_states_and_sim_tick :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	coord := Planet_Coord{.Pos_X, 384, 384}
	for !planet_placement_allowed(world, coord) do coord = planet_neighbour(coord, 1, 0)
	entity, ok := spawn_gazelle(world, coord, 0)
	testing.expect(t, ok)
	movement, _ := ecs.get(&world.movements, entity)
	transform, _ := ecs.get(&world.transforms, entity)
	net_id, _ := ecs.get(&world.net_ids, entity)
	retained_coord := planet_neighbour(coord, 1, 0)
	transform^ = planet_transform_make(retained_coord, terrain_height_at_coord(world, retained_coord))
	retained_east := movement.heading_east
	retained_north := movement.heading_north
	behaviors := [2]Creature_Behavior{.Idle, .Graze}
	for behavior in behaviors {
		serial: u32
		for ecology_behavior_choice(world.foundation.seed, net_id^, serial) != behavior do serial += 1
		movement.prior = coord
		movement.destination = retained_coord
		movement.decision_serial = serial
		movement.next_move_tick = 0
		ecology_movement_step(world, 0)
		testing.expect_value(t, movement.behavior, behavior)
		testing.expect_value(t, movement.prior, retained_coord)
		testing.expect_value(t, movement.destination, retained_coord)
		testing.expect_value(t, movement.heading_east, retained_east)
		testing.expect_value(t, movement.heading_north, retained_north)
		testing.expect_value(t, movement.decision_serial, serial + 1)
		testing.expect(t, movement.next_move_tick >= ECOLOGY_MOVE_INTERVAL_TICKS)
	}
}

@(test)
gazelle_heading_survives_snapshot_round_trip :: proc(t: ^testing.T) {
	source := new(World)
	target := new(World)
	defer free(source)
	defer free(target)
	testing.expect(t, world_init(source))
	testing.expect(t, world_init(target))
	defer world_deinit(source)
	defer world_deinit(target)
	coord := Planet_Coord{.Pos_X, 384, 384}
	for !planet_placement_allowed(source, coord) do coord = planet_neighbour(coord, 1, 0)
	entity, spawned := spawn_gazelle(source, coord, 0)
	testing.expect(t, spawned)
	net_id, identified := world_net_id_for_entity(source, entity)
	testing.expect(t, identified)
	movement, found := ecs.get(&source.movements, entity)
	testing.expect(t, found)
	movement.heading_east, movement.heading_north = ecology_wander_heading(source.foundation.seed, net_id, 91)
	movement.behavior = .Graze
	buffer := make([]u8, world_snapshot_size(source))
	defer delete(buffer)
	_, written := world_snapshot_write(source, buffer)
	testing.expect(t, written)
	testing.expect(t, world_snapshot_read(target, buffer))
	restored_entity, resolved := world_entity_by_net_id(target, net_id)
	testing.expect(t, resolved)
	restored, has_movement := ecs.get(&target.movements, restored_entity)
	testing.expect(t, has_movement)
	testing.expect_value(t, restored^, movement^)
}

@(test)
gazelle_population_is_deterministic_and_complete :: proc(t: ^testing.T) {
	first := new(World)
	second := new(World)
	defer free(first)
	defer free(second)
	testing.expect(t, world_init(first))
	testing.expect(t, world_init(second))
	defer world_deinit(first)
	defer world_deinit(second)
	first_count, first_ok := world_populate_gazelles(first)
	second_count, second_ok := world_populate_gazelles(second)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first_count, GAZELLE_FOUNDER_COUNT)
	testing.expect_value(t, first_count, second_count)
	for index in 0 ..< ecs.set_len(&first.creatures) {
		entity := first.creatures.header.entities[index]
		other := second.creatures.header.entities[index]
		testing.expect(t, ecs.has(&first.transforms, entity))
		testing.expect(t, ecs.has(&first.net_ids, entity))
		testing.expect(t, ecs.has(&first.organisms, entity))
		testing.expect(t, ecs.has(&first.genomes, entity))
		testing.expect(t, ecs.has(&first.movements, entity))
		transform, _ := ecs.get(&first.transforms, entity)
		other_transform, _ := ecs.get(&second.transforms, other)
		movement, _ := ecs.get(&first.movements, entity)
		other_movement, _ := ecs.get(&second.movements, other)
		testing.expect_value(t, transform^, other_transform^)
		testing.expect_value(t, movement^, other_movement^)
	}
}

@(test)
gazelle_spawn_rejects_existing_creature :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	coord := Planet_Coord{.Pos_X, 384, 384}
	for !collision_spawn_allowed(world, coord) do coord = planet_neighbour(coord, 1, 0)
	_, first := spawn_gazelle(world, coord, 0)
	_, second := spawn_gazelle(world, coord, 1)
	testing.expect(t, first)
	testing.expect(t, !second)
}

@(test)
gazelle_collision_reservations_are_canonical_and_unique :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	coord := Planet_Coord{.Pos_X, 0, PLANET_FACE_CELLS / 2}
	canonical := planet_canonical(coord)
	ecology_collision_begin(&world.ecology_collision)
	ecology_collision_reserve(&world.ecology_collision, coord)
	testing.expect(t, ecology_collision_reserved(&world.ecology_collision, canonical))
	testing.expect_value(t, world.ecology_collision.reserve_count, 1)
}
