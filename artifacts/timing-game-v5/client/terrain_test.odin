#+build !js
package main

import shared "../shared"
import "core:strings"
import "core:testing"
import "core:time"
import "ingot:asset"
import rl "ingot:gfx"
import procgen "ingot:procgen"

@(test)
terrain_water_physics_uses_resolved_raised_bed_surface :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	testing.expect(t, shared.world_init_seed(&value.world, shared.TERRAIN_SEED))
	defer shared.world_deinit(&value.world)
	renderer := &value.terrain.ocean
	ocean_surf_fixture_init(&renderer.nearshore, {1, 0, 0}, .Deep)
	for index in 0 ..< OCEAN_NEARSHORE_COUNT {
		renderer.nearshore.bathymetry[index] = 3
		renderer.nearshore.state[index].depth = 0.5
	}
	debug_ocean_fixture_query_update(renderer)
	sample := world_water_physics_sample(value, &renderer.render_query, {1083.25, 0, 0}, 0)
	testing.expect(t, sample.wet)
	testing.expect_value(t, sample.surface, [3]f32{1083.5, 0, 0})
	testing.expect_value(t, sample.depth, f32(0.5))
	testing.expect_value(t, sample.normal, [3]f32{1, 0, 0})
	for &cell in renderer.nearshore.state do cell.depth = 0
	dry := world_water_physics_sample(value, &renderer.render_query, {1083.25, 0, 0}, 0)
	testing.expect(t, !dry.wet)
	outside, outside_wet := ocean_nearshore_surface_sample(&renderer.nearshore, {-1080, 0, 0})
	testing.expect(t, !outside_wet)
	testing.expect_value(t, outside.blend, f32(0))
}

@(test)
terrain_fixture_water_physics_does_not_require_world_or_background_waves :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	renderer := &value.terrain.ocean
	ocean_surf_fixture_init(&renderer.nearshore, {1, 0, 0}, .Deep)
	query := Ocean_Macro_Wave_Query{}
	query.ready = true
	query.packet_count = 1
	query.packet_ids[0] = 123
	query.packets[0] = {
		id = 123,
		center = {1080, 0, 0},
		direction = renderer.nearshore.east,
		significant_height = 20,
		period = 8,
		front_speed = 4,
		envelope_length = 100,
		envelope_width = 80,
		band = 100,
	}
	renderer.macro.spectrum.significant_height = 20
	center := world_water_physics_sample(value, &query, {1080, 0, 0}, 17)
	testing.expect(t, center.wet)
	testing.expect_value(t, center.surface, [3]f32{1080, 0, 0})
	testing.expect_value(t, center.velocity, [3]f32{})
	corner_position := ocean_nearshore_boundary_position(&renderer.nearshore, 94, 94)
	corner := world_water_physics_sample(value, &query, corner_position, 17)
	testing.expect(t, corner.wet, "rendered square corners must support buoyancy")
	outside := world_water_physics_sample(value, &query, {-1080, 0, 0}, 17)
	testing.expect(t, !outside.wet)
	for &cell in renderer.nearshore.state do cell.depth = 0
	dry := world_water_physics_sample(value, &query, {1080, 0, 0}, 17)
	testing.expect(t, !dry.wet)
}

@(test)
terrain_shader_preserves_surface_detail_on_the_nightside :: proc(t: ^testing.T) {
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "let fog_daylight = planet_solar_factor(up, light);"),
	)
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "let night_fog = vec3<f32>(0.035, 0.055, 0.105);"),
	)
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "let local_level = mix(0.40, 1.0, planet_solar_factor"),
	)
	testing.expect(t, strings.contains(TERRAIN_SHADER, "let material_footprint = max("))
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "let material_resolved = 1.0 - smoothstep(0.75, 2.0"),
	)
	testing.expect(
		t,
		strings.contains(
			TERRAIN_SHADER,
			"let sunlight_detail = mix(0.20, 1.0, planet_solar_factor",
		),
	)
	testing.expect(t, strings.contains(TERRAIN_SHADER, "top * mapped_detail * sunlight_detail"))
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "planet_ambient_light(normal, radial, light)"),
	)
	testing.expect(
		t,
		strings.contains(TERRAIN_SHADER, "planet_direct_light(normal, radial, light)"),
	)
	testing.expect(t, strings.contains(TERRAIN_SHADER, "planet_moon_light(normal, radial, light)"))
	testing.expect(t, !strings.contains(TERRAIN_SHADER, "moon_direction = -light"))
	testing.expect(t, strings.contains(TERRAIN_SHADER, "return underwater_apply(fogged"))
}

