package main

import shared "../shared"
import ecs "ingot:ecs"
import rl "ingot:gfx"
import b3 "vendor:box3d"

Entity_Query_Proxy :: struct {
	entity:      ecs.Entity,
	net_id:      shared.Net_Id,
	bounds:      Bounds_3D,
	bounds_hash: u64,
	body:        b3.BodyId,
	shape:       b3.ShapeId,
	seen:        bool,
}

Entity_Queries :: struct {
	world:            b3.WorldId,
	proxies:          [MAX_ENTITY_QUERIES]Entity_Query_Proxy,
	shape_to_proxy:   map[u64]int,
	entity_to_proxy:  map[ecs.Entity]int,
	count:            int,
	terrain_revision: u64,
	focus_tile:       Flora_Tile_Id,
	focus_valid:      bool,
	last_tick:        u64,
	entity_counts:    [4]u32,
	built:            bool,
	updates:          u32,
	removals:         u32,
	scans:            u64,
	fingerprint:      u64,
}

entity_query_bounds_hash :: proc(bounds: Bounds_3D) -> u64 {
	hash := u64(0x9E3779B97F4A7C15)
	for value in bounds.min {
		hash = _fingerprint_mix(hash, u64(transmute(u32)value))
	}
	for value in bounds.max {
		hash = _fingerprint_mix(hash, u64(transmute(u32)value))
	}
	return hash
}

entity_query_proxy_index :: proc(queries: ^Entity_Queries, entity: ecs.Entity) -> (int, bool) {
	assert(queries != nil, "entity query proxy index: nil registry")
	if queries.entity_to_proxy == nil do return -1, false
	index, found := queries.entity_to_proxy[entity]
	if !found || index < 0 || index >= queries.count do return -1, false
	return index, queries.proxies[index].entity == entity
}

entity_query_proxy_destroy :: proc(queries: ^Entity_Queries, index: int) {
	assert(queries != nil, "entity query proxy destroy: nil registry")
	assert(index >= 0 && index < queries.count, "entity query proxy destroy: index")
	proxy := &queries.proxies[index]
	delete_key(&queries.entity_to_proxy, proxy.entity)
	if b3.Shape_IsValid(proxy.shape) {
		delete_key(&queries.shape_to_proxy, b3.StoreShapeId(proxy.shape))
	}
	if b3.Body_IsValid(proxy.body) do b3.DestroyBody(proxy.body)
	last := queries.count - 1
	if index != last {
		queries.proxies[index] = queries.proxies[last]
		moved := &queries.proxies[index]
		queries.entity_to_proxy[moved.entity] = index
		if b3.Shape_IsValid(moved.shape) {
			queries.shape_to_proxy[b3.StoreShapeId(moved.shape)] = index
		}
	}
	queries.proxies[last] = {}
	queries.count -= 1
	queries.removals += 1
}

entity_query_proxy_create :: proc(
	queries: ^Entity_Queries,
	entity: ecs.Entity,
	net_id: shared.Net_Id,
	bounds: Bounds_3D,
) -> bool {
	assert(queries != nil, "entity query proxy create: nil registry")
	if queries.count >= MAX_ENTITY_QUERIES || !entity_query_bounds_valid(bounds) do return false
	size := bounds_size(bounds)
	center := bounds_center(bounds)
	body_def := b3.DefaultBodyDef()
	body_def.type = .staticBody
	body_def.position = center
	body := b3.CreateBody(queries.world, body_def)
	if !b3.Body_IsValid(body) do return false
	hull := b3.MakeBoxHull(size.x / 2, size.y / 2, size.z / 2)
	shape_def := b3.DefaultShapeDef()
	shape_def.isSensor = true
	shape_def.filter.categoryBits = PHYSICS_CATEGORY_ENTITY_QUERY
	shape_def.filter.maskBits = 0
	shape := b3.CreateHullShape(body, shape_def, &hull.base)
	if !b3.Shape_IsValid(shape) {
		b3.DestroyBody(body)
		return false
	}
	index := queries.count
	queries.proxies[index] = {
		entity      = entity,
		net_id      = net_id,
		bounds      = bounds,
		bounds_hash = entity_query_bounds_hash(bounds),
		body        = body,
		shape       = shape,
		seen        = true,
	}
	queries.shape_to_proxy[b3.StoreShapeId(shape)] = index
	queries.entity_to_proxy[entity] = index
	queries.count += 1
	queries.updates += 1
	return true
}

entity_query_proxy_sync :: proc(
	queries: ^Entity_Queries,
	entity: ecs.Entity,
	net_id: shared.Net_Id,
	bounds: Bounds_3D,
) {
	assert(queries != nil, "entity query proxy sync: nil registry")
	index, found := entity_query_proxy_index(queries, entity)
	if !found {
		_ = entity_query_proxy_create(queries, entity, net_id, bounds)
		return
	}
	proxy := &queries.proxies[index]
	proxy.seen = true
	hash := entity_query_bounds_hash(bounds)
	if proxy.bounds_hash == hash && proxy.net_id == net_id do return
	entity_query_proxy_destroy(queries, index)
	_ = entity_query_proxy_create(queries, entity, net_id, bounds)
}

