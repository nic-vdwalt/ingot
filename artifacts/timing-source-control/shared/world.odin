package shared

import "base:runtime"
import "core:mem"
import ecs "ingot:ecs"

MAX_ENTITIES :: u32(16384)
MAX_BUILDINGS :: u32(1024)
MAX_PLAYERS :: u32(64)
GAZELLE_FOUNDER_COUNT :: u32(12)
GAZELLE_FOUNDER_SEARCH_RADIUS :: i32(96)
MAX_DEFERRED_COMMANDS :: u32(512)
MAX_DEFERRED_PAYLOAD :: u32(16384)

// World snapshot layout: [ecs snapshot][u32 version][u64 seed]
// [lithosphere][tectonic field][heightfield][waterfield][planetary state]. Bump when shape changes.
// v9: unified cave/volume recipe band across both forge demos (breaking).
// v10: fissure carving explicitly disabled in the recipe tune; an ingot pin
// bump had silently enabled it via the abstract recipe defaults (breaking).
// v11: deterministic coarse atmosphere, ocean, waves, geology, volcanism and vents.
// v12: thermally forced atmospheric mass and partitioned wind-sea and swell state.
// v13: seeded axial/orbital epoch and climate-driven surface revision.
// v14: corrected climate/biome generation and deterministic planet drainage.
// v15: persistent breaker classification and shoreline run-up history.
// v16: bounded storm sources, swell packets, sub-cell travel and pulse phase.
// v17: stable identity relationships, ECS vents and dormant ecology components.
// v18: deterministic creature movement cadence and presentation kind.
// v19: deterministic creature idle, grazing and walking behavior state.
// v20: persistent fixed-point creature heading and eight-direction movement.
// v21: explicit irradiance, marine biogeochemistry, and persistent vent habitats.
// v22: persistent surface and deep long-range ocean current layers.
// v23: persistent terrestrial flora lineage cohorts and ancestry.
// v24: lithosphere-driven terrain and coherent persistent crust geology.
// v25: circular swell ring packets.
// v26: rigid plate kinematics, collision roles, tectonic profiles and relaxation.
// v27: persistent plate drift, tectonic displacement, sediment and volcanic aerosols.
// v30: evolvable flora morphology genomes and bounded visual families.
WORLD_SNAPSHOT_VERSION :: u32(33)
PLANET_HEIGHTFIELD_SNAPSHOT_BYTES :: PLANET_FIELD_CELLS * size_of(i16)
PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES :: PLANET_FIELD_CELLS * size_of(i16)
PLANET_WATERFIELD_SNAPSHOT_BYTES :: PLANET_FIELD_CELLS * size_of(u32)
FORGE_TEST_ENABLED :: #config(FORGE_TEST, false)
_world_heap_allocator :: runtime.heap_allocator

when FORGE_TEST_ENABLED {
	_test_foundation_cache: Planet_Foundation
	_test_foundation_cache_valid: bool
}

// World is the fully-typed ECS world shared by client and server. Sets are
// registered with the pool in declaration order inside world_init; that order
// is the snapshot order, so it must never be reordered without bumping the
// snapshot version.
World :: struct {
	allocator:          mem.Allocator,
	pool:               ecs.Entity_Pool,
	transforms:         ecs.Set(Transform),
	net_ids:            ecs.Set(Net_Id),
	owners:             ecs.Set(Owner),
	buildings:          ecs.Set(Building),
	constructions:      ecs.Set(Construction),
	stockpiles:         ecs.Set(Stockpile),
	nodes:              ecs.Set(Resource_Node),
	harvest_links:      ecs.Set(Harvest_Link),
	hydrothermal_vents: ecs.Set(Hydrothermal_Vent),
	organisms:          ecs.Set(Organism),
	genomes:            ecs.Set(Genome),
	metabolisms:        ecs.Set(Metabolism),
	reproductions:      ecs.Set(Reproduction),
	movements:          ecs.Set(Movement),
	vent_origins:       ecs.Set(Vent_Origin),
	plants:             ecs.Set(Plant),
	creatures:          ecs.Set(Creature),
	deferred:           ecs.Deferred,
	ecology_collision:  Ecology_Collision_Scratch,
	// players maps player id -> stockpile-owning player entity so production
	// can credit owners without an O(n) search per building per tick.
	players:            [MAX_PLAYERS]ecs.Entity,
	entities_by_net_id: map[Net_Id]ecs.Entity,
	next_net_id:        u64,
	foundation:         Planet_Foundation,
	// The mutable terrain and finite water layers are plain value state,
	// snapshotted after the ECS sets.
	heightfield:        Planet_Heightfield,
	waterfield:         Planet_Waterfield,
	planetary:          Planetary_State,
	flora_ecology:      Flora_Ecology,
	biome_environment:  Biome_Environment_State,
	marine_ecology:     Marine_Ecology,
}

