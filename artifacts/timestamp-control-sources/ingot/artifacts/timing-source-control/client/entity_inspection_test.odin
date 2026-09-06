#+build !js
package main

import "core:testing"
import ecs "ingot:ecs"

@(test)
entity_query_registry_finds_and_repairs_proxy_indices :: proc(t: ^testing.T) {
	queries := new(Entity_Queries)
	defer free(queries)
	first := ecs.Entity{index = 2, generation = 1}
	second := ecs.Entity{index = 5, generation = 3}
	queries.proxies[0].entity = first
	queries.proxies[1].entity = second
	queries.entity_to_proxy = make(map[ecs.Entity]int)
	defer delete(queries.entity_to_proxy)
	queries.entity_to_proxy[first] = 0
	queries.entity_to_proxy[second] = 1
	queries.count = 2
	index, found := entity_query_proxy_index(queries, second)
	testing.expect(t, found)
	testing.expect_value(t, index, 1)
	_, found = entity_query_proxy_index(queries, ecs.Entity{index = 9, generation = 1})
	testing.expect(t, !found)
	queries.proxies[0] = queries.proxies[1]
	queries.entity_to_proxy[second] = 0
	index, found = entity_query_proxy_index(queries, second)
	testing.expect(t, found)
	testing.expect_value(t, index, 0)
}

@(test)
entity_query_bounds_hash_is_stable_and_sensitive :: proc(t: ^testing.T) {
	first := Bounds_3D{min = {-1, -2, -3}, max = {1, 2, 3}}
	second := Bounds_3D{min = {-1, -2, -3}, max = {1, 2, 4}}
	testing.expect_value(t, entity_query_bounds_hash(first), entity_query_bounds_hash(first))
	testing.expect(t, entity_query_bounds_hash(first) != entity_query_bounds_hash(second))
}
