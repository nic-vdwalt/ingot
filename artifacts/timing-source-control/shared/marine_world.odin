package shared

marine_ecology_inoculate :: proc(state: ^Marine_Ecology, world: ^World) -> bool {
	if len(state.cells) != PLANET_SIM_CELL_COUNT do return false
	for &cell, index in state.cells {
		if !marine_shallow_habitat(ecology_environment_at_cell(world, index)) do continue
		area := world.planetary.grid.cell_area_m2[index]
		amount := u64(min(u128(area) * 1000, u128(MARINE_MAX_CELL_MASS)))
		marine_seed_cell(&cell, amount)
	}
	state.initial_mass = marine_total_mass(state)
	return marine_ecology_valid(state)
}

marine_ecology_step_state :: proc(state: ^Marine_Ecology, world: ^World) {
	if len(state.cells) == 0 do return
	forcing := make([]Ecology_Environment, len(state.cells), state.allocator)
	defer delete(forcing, state.allocator)
	for &environment, index in forcing do environment = ecology_environment_at_cell(world, index)
	ok := marine_ecology_advance_fixture(state, forcing, 1, world.planetary.grid.neighbours)
	assert(ok)
	state.frozen = false
	assert(marine_total_mass(state) == state.initial_mass)
}
