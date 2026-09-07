#+build !js
package shared

import "core:mem"
import "core:testing"

_WATERFIELD_TEST_CENTER :: Planet_Coord{.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2}

@(test)
waterfield_initial_volume_is_finite :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	volume := waterfield_total(&world.waterfield)
	testing.expect(t, volume > 0)
	testing.expect(t, volume < u64(PLANET_FIELD_CELLS) * 256)
}

// The fill must flood to the foundation's sea level, not to some arbitrary
// cell's height: every wet cell's surface sits exactly at sea level, and a
// generated world has an actual ocean rather than a puddle.
@(test)
waterfield_initial_fill_floods_to_sea_level :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	level := i64(world.foundation.sea_level)
	wet := 0
	for depth, index in world.waterfield.depths {
		if depth == 0 do continue
		wet += 1
		surface := i64(world.waterfield.ground[index]) + i64(depth)
		if surface != level {
			testing.expectf(t, false, "wet cell %d surface %d != sea level %d", index, surface, level)
			return
		}
	}
	testing.expect(t, wet > PLANET_FIELD_CELLS / 100, "the generated world has an ocean")
}

@(test)
waterfield_ground_cache_refreshes_after_terrain_change :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	center := planet_index(_WATERFIELD_TEST_CENTER)
	before := world.waterfield.ground[center]
	world.heightfield.deltas[center] = TERRAFORM_MAX_DELTA
	waterfield_terrain_changed(&world)
	testing.expect(t, world.waterfield.ground[center] > before)
}

@(test)
waterfield_world_depth_bilinearly_interpolates_and_clamps :: proc(t: ^testing.T) {
	field: Planet_Waterfield
	planet_waterfield_init(&field)
	defer planet_waterfield_deinit(&field)
	center := _WATERFIELD_TEST_CENTER
	center_index := planet_index(center)
	right := planet_neighbour(center, 1, 0)
	below := planet_neighbour(center, 0, 1)
	diagonal := planet_neighbour(center, 1, 1)
	field.depths[center_index] = 0
	field.depths[planet_index(right)] = 4
	field.depths[planet_index(below)] = 8
	field.depths[planet_index(diagonal)] = 12
	testing.expect_value(t, field.depths[center_index], u32(0))
	testing.expect_value(t, field.depths[planet_index(right)], u32(4))
	testing.expect_value(t, field.depths[planet_index(below)], u32(8))
	testing.expect_value(t, field.depths[planet_index(diagonal)], u32(12))
}

@(test)
waterfield_flow_conserves_volume :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	before := waterfield_total(&world.waterfield)
	for tick in u64(0) ..< 24 do _ = waterfield_step(&world, tick)
	testing.expect_value(t, waterfield_total(&world.waterfield), before)
}

// A generated map is filled to a level sea, so the very first step finds
// nothing to move and the field settles. Every later step must then be
// skipped outright: the sweep is 3,690,241 cells on the main thread four
// times a second, and paying it to rediscover equilibrium is the largest
// recurring hitch this sim has.
@(test)
waterfield_settles_and_stops_sweeping :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	testing.expect(t, !world.waterfield.settled, "a fresh field must be armed")
	testing.expect(t, !waterfield_step(&world, 0), "a level sea must not move")
	testing.expect(t, world.waterfield.settled, "an unmoved step must settle the field")
	revision := world.waterfield.revision
	for tick in u64(1) ..< 8 do testing.expect(t, !waterfield_step(&world, tick))
	testing.expect_value(t, world.waterfield.revision, revision)
}

// Settling must never be a one-way door: pouring water into a hollow and
// rearming the flow has to move it again, or a terraformed basin would stay
// dry forever.
@(test)
waterfield_unsettle_rearms_the_flow :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_ = waterfield_step(&world, 0)
	testing.expect(t, world.waterfield.settled, "the level sea must settle first")
	source := planet_index(_WATERFIELD_TEST_CENTER)
	world.waterfield.depths[source] += 64
	waterfield_unsettle(&world.waterfield)
	testing.expect(t, waterfield_step(&world, 1), "a rearmed field with a mound must flow")
	testing.expect(t, world.waterfield.depths[source] < 64, "the mound must spread")
}

// The terrain paths rearm the flow themselves: an edit that raised or dropped
// ground under a settled sea would otherwise leave the water hanging where
// the old ground used to be.
@(test)
waterfield_terrain_changes_rearm_the_flow :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_ = waterfield_step(&world, 0)
	testing.expect(t, world.waterfield.settled, "the level sea must settle first")
	waterfield_terrain_changed(&world)
	testing.expect(t, !world.waterfield.settled, "a full refill must rearm the flow")
	_ = waterfield_step(&world, 1)
	testing.expect(t, world.waterfield.settled, "the refilled field settles again")
	waterfield_terrain_changed_rect(&world, _WATERFIELD_TEST_CENTER, 1)
	testing.expect(t, !world.waterfield.settled, "a rect refill must rearm the flow")
}