world_init :: proc(world: ^World, allocator := context.allocator) -> bool {
	return world_init_seed(world, TERRAIN_SEED, allocator)
}

@(private)
_test_foundation_copy :: proc(target, source: ^Planet_Foundation) {
	target.seed = source.seed
	target.sea_level = source.sea_level
	target.snow_level = source.snow_level
	target.lithosphere = source.lithosphere
	copy(target.base_height, source.base_height)
	copy(target.landform_height, source.landform_height)
	copy(target.moisture, source.moisture)
	copy(target.temperature, source.temperature)
	copy(target.continentalness, source.continentalness)
	copy(target.ruggedness, source.ruggedness)
	copy(target.slope, source.slope)
	copy(target.plate_id, source.plate_id)
	copy(target.plate_crust, source.plate_crust)
	copy(target.plate_boundary, source.plate_boundary)
	copy(target.boundary_strength, source.boundary_strength)
	copy(target.tectonic_delta, source.tectonic_delta)
	target.tectonic_revision = source.tectonic_revision
	copy(target.primary_biome, source.primary_biome)
	copy(target.secondary_biome, source.secondary_biome)
	copy(target.primary_weight, source.primary_weight)
	copy(target.river_strength, source.river_strength)
	copy(target.chasm_strength, source.chasm_strength)
	copy(target.buildable, source.buildable)
	copy(target.relaxation_delta, source.relaxation_delta)
}

world_init_seed :: proc(world: ^World, seed: u64, allocator := context.allocator) -> bool {
	assert(world != nil, "world_init_seed: nil world")
	world^ = {}
	world.allocator = allocator
	ok := ecs.pool_init(&world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.transforms, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.net_ids, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.owners, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.buildings, &world.pool, MAX_BUILDINGS, allocator)
	ok = ok && ecs.set_init(&world.constructions, &world.pool, MAX_BUILDINGS, allocator)
	ok = ok && ecs.set_init(&world.stockpiles, &world.pool, MAX_PLAYERS, allocator)
	ok = ok && ecs.set_init(&world.nodes, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.harvest_links, &world.pool, MAX_BUILDINGS, allocator)
	ok =
		ok &&
		ecs.set_init(&world.hydrothermal_vents, &world.pool, MAX_HYDROTHERMAL_VENTS, allocator)
	ok = ok && ecs.set_init(&world.organisms, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.genomes, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.metabolisms, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.reproductions, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.movements, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.vent_origins, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.plants, &world.pool, MAX_ENTITIES, allocator)
	ok = ok && ecs.set_init(&world.creatures, &world.pool, MAX_ENTITIES, allocator)
	ok =
		ok &&
		ecs.deferred_init(&world.deferred, MAX_DEFERRED_COMMANDS, MAX_DEFERRED_PAYLOAD, allocator)
	ok = ok && ecology_collision_init(&world.ecology_collision, allocator)
	if !ok {
		world_deinit(world)
		return false
	}
	planet_foundation_init(&world.foundation, allocator)
	planet_heightfield_init(&world.heightfield, allocator)
	planet_waterfield_init(&world.waterfield, allocator)
	world.entities_by_net_id = make(map[Net_Id]ecs.Entity, int(MAX_ENTITIES), allocator)
	world.next_net_id = 1
	foundation_ok := false
	when FORGE_TEST_ENABLED {
		if !_test_foundation_cache_valid || _test_foundation_cache.seed != seed {
			if !_test_foundation_cache_valid do planet_foundation_init(&_test_foundation_cache, _world_heap_allocator())
			foundation_ok = planet_foundation_generate(&_test_foundation_cache, seed)
			_test_foundation_cache_valid = foundation_ok
		} else {
			foundation_ok = true
		}
		if foundation_ok do _test_foundation_copy(&world.foundation, &_test_foundation_cache)
	} else {
		foundation_ok = planet_foundation_generate(&world.foundation, seed)
	}
	if !foundation_ok {
		world_deinit(world)
		return false
	}
	waterfield_initialize(world)
	planetary_init(&world.planetary, world, allocator)
	biome_environment_init(world, allocator)
	if !flora_ecology_init(&world.flora_ecology, seed, allocator) {
		world_deinit(world)
		return false
	}
	if !flora_ecology_inoculate(&world.flora_ecology, world) {
		world_deinit(world)
		return false
	}
	if !marine_ecology_init(&world.marine_ecology, seed, allocator) || !marine_ecology_inoculate(&world.marine_ecology, world) {
		world_deinit(world)
		return false
	}
	if !hydrothermal_init(world) {
		world_deinit(world)
		return false
	}
	planetary_diagnostics_update(world)
	assert(world.pool.set_count == 17, "world_init: unexpected set registration count")
	return true
}

