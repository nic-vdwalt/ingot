#+build !js
package ecs

import "core:testing"

@(test)
snapshot_round_trip_restores_identical_bytes :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 16))
	defer pool_deinit(&pool)
	positions: Set(f32)
	labels: Set(u64)
	testing.expect(t, set_init(&positions, &pool, 16))
	defer set_deinit(&positions)
	testing.expect(t, set_init(&labels, &pool, 16))
	defer set_deinit(&labels)
	entities: [6]Entity
	for index in 0 ..< 6 {
		entity, ok := create_entity(&pool)
		testing.expect(t, ok)
		entities[index] = entity
		testing.expect(t, add(&positions, entity, f32(index) * 1.5))
		if index % 2 == 0 do testing.expect(t, add(&labels, entity, u64(index) * 100))
	}
	// Exercise swap-remove and generational churn before the first snapshot.
	testing.expect(t, destroy_entity(&pool, entities[2]))
	testing.expect(t, remove(&positions, entities[4]))
	first := make([]u8, snapshot_size(&pool))
	defer delete(first)
	written_first, ok_first := snapshot_write(&pool, first)
	testing.expect(t, ok_first)
	testing.expect_value(t, written_first, len(first))
	// Mutate the world, then restore and verify state and bytes both match.
	replacement, ok_new := create_entity(&pool)
	testing.expect(t, ok_new)
	testing.expect(t, add(&positions, replacement, 99.0))
	testing.expect(t, destroy_entity(&pool, entities[0]))
	testing.expect(t, snapshot_read(&pool, first))
	testing.expect(t, is_alive(&pool, entities[0]))
	testing.expect(t, !is_alive(&pool, entities[2]))
	value, ok_value := get(&positions, entities[1])
	testing.expect(t, ok_value)
	testing.expect_value(t, value^, 1.5)
	testing.expect(t, !has(&positions, entities[4]))
	second := make([]u8, snapshot_size(&pool))
	defer delete(second)
	written_second, ok_second := snapshot_write(&pool, second)
	testing.expect(t, ok_second)
	testing.expect_value(t, written_second, written_first)
	for byte_index in 0 ..< len(first) {
		if first[byte_index] != second[byte_index] {
			testing.expectf(t, false, "snapshot bytes differ at offset %d", byte_index)
			return
		}
	}
}

@(test)
snapshot_read_rejects_corrupt_input :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	values: Set(u32)
	testing.expect(t, set_init(&values, &pool, 8))
	defer set_deinit(&values)
	entity, ok := create_entity(&pool)
	testing.expect(t, ok)
	testing.expect(t, add(&values, entity, 7))
	buffer := make([]u8, snapshot_size(&pool))
	defer delete(buffer)
	_, ok_write := snapshot_write(&pool, buffer)
	testing.expect(t, ok_write)
	// Truncated buffer must fail cleanly.
	testing.expect(t, !snapshot_read(&pool, buffer[:len(buffer) - 1]))
	// Corrupt magic must fail cleanly.
	corrupt := make([]u8, len(buffer))
	defer delete(corrupt)
	copy(corrupt, buffer)
	corrupt[0] = 0xFF
	testing.expect(t, !snapshot_read(&pool, corrupt))
	// A pristine buffer still restores after the failures above.
	testing.expect(t, snapshot_read(&pool, buffer))
	restored, ok_restored := get(&values, entity)
	testing.expect(t, ok_restored)
	testing.expect_value(t, restored^, 7)
}

@(test)
snapshot_write_fails_on_short_buffer :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 4))
	defer pool_deinit(&pool)
	entity, ok := create_entity(&pool)
	testing.expect(t, ok)
	testing.expect(t, is_alive(&pool, entity))
	short_buffer := make([]u8, snapshot_size(&pool) - 1)
	defer delete(short_buffer)
	_, ok_write := snapshot_write(&pool, short_buffer)
	testing.expect(t, !ok_write)
}
