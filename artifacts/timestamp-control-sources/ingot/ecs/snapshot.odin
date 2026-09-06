package ecs

import "base:runtime"

// Snapshots blit the pool's liveness state and every registered set's dense
// arrays into a caller-provided buffer. The format is versioned but not
// endian-converted: it targets save-state and same-architecture replication.
// Byte determinism holds because dense order is a pure function of the
// operation sequence (adds append, removes swap from the back, upserts stay
// in place) and sets serialize in registration order.

ECS_SNAPSHOT_MAGIC :: u32(0x49_45_43_53) // "SCEI" little-endian, reads "IECS".
ECS_SNAPSHOT_VERSION :: u32(1)

// snapshot_size returns the exact byte count snapshot_write will produce for
// the pool's current state.
snapshot_size :: proc(pool: ^Entity_Pool) -> int {
	assert(pool != nil, "snapshot_size: nil pool")
	assert(pool.capacity > 0, "snapshot_size: pool not initialised")
	size := 7 * size_of(u32)
	size += int(pool.next_index) * size_of(u32) // generations
	size += int(pool.next_index) // alive flags, one byte each
	size += int(pool.free_count) * size_of(u32)
	for set_index in 0 ..< pool.set_count {
		header := pool.sets[set_index]
		size += 2 * size_of(u32)
		size += int(header.count) * size_of(Entity)
		size += int(header.count) * int(header.element_size)
	}
	return size
}

snapshot_write :: proc(pool: ^Entity_Pool, buffer: []u8) -> (written: int, ok: bool) {
	assert(pool != nil, "snapshot_write: nil pool")
	assert(pool.capacity > 0, "snapshot_write: pool not initialised")
	cursor := 0
	if !_write_u32(buffer, &cursor, ECS_SNAPSHOT_MAGIC) do return 0, false
	if !_write_u32(buffer, &cursor, ECS_SNAPSHOT_VERSION) do return 0, false
	if !_write_u32(buffer, &cursor, pool.capacity) do return 0, false
	if !_write_u32(buffer, &cursor, pool.next_index) do return 0, false
	if !_write_u32(buffer, &cursor, pool.free_count) do return 0, false
	if !_write_u32(buffer, &cursor, pool.alive_count) do return 0, false
	if !_write_u32(buffer, &cursor, pool.set_count) do return 0, false
	generations_size := int(pool.next_index) * size_of(u32)
	if !_write_bytes(buffer, &cursor, raw_data(pool.generations), generations_size) {
		return 0, false
	}
	if !_write_bytes(buffer, &cursor, raw_data(pool.alive), int(pool.next_index)) {
		return 0, false
	}
	free_size := int(pool.free_count) * size_of(u32)
	if !_write_bytes(buffer, &cursor, raw_data(pool.free_list), free_size) do return 0, false
	for set_index in 0 ..< pool.set_count {
		header := pool.sets[set_index]
		if !_write_u32(buffer, &cursor, header.count) do return 0, false
		if !_write_u32(buffer, &cursor, header.element_size) do return 0, false
		entities_size := int(header.count) * size_of(Entity)
		if !_write_bytes(buffer, &cursor, raw_data(header.entities), entities_size) {
			return 0, false
		}
		data_size := int(header.count) * int(header.element_size)
		if !_write_bytes(buffer, &cursor, header.data, data_size) do return 0, false
	}
	assert(cursor == snapshot_size(pool), "snapshot_write: size mismatch")
	return cursor, true
}

