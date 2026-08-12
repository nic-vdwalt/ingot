package ecs

import "base:runtime"

// Deferred is a bounded command buffer for structural changes recorded while
// query iterators are live. Systems record destroy/remove/add during
// iteration; the sim flushes between systems, so dense arrays never move
// under an iterator. Commands replay in record order.
Deferred :: struct {
	commands:      []Deferred_Command,
	command_count: u32,
	payload:       []u8,
	payload_used:  u32,
	allocator:     runtime.Allocator,
}

Deferred_Kind :: enum u8 {
	Destroy,
	Remove,
	Add,
}

Deferred_Command :: struct {
	kind:           Deferred_Kind,
	entity:         Entity,
	set:            ^Set_Header,
	payload_offset: u32,
	payload_size:   u32,
}

deferred_init :: proc(
	deferred: ^Deferred,
	max_commands: u32,
	payload_capacity: u32,
	allocator := context.allocator,
) -> bool {
	assert(deferred != nil, "deferred_init: nil deferred")
	assert(max_commands > 0, "deferred_init: zero command capacity")
	assert(payload_capacity > 0, "deferred_init: zero payload capacity")
	deferred^ = {}
	deferred.commands = make([]Deferred_Command, max_commands, allocator)
	deferred.payload = make([]u8, payload_capacity, allocator)
	if deferred.commands == nil || deferred.payload == nil {
		deferred.allocator = allocator
		deferred_deinit(deferred)
		return false
	}
	deferred.allocator = allocator
	return true
}

deferred_deinit :: proc(deferred: ^Deferred) {
	assert(deferred != nil, "deferred_deinit: nil deferred")
	delete(deferred.commands, deferred.allocator)
	delete(deferred.payload, deferred.allocator)
	deferred^ = {}
}

defer_destroy :: proc(deferred: ^Deferred, entity: Entity) -> bool {
	assert(deferred != nil, "defer_destroy: nil deferred")
	assert(len(deferred.commands) > 0, "defer_destroy: deferred not initialised")
	if deferred.command_count >= u32(len(deferred.commands)) do return false
	deferred.commands[deferred.command_count] = Deferred_Command {
		kind   = .Destroy,
		entity = entity,
	}
	deferred.command_count += 1
	return true
}

defer_remove :: proc(deferred: ^Deferred, set: ^Set($T), entity: Entity) -> bool {
	assert(deferred != nil, "defer_remove: nil deferred")
	assert(set != nil, "defer_remove: nil set")
	if deferred.command_count >= u32(len(deferred.commands)) do return false
	deferred.commands[deferred.command_count] = Deferred_Command {
		kind   = .Remove,
		entity = entity,
		set    = &set.header,
	}
	deferred.command_count += 1
	return true
}

// defer_add copies the component bytes into the payload arena so the value
// survives until flush regardless of what the recording system does next.
defer_add :: proc(deferred: ^Deferred, set: ^Set($T), entity: Entity, value: T) -> bool {
	assert(deferred != nil, "defer_add: nil deferred")
	assert(set != nil, "defer_add: nil set")
	if deferred.command_count >= u32(len(deferred.commands)) do return false
	size := u32(size_of(T))
	if deferred.payload_used + size > u32(len(deferred.payload)) do return false
	value_copy := value
	runtime.mem_copy(raw_data(deferred.payload[deferred.payload_used:]), &value_copy, int(size))
	deferred.commands[deferred.command_count] = Deferred_Command {
		kind           = .Add,
		entity         = entity,
		set            = &set.header,
		payload_offset = deferred.payload_used,
		payload_size   = size,
	}
	deferred.payload_used += size
	deferred.command_count += 1
	return true
}

// flush replays commands in record order and resets the buffer. Commands
// targeting entities that died earlier in the same flush (or were already
// stale when recorded) are skipped: that is an expected operating condition
// of deferred recording, not a programmer error.
flush :: proc(pool: ^Entity_Pool, deferred: ^Deferred) {
	assert(pool != nil, "flush: nil pool")
	assert(deferred != nil, "flush: nil deferred")
	assert(deferred.command_count <= u32(len(deferred.commands)), "flush: count exceeds capacity")
	for command_index in 0 ..< deferred.command_count {
		command := deferred.commands[command_index]
		switch command.kind {
		case .Destroy:
			_ = destroy_entity(pool, command.entity)
		case .Remove:
			if is_alive(pool, command.entity) {
				_ = _header_remove(command.set, command.entity)
			}
		case .Add:
			if is_alive(pool, command.entity) {
				assert(
					command.payload_size == command.set.element_size,
					"flush: payload size mismatch",
				)
				payload := raw_data(deferred.payload[command.payload_offset:])
				// A full set drops the add; the recording site already had its
				// chance to observe capacity via the defer_add return value.
				_ = _header_add(command.set, command.entity, payload)
			}
		}
	}
	deferred.command_count = 0
	deferred.payload_used = 0
}
