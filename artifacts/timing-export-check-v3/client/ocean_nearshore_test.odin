#+build !js
package main

import "core:testing"
import "core:time"
import "core:fmt"
import shared "../shared"

@(test)
ocean_fixture_bounded_cost_probe :: proc(t: ^testing.T) {
	when !BENCH_ENABLED { return }
	value := new(Ocean_Nearshore)
	defer free(value)
	world := new(shared.World)
	defer free(world)
	breakers := new(Ocean_Breaker_Renderer)
	defer free(breakers)
	ocean_surf_fixture_init(value, {0, 0, 1}, .Bank)
	field := Ocean_Macro_Wave_Field{}
	query := Ocean_Macro_Wave_Query{ready = true}
	start := time.tick_now()
	for _ in 0 ..< 600 {
		value.pending_state = value.state
		value.pending_foam = value.foam
	}
	fmt.printf("[surf-cost] 600 snapshot copies: %.3f ms; staging bytes: %d\n", time.duration_milliseconds(time.tick_since(start)), size_of(value.pending_state) + size_of(value.pending_foam))
	start = time.tick_now()
	for _ in 0 ..< 600 {
		field.time += OCEAN_WAVE_FIXED_DT
		ocean_nearshore_fixed_step(value, world, value.focus, &field, &query, OCEAN_WAVE_FIXED_DT)
	}
	fmt.printf("[surf-cost] 600 resting Bank solver ticks: %.3f ms\n", time.duration_milliseconds(time.tick_since(start)))
	start = time.tick_now()
	for index in 0 ..< 600 {
		ocean_breakers_advance(breakers, world, value, query.packets[:query.packet_count], value.focus, f32(index + 1) * OCEAN_WAVE_FIXED_DT, OCEAN_WAVE_FIXED_DT)
	}
	fmt.printf("[surf-cost] 600 empty-source crest ticks: %.3f ms\n", time.duration_milliseconds(time.tick_since(start)))
	testing.expect(t, value.ready)
}

@(test)
ocean_fixture_mesh_matches_signed_bed_and_water :: proc(t: ^testing.T) {
	nearshore := new(Ocean_Nearshore)
	defer free(nearshore)
	mesh := new(Ocean_Fixture_Renderer)
	defer free(mesh)
	ocean_surf_fixture_init(nearshore, {1, 0, 0}, .Bank)
	ocean_fixture_mesh_fill(mesh, nearshore)
	center := ocean_nearshore_index(OCEAN_NEARSHORE_CELLS / 2, OCEAN_NEARSHORE_CELLS / 2)
	testing.expect_value(t, mesh.bed_vertices[center].position, [3]f32{1076, 0, 0})
	testing.expect_value(t, mesh.water_vertices[center].position, [3]f32{1080, 0, 0})
	testing.expect_value(t, mesh.water_vertices[center].uv, [2]f32{4, 1})
	testing.expect_value(t, mesh.water_vertices[center].scalar, 1 - clamp(f32(4) / WATER_DEPTH_MAX, f32(0), f32(1)))
	nearshore.foam[center] = 1
	ocean_fixture_mesh_fill(mesh, nearshore)
	testing.expect_value(t, mesh.water_vertices[center].scalar, 1 - clamp(f32(4) / WATER_DEPTH_MAX, f32(0), f32(1)))
	for index in mesh.indices do testing.expect(t, index < OCEAN_NEARSHORE_COUNT)
	for vertex, index in mesh.water_vertices {
		if nearshore.state[index].depth == 0 do testing.expect_value(t, vertex.uv.y, f32(0))
		column := index % OCEAN_NEARSHORE_EDGE
		row := index / OCEAN_NEARSHORE_EDGE
		position := ocean_nearshore_grid_position(nearshore, f32(column), f32(row), nearshore.bathymetry[index] + nearshore.state[index].depth)
		testing.expect(t, abs(vertex.position.x - position.x) + abs(vertex.position.y - position.y) + abs(vertex.position.z - position.z) < 0.001)
	}
	testing.expect_value(t, mesh.bed.id, u32(0))
	testing.expect_value(t, mesh.water.id, u32(0))
}