entity_queries_deinit :: proc(value: ^Entity_Queries) {
	assert(value != nil, "entity_queries_deinit: nil queries")
	for value.count > 0 do entity_query_proxy_destroy(value, value.count - 1)
	delete(value.entity_to_proxy)
	delete(value.shape_to_proxy)
	value^ = {}
}

entity_queries_begin :: proc(value: ^Client_State) {
	queries := &value.queries
	if queries.world != value.cosmetics.world {
		entity_queries_deinit(queries)
		queries.world = value.cosmetics.world
	}
	if queries.shape_to_proxy == nil {
		queries.shape_to_proxy = make(map[u64]int, MAX_ENTITY_QUERIES)
	}
	if queries.entity_to_proxy == nil {
		queries.entity_to_proxy = make(map[ecs.Entity]int, MAX_ENTITY_QUERIES)
	}
	for index in 0 ..< queries.count do queries.proxies[index].seen = false
	queries.updates = 0
	queries.removals = 0
}

entity_queries_sync :: proc(value: ^Client_State) {
	assert(value != nil, "entity_queries_sync: nil state")
	if !value.cosmetics.ready do return
	focus_center := flora_world_tile(value.camera.target)
	counts := [4]u32 {
		ecs.set_len(&value.world.buildings),
		ecs.set_len(&value.world.hydrothermal_vents),
		ecs.set_len(&value.world.creatures),
		ecs.set_len(&value.world.nodes),
	}
	if value.queries.built &&
	   value.queries.last_tick == value.tick &&
	   value.queries.terrain_revision == value.terrain.heights_revision &&
	   value.queries.focus_valid &&
	   value.queries.focus_tile == focus_center &&
	   value.queries.entity_counts == counts {
		return
	}
	entity_queries_begin(value)
	value.queries.scans += 1
	buildings := &value.world.buildings
	for index in 0 ..< ecs.set_len(buildings) {
		entity := buildings.header.entities[index]
		if bounds, ok := building_world_bounds(value, entity); ok {
			net_id, _ := shared.world_net_id_for_entity(&value.world, entity)
			entity_query_proxy_sync(&value.queries, entity, net_id, bounds)
		}
	}
	vents := &value.world.hydrothermal_vents
	for index in 0 ..< ecs.set_len(vents) {
		entity := vents.header.entities[index]
		if bounds, ok := vent_world_bounds(value, entity); ok {
			net_id, _ := shared.world_net_id_for_entity(&value.world, entity)
			entity_query_proxy_sync(&value.queries, entity, net_id, bounds)
		}
	}
	creatures := &value.world.creatures
	for index in 0 ..< ecs.set_len(creatures) {
		entity := creatures.header.entities[index]
		if bounds, ok := fauna_world_bounds(value, entity); ok {
			net_id, _ := shared.world_net_id_for_entity(&value.world, entity)
			entity_query_proxy_sync(&value.queries, entity, net_id, bounds)
		}
	}
	nodes := &value.world.nodes
	for index in 0 ..< ecs.set_len(nodes) {
		entity := nodes.header.entities[index]
		if ecs.has(&value.world.buildings, entity) do continue
		transform, has_transform := ecs.get(&value.world.transforms, entity)
		if !has_transform || !flora_node_window_contains(focus_center, transform.position) do continue
		if bounds, ok := node_world_bounds(value, entity); ok {
			net_id, _ := shared.world_net_id_for_entity(&value.world, entity)
			entity_query_proxy_sync(&value.queries, entity, net_id, bounds)
		}
	}
	index := value.queries.count - 1
	for index >= 0 {
		if !value.queries.proxies[index].seen do entity_query_proxy_destroy(&value.queries, index)
		index -= 1
	}
	value.queries.terrain_revision = value.terrain.heights_revision
	value.queries.focus_tile = focus_center
	value.queries.focus_valid = true
	value.queries.last_tick = value.tick
	value.queries.entity_counts = counts
	value.queries.fingerprint = _fingerprint_mix(
		value.queries.fingerprint,
		u64(value.queries.updates) << 32 | u64(value.queries.removals),
	)
	value.queries.built = true
}

entity_queries_pick :: proc(value: ^Client_State, ray: rl.Ray_3D) -> (ecs.Entity, f32, bool) {
	assert(value != nil, "entity_queries_pick: nil state")
	queries := &value.queries
	if queries.count == 0 do return ecs.ENTITY_NIL, 0, false
	filter := b3.DefaultQueryFilter()
	filter.categoryBits = PHYSICS_CATEGORY_DEBRIS
	filter.maskBits = PHYSICS_CATEGORY_ENTITY_QUERY
	result := b3.World_CastRayClosest(
		queries.world,
		ray.origin,
		ray.direction * TERRAIN_RAY_MAX_DISTANCE,
		filter,
	)
	if !result.hit do return ecs.ENTITY_NIL, 0, false
	index, found := queries.shape_to_proxy[b3.StoreShapeId(result.shapeId)]
	if !found || index < 0 || index >= queries.count do return ecs.ENTITY_NIL, 0, false
	proxy := queries.proxies[index]
	return proxy.entity, result.fraction * TERRAIN_RAY_MAX_DISTANCE, true
}
