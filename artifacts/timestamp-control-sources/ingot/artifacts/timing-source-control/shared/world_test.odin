package shared

import "core:testing"
import ecs "ingot:ecs"

@(test)
world_net_index_tracks_spawn_destroy_and_slot_reuse :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	coord := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	entity, spawned := spawn_resource_node(world, coord, .Ore, 150)
	testing.expect(t, spawned)
	net_id, has_id := world_net_id_for_entity(world, entity)
	testing.expect(t, has_id)
	resolved, found := world_entity_by_net_id(world, net_id)
	testing.expect(t, found)
	testing.expect_value(t, resolved, entity)
	testing.expect(t, world_destroy_entity(world, entity))
	_, found = world_entity_by_net_id(world, net_id)
	testing.expect(t, !found)
	replacement, created := ecs.create_entity(&world.pool)
	testing.expect(t, created)
	testing.expect(t, replacement != entity)
	_, found = world_entity_by_net_id(world, net_id)
	testing.expect(t, !found)
}

@(test)
world_snapshot_rebuilds_stable_identity_index :: proc(t: ^testing.T) {
	source := new(World)
	target := new(World)
	defer free(source)
	defer free(target)
	testing.expect(t, world_init(source))
	defer world_deinit(source)
	testing.expect(t, world_init(target))
	defer world_deinit(target)
	coord := Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}
	entity, spawned := spawn_resource_node(source, coord, .Energy, 200)
	testing.expect(t, spawned)
	net_id, has_id := world_net_id_for_entity(source, entity)
	testing.expect(t, has_id)
	buffer := make([]u8, world_snapshot_size(source))
	defer delete(buffer)
	_, written := world_snapshot_write(source, buffer)
	testing.expect(t, written)
	testing.expect(t, world_snapshot_read(target, buffer))
	resolved, found := world_entity_by_net_id(target, net_id)
	testing.expect(t, found)
	resolved_id, has_resolved_id := world_net_id_for_entity(target, resolved)
	testing.expect(t, has_resolved_id)
	testing.expect_value(t, resolved_id, net_id)
}