@(test)
ocean_fixture_source_drives_local_water_and_accounts_mass :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	field := Ocean_Macro_Wave_Field{}
	query := Ocean_Macro_Wave_Query{packet_count = 1, ready = true}
	query.packets[0] = {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = {1080, 0, 0},
		direction = value.east,
		period = 8,
		phase_epoch = 10,
		phase_speed = 12,
		front_speed = 0.24,
		significant_height = 2,
		band = 4,
		envelope_length = 4,
		envelope_width = 90,
	}
	before := ocean_nearshore_mass(value)
	ocean_nearshore_debug_source_force(value, &field, &query, 9)
	testing.expect_value(t, ocean_nearshore_mass(value), before)
	ocean_nearshore_debug_source_force(value, &field, &query, 12)
	center := ocean_nearshore_index(OCEAN_NEARSHORE_CELLS / 2, OCEAN_NEARSHORE_CELLS / 2)
	testing.expect(t, abs(value.state[center].depth - 12) > 0.01)
	change := f64(0)
	for cell, index in value.state do change += f64(cell.depth) - f64(value.still_depth[index])
	testing.expect(t, abs(change - value.last_source_mass) < 0.001)
	momentum: [2]f64
	energy := f64(0)
	for cell, index in value.state {
		momentum += [2]f64{f64(cell.momentum_x), f64(cell.momentum_y)}
		rest := Ocean_Nearshore_Cell{depth = value.still_depth[index]}
		energy += ocean_nearshore_cell_energy(cell, value.bathymetry[index]) - ocean_nearshore_cell_energy(rest, value.bathymetry[index])
	}
	testing.expect_value(t, momentum, value.last_source_momentum)
	testing.expect(t, abs(energy - value.last_source_energy) < 0.000001)
	testing.expect(t, energy > 0)
	mesh := new(Ocean_Fixture_Renderer)
	defer free(mesh)
	ocean_fixture_mesh_fill(mesh, value)
	sample, wet := ocean_nearshore_surface_sample(value, {1080, 0, 0})
	testing.expect(t, wet)
	testing.expect(t, abs(mesh.water_vertices[center].position.x - 1080 - sample.displacement.x) < 0.001)
	value.fixture_active = false
	before = ocean_nearshore_mass(value)
	ocean_nearshore_debug_source_force(value, &field, &query, 14)
	testing.expect_value(t, ocean_nearshore_mass(value), before)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	query.packets[0].radial = true
	ocean_nearshore_debug_source_force(value, &field, &query, 12)
	testing.expect(t, abs(value.state[center].depth - 12) > 0.01)
	before = ocean_nearshore_mass(value)
	ocean_nearshore_debug_source_force(value, &field, &query, 1000)
	testing.expect_value(t, ocean_nearshore_mass(value), before)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	query.packets[0].center = ocean_nearshore_boundary_position(value, 80, 60)
	ocean_nearshore_debug_source_force(value, &field, &query, 12)
	testing.expect(t, abs(value.state[ocean_nearshore_index(80, 60)].depth - 12) > 0.01)
	testing.expect_value(t, value.state[center].depth, f32(12))
}

