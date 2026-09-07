package shared

import "core:testing"

@(test)
marine_food_web_conserves_mass :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 54019, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1_000_000)
	forcing := [1]Ecology_Environment{{water_depth_mm = 10_000, surface_par = 1000, temperature_mk = 290_000, dissolved_oxygen = 1000}}
	testing.expect(t, marine_ecology_advance_fixture(&state, forcing[:], 2400))
	testing.expect(t, marine_total_mass(&state) == 1_000_000)
	for cohort in state.cells[0].cohorts[:4] do testing.expect(t, cohort.mass > 0)
	forcing[0].land = true
	testing.expect(t, marine_ecology_advance_fixture(&state, forcing[:], 1))
	testing.expect(t, marine_total_mass(&state) == 1_000_000)
	for cohort in state.cells[0].cohorts do testing.expect(t, cohort.mass == 0)
}

@(test)
marine_armour_has_predation_benefit_and_maintenance_cost :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	state.mutation_enabled = false
	state.lineages[1].traits.armour = 0
	state.lineages[2].traits = state.lineages[1].traits
	state.lineages[2].traits.armour = 1000
	control: Marine_Cell
	control.cohorts[0] = {lineage = 2, mass = 100000}
	control.cohorts[1] = {lineage = 3, mass = 100000}
	predated := control
	control.inorganic = 50000
	predated.cohorts[2] = {lineage = 4, mass = 50000}
	environment := Ecology_Environment{water_depth_mm = 10000, dissolved_oxygen = 1000}
	marine_cell_step(&state, &control, environment)
	marine_cell_step(&state, &predated, environment)
	testing.expect(t, control.cohorts[0].mass > control.cohorts[1].mass)
	unarmoured_loss := control.cohorts[0].mass - predated.cohorts[0].mass
	armoured_loss := control.cohorts[1].mass - predated.cohorts[1].mass
	testing.expect(t, unarmoured_loss > armoured_loss && armoured_loss > 0)
	testing.expect(t, marine_cell_mass(&control) == 250000 && marine_cell_mass(&predated) == 250000)
}

@(test)
marine_allocation_is_bounded :: proc(t: ^testing.T) {
	requests: [MARINE_COHORTS_PER_CELL]u64
	requests[0], requests[1], requests[2] = 3, 3, 3
	allocation := marine_allocate(5, requests)
	testing.expect(t, allocation[0] == 2 && allocation[1] == 2 && allocation[2] == 1)
	testing.expect(t, marine_allocate(0, requests) == [MARINE_COHORTS_PER_CELL]u64{})
	keys := [MARINE_COHORTS_PER_CELL]u32{0 = 3, 1 = 1, 2 = 2}
	stable := marine_allocate(5, requests, keys)
	testing.expect(t, stable[0] == 1 && stable[1] == 2 && stable[2] == 2)
	keys[0], keys[1] = keys[1], keys[0]
	permuted := marine_allocate(5, requests, keys)
	testing.expect(t, permuted[0] == stable[1] && permuted[1] == stable[0] && permuted[2] == stable[2])
}

@(test)
marine_feeding_defers_assimilation :: proc(t: ^testing.T) {
	cell := Marine_Cell{producers = 100, deposited = 10}
	cell.cohorts[0] = {lineage = 1, mass = 100}
	requests := [MARINE_COHORTS_PER_CELL]u64{0 = 20}
	gains: [MARINE_COHORTS_PER_CELL]u64
	waste: u64
	marine_feed_pool(&cell, &cell.producers, 100, requests, &gains, &waste)
	testing.expect(t, cell.producers == 80 && cell.cohorts[0].mass == 100)
	testing.expect(t, cell.deposited == 10 && gains[0] == 15 && waste == 5)
	marine_feed_pool(&cell, &cell.deposited, 10, requests, &gains, &waste)
	testing.expect(t, cell.deposited == 0 && gains[0] == 23 && waste == 7)
}
