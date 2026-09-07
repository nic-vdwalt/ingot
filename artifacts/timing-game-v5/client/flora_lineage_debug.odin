package main

import shared "../shared"

FLORA_LINEAGE_FOCUS_DISTANCE :: f32(42)

Flora_Lineage_Debug_State :: struct {
	selected:    shared.Lineage_Id,
	child_index: i32,
}

Flora_Lineage_Population :: struct {
	active_cells:    u32,
	total_cover:     u64,
	total_biomass:   u64,
	strongest_cell:  int,
	strongest_score: u64,
	child_count:     u32,
}

flora_lineage_debug_reset :: proc(state: ^Flora_Lineage_Debug_State) {
	assert(state != nil, "flora lineage debug reset: nil state")
	state^ = {}
}

flora_lineage_debug_resolve :: proc(
	state: ^Flora_Lineage_Debug_State,
	ecology: ^shared.Flora_Ecology,
) -> (^shared.Flora_Lineage, int, bool) {
	assert(state != nil && ecology != nil, "flora lineage debug resolve: nil input")
	if ecology.lineage_count == 0 {
		state^ = {}
		return nil, -1, false
	}
	for index in 0 ..< int(ecology.lineage_count) {
		if ecology.lineages[index].id == state.selected do return &ecology.lineages[index], index, true
	}
	state.selected = ecology.lineages[0].id
	state.child_index = 0
	return &ecology.lineages[0], 0, true
}

flora_lineage_debug_select_offset :: proc(
	state: ^Flora_Lineage_Debug_State,
	ecology: ^shared.Flora_Ecology,
	offset: int,
) {
	_, index, found := flora_lineage_debug_resolve(state, ecology)
	if !found do return
	count := int(ecology.lineage_count)
	index = (index + offset + count) % count
	state.selected = ecology.lineages[index].id
	state.child_index = 0
}

flora_lineage_debug_select_parent :: proc(
	state: ^Flora_Lineage_Debug_State,
	ecology: ^shared.Flora_Ecology,
) -> bool {
	lineage, _, found := flora_lineage_debug_resolve(state, ecology)
	if !found || lineage.parent == shared.Lineage_Id(0) do return false
	if _, parent_found := shared.flora_ecology_lineage(ecology, lineage.parent); !parent_found do return false
	state.selected = lineage.parent
	state.child_index = 0
	return true
}

flora_lineage_debug_child :: proc(
	ecology: ^shared.Flora_Ecology,
	parent: shared.Lineage_Id,
	ordinal: int,
) -> (shared.Lineage_Id, bool) {
	if ordinal < 0 do return shared.Lineage_Id(0), false
	seen := 0
	for index in 0 ..< int(ecology.lineage_count) {
		if ecology.lineages[index].parent != parent do continue
		if seen == ordinal do return ecology.lineages[index].id, true
		seen += 1
	}
	return shared.Lineage_Id(0), false
}

flora_lineage_debug_select_child :: proc(
	state: ^Flora_Lineage_Debug_State,
	ecology: ^shared.Flora_Ecology,
	offset: int,
) -> bool {
	lineage, _, found := flora_lineage_debug_resolve(state, ecology)
	if !found do return false
	count := 0
	for index in 0 ..< int(ecology.lineage_count) do if ecology.lineages[index].parent == lineage.id do count += 1
	if count == 0 do return false
	state.child_index = i32((int(state.child_index) + offset + count) % count)
	child, child_found := flora_lineage_debug_child(ecology, lineage.id, int(state.child_index))
	if !child_found do return false
	state.selected = child
	state.child_index = 0
	return true
}

flora_lineage_debug_population :: proc(
	ecology: ^shared.Flora_Ecology,
	lineage: shared.Lineage_Id,
) -> Flora_Lineage_Population {
	assert(ecology != nil, "flora lineage debug population: nil ecology")
	result := Flora_Lineage_Population{strongest_cell = -1}
	for cell, cell_index in ecology.cells {
		cell_present := false
		for cohort in cell.cohorts {
			if cohort.lineage != lineage do continue
			cell_present = true
			cover := u64(max(cohort.ground_cover, cohort.canopy_cover))
			result.total_cover += cover
			result.total_biomass += u64(cohort.biomass)
			score := u64(cohort.biomass) + cover * 100
			if score > result.strongest_score || score == result.strongest_score && cell_index < result.strongest_cell {
				result.strongest_score = score
				result.strongest_cell = cell_index
			}
		}
		if cell_present do result.active_cells += 1
	}
	for index in 0 ..< int(ecology.lineage_count) do if ecology.lineages[index].parent == lineage do result.child_count += 1
	return result
}

flora_lineage_debug_jump :: proc(value: ^Client_State, cell_index: int) -> bool {
	assert(value != nil, "flora lineage debug jump: nil state")
	if cell_index < 0 || cell_index >= shared.PLANET_SIM_CELL_COUNT do return false
	direction := shared.planet_sim_direction(shared.planet_sim_coord_for_index(cell_index))
	value.orbit.target = direction * shared.PLANET_RADIUS
	value.orbit.distance = clamp(
		FLORA_LINEAGE_FOCUS_DISTANCE,
		value.orbit_config.min_distance,
		value.orbit_config.max_distance,
	)
	value.camera_height_offset = 0
	camera_apply_seated(value, 0)
	return true
}