@(test)
ocean_fixture_source_propagates_without_boundary_reinjection :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	field := Ocean_Macro_Wave_Field{}
	query := Ocean_Macro_Wave_Query{packet_count = 1, ready = true}
	query.packets[0] = {
		id = OCEAN_DEBUG_TEST_PULSE_ID,
		center = {1080, 0, 0},
		direction = value.east,
		period = 8,
		phase_speed = 12,
		front_speed = 0.24,
		significant_height = 2,
		band = 400,
		envelope_length = 400,
		envelope_width = 400,
	}
	original_query := query
	ocean_nearshore_boundary_force(value, &field, &query, 2)
	testing.expect_value(t, query, original_query)
	for cell in value.state do testing.expect_value(t, cell.depth, f32(12))
	testing.expect_value(t, value.last_boundary_mass, f64(0))
	ocean_nearshore_debug_source_force(value, &field, &query, 2)
	neighbor := ocean_nearshore_index(50, 48)
	remote := ocean_nearshore_index(70, 48)
	testing.expect_value(t, value.state[neighbor].depth, f32(12))
	testing.expect_value(t, value.state[remote].depth, f32(12))
	for _ in 0 ..< 30 do ocean_nearshore_euler(value, OCEAN_WAVE_FIXED_DT)
	testing.expect(t, abs(value.state[neighbor].depth - 12) > 0.0001)
	testing.expect(t, abs(value.state[remote].depth - 12) < 0.00001)
	value.fixture_active = false
	ocean_nearshore_boundary_force(value, &field, &query, 2)
	boundary_changed := false
	for column in 0 ..< OCEAN_NEARSHORE_EDGE {
		if abs(value.state[ocean_nearshore_index(column, 0)].depth - 12) > 0.001 do boundary_changed = true
	}
	testing.expect(t, boundary_changed, "ordinary ocean must retain packet boundary forcing")
}

@(test)
ocean_surf_fixtures_are_deterministic_and_pinned :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	for kind in Ocean_Surf_Fixture {
		ocean_surf_fixture_init(value, {0, 0, 1}, kind)
		testing.expect(t, value.ready && value.fixture_active)
		center := ocean_nearshore_index(OCEAN_NEARSHORE_CELLS / 2, OCEAN_NEARSHORE_CELLS / 2)
		testing.expect_value(t, value.state[center].depth, ocean_surf_fixture_depth(kind, 0, 0))
		for cell, index in value.state {
			testing.expect(t, cell.depth >= 0)
			testing.expect_value(t, cell.depth, max(-value.bathymetry[index], f32(0)))
			testing.expect_value(t, cell.momentum_x, f32(0))
		}
		value.state[center].momentum_x = 10
		ocean_surf_fixture_init(value, {0, 0, 1}, kind)
		testing.expect_value(t, value.state[center].momentum_x, f32(0))
	}
	for kind in Ocean_Surf_Fixture {
		ocean_surf_fixture_init(value, {0, 0, 1}, kind)
		mass_before := ocean_nearshore_mass(value)
		for _ in 0 ..< 120 do ocean_nearshore_euler(value, 1.0 / 60.0)
		testing.expect(t, abs(ocean_nearshore_mass(value) - mass_before) < 0.01)
		for cell, index in value.state {
			testing.expect(t, abs(cell.depth - value.still_depth[index]) < 0.001)
			testing.expect(t, abs(cell.momentum_x) + abs(cell.momentum_y) < 0.001)
		}
	}
	testing.expect(t, ocean_surf_fixture_bed(.Beach, 180, 0) > 0)
	testing.expect(t, ocean_surf_fixture_bed(.Bank, 180, 0) > 0)
	testing.expect(t, ocean_surf_fixture_depth(.Bank, 8, 0) < ocean_surf_fixture_depth(.Beach, 8, 0))
	testing.expect(t, ocean_surf_fixture_depth(.Reef, 0, 0) < ocean_surf_fixture_depth(.Reef, 80, 0))
	ocean_surf_fixture_init(value, {}, .Deep)
	testing.expect(t, !value.ready && !value.fixture_active)
}

@(test)
ocean_nearshore_cfl_backlog_is_bounded_and_accounted :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	world := new(shared.World)
	defer free(value)
	defer free(world)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	for &cell in value.state do cell.momentum_x = cell.depth * 10_000
	field := Ocean_Macro_Wave_Field{time = 1}
	query: Ocean_Macro_Wave_Query
	ocean_nearshore_fixed_step(value, world, value.focus, &field, &query, 1)
	testing.expect_value(t, value.last_substeps, OCEAN_NEARSHORE_MAX_SUBSTEPS)
	testing.expect(t, value.time_backlog > 0 && value.time_backlog <= 0.5)
	testing.expect(t, abs(value.last_advanced_time + value.time_backlog + value.dropped_time - 1) < 0.00001)
	previous_backlog := value.time_backlog
	previous_dropped := value.dropped_time
	field.time += OCEAN_WAVE_FIXED_DT
	ocean_nearshore_fixed_step(value, world, value.focus, &field, &query, OCEAN_WAVE_FIXED_DT)
	testing.expect(t, abs(value.last_advanced_time + value.time_backlog + value.dropped_time - previous_dropped - previous_backlog - OCEAN_WAVE_FIXED_DT) < 0.00001)
}

