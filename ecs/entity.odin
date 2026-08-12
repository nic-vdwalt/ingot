package ecs

import "base:runtime"

// Upper bound on component sets a single Entity_Pool can track. The registry
// is a fixed array rather than a growing allocation because destroy_entity
// walks it every call and Tiger Style puts a limit on everything.
ECS_MAX_SETS :: 64

// Entity handles pack an index and a generation so a stale handle held across
// a destroy/create cycle can never alias the new entity occupying the slot.
Entity :: struct {
	index:      u32,
	generation: u32,
}

// The zero value is never a live entity because generations start at 1.
ENTITY_NIL :: Entity{}

// Entity_Pool owns entity liveness and the registry of component sets. All
// storage is allocated once in pool_init; nothing grows afterwards.
Entity_Pool :: struct {
	generations: []u32,
	alive:       []bool,
	free_list:   []u32,
	free_count:  u32,
	next_index:  u32,
	alive_count: u32,
	capacity:    u32,
	sets:        [ECS_MAX_SETS]^Set_Header,
	set_count:   u32,
	allocator:   runtime.Allocator,
}

pool_init :: proc(pool: ^Entity_Pool, capacity: u32, allocator := context.allocator) -> bool {
	assert(pool != nil, "pool_init: nil pool")
	assert(capacity > 0, "pool_init: zero capacity")
	pool^ = {}
	pool.generations = make([]u32, capacity, allocator)
	pool.alive = make([]bool, capacity, allocator)
	pool.free_list = make([]u32, capacity, allocator)
	if pool.generations == nil || pool.alive == nil || pool.free_list == nil {
		pool_deinit(pool)
		return false
	}
	// Generations start at 1 so ENTITY_NIL (generation 0) can never match.
	for &generation in pool.generations do generation = 1
	pool.capacity = capacity
	pool.allocator = allocator
	return true
}

// pool_deinit frees pool storage. Component sets registered with the pool must
// be deinitialised by their owner as well; the registry is cleared here so a
// torn-down pool can never walk freed sets.
pool_deinit :: proc(pool: ^Entity_Pool) {
	assert(pool != nil, "pool_deinit: nil pool")
	delete(pool.generations, pool.allocator)
	delete(pool.alive, pool.allocator)
	delete(pool.free_list, pool.allocator)
	pool^ = {}
}

// create_entity is safe to call during query iteration because it never
// touches component sets; only destroy/add/remove must go through Deferred.
create_entity :: proc(pool: ^Entity_Pool) -> (entity: Entity, ok: bool) {
	assert(pool != nil, "create_entity: nil pool")
	assert(pool.capacity > 0, "create_entity: pool not initialised")
	index: u32
	if pool.free_count > 0 {
		pool.free_count -= 1
		index = pool.free_list[pool.free_count]
	} else {
		if pool.next_index >= pool.capacity do return ENTITY_NIL, false
		index = pool.next_index
		pool.next_index += 1
	}
	assert(!pool.alive[index], "create_entity: reused slot still alive")
	pool.alive[index] = true
	pool.alive_count += 1
	return Entity{index = index, generation = pool.generations[index]}, true
}

// destroy_entity removes the entity from every registered component set, then
// retires the slot. Returns false for stale or never-created handles, which is
// an operating condition (deferred buffers replay them), not a bug.
destroy_entity :: proc(pool: ^Entity_Pool, entity: Entity) -> bool {
	assert(pool != nil, "destroy_entity: nil pool")
	if !is_alive(pool, entity) do return false
	assert(pool.alive_count > 0, "destroy_entity: alive count underflow")
	for set_index in 0 ..< pool.set_count {
		// Absence in a given set is expected; the walk is what guarantees no
		// set keeps a component for a dead entity.
		_ = _header_remove(pool.sets[set_index], entity)
	}
	pool.alive[entity.index] = false
	pool.alive_count -= 1
	// Generation wraps back to 1 rather than 0 so ENTITY_NIL stays invalid.
	next_generation := pool.generations[entity.index] + 1
	if next_generation == 0 do next_generation = 1
	pool.generations[entity.index] = next_generation
	assert(pool.free_count < pool.capacity, "destroy_entity: free list overflow")
	pool.free_list[pool.free_count] = entity.index
	pool.free_count += 1
	return true
}

is_alive :: proc(pool: ^Entity_Pool, entity: Entity) -> bool {
	assert(pool != nil, "is_alive: nil pool")
	assert(pool.capacity > 0, "is_alive: pool not initialised")
	if entity.index >= pool.next_index do return false
	if !pool.alive[entity.index] do return false
	return pool.generations[entity.index] == entity.generation
}

alive_count :: proc(pool: ^Entity_Pool) -> u32 {
	assert(pool != nil, "alive_count: nil pool")
	assert(pool.alive_count <= pool.capacity, "alive_count: count exceeds capacity")
	return pool.alive_count
}
