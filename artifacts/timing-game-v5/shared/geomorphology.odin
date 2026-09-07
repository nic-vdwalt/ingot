package shared

import "core:mem"

GEOMORPHOLOGY_MAX_SUBSTEPS :: 4
GEOMORPHOLOGY_SUBSTEPS :: #config(PLANET_GEOMORPHOLOGY_SUBSTEPS, 2)
GEOMORPHOLOGY_EROSION_MAX_FIXED :: i32(4)
GEOMORPHOLOGY_DEPOSITION_MAX_FIXED :: i32(4)
#assert(GEOMORPHOLOGY_SUBSTEPS > 0 && GEOMORPHOLOGY_SUBSTEPS <= GEOMORPHOLOGY_MAX_SUBSTEPS)

Geomorphology_State :: struct {
	flow_to:           []u32,
	flow_accumulation: []u32,
	sediment_load:     []u32,
	erosional_delta:   []i32,
	queue:              []u32,
	indegree:           []u8,
	revision:           u64,
	pending_years:      u32,
}

geomorphology_init :: proc(state: ^Geomorphology_State, allocator := context.allocator) {
	assert(state != nil, "geomorphology_init: nil state")
	state^ = {}
	state.flow_to = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.flow_accumulation = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.sediment_load = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.erosional_delta = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.queue = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.indegree = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
}

geomorphology_deinit :: proc(state: ^Geomorphology_State, allocator := context.allocator) {
	assert(state != nil, "geomorphology_deinit: nil state")
	delete(state.indegree, allocator)
	delete(state.queue, allocator)
	delete(state.erosional_delta, allocator)
	delete(state.sediment_load, allocator)
	delete(state.flow_accumulation, allocator)
	delete(state.flow_to, allocator)
	state^ = {}
}

geomorphology_height_fixed :: proc(world: ^World, index: int) -> i32 {
	assert(world != nil, "geomorphology_height_fixed: nil world")
	coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
	return i32(world.foundation.base_height[planet_index(coord)]) +
		tectonics_displacement_fixed(&world.planetary.tectonics, index)
}

geomorphology_resolve_flow :: proc(world: ^World, state: ^Geomorphology_State) -> bool {
	assert(world != nil && state != nil, "geomorphology_resolve_flow: nil input")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state.flow_to[index] = u32(index)
		state.flow_accumulation[index] = 1
		state.indegree[index] = 0
		best_height := geomorphology_height_fixed(world, index)
		for neighbour in world.planetary.grid.neighbours[index] {
			candidate := int(neighbour)
			height := geomorphology_height_fixed(world, candidate)
			if height < best_height {
				best_height = height
				state.flow_to[index] = neighbour
			}
		}
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		target := int(state.flow_to[index])
		if target == index do continue
		if state.flow_to[target] == u32(index) {
			if index < target do state.flow_to[target] = u32(target)
			else do state.flow_to[index] = u32(index)
		}
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		target := int(state.flow_to[index])
		if target == index do continue
		if state.indegree[target] == max(u8) do return false
		state.indegree[target] += 1
	}
	head, tail := 0, 0
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if state.indegree[index] == 0 {
			state.queue[tail] = u32(index)
			tail += 1
		}
	}
	for head < tail {
		index := int(state.queue[head])
		head += 1
		target := int(state.flow_to[index])
		if target == index do continue
		state.flow_accumulation[target] = min(
			state.flow_accumulation[target] + state.flow_accumulation[index],
			max(u32),
		)
		state.indegree[target] -= 1
		if state.indegree[target] == 0 {
			state.queue[tail] = u32(target)
			tail += 1
		}
	}
	return tail == PLANET_SIM_CELL_COUNT
}

