package main

import "../shared"
import "core:time"

Planet_Surface_Revision :: struct {
	climate, flora, biome, habitat, water, terrain, debug: u64,
}

Planet_Surface_Sample :: struct {
	color: [3]f32,
	ground, canopy, organic, sediment, moisture: f32,
	air_temperature: i32,
	snow: u32,
}

Planet_Surface_Packed :: struct {
	color: [3]u8,
	ground, canopy, organic, sediment, moisture: u8,
	air_temperature: i32,
	snow: u32,
}

planet_surface_pack :: proc(sample: Planet_Surface_Sample) -> Planet_Surface_Packed {
	result := Planet_Surface_Packed {
		ground = u8(clamp(sample.ground * 255 + 0.5, 0, 255)),
		canopy = u8(clamp(sample.canopy * 255 + 0.5, 0, 255)),
		organic = u8(clamp(sample.organic * 255 + 0.5, 0, 255)),
		sediment = u8(clamp(sample.sediment * 255 + 0.5, 0, 255)),
		moisture = u8(clamp(sample.moisture * 255 + 0.5, 0, 255)),
		air_temperature = sample.air_temperature, snow = sample.snow,
	}
	for color, channel in sample.color do result.color[channel] = u8(clamp(color + 0.5, 0, 255))
	return result
}

planet_surface_unpack :: proc(sample: Planet_Surface_Packed) -> Planet_Surface_Sample {
	result := Planet_Surface_Sample {
		ground = f32(sample.ground) / 255, canopy = f32(sample.canopy) / 255,
		organic = f32(sample.organic) / 255, sediment = f32(sample.sediment) / 255,
		moisture = f32(sample.moisture) / 255,
		air_temperature = sample.air_temperature, snow = sample.snow,
	}
	for color, channel in sample.color do result.color[channel] = f32(color)
	return result
}

Planet_Surface_Publication :: struct {
	current, next: [shared.PLANET_SIM_CELL_COUNT]Planet_Surface_Packed,
	observed, target, published: Planet_Surface_Revision,
	initialized, active, pending: bool,
	rows: [PLANET_ALBEDO_ROWS]bool,
	order: [PLANET_ALBEDO_ROWS]i32,
	order_count, order_cursor: int,
	visible: [shared.PLANET_FACE_COUNT]bool,
	debug: bool,
	faces: [shared.PLANET_FACE_COUNT]bool,
	cursor: i32,
	captures, generations: u64,
}

#assert(size_of(Planet_Surface_Packed) == 16)
#assert(size_of(Planet_Surface_Publication) + shared.PLANET_SIM_CELL_COUNT * 12 * size_of(f32) + PLANET_MATERIAL_PADDED_SIZE * PLANET_MATERIAL_PADDED_SIZE * 3 <= 8 * 1024 * 1024)

planet_surface_revision :: proc(value: ^Terrain, world: ^shared.World) -> Planet_Surface_Revision {
	return {world.planetary.climate.surface_revision, world.flora_ecology.revision,
		world.biome_environment.header.last_tick, world.biome_environment.header.revision, world.waterfield.revision,
		world.foundation.tectonic_revision, value.lithosphere_debug_revision}
}

planet_surface_capture :: proc(world: ^shared.World, index: int) -> Planet_Surface_Sample {
	coord := shared.planet_sim_terrain_coord(shared.planet_sim_coord_for_index(index))
	direction := shared.planet_direction(coord)
	habitat := shared.flora_habitat_at_cell(world, index)
	moisture := f32(habitat.moisture) / 255
	temperature := f32(habitat.temperature) / 255
	ground, canopy := planet_material_flora_cover(world, direction)
	weights := shared.biome_environment_at_coord(world, coord)
	sample := Planet_Surface_Sample {
		ground = ground, canopy = canopy, moisture = moisture,
		air_temperature = habitat.temperature_mk,
		snow = world.planetary.climate.snow[index],
	}
	for weight, biome in weights {
		sample.color += _biome_color(biome, moisture, temperature) * weight
		controls := planet_material_controls(biome, ground, canopy, moisture, 0)
		sample.organic += controls.organic * weight
		sample.sediment += controls.sediment * weight
	}
	flora_color, cover := _flora_ground_color(world, direction)
	sample.color = _mix3(sample.color, flora_color, cover)
	return sample
}

planet_surface_vertex :: proc(state: ^Planet_Surface_Publication, coord: shared.Planet_Coord) -> Planet_Surface_Sample {
	stride := i32(shared.PLANET_FACE_CELLS / shared.PLANET_SIM_FACE_CELLS)
	canonical := shared.planet_canonical(coord)
	result: Planet_Surface_Sample
	temperature, snow: f64
	for corner in 0 ..< 4 {
		neighbor := shared.planet_neighbour(canonical, corner % 2 == 0 ? -stride / 2 : stride / 2, corner / 2 == 0 ? -stride / 2 : stride / 2)
		sample := planet_surface_unpack(state.current[shared.planetary_sample_index(shared.planet_direction(neighbor))])
		result.color += sample.color * 0.25
		result.ground += sample.ground * 0.25
		result.canopy += sample.canopy * 0.25
		result.organic += sample.organic * 0.25
		result.sediment += sample.sediment * 0.25
		result.moisture += sample.moisture * 0.25
		temperature += f64(sample.air_temperature) * 0.25
		snow += f64(sample.snow) * 0.25
	}
	result.air_temperature = i32(temperature)
	result.snow = u32(snow)
	return result
}