world_deinit :: proc(world: ^World) {
	assert(world != nil, "world_deinit: nil world")
	allocator := world.allocator
	marine_ecology_deinit(&world.marine_ecology, allocator)
	flora_ecology_deinit(&world.flora_ecology, allocator)
	biome_environment_deinit(&world.biome_environment, allocator)
	planetary_deinit(&world.planetary, allocator)
	planet_waterfield_deinit(&world.waterfield, allocator)
	planet_heightfield_deinit(&world.heightfield, allocator)
	planet_foundation_deinit(&world.foundation, allocator)
	delete(world.entities_by_net_id)
	ecology_collision_deinit(&world.ecology_collision, allocator)
	ecs.deferred_deinit(&world.deferred)
	ecs.set_deinit(&world.creatures)
	ecs.set_deinit(&world.plants)
	ecs.set_deinit(&world.vent_origins)
	ecs.set_deinit(&world.movements)
	ecs.set_deinit(&world.reproductions)
	ecs.set_deinit(&world.metabolisms)
	ecs.set_deinit(&world.genomes)
	ecs.set_deinit(&world.organisms)
	ecs.set_deinit(&world.hydrothermal_vents)
	ecs.set_deinit(&world.harvest_links)
	ecs.set_deinit(&world.nodes)
	ecs.set_deinit(&world.stockpiles)
	ecs.set_deinit(&world.constructions)
	ecs.set_deinit(&world.buildings)
	ecs.set_deinit(&world.owners)
	ecs.set_deinit(&world.net_ids)
	ecs.set_deinit(&world.transforms)
	ecs.pool_deinit(&world.pool)
	world^ = {}
}

// spawn_player creates the player's stockpile entity with starting resources.
// Player ids are dense and bounded by MAX_PLAYERS.
spawn_player :: proc(world: ^World, player: u32) -> (entity: ecs.Entity, ok: bool) {
	assert(world != nil, "spawn_player: nil world")
	assert(player < MAX_PLAYERS, "spawn_player: player id out of range")
	if ecs.is_alive(&world.pool, world.players[player]) do return world.players[player], false
	entity = ecs.create_entity(&world.pool) or_return
	starting := Stockpile{}
	starting.amounts[.Ore] = 500
	starting.amounts[.Energy] = 200
	added := ecs.add(&world.stockpiles, entity, starting)
	added = added && ecs.add(&world.owners, entity, Owner{player = player})
	net_id := _allocate_net_id(world)
	added = added && ecs.add(&world.net_ids, entity, net_id)
	if !added {
		_ = ecs.destroy_entity(&world.pool, entity)
		return ecs.ENTITY_NIL, false
	}
	world_net_index_add(world, entity, net_id)
	world.players[player] = entity
	return entity, true
}