@(test)
material_weights_keep_warm_mountains_rocky_and_cold_mountains_snowy :: proc(t: ^testing.T) {
	warm_rock, warm_snow := terrain_material_weights(0.8, 0)
	cold_rock, cold_snow := terrain_material_weights(0.8, 1)
	testing.expect(t, warm_rock > warm_snow)
	testing.expect(t, cold_snow > warm_snow)
	testing.expect(t, cold_rock > 0, "steep snowy terrain retains exposed rock")
}

@(test)
rocky_coast_weight_preserves_sheltered_sand_and_exposed_rock :: proc(t: ^testing.T) {
	sheltered := terrain_rocky_coast_weight(.Coast, 0.5, 0, 0.05, 0.1)
	exposed := terrain_rocky_coast_weight(.Coast, 0.5, 0, 0.7, 0.9)
	inland := terrain_rocky_coast_weight(.Coast, 5, 0, 0.7, 0.9)
	non_coast := terrain_rocky_coast_weight(.Mountain, 0.5, 0, 0.7, 0.9)
	testing.expect(t, sheltered < 0.1)
	testing.expect(t, exposed > 0.8)
	testing.expect(t, inland < exposed)
	testing.expect_value(t, non_coast, f32(0))
}

@(test)
flora_ground_colour_requires_authoritative_cover :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	shared.flora_ecology_sterilize(&world.flora_ecology)
	direction := shared.planet_sim_direction({.Pos_X, 12, 12})
	_, sterile_cover := _flora_ground_color(world, direction)
	testing.expect_value(t, sterile_cover, f32(0))
	testing.expect(t, shared.flora_ecology_inoculate(&world.flora_ecology, world))
	occupied := -1
	for cell, index in world.flora_ecology.cells {
		if cell.cohorts[0].lineage != shared.Lineage_Id(0) {
			occupied = index
			break
		}
	}
	testing.expect(t, occupied >= 0)
	direction = shared.planet_sim_direction(shared.planet_sim_coord_for_index(occupied))
	_, living_cover := _flora_ground_color(world, direction)
	testing.expect(t, living_cover > 0 && living_cover < 1)
}

@(test)
terrain_material_revision_tracks_flora_and_climate :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world), "world init")
	defer shared.world_deinit(world)
	initial := terrain_material_revision(world)
	world.flora_ecology.revision += 1
	testing.expect(t, terrain_material_revision(world) != initial)
	flora_revision := terrain_material_revision(world)
	world.planetary.climate.surface_revision += 1
	testing.expect(t, terrain_material_revision(world) != flora_revision)
}

// The loading screen gates the Playing transition on this: a mid-bake
// entry into gameplay forces long frames while climate rows bake.
@(test)
terrain_gameplay_bake_budget_is_submillisecond_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, TERRAIN_BAKE_GAMEPLAY_STRIPE_ROWS, i32(1))
	testing.expect_value(t, TERRAIN_BAKE_BUDGET, time.Millisecond)
}

@(test)
terrain_material_bake_pending_tracks_rows_and_upload :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	// Zeroed terrain: not ready, so the bake is pending by definition.
	testing.expect(t, terrain_material_bake_pending(terrain))
	terrain.ready = true
	testing.expect(t, terrain_material_bake_pending(terrain))
	terrain.climate_row = PLANET_ALBEDO_ROWS
	testing.expect(t, terrain_material_bake_pending(terrain))
	terrain.albedo_row = PLANET_ALBEDO_ROWS
	terrain.upload_faces[3] = true
	testing.expect(t, terrain_material_bake_pending(terrain))
	terrain.upload_faces[3] = false
	testing.expect(t, !terrain_material_bake_pending(terrain))
}