planet_surface_sample :: proc(state: ^Planet_Surface_Publication, direction: [3]f32) -> Planet_Surface_Sample {
	face, cell_u, cell_v := shared.planet_locate(direction)
	stride := i32(shared.PLANET_FACE_CELLS / shared.PLANET_SIM_FACE_CELLS)
	low_u := min(i32(cell_u / f32(stride)), i32(shared.PLANET_SIM_FACE_CELLS - 1))
	low_v := min(i32(cell_v / f32(stride)), i32(shared.PLANET_SIM_FACE_CELLS - 1))
	blend_u := clamp(cell_u / f32(stride) - f32(low_u), 0, 1)
	blend_v := clamp(cell_v / f32(stride) - f32(low_v), 0, 1)
	result: Planet_Surface_Sample
	temperature, snow: f64
	for corner in 0 ..< 4 {
		u := (low_u + i32(corner % 2)) * stride
		v := (low_v + i32(corner / 2)) * stride
		coord := shared.Planet_Coord{face, u, v}
		weight := (corner % 2 == 0 ? 1 - blend_u : blend_u) * (corner / 2 == 0 ? 1 - blend_v : blend_v)
		sample := planet_surface_vertex(state, coord)
		result.color += sample.color * weight
		result.ground += sample.ground * weight
		result.canopy += sample.canopy * weight
		result.organic += sample.organic * weight
		result.sediment += sample.sediment * weight
		result.moisture += sample.moisture * weight
		temperature += f64(sample.air_temperature) * f64(weight)
		snow += f64(sample.snow) * f64(weight)
	}
	result.air_temperature = i32(temperature)
	result.snow = u32(snow)
	return result
}

planet_surface_mark :: proc(state: ^Planet_Surface_Publication, index: int) {
	center := shared.planet_sim_terrain_coord(shared.planet_sim_coord_for_index(index))
	stride := i32(shared.PLANET_FACE_CELLS / shared.PLANET_SIM_FACE_CELLS)
	for offset_v in -2 * stride ..= 2 * stride {
		for offset_u in ([5]i32{-2 * stride, -stride, 0, stride, 2 * stride}) {
			coord := shared.planet_neighbour(center, offset_u, offset_v)
			row := i32(coord.face) * PLANET_ALBEDO_SIZE + clamp(i32(f32(coord.v) * f32(PLANET_ALBEDO_SIZE) / f32(shared.PLANET_FACE_CELLS)), 0, PLANET_ALBEDO_SIZE - 1)
			for delta in i32(-2) ..= 2 {
				local := clamp(row % PLANET_ALBEDO_SIZE + delta, 0, PLANET_ALBEDO_SIZE - 1)
				state.rows[i32(coord.face) * PLANET_ALBEDO_SIZE + local] = true
			}
		}
	}
}

planet_surface_observe :: proc(value: ^Terrain, world: ^shared.World) {
	state := &value.surface_publication
	revision := planet_surface_revision(value, world)
	if !state.initialized || revision != state.observed {
		for &sample, index in state.next do sample = planet_surface_pack(planet_surface_capture(world, index))
		state.observed = revision
		state.pending = true
		state.captures += 1
	}
	if !state.initialized {
		state.current = state.next
		state.target = revision
		state.debug = value.lithosphere_debug
		state.initialized = true
		state.pending = false
		return
	}
	if state.active || !state.pending || value.climate_row < PLANET_ALBEDO_ROWS || value.albedo_row < PLANET_ALBEDO_ROWS || value.albedo_min_row <= value.albedo_max_row do return
	for upload in value.upload_faces do if upload do return
	for sample, index in state.next {
		if sample != state.current[index] do planet_surface_mark(state, index)
	}
	if state.target.debug != state.observed.debug {
		for &dirty in state.rows do dirty = true
	}
	state.current = state.next
	state.target = state.observed
	state.debug = value.lithosphere_debug
	planet_surface_schedule(state)
	state.pending = false
	state.cursor = 0
	state.active = true
	state.generations += 1
}

planet_surface_bake :: proc(value: ^Terrain, world: ^shared.World, start: time.Tick, rows_baked: ^i32) {
	state := &value.surface_publication
	if !state.active do return
	for state.order_cursor < state.order_count {
		if !_bake_has_budget(start, rows_baked^) do return
		row := state.order[state.order_cursor]
		_albedo_bake_rows(value, world, row, row + 1)
		state.rows[row] = false
		state.faces[row / PLANET_ALBEDO_SIZE] = true
		state.order_cursor += 1
		rows_baked^ += 1
	}
	state.cursor = PLANET_ALBEDO_ROWS
	changed := false
	for &dirty in state.faces {
		changed = changed || dirty
		dirty = false
	}
	if changed do for &upload in value.upload_faces do upload = true
}

planet_surface_schedule :: proc(state: ^Planet_Surface_Publication) {
	state.order_count, state.order_cursor = 0, 0
	visible_cursor, oldest_cursor := 0, 0
	selected: [PLANET_ALBEDO_ROWS]bool
	for slot in 0 ..< PLANET_ALBEDO_ROWS {
		row := -1
		if slot % 4 != 0 {
			for visible_cursor < PLANET_ALBEDO_ROWS {
				candidate := visible_cursor
				visible_cursor += 1
				if state.rows[candidate] && !selected[candidate] && state.visible[candidate / PLANET_ALBEDO_SIZE] {
					row = candidate
					break
				}
			}
		}
		if row < 0 {
			for oldest_cursor < PLANET_ALBEDO_ROWS {
				candidate := oldest_cursor
				oldest_cursor += 1
				if state.rows[candidate] && !selected[candidate] {
					row = candidate
					break
				}
			}
		}
		if row < 0 do break
		selected[row] = true
		state.order[state.order_count] = i32(row)
		state.order_count += 1
	}
}