// spawn_resource_node creates a map tile entity that scales Mine yield.
spawn_resource_node :: proc(
	world: ^World,
	coord: Planet_Coord,
	kind: Resource_Kind,
	richness_percent: u32,
) -> (
	entity: ecs.Entity,
	ok: bool,
) {
	assert(world != nil, "spawn_resource_node: nil world")
	assert(richness_percent >= 100 && richness_percent <= 400, "spawn_resource_node: bad richness")
	assert(planet_coord_valid(coord), "spawn_resource_node: invalid coordinate")
	entity = ecs.create_entity(&world.pool) or_return
	index := planet_index(coord)
	height := f32(world.foundation.base_height[index]) / f32(HEIGHT_DELTA_SCALE)
	added := ecs.add(&world.transforms, entity, planet_transform_make(coord, height))
	node := Resource_Node {
		kind             = kind,
		richness_percent = richness_percent,
	}
	added = added && ecs.add(&world.nodes, entity, node)
	net_id := _allocate_net_id(world)
	added = added && ecs.add(&world.net_ids, entity, net_id)
	if !added {
		_ = ecs.destroy_entity(&world.pool, entity)
		return ecs.ENTITY_NIL, false
	}
	world_net_index_add(world, entity, net_id)
	return entity, true
}

spawn_gazelle :: proc(
	world: ^World,
	coord: Planet_Coord,
	founder: u32,
) -> (
	entity: ecs.Entity,
	ok: bool,
) {
	assert(world != nil, "spawn_gazelle: nil world")
	assert(planet_coord_valid(coord), "spawn_gazelle: invalid coordinate")
	canonical := planet_canonical(coord)
	if !collision_spawn_allowed(world, canonical) do return ecs.ENTITY_NIL, false
	entity = ecs.create_entity(&world.pool) or_return
	genome := Genome {
		metabolism            = 20,
		growth                = 40,
		mobility              = 180,
		thermal_preference_mk = 295_000,
	}
	genome.id = genome_id(genome)
	net_id := _allocate_net_id(world)
	heading_east, heading_north := ecology_wander_heading(world.foundation.seed, net_id, 0)
	organism := Organism {
		health  = 100,
		energy  = 100_000,
		genome  = genome.id,
		species = species_id_from_genome(genome.id),
		lineage = lineage_id_founder(world.foundation.seed, u64(founder) + 1),
		stage   = .Adult,
	}
	movement := Movement {
		heading_east   = heading_east,
		heading_north  = heading_north,
		speed_mm_step  = 2_000,
		prior          = canonical,
		destination    = canonical,
		next_move_tick = u64(founder % u32(ECOLOGY_MOVE_INTERVAL_TICKS)),
		behavior       = .Idle,
	}
	added := ecs.add(
		&world.transforms,
		entity,
		planet_transform_make(canonical, terrain_height_at_coord(world, canonical)),
	)
	added = added && ecs.add(&world.net_ids, entity, net_id)
	added = added && ecs.add(&world.organisms, entity, organism)
	added = added && ecs.add(&world.genomes, entity, genome)
	added = added && ecs.add(&world.movements, entity, movement)
	added =
		added &&
		ecs.add(&world.creatures, entity, Creature{sensory_range_mm = 24_000, kind = .Gazelle})
	if !added {
		_ = ecs.destroy_entity(&world.pool, entity)
		return ecs.ENTITY_NIL, false
	}
	world_net_index_add(world, entity, net_id)
	return entity, true
}