@(test)
terrain_material_revisions_debounce_and_coalesce :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	terrain.albedo_row = PLANET_ALBEDO_ROWS
	terrain.albedo_min_row = PLANET_ALBEDO_ROWS
	terrain.albedo_max_row = -1
	terrain.surface_revision = 3
	terrain.surface_target_revision = 3
	terrain.surface_observed_revision = 3

	terrain_material_revision_update(terrain, 7)
	testing.expect_value(t, terrain.surface_observed_revision, u64(7))
	testing.expect_value(t, terrain.surface_target_revision, u64(3))
	testing.expect_value(t, terrain.albedo_min_row, i32(PLANET_ALBEDO_ROWS))
	for _ in 0 ..< TERRAIN_CLIMATE_REVISION_QUIET_FRAMES {
		terrain_material_revision_update(terrain, 7)
	}
	testing.expect_value(t, terrain.surface_target_revision, u64(7))
	testing.expect_value(t, terrain.albedo_min_row, i32(0))
	testing.expect_value(t, terrain.albedo_max_row, i32(PLANET_ALBEDO_ROWS - 1))

	terrain_material_revision_update(terrain, 8)
	testing.expect_value(t, terrain.surface_target_revision, u64(7))
	testing.expect_value(t, terrain.surface_observed_revision, u64(8))
}

@(test)
terrain_tectonic_revision_marks_published_tiles :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, 5151))
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.ready = true
	terrain.albedo_min_row = PLANET_ALBEDO_ROWS
	terrain.albedo_max_row = -1
	world.planetary.tectonics.dirty_tiles[0] = 0
	world.planetary.tectonics.dirty_count = 1
	world.foundation.tectonic_revision = 1
	terrain_tectonic_revision_update(terrain, world)
	coord := shared.planet_sim_terrain_coord(shared.planet_sim_coord_for_index(0))
	testing.expect(t, terrain.dirty[_planet_patch_index_for(coord)])
	testing.expect_value(t, terrain.tectonic_revision, u64(1))
}

@(test)
terrain_build_progress_only_completes_after_bake :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	testing.expect_value(t, terrain_build_progress(terrain), 0)
	// Patches done but bake untouched: the bar must not read complete.
	terrain.ready = true
	partial := terrain_build_progress(terrain)
	testing.expect(t, partial > 0 && partial < 1)
	terrain.climate_row = PLANET_ALBEDO_ROWS
	terrain.albedo_row = PLANET_ALBEDO_ROWS
	testing.expect_value(t, terrain_build_progress(terrain), 1)
}

// A terraform edit must mark the owning render patch dirty, widen the
// per-face albedo re-bake window, and rearm the water refresh — a missing
// flag is silent staleness, not a crash.
@(test)
terrain_mark_dirty_covers_patch_albedo_and_water :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	terrain.albedo_min_row = PLANET_ALBEDO_ROWS
	terrain.albedo_max_row = -1
	center := shared.Planet_Coord{.Pos_Y, 300, 300}
	revision := terrain.heights_revision
	terrain_mark_dirty(terrain, center)
	patch_index := _planet_patch_index_for(center)
	testing.expect(t, terrain.dirty[patch_index], "owning patch marked")
	testing.expect(t, terrain.water_dirty, "water refresh armed")
	testing.expect(t, terrain.heights_revision > revision, "height revision bumped")
	// The albedo window covers the touched rows on the owning face.
	face_base := i32(int(center.face)) * PLANET_ALBEDO_SIZE
	center_row := face_base + center.v * PLANET_ALBEDO_SIZE / i32(shared.PLANET_FACE_CELLS)
	testing.expect(t, terrain.albedo_min_row <= center_row, "window reaches the centre row")
	testing.expect(t, terrain.albedo_max_row >= center_row, "window reaches the centre row")
	// Far cheaper than the full face: that is the entire point.
	testing.expect(
		t,
		terrain.albedo_max_row - terrain.albedo_min_row < PLANET_ALBEDO_SIZE / 8,
		"window is a small band",
	)
}

