// flora_seam_test.odin pins planetforger's cube-sphere flora seam: tile
// mapping from directions, the cross-face streaming window, the tangent-frame
// instance transform, and the radial seat arithmetic.
package main

import shared "../shared"
import "core:math/linalg"
import "core:testing"

@(test)
flora_world_tile_maps_face_direction :: proc(t: ^testing.T) {
	direction := linalg.normalize([3]f32{1, 0, 0})
	tile := flora_world_tile(direction)
	expected := planet_stream_tile(direction)
	testing.expect_value(t, tile.face, i32(expected.face))
	testing.expect(t, tile.tile_u >= 0 && tile.tile_u < i32(PLANET_STREAM_TILES_PER_FACE))
	testing.expect(t, tile.tile_v >= 0 && tile.tile_v < i32(PLANET_STREAM_TILES_PER_FACE))
	// A zero focus (fresh state before the camera seats) must not assert
	// inside planet_locate; it lands on the spawn face.
	fallback := flora_world_tile({0, 0, 0})
	testing.expect(t, flora_tile_eq(fallback, flora_world_tile({1, 0, 0})))
}

@(test)
flora_stream_window_is_full_and_unique_away_from_edges :: proc(t: ^testing.T) {
	center := flora_world_tile(linalg.normalize([3]f32{1, 0, 0}))
	window: [FLORA_STREAM_TILE_COUNT]Flora_Tile_Id
	count := flora_stream_window(center, &window)
	testing.expect_value(t, count, FLORA_STREAM_TILE_COUNT)
	for first in 0 ..< count {
		for second in first + 1 ..< count {
			testing.expect(t, !flora_tile_eq(window[first], window[second]), "window tile duplicated")
		}
	}
}

@(test)
flora_stream_window_crosses_face_edges :: proc(t: ^testing.T) {
	// A centre tile hugging the +X face's u = 0 edge (mid-height, away from
	// the corners) must pull window tiles from the adjacent face.
	edge_cell := shared.Planet_Coord {
		.Pos_X,
		i32(PLANET_STREAM_TILE_CELLS / 2),
		i32(shared.PLANET_FACE_CELLS / 2),
	}
	center := flora_world_tile(shared.planet_direction(edge_cell))
	window: [FLORA_STREAM_TILE_COUNT]Flora_Tile_Id
	count := flora_stream_window(center, &window)
	testing.expect(t, count > 0, "window has tiles")
	foreign_faces := 0
	for index in 0 ..< count {
		if window[index].face != center.face do foreign_faces += 1
	}
	testing.expect(t, foreign_faces > 0, "window crosses onto the adjacent face")
}

@(test)
flora_sphere_transform_aligns_up_to_surface_normal :: proc(t: ^testing.T) {
	direction := linalg.normalize([3]f32{1, 1, 1})
	up, east, north := shared.planet_basis(direction)
	instance := Flora_Instance {
		position  = shared.planet_position(direction, 5),
		direction = direction,
		up        = up,
		east      = east,
		north     = north,
		yaw       = 0,
		cos_yaw   = 1,
		sin_yaw   = 0,
		scale     = 1,
		mesh      = .Conifer_A,
	}
	transform := flora_instance_transform(&instance)
	// Column 2 (model Z in world space) must align with the surface normal.
	column_z := [3]f32{transform[0, 2], transform[1, 2], transform[2, 2]}
	testing.expect(t, linalg.dot(column_z, up) > 0.999, "model Z aligns with surface normal")
	// Translation carries the sphere-surface position through unchanged.
	testing.expect_value(t, transform[0, 3], instance.position.x)
	testing.expect_value(t, transform[1, 3], instance.position.y)
	testing.expect_value(t, transform[2, 3], instance.position.z)
}

// Scatter seats every instance radially: without a physics world the seat is
// the analytic cached height, so the instance's distance from the planet
// centre must equal spawn_height minus the mesh sink, and its stored basis
// must stand on the local surface normal.
@(test)
flora_sphere_scatter_seats_radially_on_the_cached_grid :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain_scatter_prepare(terrain, world)
	flora := new(Flora)
	defer free(flora)
	ruins := new(Ruins)
	defer free(ruins)
	flora.ready = true
	flora_regenerate(flora, terrain, world, ruins)
	testing.expect(t, flora.count > 0, "scatter produced instances")
	for slot in 0 ..< flora.tile_count {
		span := flora.tiles[slot]
		if !span.occupied do continue
		for index in span.large_begin ..< span.ground_end {
			if index >= span.large_end && index < span.ground_begin do continue
			instance := flora.instances[index]
			radial := linalg.length(instance.position) - shared.PLANET_RADIUS
			expected := instance.spawn_height - _flora_sink(instance.mesh) * instance.target_scale
			testing.expectf(
				t,
				abs(radial - expected) < 2e-3,
				"instance %d radial height %v, want %v",
				index,
				radial,
				expected,
			)
			alignment := linalg.dot(instance.up, linalg.normalize(instance.position))
			testing.expectf(
				t,
				alignment > 0.999,
				"instance %d up misaligned with surface normal (dot %v)",
				index,
				alignment,
			)
		}
	}
}