world_populate_gazelles :: proc(world: ^World) -> (count: u32, ok: bool) {
	assert(world != nil, "world_populate_gazelles: nil world")
	assert(
		ecs.set_len(&world.creatures) == 0,
		"world_populate_gazelles: creatures already present",
	)
	center := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	for radius in i32(0) ..= GAZELLE_FOUNDER_SEARCH_RADIUS {
		for offset in -radius ..= radius {
			if count >= GAZELLE_FOUNDER_COUNT do break
			candidates := [4]Planet_Coord {
				planet_neighbour(center, offset, radius),
				planet_neighbour(center, offset, -radius),
				planet_neighbour(center, radius, offset),
				planet_neighbour(center, -radius, offset),
			}
			for coord in candidates {
				if count >= GAZELLE_FOUNDER_COUNT do break
				if _, spawned := spawn_gazelle(world, coord, count); spawned do count += 1
			}
		}
		if count >= GAZELLE_FOUNDER_COUNT do break
	}
	return count, count == GAZELLE_FOUNDER_COUNT
}

world_snapshot_size :: proc(world: ^World) -> int {
	assert(world != nil, "world_snapshot_size: nil world")
	payload_size := size_of(u32) + size_of(world.foundation.seed) + size_of(world.foundation.lithosphere)
	payload_size += PLANET_HEIGHTFIELD_SNAPSHOT_BYTES + PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES
	payload_size += size_of(world.foundation.tectonic_revision)
	payload_size += PLANET_WATERFIELD_SNAPSHOT_BYTES + size_of(world.waterfield.revision)
	payload_size += planetary_snapshot_size(&world.planetary)
	payload_size += BIOME_ENVIRONMENT_SNAPSHOT_BYTES
	payload_size += marine_ecology_snapshot_size(&world.marine_ecology)
	payload_size += flora_ecology_snapshot_size(&world.flora_ecology)
	return ecs.snapshot_size(&world.pool) + payload_size
}

world_snapshot_write :: proc(world: ^World, buffer: []u8) -> (written: int, ok: bool) {
	assert(world != nil, "world_snapshot_write: nil world")
	ecs_written := ecs.snapshot_write(&world.pool, buffer) or_return
	cursor := ecs_written
	if len(buffer) - cursor < world_snapshot_size(world) - ecs_written do return 0, false
	version := WORLD_SNAPSHOT_VERSION
	copy(buffer[cursor:], mem.ptr_to_bytes(&version))
	cursor += size_of(u32)
	seed := world.foundation.seed
	copy(buffer[cursor:], mem.ptr_to_bytes(&seed))
	cursor += size_of(world.foundation.seed)
	copy(buffer[cursor:], mem.ptr_to_bytes(&world.foundation.lithosphere))
	cursor += size_of(world.foundation.lithosphere)
	copy(buffer[cursor:], mem.slice_to_bytes(world.foundation.tectonic_delta))
	cursor += PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES
	copy(buffer[cursor:], mem.ptr_to_bytes(&world.foundation.tectonic_revision))
	cursor += size_of(world.foundation.tectonic_revision)
	copy(buffer[cursor:], mem.slice_to_bytes(world.heightfield.deltas))
	cursor += PLANET_HEIGHTFIELD_SNAPSHOT_BYTES
	copy(buffer[cursor:], mem.slice_to_bytes(world.waterfield.depths))
	cursor += PLANET_WATERFIELD_SNAPSHOT_BYTES
	copy(buffer[cursor:], mem.ptr_to_bytes(&world.waterfield.revision))
	cursor += size_of(world.waterfield.revision)
	planetary_written, planetary_ok := planetary_snapshot_write(&world.planetary, buffer[cursor:])
	if !planetary_ok do return 0, false
	cursor += planetary_written
	if !biome_environment_snapshot_write(&world.biome_environment, buffer[cursor:]) do return 0, false
	cursor += BIOME_ENVIRONMENT_SNAPSHOT_BYTES
	marine_written, marine_ok := marine_ecology_snapshot_write(&world.marine_ecology, buffer[cursor:])
	if !marine_ok do return 0, false
	cursor += marine_written
	flora_written, flora_ok := flora_ecology_snapshot_write(&world.flora_ecology, buffer[cursor:])
	if !flora_ok do return 0, false
	cursor += flora_written
	assert(cursor == world_snapshot_size(world), "world_snapshot_write: size mismatch")
	return cursor, true
}