@(test)
terrain_material_dirty_reaches_ao_across_nearby_seam :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	for face in 0 ..< shared.PLANET_FACE_COUNT {
		for edge in 0 ..< 4 {
			terrain.albedo_min_row = PLANET_ALBEDO_ROWS
			terrain.albedo_max_row = -1
			terrain.dirty = {}
			center := shared.Planet_Coord{procgen.Terrain_Face_V4(face), 384, 384}
			if edge < 2 do center.u = edge == 0 ? 16 : 752
			else do center.v = edge == 2 ? 16 : 752
			terrain_mark_dirty(terrain, center, 1)
			offset_u := edge < 2 ? (edge == 0 ? -24 : 24) : 0
			offset_v := edge >= 2 ? (edge == 2 ? -24 : 24) : 0
			neighbor := shared.planet_neighbour(center, i32(offset_u), i32(offset_v))
			testing.expect(t, neighbor.face != center.face)
			row := i32(neighbor.face) * PLANET_ALBEDO_SIZE + neighbor.v * PLANET_ALBEDO_SIZE / i32(shared.PLANET_FACE_CELLS)
			testing.expect(t, terrain.albedo_min_row <= row && terrain.albedo_max_row >= row)
			testing.expect(t, !terrain.dirty[_planet_patch_index_for(neighbor)])
		}
	}
}

@(test)
terrain_water_dirty_tracks_renderer_revision :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	terrain.ocean.water_revision = 4
	terrain_water_dirty_update(terrain, 5)
	testing.expect(t, terrain.water_dirty)
	terrain.ocean.water_revision = 5
	terrain_water_dirty_update(terrain, 5)
	testing.expect(t, !terrain.water_dirty)
}

// An edit at a face edge must also dirty the adjacent face's border patch,
// or the seam shows a crack between the rebuilt and the stale side.
@(test)
terrain_mark_dirty_crosses_the_face_seam :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	terrain.albedo_min_row = PLANET_ALBEDO_ROWS
	terrain.albedo_max_row = -1
	edge := shared.Planet_Coord{.Pos_X, shared.PLANET_FACE_CELLS, shared.PLANET_FACE_CELLS / 2}
	terrain_mark_dirty(terrain, edge)
	per_face := shared.PLANET_PATCHES_PER_FACE * shared.PLANET_PATCHES_PER_FACE
	marked_faces: [shared.PLANET_FACE_COUNT]bool
	for dirty, index in terrain.dirty {
		if dirty do marked_faces[index / per_face] = true
	}
	count := 0
	for marked in marked_faces do if marked do count += 1
	testing.expect(t, count >= 2, "the edit marks patches on at least two faces")
}

// The parallel bakes are only safe if striping cannot change the result.
// Rows are disjoint writes over read-only inputs, but _terrain_ao reads
// +/-32 rows of base_heights across stripe boundaries, so this pins the
// guarantee rather than trusting the argument. A regression here shows up
// in-game as visible seams in the terrain albedo at worker-stripe
// boundaries.
@(test)
terrain_striped_climate_bake_matches_serial :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	striped := new(Terrain)
	defer free(striped)
	serial := new(Terrain)
	defer free(serial)
	// More rows than workers, so several stripe boundaries are crossed.
	rows := i32(128)
	testing.expect(t, int(rows) > terrain_bake_worker_count(), "range must cross stripes")
	_climate_bake_rows(striped, world, 0, rows)
	for row in i32(0) ..< rows {
		_climate_bake_row(serial, world, row)
	}
	texels := int(rows) * PLANET_ALBEDO_SIZE
	for index in 0 ..< texels {
		if striped.base_heights[index] != serial.base_heights[index] {
			testing.expectf(t, false, "base_heights differ at %d", index)
			return
		}
		if striped.moisture[index] != serial.moisture[index] {
			testing.expectf(t, false, "moisture differs at %d", index)
			return
		}
		if striped.temperature[index] != serial.temperature[index] {
			testing.expectf(t, false, "temperature differs at %d", index)
			return
		}
		if striped.primary_biome[index] != serial.primary_biome[index] {
			testing.expectf(t, false, "primary_biome differs at %d", index)
			return
		}
	}
}