@(test)
waterfield_connected_dry_cell_fills_and_source_falls :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	mem.zero_slice(world.waterfield.depths)
	source_coord := _WATERFIELD_TEST_CENTER
	target_coord := planet_neighbour(source_coord, 1, 0)
	source := planet_index(source_coord)
	target := planet_index(target_coord)
	world.heightfield.deltas[source] = 0
	world.heightfield.deltas[target] = -TERRAFORM_MAX_DELTA
	waterfield_terrain_changed(&world)
	world.waterfield.depths[source] = 32
	before := waterfield_total(&world.waterfield)
	source_before := world.waterfield.depths[source]
	for tick in u64(0) ..< 8 do _ = waterfield_step(&world, tick)
	testing.expect(t, world.waterfield.depths[target] > 0)
	testing.expect(t, world.waterfield.depths[source] < source_before)
	testing.expect_value(t, waterfield_total(&world.waterfield), before)
}

@(test)
waterfield_disconnected_hole_stays_dry :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	mem.zero_slice(world.waterfield.depths)
	source_coord := _WATERFIELD_TEST_CENTER
	target_coord := planet_neighbour(source_coord, 2, 0)
	source := planet_index(source_coord)
	target := planet_index(target_coord)
	world.waterfield.depths[source] = 24
	wall_neighbours := [?]Planet_Coord {
		planet_neighbour(target_coord, -1, 0),
		planet_neighbour(target_coord, 1, 0),
		planet_neighbour(target_coord, 0, -1),
		planet_neighbour(target_coord, 0, 1),
	}
	for wall in wall_neighbours {
		world.heightfield.deltas[planet_index(wall)] = TERRAFORM_MAX_DELTA
	}
	world.heightfield.deltas[target] = -TERRAFORM_MAX_DELTA
	waterfield_terrain_changed(&world)
	for tick in u64(0) ..< 8 do _ = waterfield_step(&world, tick)
	testing.expect_value(t, world.waterfield.depths[target], u32(0))
}

@(test)
waterfield_survives_snapshot_roundtrip :: proc(t: ^testing.T) {
	world_a, world_b: World
	testing.expect(t, world_init(&world_a))
	defer world_deinit(&world_a)
	testing.expect(t, world_init(&world_b))
	defer world_deinit(&world_b)
	for tick in u64(0) ..< 5 do _ = waterfield_step(&world_a, tick)
	buffer := make([]u8, world_snapshot_size(&world_a))
	defer delete(buffer)
	_, ok := world_snapshot_write(&world_a, buffer)
	testing.expect(t, ok)
	testing.expect(t, world_snapshot_read(&world_b, buffer))
	_test_expect_slice_equal(t, world_b.waterfield.depths, world_a.waterfield.depths)
	_test_expect_slice_equal(t, world_b.waterfield.ground, world_a.waterfield.ground)
	testing.expect_value(t, world_b.waterfield.revision, world_a.waterfield.revision)
}

// The rect refill must produce the same ground as the full rebuild. After a
// terraform edit the ground array must match a fresh full sweep.
@(test)
waterfield_rect_refill_matches_a_full_refill :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	center := _WATERFIELD_TEST_CENTER
	planet_heightfield_apply(&world.heightfield, center, 1)
	waterfield_terrain_changed_rect(&world, center, TERRAFORM_RADIUS)
	rect_ground := make([]i32, PLANET_FIELD_CELLS)
	defer delete(rect_ground)
	copy(rect_ground, world.waterfield.ground)
	_planet_waterfield_ground_fill(&world)
	_test_expect_slice_equal(t, world.waterfield.ground, rect_ground)
}

// A rect crossing a face edge must land on the adjacent face rather than
// index out of bounds. A brush at a face corner is an ordinary player
// action, not an edge case, so the seam crossing has to hold without an
// assertion firing.
@(test)
waterfield_rect_refill_crosses_the_face_seam :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	last := i32(PLANET_FACE_CELLS)
	before := world.waterfield.revision
	waterfield_terrain_changed_rect(&world, Planet_Coord{.Pos_X, 1, 1}, 4)
	waterfield_terrain_changed_rect(&world, Planet_Coord{.Pos_X, last - 1, last - 1}, 8)
	testing.expect_value(t, world.waterfield.revision, before + 2)
}
