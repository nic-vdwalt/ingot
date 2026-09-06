package main

import "core:testing"
import "../shared"
import "core:time"

@(test)
planet_surface_packing_preserves_sterility_and_bounds :: proc(t: ^testing.T) {
	for level in 0 ..= 1000 {
		fraction := f32(level) / 1000
		original := Planet_Surface_Sample {
			color = {fraction * 255, 37.25, 254.75},
			ground = fraction, canopy = fraction, organic = fraction,
			sediment = fraction, moisture = fraction,
			air_temperature = 273123, snow = 4294967295,
		}
		decoded := planet_surface_unpack(planet_surface_pack(original))
		testing.expect(t, abs(decoded.ground - fraction) <= 0.5 / 255 + 0.000001)
		testing.expect_value(t, decoded.ground, decoded.canopy)
		testing.expect_value(t, decoded.ground, decoded.organic)
		testing.expect_value(t, decoded.ground, decoded.sediment)
		testing.expect_value(t, decoded.ground, decoded.moisture)
		for color, channel in decoded.color do testing.expect(t, abs(color - original.color[channel]) <= 0.50001)
		testing.expect_value(t, decoded.air_temperature, original.air_temperature)
		testing.expect_value(t, decoded.snow, original.snow)
	}
	bare := planet_surface_unpack(planet_surface_pack(Planet_Surface_Sample{}))
	testing.expect_value(t, bare.ground, f32(0))
	testing.expect_value(t, bare.canopy, f32(0))
	testing.expect_value(t, bare.organic, f32(0))
}

@(test)
planet_surface_completion_refreshes_gutter_dependents :: proc(t: ^testing.T) {
	terrain := new(Terrain)
	defer free(terrain)
	state := &terrain.surface_publication
	state.active = true
	state.faces[2] = true
	rows := i32(0)
	planet_surface_bake(terrain, nil, time.tick_now(), &rows)
	for upload in terrain.upload_faces do testing.expect(t, upload)
	for dirty in state.faces do testing.expect(t, !dirty)
	testing.expect_value(t, rows, i32(0))
	testing.expect_value(t, state.cursor, i32(PLANET_ALBEDO_ROWS))
	terrain.upload_faces = {}
	planet_surface_bake(terrain, nil, time.tick_now(), &rows)
	for upload in terrain.upload_faces do testing.expect(t, !upload)
}

@(test)
planet_surface_publication_pins_generation_and_retains_changes :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.climate_row = PLANET_ALBEDO_ROWS
	terrain.albedo_row = PLANET_ALBEDO_ROWS
	terrain.albedo_min_row = PLANET_ALBEDO_ROWS
	terrain.albedo_max_row = -1
	planet_surface_observe(terrain, world)
	state := &terrain.surface_publication
	initial := state.current[100]
	captures := state.captures
	planet_surface_observe(terrain, world)
	testing.expect_value(t, state.captures, captures)
	world.planetary.climate.snow[100] += 1000
	world.planetary.climate.surface_revision += 1
	planet_surface_observe(terrain, world)
	testing.expect(t, state.active)
	testing.expect(t, state.current[100] != initial)
	pinned := state.current[100]
	target := state.target
	for _ in 0 ..< 3 {
		world.planetary.climate.snow[100] += 1000
		world.planetary.climate.surface_revision += 1
		planet_surface_observe(terrain, world)
		testing.expect_value(t, state.current[100], pinned)
		testing.expect_value(t, state.target, target)
	}
	testing.expect(t, state.pending)
	dirty_rows := 0
	for dirty in state.rows do if dirty do dirty_rows += 1
	testing.expect(t, dirty_rows > 0 && dirty_rows < PLANET_ALBEDO_SIZE)
	for dirty in terrain.dirty do testing.expect(t, !dirty)
	state.rows = {}
	state.active = false
	planet_surface_observe(terrain, world)
	testing.expect_value(t, state.current[100], state.next[100])
	testing.expect_value(t, state.target, state.observed)
	shared.flora_ecology_sterilize(&world.flora_ecology)
	sample := planet_surface_capture(world, 100)
	testing.expect_value(t, sample.ground, f32(0))
	testing.expect_value(t, sample.canopy, f32(0))
}

@(test)
planet_surface_dirty_rows_cross_faces_without_global_rebake :: proc(t: ^testing.T) {
	state := new(Planet_Surface_Publication)
	defer free(state)
	planet_surface_mark(state, 0)
	faces: [shared.PLANET_FACE_COUNT]bool
	count := 0
	for dirty, row in state.rows {
		if !dirty do continue
		count += 1
		faces[row / PLANET_ALBEDO_SIZE] = true
	}
	face_count := 0
	for dirty in faces do if dirty do face_count += 1
	testing.expect(t, face_count >= 2)
	testing.expect(t, count < PLANET_ALBEDO_ROWS / 2)
}

@(test)
planet_surface_scheduler_reserves_offscreen_progress :: proc(t: ^testing.T) {
	state := new(Planet_Surface_Publication)
	defer free(state)
	for &dirty in state.rows do dirty = true
	state.visible[5] = true
	planet_surface_schedule(state)
	testing.expect_value(t, state.order_count, int(PLANET_ALBEDO_ROWS))
	testing.expect_value(t, state.order[0], i32(0))
	testing.expect_value(t, state.order[1], i32(5 * PLANET_ALBEDO_SIZE))
	testing.expect_value(t, state.order[4], i32(1))
	seen: [PLANET_ALBEDO_ROWS]bool
	for row in state.order[:state.order_count] {
		testing.expect(t, !seen[row])
		seen[row] = true
	}
	state.rows = {}
	planet_surface_schedule(state)
	testing.expect_value(t, state.order_count, 0)
}

