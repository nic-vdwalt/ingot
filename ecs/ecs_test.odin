#+build !js
package ecs

import "core:testing"

@(test)
generational_reuse_invalidates_stale_handles :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	first, ok_first := create_entity(&pool)
	testing.expect(t, ok_first)
	testing.expect(t, is_alive(&pool, first))
	testing.expect(t, destroy_entity(&pool, first))
	testing.expect(t, !is_alive(&pool, first))
	second, ok_second := create_entity(&pool)
	testing.expect(t, ok_second)
	testing.expect_value(t, second.index, first.index)
	testing.expect(t, second.generation != first.generation)
	testing.expect(t, is_alive(&pool, second))
	testing.expect(t, !is_alive(&pool, first))
	testing.expect(t, !destroy_entity(&pool, first))
}

@(test)
pool_create_respects_capacity :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 2))
	defer pool_deinit(&pool)
	_, ok_a := create_entity(&pool)
	_, ok_b := create_entity(&pool)
	_, ok_c := create_entity(&pool)
	testing.expect(t, ok_a)
	testing.expect(t, ok_b)
	testing.expect(t, !ok_c)
	testing.expect_value(t, alive_count(&pool), 2)
}

@(test)
destroy_removes_entity_from_all_sets :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	positions: Set(f32)
	labels: Set(u64)
	testing.expect(t, set_init(&positions, &pool, 8))
	defer set_deinit(&positions)
	testing.expect(t, set_init(&labels, &pool, 8))
	defer set_deinit(&labels)
	entity, ok := create_entity(&pool)
	testing.expect(t, ok)
	testing.expect(t, add(&positions, entity, 1.5))
	testing.expect(t, add(&labels, entity, 42))
	testing.expect(t, destroy_entity(&pool, entity))
	testing.expect(t, !has(&positions, entity))
	testing.expect(t, !has(&labels, entity))
	testing.expect_value(t, set_len(&positions), 0)
	testing.expect_value(t, set_len(&labels), 0)
}

@(test)
swap_remove_keeps_sparse_dense_integrity :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	values: Set(u32)
	testing.expect(t, set_init(&values, &pool, 8))
	defer set_deinit(&values)
	a, _ := create_entity(&pool)
	b, _ := create_entity(&pool)
	c, _ := create_entity(&pool)
	testing.expect(t, add(&values, a, 10))
	testing.expect(t, add(&values, b, 20))
	testing.expect(t, add(&values, c, 30))
	testing.expect(t, remove(&values, b))
	testing.expect_value(t, set_len(&values), 2)
	testing.expect(t, !has(&values, b))
	value_a, ok_a := get(&values, a)
	testing.expect(t, ok_a)
	testing.expect_value(t, value_a^, 10)
	value_c, ok_c := get(&values, c)
	testing.expect(t, ok_c)
	testing.expect_value(t, value_c^, 30)
	// Removing the last dense entry must leave the slot absent, not aliased.
	testing.expect(t, remove(&values, c))
	testing.expect(t, !has(&values, c))
	testing.expect(t, remove(&values, a))
	testing.expect_value(t, set_len(&values), 0)
	testing.expect(t, !remove(&values, a))
}

@(test)
add_is_upsert_and_respects_capacity :: proc(t: ^testing.T) {
	pool: Entity_Pool
	testing.expect(t, pool_init(&pool, 8))
	defer pool_deinit(&pool)
	values: Set(u32)
	testing.expect(t, set_init(&values, &pool, 2))
	defer set_deinit(&values)
	a, _ := create_entity(&pool)
	b, _ := create_entity(&pool)
	c, _ := create_entity(&pool)
	testing.expect(t, add(&values, a, 1))
	testing.expect(t, add(&values, a, 2))
	testing.expect_value(t, set_len(&values), 1)
	value_a, _ := get(&values, a)
	testing.expect_value(t, value_a^, 2)
	testing.expect(t, add(&values, b, 3))
	testing.expect(t, !add(&values, c, 4))
}