@(test)
ocean_nearshore_mass_budget_separates_forcing_from_residual :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	world := new(shared.World)
	defer free(value)
	defer free(world)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	field := Ocean_Macro_Wave_Field{time = OCEAN_WAVE_FIXED_DT}
	query: Ocean_Macro_Wave_Query
	value.state[ocean_nearshore_index(0, 20)].depth = 14
	before := f64(0)
	for cell in value.state do before += f64(cell.depth)
	ocean_nearshore_fixed_step(value, world, value.focus, &field, &query, OCEAN_WAVE_FIXED_DT)
	after := f64(0)
	for cell in value.state do after += f64(cell.depth)
	testing.expect(t, abs(value.last_boundary_mass + 2) < 0.00001)
	testing.expect(t, abs(value.last_mass_error) < 0.00001)
	testing.expect(t, abs(after - before - value.last_boundary_mass - value.last_clamp_mass - value.last_mass_error) < 0.00001)
}

@(test)
ocean_nearshore_wetted_raised_bed_reports_actual_surface :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	ocean_surf_fixture_init(value, {1, 0, 0}, .Deep)
	for index in 0 ..< OCEAN_NEARSHORE_COUNT {
		value.bathymetry[index] = 3
		value.still_depth[index] = 0
		value.state[index] = {depth = 0.5}
	}
	sample, valid := ocean_nearshore_surface_sample(value, shared.planet_position(value.focus, 0))
	testing.expect(t, valid)
	testing.expect_value(t, sample.depth, f32(0.5))
	testing.expect_value(t, sample.displacement, [3]f32{3.5, 0, 0})
	testing.expect_value(t, sample.normal, value.focus)
}

@(test)
ocean_nearshore_thin_water_is_not_deleted :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	for &cell in value.state do cell.depth = OCEAN_NEARSHORE_DRY_DEPTH * 0.5
	before := ocean_nearshore_mass(value)
	ocean_nearshore_euler(value, OCEAN_WAVE_FIXED_DT)
	testing.expect_value(t, ocean_nearshore_mass(value), before)
	for cell in value.state do testing.expect(t, cell.depth > 0)
}

@(test)
ocean_nearshore_hll_flux_preserves_nonnegative_depth :: proc(t: ^testing.T) {
	flux := ocean_nearshore_hll_flux({depth = 1, momentum_x = 0.4}, {depth = 0}, 0, 0.5, 0)
	testing.expect(t, flux.depth >= 0)
}

@(test)
ocean_nearshore_still_water_remains_still :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	for &cell in value.state do cell.depth = 1
	before := ocean_nearshore_mass(value)
	ocean_nearshore_euler(value, 0.01)
	after := ocean_nearshore_mass(value)
	testing.expect(t, abs(after - before) < 0.001)
}

@(test)
ocean_nearshore_sloping_bed_remains_at_rest :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			bed := f32(column) * 0.005
			value.bathymetry[index] = bed
			value.state[index].depth = 1 - bed
		}
	}
	before := ocean_nearshore_mass(value)
	for _ in 0 ..< 120 do ocean_nearshore_euler(value, 1.0 / 60.0)
	after := ocean_nearshore_mass(value)
	maximum_momentum := f32(0)
	maximum_surface_error := f32(0)
	for row in 1 ..< OCEAN_NEARSHORE_CELLS {
		for column in 1 ..< OCEAN_NEARSHORE_CELLS {
			index := ocean_nearshore_index(column, row)
			cell := value.state[index]
			maximum_momentum = max(maximum_momentum, abs(cell.momentum_x) + abs(cell.momentum_y))
			maximum_surface_error = max(
				maximum_surface_error,
				abs(cell.depth + value.bathymetry[index] - 1),
			)
		}
	}
	testing.expect(t, maximum_momentum < 0.001)
	testing.expect(t, maximum_surface_error < 0.001)
	testing.expect(t, abs(after - before) < 0.01)
}