world_snapshot_read :: proc(world: ^World, buffer: []u8) -> bool {
	assert(world != nil, "world_snapshot_read: nil world")
	payload_size := size_of(u32) + size_of(world.foundation.seed) + size_of(world.foundation.lithosphere)
	payload_size += PLANET_HEIGHTFIELD_SNAPSHOT_BYTES + PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES
	payload_size += size_of(world.foundation.tectonic_revision)
	payload_size += PLANET_WATERFIELD_SNAPSHOT_BYTES + size_of(world.waterfield.revision)
	payload_size += planetary_snapshot_size(&world.planetary)
	payload_size += BIOME_ENVIRONMENT_SNAPSHOT_BYTES
	if len(buffer) < size_of(u64) do return false
	flora_payload_size: u64
	copy(mem.ptr_to_bytes(&flora_payload_size), buffer[len(buffer) - size_of(u64):])
	if flora_payload_size > u64(len(buffer)) || flora_payload_size < size_of(u64) do return false
	flora_start := len(buffer) - int(flora_payload_size)
	if flora_start < 8 do return false
	footer_cursor := flora_start - 8
	marine_payload_size: u64
	if !marine_snapshot_scalar(buffer, &footer_cursor, &marine_payload_size, true) do return false
	if marine_payload_size < 8 || marine_payload_size > u64(flora_start) do return false
	if payload_size > flora_start - int(marine_payload_size) do return false
	payload_size += int(flora_payload_size) + int(marine_payload_size)
	if len(buffer) < payload_size do return false
	ecs_size := len(buffer) - payload_size
	cursor := ecs_size
	version: u32
	copy(mem.ptr_to_bytes(&version), buffer[cursor:cursor + size_of(u32)])
	if version != WORLD_SNAPSHOT_VERSION do return false
	cursor += size_of(u32)
	seed: u64
	copy(mem.ptr_to_bytes(&seed), buffer[cursor:cursor + size_of(u64)])
	cursor += size_of(u64)
	if !planet_foundation_generate(&world.foundation, seed) do return false
	copy(
		mem.ptr_to_bytes(&world.foundation.lithosphere),
		buffer[cursor:cursor + size_of(world.foundation.lithosphere)],
	)
	cursor += size_of(world.foundation.lithosphere)
	copy(
		mem.slice_to_bytes(world.foundation.tectonic_delta),
		buffer[cursor:cursor + PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES],
	)
	cursor += PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES
	copy(
		mem.ptr_to_bytes(&world.foundation.tectonic_revision),
		buffer[cursor:cursor + size_of(world.foundation.tectonic_revision)],
	)
	cursor += size_of(world.foundation.tectonic_revision)
	if !ecs.snapshot_read(&world.pool, buffer[:ecs_size]) do return false
	copy(
		mem.slice_to_bytes(world.heightfield.deltas),
		buffer[cursor:cursor + PLANET_HEIGHTFIELD_SNAPSHOT_BYTES],
	)
	world.heightfield.modified = false
	for delta in world.heightfield.deltas {
		if delta != 0 {
			world.heightfield.modified = true
			break
		}
	}
	cursor += PLANET_HEIGHTFIELD_SNAPSHOT_BYTES
	copy(
		mem.slice_to_bytes(world.waterfield.depths),
		buffer[cursor:cursor + PLANET_WATERFIELD_SNAPSHOT_BYTES],
	)
	cursor += PLANET_WATERFIELD_SNAPSHOT_BYTES
	copy(
		mem.ptr_to_bytes(&world.waterfield.revision),
		buffer[cursor:cursor + size_of(world.waterfield.revision)],
	)
	cursor += size_of(world.waterfield.revision)
	planetary_size := planetary_snapshot_size(&world.planetary)
	if !planetary_snapshot_read(&world.planetary, buffer[cursor:cursor + planetary_size]) do return false
	cursor += planetary_size
	tectonics_restore_foundation(world)
	if !biome_environment_snapshot_read(world, buffer[cursor:cursor + BIOME_ENVIRONMENT_SNAPSHOT_BYTES]) do return false
	cursor += BIOME_ENVIRONMENT_SNAPSHOT_BYTES
	marine_size := int(marine_payload_size)
	if !marine_ecology_snapshot_read(&world.marine_ecology, buffer[cursor:cursor + marine_size]) do return false
	cursor += marine_size
	flora_size := int(flora_payload_size)
	if !flora_ecology_snapshot_read(&world.flora_ecology, buffer[cursor:cursor + flora_size]) do return false
	cursor += flora_size
	assert(cursor == len(buffer), "world_snapshot_read: size mismatch")
	_planet_waterfield_ground_fill(world)
	world.waterfield.settled = false
	world.players = {}
	world.next_net_id = 1
	clear(&world.entities_by_net_id)
	for index in 0 ..< ecs.set_len(&world.stockpiles) {
		entity := world.stockpiles.header.entities[index]
		owner, has_owner := ecs.get(&world.owners, entity)
		assert(has_owner, "world_snapshot_read: stockpile entity without owner")
		assert(owner.player < MAX_PLAYERS, "world_snapshot_read: player id out of range")
		world.players[owner.player] = entity
	}
	for index in 0 ..< ecs.set_len(&world.net_ids) {
		entity := world.net_ids.header.entities[index]
		net_id := world.net_ids.items[index]
		if u64(net_id) == 0 || net_id in world.entities_by_net_id do return false
		world.entities_by_net_id[net_id] = entity
		if u64(net_id) >= world.next_net_id {
			if u64(net_id) == max(u64) do return false
			world.next_net_id = u64(net_id) + 1
		}
	}
	return true
}