@(test)
terrain_striped_albedo_bake_matches_serial :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	striped := new(Terrain)
	defer free(striped)
	serial := new(Terrain)
	defer free(serial)
	// _terrain_ao samples +/-32 rows, so bake climate over a wider band than
	// the albedo range being compared.
	climate_rows := i32(160)
	for terrain in ([]^Terrain{striped, serial}) {
		terrain.world_ref = world
		terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
		terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
		planet_surface_observe(terrain, world)
		_climate_bake_rows(terrain, world, 0, climate_rows)
		// _albedo_bake_row asserts the climate cache is complete.
		terrain.climate_row = PLANET_ALBEDO_ROWS
	}
	low, high := i32(32), i32(128)
	_albedo_bake_rows(striped, world, low, high)
	for row in low ..< high {
		_albedo_bake_row(serial, world, row)
	}
	for index in int(low) * PLANET_ALBEDO_SIZE * 3 ..< int(high) * PLANET_ALBEDO_SIZE * 3 {
		if striped.albedo_pixels[index] != serial.albedo_pixels[index] {
			testing.expectf(t, false, "albedo differs at byte %d", index)
			return
		}
		if striped.normal_pixels[index] != serial.normal_pixels[index] {
			testing.expectf(t, false, "material controls differ at byte %d", index)
			return
		}
		if striped.roughness_ao_pixels[index] != serial.roughness_ao_pixels[index] {
			testing.expectf(t, false, "roughness/AO/snow differs at byte %d", index)
			return
		}
	}
}

// The render patch is built straight from the foundation, so its vertices
// must reproduce the shared height/direction math exactly — including the
// terraform delta.
@(test)
terrain_planet_patch_builds_from_the_foundation :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	center := shared.Planet_Coord {
		.Pos_X,
		shared.PLANET_FACE_CELLS / 2,
		shared.PLANET_FACE_CELLS / 2,
	}
	shared.planet_heightfield_apply(&world.heightfield, center, 1)
	patch := new(Planet_Render_Patch)
	defer free(patch)
	patch.face = .Pos_X
	patch.patch_u = int(center.u) / shared.PLANET_PATCH_CELLS
	patch.patch_v = int(center.v) / shared.PLANET_PATCH_CELLS
	testing.expect(t, planet_render_patch_generate(patch, world), "patch generation")
	defer planet_render_patch_deinit(patch)
	column := int(center.u) - patch.patch_u * shared.PLANET_PATCH_CELLS
	row := int(center.v) - patch.patch_v * shared.PLANET_PATCH_CELLS
	vertex := patch.vertices[row * PLANET_RENDER_PATCH_EDGE + column]
	expected_height := shared.terrain_height_at_coord(world, center)
	expected := shared.planet_position(shared.planet_direction(center), expected_height)
	testing.expect_value(t, vertex.position, expected)
	testing.expect(t, patch.height_max >= expected_height, "bounds cover the raised centre")
	testing.expect(t, patch.height_min <= patch.height_max, "bounds ordered")
}

@(test)
terrain_planet_patch_triangles_face_outward :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	for face in procgen.Terrain_Face_V4 {
		patch := Planet_Render_Patch {
			face = face,
		}
		testing.expect(t, planet_render_patch_generate(&patch, world), "patch generation")
		defer planet_render_patch_deinit(&patch)
		for cursor := 0; cursor < len(patch.indices); cursor += 6 * 257 {
			a := patch.vertices[patch.indices[cursor]].position
			b := patch.vertices[patch.indices[cursor + 1]].position
			c := patch.vertices[patch.indices[cursor + 2]].position
			ab := b - a
			ac := c - a
			normal := [3]f32 {
				ab.y * ac.z - ab.z * ac.y,
				ab.z * ac.x - ab.x * ac.z,
				ab.x * ac.y - ab.y * ac.x,
			}
			center := (a + b + c) / 3
			testing.expectf(
				t,
				normal.x * center.x + normal.y * center.y + normal.z * center.z > 0,
				"%v triangle at index %d faces inward",
				face,
				cursor,
			)
		}
	}
}