@(test)
ocean_nearshore_break_contour_interpolates_depth_crossing :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	value.ready = true
	value.focus = {0, 0, 1}
	value.east = {1, 0, 0}
	value.north = {0, 1, 0}
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			value.still_depth[index] = 1 + f32(column) * 0.25
			value.bathymetry[index] = -value.still_depth[index]
		}
	}
	segments: [OCEAN_NEARSHORE_BREAK_SEGMENT_MAX]Ocean_Nearshore_Break_Segment
	count := ocean_nearshore_break_segments(value, 1.125, segments[:])
	testing.expect(t, count > 0)
	if count == 0 do return
	testing.expect(t, abs(segments[0].depth - 1.125) < 0.0001)
	testing.expect(t, segments[0].bed_slope > 0)
	testing.expect(t, abs(segments[0].tangent.y - 1) < 0.0001)
	testing.expect(t, segments[0].shallow_normal.x < 0)
}

@(test)
ocean_nearshore_break_contour_ignores_uniform_and_dry_fields :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	value.ready = true
	for &depth in value.still_depth do depth = 4
	segments: [8]Ocean_Nearshore_Break_Segment
	testing.expect_value(t, ocean_nearshore_break_segments(value, 2, segments[:]), 0)
	for &depth in value.still_depth do depth = 0
	testing.expect_value(t, ocean_nearshore_break_segments(value, 2, segments[:]), 0)
}

@(test)
ocean_nearshore_constants_are_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, OCEAN_NEARSHORE_CELLS, 96)
	testing.expect(t, OCEAN_NEARSHORE_CFL <= 0.5)
	testing.expect(t, OCEAN_NEARSHORE_MAX_SUBSTEPS <= 8)
	testing.expect(t, OCEAN_NEARSHORE_MOMENTUM_SETTLE_S <= 8)
}

@(test)
ocean_nearshore_depression_refills_without_losing_mass :: proc(t: ^testing.T) {
	value := new(Ocean_Nearshore)
	defer free(value)
	for &cell in value.state do cell.depth = 1
	center_column := OCEAN_NEARSHORE_CELLS / 2
	center_row := OCEAN_NEARSHORE_CELLS / 2
	center := ocean_nearshore_index(center_column, center_row)
	value.state[center].depth -= 0.2
	value.state[ocean_nearshore_index(center_column - 1, center_row)].depth += 0.05
	value.state[ocean_nearshore_index(center_column + 1, center_row)].depth += 0.05
	value.state[ocean_nearshore_index(center_column, center_row - 1)].depth += 0.05
	value.state[ocean_nearshore_index(center_column, center_row + 1)].depth += 0.05
	before := ocean_nearshore_mass(value)
	for _ in 0 ..< 8 * 60 do ocean_nearshore_euler(value, 1.0 / 60.0)
	after := ocean_nearshore_mass(value)
	testing.expect(t, abs(value.state[center].depth - 1) < 0.02)
	testing.expect(t, abs(after - before) < 0.01)
}

@(test)
ocean_nearshore_momentum_settling_is_timestep_independent :: proc(t: ^testing.T) {
	remaining: [3]f32
	steps := [3]int{8 * 30, 8 * 60, 8 * 120}
	for step_count, run_index in steps {
		value := new(Ocean_Nearshore)
		for &cell in value.state do cell.depth = 1
		center := ocean_nearshore_index(OCEAN_NEARSHORE_CELLS / 2, OCEAN_NEARSHORE_CELLS / 2)
		value.state[center].momentum_x = 0.5
		dt := 8.0 / f32(step_count)
		for _ in 0 ..< step_count do ocean_nearshore_euler(value, dt)
		for cell in value.state do remaining[run_index] += abs(cell.momentum_x) + abs(cell.momentum_y)
		free(value)
	}
	testing.expect(t, abs(remaining[0] - remaining[1]) < 0.02)
	testing.expect(t, abs(remaining[1] - remaining[2]) < 0.02)
}
