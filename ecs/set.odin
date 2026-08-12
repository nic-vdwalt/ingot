package ecs

import "base:runtime"

// Set_Header is the type-erased view of a Set(T). The Entity_Pool keeps header
// pointers so destroy_entity, Deferred.flush, and snapshots can walk every
// component set without knowing component types, while all game-facing access
// stays fully typed through Set(T).
Set_Header :: struct {
	sparse:       []u32, // Entity index -> dense index + 1; zero means absent.
	entities:     []Entity, // Dense entity list, parallel to the data array.
	data:         rawptr, // Dense component storage, capacity * element_size bytes.
	element_size: u32,
	count:        u32,
	capacity:     u32,
	allocator:    runtime.Allocator,
}

// Set(T) is a sparse-set component store: O(1) add/remove/get, densely packed
// iteration, fixed capacity decided at init.
Set :: struct($T: typeid) {
	header: Set_Header,
	items:  []T,
}

// set_init allocates storage once and registers the set with the pool so
// generic walks (destroy, snapshot) can reach it. Registration order is the
// snapshot order, so worlds must init their sets in a fixed order.
set_init :: proc(
	set: ^Set($T),
	pool: ^Entity_Pool,
	capacity: u32,
	allocator := context.allocator,
) -> bool {
	assert(set != nil, "set_init: nil set")
	assert(pool != nil, "set_init: nil pool")
	assert(capacity > 0 && capacity <= pool.capacity, "set_init: bad capacity")
	if pool.set_count >= ECS_MAX_SETS do return false
	set^ = {}
	set.header.sparse = make([]u32, pool.capacity, allocator)
	set.header.entities = make([]Entity, capacity, allocator)
	set.items = make([]T, capacity, allocator)
	if set.header.sparse == nil || set.header.entities == nil || set.items == nil {
		set.header.allocator = allocator
		set_deinit(set)
		return false
	}
	set.header.data = raw_data(set.items)
	set.header.element_size = size_of(T)
	set.header.capacity = capacity
	set.header.allocator = allocator
	pool.sets[pool.set_count] = &set.header
	pool.set_count += 1
	return true
}

// set_deinit frees set storage. The owning pool must be torn down (or reset)
// with it; the pool registry is only cleared by pool_deinit.
set_deinit :: proc(set: ^Set($T)) {
	assert(set != nil, "set_deinit: nil set")
	delete(set.header.sparse, set.header.allocator)
	delete(set.header.entities, set.header.allocator)
	delete(set.items, set.header.allocator)
	set^ = {}
}

// add inserts or overwrites. Upserting in place (instead of remove + append)
// keeps dense order stable, which keeps snapshots byte-deterministic.
add :: proc(set: ^Set($T), entity: Entity, value: T) -> bool {
	assert(set != nil, "add: nil set")
	assert(entity.index < u32(len(set.header.sparse)), "add: entity index out of range")
	slot := set.header.sparse[entity.index]
	if slot != 0 {
		set.items[slot - 1] = value
		return true
	}
	if set.header.count >= set.header.capacity do return false
	dense := set.header.count
	set.header.entities[dense] = entity
	set.items[dense] = value
	set.header.sparse[entity.index] = dense + 1
	set.header.count += 1
	return true
}

remove :: proc(set: ^Set($T), entity: Entity) -> bool {
	assert(set != nil, "remove: nil set")
	return _header_remove(&set.header, entity)
}

get :: proc(set: ^Set($T), entity: Entity) -> (value: ^T, ok: bool) {
	assert(set != nil, "get: nil set")
	assert(entity.index < u32(len(set.header.sparse)), "get: entity index out of range")
	slot := set.header.sparse[entity.index]
	if slot == 0 do return nil, false
	return &set.items[slot - 1], true
}

has :: proc(set: ^Set($T), entity: Entity) -> bool {
	assert(set != nil, "has: nil set")
	assert(entity.index < u32(len(set.header.sparse)), "has: entity index out of range")
	return set.header.sparse[entity.index] != 0
}

set_len :: proc(set: ^Set($T)) -> u32 {
	assert(set != nil, "set_len: nil set")
	assert(set.header.count <= set.header.capacity, "set_len: count exceeds capacity")
	return set.header.count
}

// _header_remove is the type-erased swap-remove shared by typed remove,
// destroy_entity, and Deferred.flush. Data moves by memcpy of element_size
// bytes, so components must be plain data (no internal pointers to self).
_header_remove :: proc(header: ^Set_Header, entity: Entity) -> bool {
	assert(header != nil, "_header_remove: nil header")
	assert(entity.index < u32(len(header.sparse)), "_header_remove: entity index out of range")
	slot := header.sparse[entity.index]
	if slot == 0 do return false
	assert(header.count > 0, "_header_remove: count underflow")
	dense := slot - 1
	last := header.count - 1
	moved := header.entities[last]
	header.entities[dense] = moved
	if dense != last {
		size := uintptr(header.element_size)
		dst := rawptr(uintptr(header.data) + uintptr(dense) * size)
		src := rawptr(uintptr(header.data) + uintptr(last) * size)
		runtime.mem_copy(dst, src, int(header.element_size))
	}
	// Order matters: when the removed entity is the last dense entry, moved ==
	// entity, and the final write below must win so the slot reads as absent.
	header.sparse[moved.index] = slot
	header.sparse[entity.index] = 0
	header.count = last
	return true
}

// _header_add is the type-erased append used by Deferred.flush. It mirrors
// add, including upsert-in-place semantics.
_header_add :: proc(header: ^Set_Header, entity: Entity, value: rawptr) -> bool {
	assert(header != nil, "_header_add: nil header")
	assert(value != nil, "_header_add: nil value")
	assert(entity.index < u32(len(header.sparse)), "_header_add: entity index out of range")
	size := uintptr(header.element_size)
	slot := header.sparse[entity.index]
	if slot != 0 {
		dst := rawptr(uintptr(header.data) + uintptr(slot - 1) * size)
		runtime.mem_copy(dst, value, int(header.element_size))
		return true
	}
	if header.count >= header.capacity do return false
	dense := header.count
	header.entities[dense] = entity
	dst := rawptr(uintptr(header.data) + uintptr(dense) * size)
	runtime.mem_copy(dst, value, int(header.element_size))
	header.sparse[entity.index] = dense + 1
	header.count += 1
	return true
}
