package shared

marine_initial_diagnostics :: proc(state: ^Marine_Ecology) {
	occupied: [MARINE_MAX_LINEAGES]bool
	state.guild_mass = {}
	for cell in state.cells {
		for cohort in cell.cohorts {
			if cohort.mass == 0 do continue
			occupied[cohort.lineage - 1] = true
			state.guild_mass[int(state.lineages[cohort.lineage - 1].traits.guild)] += cohort.mass
		}
	}
	for &lineage, index in state.lineages[:state.lineage_count] do lineage.extinct = !occupied[index]
}

marine_ecology_inoculate :: proc(state: ^Marine_Ecology, world: ^World) -> bool {
	if state == nil || world == nil do return false
	if len(state.cells) != PLANET_SIM_CELL_COUNT || !marine_ecology_valid(state) do return false
	for &cell, index in state.cells {
		if !marine_shallow_habitat(ecology_environment_at_cell(world, index)) do continue
		area := world.planetary.grid.cell_area_m2[index]
		amount := u64(min(u128(area) * 1000, u128(MARINE_MAX_CELL_MASS)))
		marine_seed_cell(&cell, amount)
	}
	state.initial_mass = marine_total_mass(state)
	marine_initial_diagnostics(state)
	return marine_diagnostics_valid(state)
}

marine_ecology_step_state :: proc(state: ^Marine_Ecology, world: ^World) {
	if len(state.cells) == 0 do return
	assert(len(state.cells) == PLANET_SIM_CELL_COUNT)
	forcing, forcing_error := make([]Ecology_Environment, len(state.cells), state.allocator)
	assert(forcing_error == nil)
	if forcing_error != nil do return
	defer delete(forcing, state.allocator)
	for &environment, index in forcing do environment = ecology_environment_at_cell(world, index)
	ok := marine_ecology_advance_fixture(state, forcing, 1, world.planetary.grid.neighbours)
	assert(ok)
	if !ok do return
	state.frozen = false
	assert(marine_total_mass(state) == state.initial_mass)
}
