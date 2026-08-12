#+build !js
package ecs

import "core:testing"

@(test)
iter2_yields_exact_intersection :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 16))
	defer pool_deinit(&pool)
	positions: Set(f32)
	speeds: Set(u32)
	testing.expect(t, set_init(&positions, &pool, 16))
	defer set_deinit(&positions)
	testing.expect(t, set_init(&speeds, &pool, 16))
	defer set_deinit(&speeds)
	both_count := 0
	for index in 0 ..< 9 {
		entity, ok := create_entity(&pool)
		testing.expect(t, ok)
		// Thirds: position only, speed only, both.
		if index % 3 == 0 do testing.expect(t, add(&positions, entity, f32(index)))
		if index % 3 == 1 do testing.expect(t, add(&speeds, entity, u32(index)))
		if index % 3 == 2 {
			testing.expect(t, add(&positions, entity, f32(index)))
			testing.expect(t, add(&speeds, entity, u32(index)))
			both_count += 1
		}
	}
	seen := 0
	it := iter2(&positions, &speeds)
	for {
		entity, position, speed, ok := iter2_next(&it)
		if !ok do break
		testing.expect(t, is_alive(&pool, entity))
		testing.expect_value(t, u32(position^), speed^)
		seen += 1
	}
	testing.expect_value(t, seen, both_count)
}

@(test)
iter3_and_iter4_match_membership :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 16))
	defer pool_deinit(&pool)
	a_set: Set(u8)
	b_set: Set(u16)
	c_set: Set(u32)
	d_set: Set(u64)
	testing.expect(t, set_init(&a_set, &pool, 16))
	defer set_deinit(&a_set)
	testing.expect(t, set_init(&b_set, &pool, 16))
	defer set_deinit(&b_set)
	testing.expect(t, set_init(&c_set, &pool, 16))
	defer set_deinit(&c_set)
	testing.expect(t, set_init(&d_set, &pool, 16))
	defer set_deinit(&d_set)
	full, ok_full := create_entity(&pool)
	testing.expect(t, ok_full)
	partial, ok_partial := create_entity(&pool)
	testing.expect(t, ok_partial)
	testing.expect(t, add(&a_set, full, 1))
	testing.expect(t, add(&b_set, full, 2))
	testing.expect(t, add(&c_set, full, 3))
	testing.expect(t, add(&d_set, full, 4))
	testing.expect(t, add(&a_set, partial, 1))
	testing.expect(t, add(&b_set, partial, 2))
	testing.expect(t, add(&c_set, partial, 3))
	seen3 := 0
	it3 := iter3(&a_set, &b_set, &c_set)
	for {
		_, _, _, _, ok := iter3_next(&it3)
		if !ok do break
		seen3 += 1
	}
	testing.expect_value(t, seen3, 2)
	seen4 := 0
	it4 := iter4(&a_set, &b_set, &c_set, &d_set)
	for {
		entity, _, _, _, _, ok := iter4_next(&it4)
		if !ok do break
		testing.expect_value(t, entity, full)
		seen4 += 1
	}
	testing.expect_value(t, seen4, 1)
}

@(test)
deferred_flush_replays_in_record_order :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	values: Set(u32)
	testing.expect(t, set_init(&values, &pool, 8))
	defer set_deinit(&values)
	deferred: Deferred
	testing.expect(t, deferred_init(&deferred, 16, 256))
	defer deferred_deinit(&deferred)
	a, _ := create_entity(&pool)
	b, _ := create_entity(&pool)
	testing.expect(t, add(&values, a, 1))
	// Record order: add b, overwrite b, remove a, destroy b.
	testing.expect(t, defer_add(&deferred, &values, b, 10))
	testing.expect(t, defer_add(&deferred, &values, b, 20))
	testing.expect(t, defer_remove(&deferred, &values, a))
	testing.expect(t, defer_destroy(&deferred, b))
	flush(&pool, &deferred)
	testing.expect(t, !has(&values, a))
	testing.expect(t, is_alive(&pool, a))
	testing.expect(t, !is_alive(&pool, b))
	testing.expect_value(t, set_len(&values), 0)
	testing.expect_value(t, deferred.command_count, 0)
	testing.expect_value(t, deferred.payload_used, 0)
}

@(test)
deferred_skips_stale_entities_and_bounds_capacity :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	values: Set(u32)
	testing.expect(t, set_init(&values, &pool, 8))
	defer set_deinit(&values)
	deferred: Deferred
	testing.expect(t, deferred_init(&deferred, 2, 8))
	defer deferred_deinit(&deferred)
	a, _ := create_entity(&pool)
	testing.expect(t, defer_add(&deferred, &values, a, 1))
	testing.expect(t, defer_destroy(&deferred, a))
	// Command buffer is full now.
	testing.expect(t, !defer_destroy(&deferred, a))
	flush(&pool, &deferred)
	testing.expect(t, !is_alive(&pool, a))
	// Add recorded for an entity destroyed before flush must not resurrect it.
	testing.expect(t, defer_add(&deferred, &values, a, 2))
	flush(&pool, &deferred)
	testing.expect_value(t, set_len(&values), 0)
	// Payload arena bound: a u32 add needs 4 bytes; 3 adds exceed 8.
	b, _ := create_entity(&pool)
	testing.expect(t, defer_add(&deferred, &values, b, 1))
	testing.expect(t, defer_add(&deferred, &values, b, 2))
	testing.expect(t, !defer_add(&deferred, &values, b, 3))
}
