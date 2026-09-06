#+build !js
package main

import shared "../shared"
import "core:testing"

@(test)
ruins_are_seed_deterministic_and_bounded :: proc(t: ^testing.T) {
	world: shared.World
	testing.expect(t, shared.world_init_seed(&world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&world)
	_, nodes_ok := shared.world_populate_nodes(&world)
	testing.expect(t, nodes_ok)
	first, second: Ruins
	testing.expect(t, ruins_generate(&first, nil, &world, {0, 0}))
	testing.expect(t, ruins_generate(&second, nil, &world, {0, 0}))
	testing.expect_value(t, first.site_count, second.site_count)
	testing.expect_value(t, first.instance_count, second.instance_count)
	testing.expect(t, first.site_count <= RUIN_SITE_MAX)
	testing.expect(t, first.instance_count <= RUIN_INSTANCE_MAX)
	for site, index in first.sites[:first.site_count] do testing.expect_value(t, site, second.sites[index])
	for instance, index in first.instances[:first.instance_count] {
		testing.expect_value(t, instance, second.instances[index])
		testing.expect(t, instance.mesh >= .Ruin_Wall_A && instance.mesh <= .Ruin_Wall_D)
	}
}

@(test)
ruin_sites_are_rare_and_terrain_valid :: proc(t: ^testing.T) {
	world: shared.World
	testing.expect(t, shared.world_init_seed(&world, 117))
	defer shared.world_deinit(&world)
	_, nodes_ok := shared.world_populate_nodes(&world)
	testing.expect(t, nodes_ok)
	ruins: Ruins
	testing.expect(t, ruins_generate(&ruins, nil, &world, {0, 0}))
	testing.expect(t, ruins.site_count <= RUIN_SITE_MAX)
	for site in ruins.sites[:ruins.site_count] {
		grid_x := i32(site.position.x / shared.GRID_CELL_SIZE)
		grid_y := i32(site.position.y / shared.GRID_CELL_SIZE)
		testing.expect(t, shared.grid_in_world(grid_x, grid_y))
		sample := shared.terrain_sample(&world, site.position.x, site.position.y)
		testing.expect(t, sample.slope <= shared.PLACEMENT_MAX_SLOPE * 0.75)
		testing.expect(t, ruins_contains(&ruins, site.position.x, site.position.y, RUIN_CLEARANCE))
	}
}

@(test)
ruin_tiles_are_window_invariant :: proc(t: ^testing.T) {
	world: shared.World
	testing.expect(t, shared.world_init_seed(&world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&world)
	// The same absolute tile generated from two different window centres one
	// tile apart must produce identical sites inside the overlap.
	centered, shifted: Ruins
	testing.expect(t, ruins_generate(&centered, nil, &world, {0, 0}))
	testing.expect(
		t,
		ruins_generate(&shifted, nil, &world, {RUIN_STREAM_TILE_SIZE, 0}),
	)
	overlap_min := -f32(RUIN_STREAM_RADIUS - 1) * RUIN_STREAM_TILE_SIZE
	overlap_max := f32(RUIN_STREAM_RADIUS - 1) * RUIN_STREAM_TILE_SIZE
	for site in centered.sites[:centered.site_count] {
		if site.position.x < overlap_min || site.position.x > overlap_max do continue
		if site.position.y < overlap_min || site.position.y > overlap_max do continue
		found := false
		for other in shifted.sites[:shifted.site_count] {
			if other.key == site.key && other.position == site.position {
				found = true
				break
			}
		}
		testing.expectf(
			t,
			found,
			"site at (%f,%f) missing after window shift",
			site.position.x,
			site.position.y,
		)
	}
}