// snapshot_read restores a pool and its registered sets from a buffer written
// by snapshot_write. The pool and sets must already be initialised with the
// same capacities and registration order as the writer. Validation failures
// return false (untrusted input is an operating condition); the pool may be
// partially overwritten on failure, so callers should treat false as fatal
// for that world instance.
snapshot_read :: proc(pool: ^Entity_Pool, buffer: []u8) -> bool {
	assert(pool != nil, "snapshot_read: nil pool")
	assert(pool.capacity > 0, "snapshot_read: pool not initialised")
	cursor := 0
	header_values: [7]u32
	for &value in header_values {
		if !_read_u32(buffer, &cursor, &value) do return false
	}
	if header_values[0] != ECS_SNAPSHOT_MAGIC do return false
	if header_values[1] != ECS_SNAPSHOT_VERSION do return false
	if header_values[2] != pool.capacity do return false
	next_index := header_values[3]
	free_count := header_values[4]
	saved_alive_count := header_values[5]
	if header_values[6] != pool.set_count do return false
	if next_index > pool.capacity || free_count > pool.capacity do return false
	if saved_alive_count > next_index do return false
	// Reset all liveness state first so slots beyond the snapshot's high-water
	// mark return to their init state; restored bytes then overwrite the rest.
	for index in 0 ..< pool.capacity {
		pool.generations[index] = 1
		pool.alive[index] = false
	}
	generations_size := int(next_index) * size_of(u32)
	if !_read_bytes(buffer, &cursor, raw_data(pool.generations), generations_size) do return false
	if !_read_bytes(buffer, &cursor, raw_data(pool.alive), int(next_index)) do return false
	free_size := int(free_count) * size_of(u32)
	if !_read_bytes(buffer, &cursor, raw_data(pool.free_list), free_size) do return false
	pool.next_index = next_index
	pool.free_count = free_count
	pool.alive_count = saved_alive_count
	for set_index in 0 ..< pool.set_count {
		if !_snapshot_read_set(pool, pool.sets[set_index], buffer, &cursor) do return false
	}
	return cursor == len(buffer)
}

_snapshot_read_set :: proc(
	pool: ^Entity_Pool,
	header: ^Set_Header,
	buffer: []u8,
	cursor: ^int,
) -> bool {
	assert(pool != nil && header != nil, "_snapshot_read_set: nil argument")
	assert(cursor != nil, "_snapshot_read_set: nil cursor")
	count: u32
	element_size: u32
	if !_read_u32(buffer, cursor, &count) do return false
	if !_read_u32(buffer, cursor, &element_size) do return false
	if element_size != header.element_size do return false
	if count > header.capacity do return false
	entities_size := int(count) * size_of(Entity)
	if !_read_bytes(buffer, cursor, raw_data(header.entities), entities_size) do return false
	data_size := int(count) * int(element_size)
	if !_read_bytes(buffer, cursor, header.data, data_size) do return false
	header.count = count
	// Rebuild the sparse index from the restored dense arrays; every dense
	// entity must be in range and alive, otherwise the snapshot is corrupt.
	for &slot in header.sparse do slot = 0
	for dense in 0 ..< count {
		entity := header.entities[dense]
		if entity.index >= pool.capacity do return false
		if !pool.alive[entity.index] do return false
		if header.sparse[entity.index] != 0 do return false
		header.sparse[entity.index] = dense + 1
	}
	return true
}

_write_u32 :: proc(buffer: []u8, cursor: ^int, value: u32) -> bool {
	assert(cursor != nil, "_write_u32: nil cursor")
	assert(cursor^ >= 0, "_write_u32: negative cursor")
	value_copy := value
	return _write_bytes(buffer, cursor, &value_copy, size_of(u32))
}

_write_bytes :: proc(buffer: []u8, cursor: ^int, source: rawptr, size: int) -> bool {
	assert(cursor != nil, "_write_bytes: nil cursor")
	assert(size >= 0, "_write_bytes: negative size")
	if size == 0 do return true
	assert(source != nil, "_write_bytes: nil source with nonzero size")
	if cursor^ + size > len(buffer) do return false
	runtime.mem_copy(raw_data(buffer[cursor^:]), source, size)
	cursor^ += size
	return true
}

_read_u32 :: proc(buffer: []u8, cursor: ^int, value: ^u32) -> bool {
	assert(cursor != nil, "_read_u32: nil cursor")
	assert(value != nil, "_read_u32: nil value")
	return _read_bytes(buffer, cursor, value, size_of(u32))
}

_read_bytes :: proc(buffer: []u8, cursor: ^int, destination: rawptr, size: int) -> bool {
	assert(cursor != nil, "_read_bytes: nil cursor")
	assert(size >= 0, "_read_bytes: negative size")
	if size == 0 do return true
	assert(destination != nil, "_read_bytes: nil destination with nonzero size")
	if cursor^ + size > len(buffer) do return false
	runtime.mem_copy(destination, raw_data(buffer[cursor^:]), size)
	cursor^ += size
	return true
}