world_net_id_for_entity :: proc(world: ^World, entity: ecs.Entity) -> (Net_Id, bool) {
	assert(world != nil, "world_net_id_for_entity: nil world")
	if !ecs.is_alive(&world.pool, entity) do return {}, false
	net_id, ok := ecs.get(&world.net_ids, entity)
	if !ok || u64(net_id^) == 0 do return {}, false
	return net_id^, true
}

world_entity_by_net_id :: proc(world: ^World, net_id: Net_Id) -> (ecs.Entity, bool) {
	assert(world != nil, "world_entity_by_net_id: nil world")
	if u64(net_id) == 0 do return ecs.ENTITY_NIL, false
	entity, ok := world.entities_by_net_id[net_id]
	if !ok || !ecs.is_alive(&world.pool, entity) do return ecs.ENTITY_NIL, false
	stored, has_id := ecs.get(&world.net_ids, entity)
	if !has_id || stored^ != net_id do return ecs.ENTITY_NIL, false
	return entity, true
}

world_net_index_add :: proc(world: ^World, entity: ecs.Entity, net_id: Net_Id) {
	assert(world != nil, "world_net_index_add: nil world")
	assert(ecs.is_alive(&world.pool, entity), "world_net_index_add: dead entity")
	assert(u64(net_id) > 0, "world_net_index_add: zero id")
	assert(net_id not_in world.entities_by_net_id, "world_net_index_add: duplicate id")
	world.entities_by_net_id[net_id] = entity
}

world_destroy_entity :: proc(world: ^World, entity: ecs.Entity) -> bool {
	assert(world != nil, "world_destroy_entity: nil world")
	if net_id, ok := world_net_id_for_entity(world, entity); ok {
		delete_key(&world.entities_by_net_id, net_id)
	}
	return ecs.destroy_entity(&world.pool, entity)
}

_allocate_net_id :: proc(world: ^World) -> Net_Id {
	assert(world != nil, "_allocate_net_id: nil world")
	assert(world.next_net_id > 0, "_allocate_net_id: world not initialised")
	assert(world.next_net_id < max(u64), "_allocate_net_id: exhausted")
	id := Net_Id(world.next_net_id)
	world.next_net_id += 1
	return id
}