geomorphology_erode_and_deposit :: proc(world: ^World, state: ^Geomorphology_State, years: u32) {
	assert(world != nil && state != nil, "geomorphology erosion: nil input")
	if years == 0 do return
	year_scale := years / 5_000
	if year_scale == 0 do return
	for queued in state.queue {
		index := int(queued)
		target := int(state.flow_to[index])
		drop := max(geomorphology_height_fixed(world, index) - geomorphology_height_fixed(world, target), 0)
		capacity := u32(min(u64(state.flow_accumulation[index]) * u64(drop) * u64(year_scale) / 4_096, u64(64)))
		if state.sediment_load[index] < capacity {
			erosion := min(i32(capacity - state.sediment_load[index]), GEOMORPHOLOGY_EROSION_MAX_FIXED, world.planetary.tectonics.uplift_fixed[index] + TECTONIC_SUBSIDENCE_MAX_FIXED)
			state.erosional_delta[index] -= erosion
			state.sediment_load[index] += u32(erosion)
		} else if state.sediment_load[index] > capacity {
			deposit := min(i32(state.sediment_load[index] - capacity), GEOMORPHOLOGY_DEPOSITION_MAX_FIXED, TECTONIC_SEDIMENT_MAX_FIXED - world.planetary.tectonics.sediment_fixed[index])
			state.sediment_load[index] -= u32(deposit)
			world.planetary.tectonics.sediment_fixed[index] = min(
				world.planetary.tectonics.sediment_fixed[index] + deposit,
				TECTONIC_SEDIMENT_MAX_FIXED,
			)
		}
		if target != index {
			transfer := min(state.sediment_load[index] / 4, max(u32) - state.sediment_load[target])
			state.sediment_load[index] -= transfer
			state.sediment_load[target] += transfer
		}
	}
}

geomorphology_step :: proc(world: ^World, years: u32) -> bool {
	assert(world != nil, "geomorphology_step: nil world")
	if years == 0 do return false
	state := &world.planetary.geomorphology
	state.pending_years += years
	for state.pending_years >= 5_000 {
		if !geomorphology_resolve_flow(world, state) do return false
		geomorphology_erode_and_deposit(world, state, 5_000)
		for index in 0 ..< PLANET_SIM_CELL_COUNT {
			world.planetary.tectonics.uplift_fixed[index] = clamp(world.planetary.tectonics.uplift_fixed[index] + state.erosional_delta[index], -TECTONIC_SUBSIDENCE_MAX_FIXED, TECTONIC_UPLIFT_MAX_FIXED)
			state.erosional_delta[index] = 0
		}
		state.pending_years -= 5_000
	}
	state.revision += 1
	return true
}

geomorphology_snapshot_size :: proc(state: ^Geomorphology_State) -> int {
	assert(state != nil, "geomorphology_snapshot_size: nil state")
	return size_of(state.revision) + size_of(state.pending_years) + PLANET_SIM_CELL_COUNT *
		(size_of(u32) * 4 + size_of(i32) + size_of(u8))
}

geomorphology_snapshot_write :: proc(state: ^Geomorphology_State, buffer: []u8) -> (int, bool) {
	assert(state != nil, "geomorphology_snapshot_write: nil state")
	if len(buffer) < geomorphology_snapshot_size(state) do return 0, false
	cursor := 0
	fields := [][]u8 {
		mem.ptr_to_bytes(&state.revision), mem.ptr_to_bytes(&state.pending_years), mem.slice_to_bytes(state.flow_to),
		mem.slice_to_bytes(state.flow_accumulation), mem.slice_to_bytes(state.sediment_load),
		mem.slice_to_bytes(state.erosional_delta), mem.slice_to_bytes(state.queue),
		mem.slice_to_bytes(state.indegree),
	}
	for field in fields do planetary_snapshot_put(buffer, &cursor, field)
	return cursor, cursor == geomorphology_snapshot_size(state)
}

geomorphology_snapshot_read :: proc(state: ^Geomorphology_State, buffer: []u8) -> bool {
	assert(state != nil, "geomorphology_snapshot_read: nil state")
	if len(buffer) != geomorphology_snapshot_size(state) do return false
	cursor := 0
	fields := [][]u8 {
		mem.ptr_to_bytes(&state.revision), mem.ptr_to_bytes(&state.pending_years), mem.slice_to_bytes(state.flow_to),
		mem.slice_to_bytes(state.flow_accumulation), mem.slice_to_bytes(state.sediment_load),
		mem.slice_to_bytes(state.erosional_delta), mem.slice_to_bytes(state.queue),
		mem.slice_to_bytes(state.indegree),
	}
	for field in fields do planetary_snapshot_get(buffer, &cursor, field)
	return cursor == len(buffer)
}