// The planet water vertices carry the WATER_SHADER contract: scalar is
// shallowness, uv is {depth, coverage}, and the position sits on the water
// surface rather than at the raw planet radius.
@(test)
weather_water_parameters_use_wet_face_waves :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	face_cells := shared.PLANET_SIM_FACE_CELLS * shared.PLANET_SIM_FACE_CELLS
	world.planetary.ocean.mean_depth_mm = make([]u32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.waves.height_mm = make([]u32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.waves.period_ms = make([]u32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.waves.direction_east = make([]i32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.waves.direction_north = make([]i32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.waves.breaking = make([]u32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.climate.wind_east = make([]i32, shared.PLANET_SIM_CELL_COUNT)
	world.planetary.climate.wind_north = make([]i32, shared.PLANET_SIM_CELL_COUNT)
	defer delete(world.planetary.climate.wind_north)
	defer delete(world.planetary.climate.wind_east)
	defer delete(world.planetary.waves.breaking)
	defer delete(world.planetary.waves.direction_north)
	defer delete(world.planetary.waves.direction_east)
	defer delete(world.planetary.waves.period_ms)
	defer delete(world.planetary.waves.height_mm)
	defer delete(world.planetary.ocean.mean_depth_mm)
	dry := weather_water_parameters(world, 0)
	testing.expect_value(t, dry.x, f32(0))
	dry_direction_length := dry.y * dry.y + dry.z * dry.z + dry.w * dry.w
	testing.expect(t, abs(dry_direction_length - 1) < 0.0001)
	index := face_cells / 2
	world.planetary.ocean.mean_depth_mm[index] = 10_000
	world.planetary.waves.height_mm[index] = 1_200
	world.planetary.waves.direction_east[index] = shared.WAVE_DIRECTION_SCALE
	moderate := weather_water_parameters(world, 0)
	testing.expect(t, moderate.x > 0)
	world.planetary.waves.height_mm[index] = 20_000
	storm := weather_water_parameters(world, 0)
	testing.expect(t, storm.x > moderate.x)
	testing.expect_value(t, storm.x, f32(2.5))
	direction_length := storm.y * storm.y + storm.z * storm.z + storm.w * storm.w
	testing.expect(t, abs(direction_length - 1) < 0.0001)
	testing.expect_value(t, weather_water_parameters(world, 1).x, f32(0))
}

@(test)
terrain_planet_water_encodes_the_shader_contract :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	mesh := new(Planet_Water_Mesh)
	defer free(mesh)
	mesh.face = .Pos_X
	for &surface in world.planetary.ocean.surface_mm do surface = 250
	planet_water_mesh_generate(mesh, world)
	defer planet_water_mesh_deinit(mesh)
	wet := 0
	for row in 0 ..< PLANET_WATER_FACE_EDGE {
		for column in 0 ..< PLANET_WATER_FACE_EDGE {
			coord := shared.Planet_Coord {
				mesh.face,
				i32(column * PLANET_WATER_CELL_STRIDE),
				i32(row * PLANET_WATER_CELL_STRIDE),
			}
			ground := shared.terrain_height_at_coord(world, coord)
			depth := shared.waterfield_depth_at_coord(world, coord)
			_, shallow, coverage := water_render_sample(ground, depth)
			vertex := mesh.vertices[row * PLANET_WATER_FACE_EDGE + column]
			testing.expect_value(t, vertex.scalar, shallow)
			testing.expect_value(t, vertex.uv, [2]f32{depth, coverage})
			sample := water_render_sample_at(world, coord)
			expected_surface := sample.surface
			direction := shared.planet_direction(coord)
			if sample.kind == .Ocean {
				planetary_index := shared.planetary_sample_index(direction)
				expected_surface += shared.planet_render_height_from_mm(
					world.planetary.ocean.surface_mm[planetary_index],
				)
			}
			expected := shared.planet_position(direction, expected_surface)
			testing.expect_value(t, vertex.position, expected)
			if coverage > 0 do wet += 1
		}
	}
	if wet > 0 {
		testing.expect(t, mesh.has_water, "a face with wet vertices reports water")
	}
}

@(test)
water_render_column_depth_tracks_displaced_volume :: proc(t: ^testing.T) {
	testing.expect_value(t, water_render_column_depth(6, 2), f32(8))
	testing.expect_value(t, water_render_column_depth(6, -2), f32(4))
	testing.expect_value(t, water_render_column_depth(2, -3), f32(0))
	testing.expect_value(t, water_render_column_depth(0, 4), f32(0))
	testing.expect_value(t, water_render_column_depth(0, -4), f32(0))
	for kind in Water_Render_Kind {
		if kind == .None do continue
		sample := Water_Render_Sample {
			depth = 3,
			kind  = kind,
		}
		testing.expect_value(t, water_render_column_depth(sample.depth, 1), f32(4))
	}
}

@(test)
terrain_planet_water_refines_orbital_coastline_topology :: proc(t: ^testing.T) {
	testing.expect_value(t, PLANET_WATER_FACE_CELLS, 128)
	testing.expect_value(t, PLANET_WATER_CELL_STRIDE, shared.PLANET_FACE_CELLS / 128)
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	mesh := new(Planet_Water_Mesh)
	defer free(mesh)
	mesh.face = .Pos_X
	planet_water_mesh_generate(mesh, world)
	defer planet_water_mesh_deinit(mesh)
	testing.expect_value(t, len(mesh.vertices), PLANET_WATER_FACE_VERTICES)
	testing.expect_value(t, len(mesh.indices), PLANET_WATER_FACE_INDICES)
	maximum := u32(0)
	for index in mesh.indices {
		testing.expect(t, int(index) < len(mesh.vertices), "water index in range")
		maximum = max(maximum, index)
	}
	testing.expect_value(t, maximum, u32(PLANET_WATER_FACE_VERTICES - 1))
}

@(test)
ocean_clipmap_resolves_swell_and_excludes_annulus_center :: proc(t: ^testing.T) {
	spacing := f32(3_600) / f32(OCEAN_CLIPMAP_CELLS)
	testing.expect(t, f32(145) / spacing >= 5)
	ring := Ocean_Clipmap_Ring {
		inner_radius = 180,
		outer_radius = 540,
		indices      = make([]u32, OCEAN_CLIPMAP_INDICES_MAX),
	}
	defer delete(ring.indices)
	ocean_ring_indices_fill(&ring)
	testing.expect(t, ring.index_count < OCEAN_CLIPMAP_INDICES_MAX)
	center := OCEAN_CLIPMAP_CELLS / 2
	testing.expect(t, !ocean_ring_cell_active(ring, center, center))
	testing.expect(t, ocean_ring_cell_active(ring, 0, 0))
}

// Horizon culling must keep every patch the camera can see: the near side
// of the planet passes, the antipode fails, and a camera inside the sphere
// (loading, cinematics) draws everything.
@(test)
terrain_patch_horizon_culling_keeps_the_near_side :: proc(t: ^testing.T) {
	camera := [3]f32{0, -shared.PLANET_RADIUS * 2, 0}
	facing := [3]f32{0, -1, 0}
	antipode := [3]f32{0, 1, 0}
	testing.expect(t, _planet_patch_visible(facing, camera), "facing patch visible")
	testing.expect(t, !_planet_patch_visible(antipode, camera), "antipodal patch culled")
	inside := [3]f32{0, 0, 0}
	testing.expect(t, _planet_patch_visible(antipode, inside), "inside camera draws all")
}

@(test)
terrain_ray_hits_only_the_near_hemisphere :: proc(t: ^testing.T) {
	radius := shared.PLANET_RADIUS
	front_ray := rl.Ray_3D {
		origin    = {0, 0, radius * 2},
		direction = {0, 0, -1},
	}
	testing.expect(t, _terrain_ray_hit_near_side(front_ray, {0, 0, radius}))
	testing.expect(t, !_terrain_ray_hit_near_side(front_ray, {0, 0, -radius}))
	limb_ray := rl.Ray_3D {
		origin    = {radius * 2, radius * 0.5, 0},
		direction = {-2, -0.5, 0},
	}
	testing.expect(t, _terrain_ray_hit_near_side(limb_ray, {radius, radius * 0.25, 0}))
	testing.expect(t, !_terrain_ray_hit_near_side(limb_ray, {-radius, -radius * 0.25, 0}))
	invalid_ray := rl.Ray_3D {
		origin = {0, 0, radius * 2},
	}
	testing.expect(t, !_terrain_ray_hit_near_side(invalid_ray, {0, 0, radius}))
}

// The border lock is what makes mixed-LOD patch seams crack-free: every
// vertex on the patch's face-UV boundary must be pinned, and interior
// vertices must stay free to collapse.
@(test)
planet_patch_lod_border_pins_the_uv_boundary :: proc(t: ^testing.T) {
	patch := Planet_Render_Patch {
		patch_u = 2,
		patch_v = 3,
	}
	cells := f32(shared.PLANET_FACE_CELLS)
	u_low := f32(2 * shared.PLANET_PATCH_CELLS) / cells
	u_high := f32(3 * shared.PLANET_PATCH_CELLS) / cells
	v_low := f32(3 * shared.PLANET_PATCH_CELLS) / cells
	v_high := f32(4 * shared.PLANET_PATCH_CELLS) / cells
	interior_u := (u_low + u_high) / 2
	interior_v := (v_low + v_high) / 2
	vertices := [6]asset.Vertex {
		{uv = {u_low, interior_v}},
		{uv = {u_high, interior_v}},
		{uv = {interior_u, v_low}},
		{uv = {interior_u, v_high}},
		{uv = {interior_u, interior_v}},
		// One full cell inside the border: free, unlike the boundary row.
		{uv = {u_low + 1 / cells, interior_v}},
	}
	locked: [6]bool
	_planet_patch_lod_border(locked[:], vertices[:], &patch)
	for index in 0 ..< 4 do testing.expect(t, locked[index])
	testing.expect(t, !locked[4])
	testing.expect(t, !locked[5])
}

// Walking the camera away from a patch must never make the level finer, and
// must reach every level; and selection must never name a missing level.
@(test)
planet_patch_lod_selection_is_monotonic_and_safe :: proc(t: ^testing.T) {
	value := new(Terrain)
	defer free(value)
	value.patch_lods[0] = TERRAIN_LOD_COUNT
	value.patch_lod_error[0] = {0, 0.35}
	value.planet_patches[0].center = {1, 0, 0}
	value.planet_patches[0].height_min = 0
	value.planet_patches[0].height_max = 8
	previous := 0
	seen: [TERRAIN_LOD_COUNT]bool
	for step in 0 ..< 400 {
		camera := [3]f32{shared.PLANET_RADIUS + 10 + f32(step) * 4, 0, 0}
		level := _planet_patch_lod(value, 0, camera)
		testing.expect(t, level < TERRAIN_LOD_COUNT)
		testing.expect(t, level >= previous)
		seen[level] = true
		previous = level
	}
	for level in 0 ..< TERRAIN_LOD_COUNT do testing.expect(t, seen[level])
	// A patch the simplifier refused keeps one level, and selection must
	// stay on it however far away the camera stands.
	far_camera := [3]f32{shared.PLANET_RADIUS * 6, 0, 0}
	value.patch_lods[0] = 1
	value.patch_lod_error[0] = {0, 0}
	testing.expect_value(t, _planet_patch_lod(value, 0, far_camera), 0)
	// An error too large for even the far budget also keeps level zero,
	// which is what makes level zero's zero error the safe default.
	value.patch_lods[0] = TERRAIN_LOD_COUNT
	value.patch_lod_error[0] = {0, 1.0e9}
	testing.expect_value(t, _planet_patch_lod(value, 0, far_camera), 0)
}
