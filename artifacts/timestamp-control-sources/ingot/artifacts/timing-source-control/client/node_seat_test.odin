package main

import "core:math/linalg"
import "core:testing"
import ecs "ingot:ecs"
import shared "../shared"

// The node seat cache must serve unchanged frames without a probe and drop
// its entry when anything the probe depends on changes: the node's own
// transform, the committed collision of its patch, a seam neighbour's
// patch, or the heights revision that moves the probe origin.
@(test)
node_seat_cache_reprobes_only_when_its_key_changes :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, world_create(value), "world create")
	defer {
		planetary_prepare_deinit(&value.planetary_prepare)
		node_seat_cache_deinit(&value.node_seats)
		shared.world_deinit(&value.world)
	}
	value.terrain.world_ref = &value.world
	nodes := &value.world.nodes
	testing.expect(t, ecs.set_len(nodes) > 0, "world has nodes")
	entity := nodes.header.entities[0]
	transform, has_transform := ecs.get(&value.world.transforms, entity)
	testing.expect(t, has_transform)
	cache := &value.node_seats

	first := _node_seated_position(value, entity, transform)
	testing.expect_value(t, cache.misses, u64(1))
	testing.expect_value(t, cache.hits, u64(0))
	casts := value.terrain.surface_probe_casts
	for _ in 0 ..< 5 {
		testing.expect_value(t, _node_seated_position(value, entity, transform), first)
	}
	testing.expect_value(t, cache.hits, u64(5))
	testing.expect_value(t, cache.misses, u64(1))
	testing.expect_value(t, value.terrain.surface_probe_casts, casts)

	// Committed collision replacement of the owning patch invalidates.
	coord := shared.planet_coord_from_direction(linalg.normalize(transform.position))
	value.terrain.patch_collision_revision[_planet_patch_index_for(coord)] += 1
	_ = _node_seated_position(value, entity, transform)
	testing.expect_value(t, cache.misses, u64(2))
	_ = _node_seated_position(value, entity, transform)
	testing.expect_value(t, cache.hits, u64(6))

	// A terraform (heights revision) invalidates.
	value.terrain.heights_revision += 1
	_ = _node_seated_position(value, entity, transform)
	testing.expect_value(t, cache.misses, u64(3))

	// A moved transform invalidates.
	moved := transform^
	moved.position = transform.position * 1.0001
	_ = _node_seated_position(value, entity, &moved)
	testing.expect_value(t, cache.misses, u64(4))
	_ = _node_seated_position(value, entity, &moved)
	testing.expect_value(t, cache.hits, u64(7))

	// A different node has its own entry.
	if ecs.set_len(nodes) > 1 {
		other := nodes.header.entities[1]
		other_transform, ok_other := ecs.get(&value.world.transforms, other)
		testing.expect(t, ok_other)
		_ = _node_seated_position(value, other, other_transform)
		testing.expect_value(t, cache.misses, u64(5))
		testing.expect_value(t, len(cache.seats), 2)
	}
}

// A seam cell's seat depends on every duplicate's patch, so replacing a
// neighbouring face's patch must change the key too.
@(test)
terrain_seat_revision_covers_seam_duplicates :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	edge := shared.Planet_Coord{face = .Pos_X, u = 0, v = shared.PLANET_FACE_CELLS / 2}
	duplicates, count := shared.planet_duplicates(edge)
	testing.expect(t, count > 0, "edge cell has a duplicate")
	before := terrain_seat_revision(terrain, edge)
	terrain.patch_collision_revision[_planet_patch_index_for(duplicates[0])] += 1
	testing.expect(t, terrain_seat_revision(terrain, edge) != before, "duplicate patch changes key")
	interior := shared.Planet_Coord{face = .Pos_X, u = shared.PLANET_FACE_CELLS / 2, v = shared.PLANET_FACE_CELLS / 2}
	interior_before := terrain_seat_revision(terrain, interior)
	terrain.patch_collision_revision[_planet_patch_index_for(edge)] += 1
	testing.expect_value(t, terrain_seat_revision(terrain, interior), interior_before)
}
