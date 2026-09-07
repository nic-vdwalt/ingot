package main

import shared "../shared"
import rl "ingot:gfx"

Ocean_Fixture_Renderer :: struct {
	bed: rl.Gpu_Mesh,
	water: rl.Gpu_Mesh,
	bed_vertices: [OCEAN_NEARSHORE_COUNT]rl.Gpu_3D_Vertex,
	water_vertices: [OCEAN_NEARSHORE_COUNT]rl.Gpu_3D_Vertex,
	indices: [OCEAN_NEARSHORE_CELLS * OCEAN_NEARSHORE_CELLS * 6]u32,
	last_time: f32,
	last_focus: [3]f32,
	ready: bool,
}

ocean_fixture_mesh_fill :: proc(value: ^Ocean_Fixture_Renderer, nearshore: ^Ocean_Nearshore) {
	spacing := OCEAN_NEARSHORE_RADIUS * 2 / f32(OCEAN_NEARSHORE_CELLS)
	for row in 0 ..< OCEAN_NEARSHORE_EDGE {
		for column in 0 ..< OCEAN_NEARSHORE_EDGE {
			index := ocean_nearshore_index(column, row)
			radial, _ := ocean_wave_normalize(ocean_nearshore_boundary_position(nearshore, column, row))
			bed := nearshore.bathymetry[index]
			depth := nearshore.state[index].depth
			left := ocean_nearshore_index(max(column - 1, 0), row)
			right := ocean_nearshore_index(min(column + 1, OCEAN_NEARSHORE_CELLS), row)
			down := ocean_nearshore_index(column, max(row - 1, 0))
			up := ocean_nearshore_index(column, min(row + 1, OCEAN_NEARSHORE_CELLS))
			bed_slope_x := (nearshore.bathymetry[right] - nearshore.bathymetry[left]) / (2 * spacing)
			bed_slope_y := (nearshore.bathymetry[up] - nearshore.bathymetry[down]) / (2 * spacing)
			water_slope_x := bed_slope_x + (nearshore.state[right].depth - nearshore.state[left].depth) / (2 * spacing)
			water_slope_y := bed_slope_y + (nearshore.state[up].depth - nearshore.state[down].depth) / (2 * spacing)
			bed_normal, _ := ocean_wave_normalize(radial - nearshore.east * bed_slope_x - nearshore.north * bed_slope_y)
			water_normal, _ := ocean_wave_normalize(radial - nearshore.east * water_slope_x - nearshore.north * water_slope_y)
			value.bed_vertices[index] = {
				position = shared.planet_position(radial, bed),
				normal = bed_normal,
				uv = {f32(column) / f32(OCEAN_NEARSHORE_CELLS), f32(row) / f32(OCEAN_NEARSHORE_CELLS)},
			}
			value.water_vertices[index] = {
				position = shared.planet_position(radial, bed + depth),
				normal = water_normal,
				scalar = 1 - clamp(depth / WATER_DEPTH_MAX, f32(0), f32(1)),
				uv = {depth, 1 if depth >= OCEAN_NEARSHORE_DRY_DEPTH else 0},
			}
		}
	}
	cursor := 0
	for row in 0 ..< OCEAN_NEARSHORE_CELLS {
		for column in 0 ..< OCEAN_NEARSHORE_CELLS {
			first := u32(ocean_nearshore_index(column, row))
			second := first + 1
			third := first + OCEAN_NEARSHORE_EDGE
			value.indices[cursor + 0] = first
			value.indices[cursor + 1] = second
			value.indices[cursor + 2] = third
			value.indices[cursor + 3] = second
			value.indices[cursor + 4] = third + 1
			value.indices[cursor + 5] = third
			cursor += 6
		}
	}
}

ocean_fixture_upload :: proc(value: ^Ocean_Fixture_Renderer) {
	value.ready = false
	if value.bed.id == 0 {
		mesh, valid := rl.create_gpu_mesh(value.bed_vertices[:], value.indices[:], .Triangles)
		if !valid do return
		value.bed = mesh
	} else {
		if !rl.update_gpu_mesh_vertices(value.bed, value.bed_vertices[:]) do return
	}
	if value.water.id == 0 {
		mesh, valid := rl.create_gpu_mesh(value.water_vertices[:], value.indices[:], .Triangles)
		if !valid do return
		value.water = mesh
	} else {
		if !rl.update_gpu_mesh_vertices(value.water, value.water_vertices[:]) do return
	}
	value.ready = true
}

ocean_fixture_deinit :: proc(value: ^Ocean_Fixture_Renderer) {
	if value.bed.id != 0 do rl.destroy_gpu_mesh(&value.bed)
	if value.water.id != 0 do rl.destroy_gpu_mesh(&value.water)
	value^ = {}
}
