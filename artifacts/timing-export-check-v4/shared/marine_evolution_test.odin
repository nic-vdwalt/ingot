package shared

import "core:testing"

@(test)
marine_descendants_establish_and_replay :: proc(t: ^testing.T) {
	first, second: Marine_Ecology
	testing.expect(t, marine_ecology_init(&first, 54019, context.allocator, 1))
	testing.expect(t, marine_ecology_init(&second, 54019, context.allocator, 1))
	defer marine_ecology_deinit(&first)
	defer marine_ecology_deinit(&second)
	marine_seed_cell(&first.cells[0], 1_000_000)
	marine_seed_cell(&second.cells[0], 1_000_000)
	forcing := [1]Ecology_Environment{{water_depth_mm = 10_000, surface_par = 1000, temperature_mk = 290_000, dissolved_oxygen = 1000}}
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 2400))
	testing.expect(t, marine_ecology_advance_fixture(&second, forcing[:], 2400))
	testing.expect(t, first.cells[0] == second.cells[0])
	testing.expect(t, first.birth_serial == second.birth_serial)
	established := false
	for lineage in first.lineages[4:first.lineage_count] do established ||= lineage.established
	testing.expect(t, established)
	testing.expect(t, marine_total_mass(&first) == 1_000_000)
}

@(test)
marine_migration_preserves_mass_and_rejects_full_cells :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 2))
	defer marine_ecology_deinit(&state)
	state.cells[0].cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	forcing := [2]Ecology_Environment{{water_depth_mm = 10000}, {water_depth_mm = 10000}}
	neighbours := [2][4]u32{{1, 1, 1, 1}, {0, 0, 0, 0}}
	testing.expect(t, marine_migrate(&state, neighbours[:], forcing[:]))
	testing.expect(t, marine_total_mass(&state) == 10000)
	testing.expect(t, state.cells[1].cohorts[0].mass > 0)
	testing.expect(t, state.cells[0].cohorts[0].reserve + state.cells[1].cohorts[0].reserve == 1000)
	state.cells[1] = {}
	state.lineage_count = 12
	for index in 4 ..< 12 {
		state.lineages[index] = {traits = state.lineages[0].traits, parent = 1}
		state.cells[1].cohorts[index - 4] = {lineage = u32(index + 1), mass = 100}
	}
	before := state.cells[0]
	testing.expect(t, marine_migrate(&state, neighbours[:], forcing[:]))
	testing.expect(t, state.cells[0] == before)
	neighbours[0][0] = 2
	before_mass := marine_total_mass(&state)
	testing.expect(t, !marine_migrate(&state, neighbours[:], forcing[:]))
	testing.expect(t, marine_total_mass(&state) == before_mass)
}

@(test)
marine_migration_aggregates_arrivals_and_ignores_slot_order :: proc(t: ^testing.T) {
	first, second: Marine_Ecology
	testing.expect(t, marine_ecology_init(&first, 42, context.allocator, 3))
	testing.expect(t, marine_ecology_init(&second, 42, context.allocator, 3))
	defer marine_ecology_deinit(&first)
	defer marine_ecology_deinit(&second)
	first.cells[0].cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	first.cells[1].cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	first.cells[2].inorganic = MARINE_MAX_CELL_MASS - 101
	copy(second.cells, first.cells)
	second.cells[0].cohorts[7] = second.cells[0].cohorts[0]
	second.cells[0].cohorts[0] = {}
	forcing := [3]Ecology_Environment{{water_depth_mm = 10000}, {water_depth_mm = 10000}, {water_depth_mm = 10000}}
	neighbours := [3][4]u32{{0, 0, 2, 0}, {1, 1, 2, 1}, {2, 2, 2, 2}}
	before := marine_total_mass(&first)
	testing.expect(t, marine_migrate(&first, neighbours[:], forcing[:]))
	testing.expect(t, marine_migrate(&second, neighbours[:], forcing[:]))
	testing.expect(t, first.cells[2].cohorts[0].mass == 101)
	testing.expect(t, first.cells[0].cohorts[0].mass == 9949)
	testing.expect(t, first.cells[1].cohorts[0].mass == 9950)
	testing.expect(t, first.cells[0].cohorts[0] == second.cells[0].cohorts[7])
	testing.expect(t, first.cells[1] == second.cells[1] && first.cells[2] == second.cells[2])
	testing.expect(t, marine_total_mass(&first) == before && marine_total_mass(&second) == before)
	testing.expect(t, marine_ecology_valid(&first) && marine_ecology_valid(&second))
}

@(test)
marine_traits_have_matched_ecological_costs :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	state.lineages[1].traits = {guild = .Deposit, body = .Worm, adult_mass = 100, elongation = 500, appendages = 300, oxygen_tolerance = 1, feeding_specialization = 500}
	state.lineages[2].traits = state.lineages[1].traits
	state.lineages[2].traits.oxygen_tolerance = 1000
	initial: Marine_Cell
	initial.cohorts[0] = {lineage = 2, mass = 100000}
	initial.cohorts[1] = {lineage = 3, mass = 100000}
	oxic, hypoxic := initial, initial
	marine_cell_step(&state, &oxic, {water_depth_mm = 10000, dissolved_oxygen = 1000})
	marine_cell_step(&state, &hypoxic, {water_depth_mm = 10000})
	testing.expect(t, oxic.cohorts[0].mass > oxic.cohorts[1].mass)
	testing.expect(t, hypoxic.cohorts[0].mass < hypoxic.cohorts[1].mass)
	state.lineages[2].traits = state.lineages[1].traits
	state.lineages[2].traits.adult_mass = 1000
	large := initial
	marine_cell_step(&state, &large, {water_depth_mm = 10000, dissolved_oxygen = 1000})
	testing.expect(t, large.cohorts[0].mass > large.cohorts[1].mass)
	state.lineages[2].traits = state.lineages[1].traits
	state.lineages[2].traits.feeding_specialization = 1000
	feeding := initial
	feeding.deposited = 100000
	marine_cell_step(&state, &feeding, {water_depth_mm = 10000, dissolved_oxygen = 1000})
	testing.expect(t, feeding.cohorts[1].mass > feeding.cohorts[0].mass)
	testing.expect(t, marine_cell_mass(&oxic) == 200000 && marine_cell_mass(&hypoxic) == 200000)
	testing.expect(t, marine_cell_mass(&large) == 200000 && marine_cell_mass(&feeding) == 300000)
	lost := initial
	before_extinctions := state.local_extinctions
	marine_cell_step(&state, &lost, {land = true})
	testing.expect(t, state.local_extinctions == before_extinctions + 2)
	testing.expect(t, marine_cell_mass(&lost) == 200000)
}

@(test)
marine_migration_crosses_planetary_seams :: proc(t: ^testing.T) {
	grid: Planet_Sim_Grid
	planet_sim_grid_init(&grid, planet_physical_earthlike())
	defer planet_sim_grid_deinit(&grid)
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42))
	defer marine_ecology_deinit(&state)
	forcing := make([]Ecology_Environment, PLANET_SIM_CELL_COUNT)
	defer delete(forcing)
	for &environment in forcing do environment.water_depth_mm = 10000
	found := false
	for adjacent, source in grid.neighbours {
		for target, edge in adjacent {
			if planet_sim_coord_for_index(source).face == planet_sim_coord_for_index(int(target)).face do continue
			state.step = u64((edge + 2) % 4)
			state.elapsed_seconds = state.step * MARINE_STEP_SECONDS
			state.cells[source].cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
			reciprocal := false
			for neighbour in grid.neighbours[target] do reciprocal ||= neighbour == u32(source)
			testing.expect(t, reciprocal)
			testing.expect(t, marine_migrate(&state, grid.neighbours, forcing))
			testing.expect(t, state.cells[target].cohorts[0].mass > 0)
			testing.expect(t, marine_total_mass(&state) == 10000 && marine_ecology_valid(&state))
			testing.expect(t, state.cells[source].cohorts[0].reserve + state.cells[target].cohorts[0].reserve == 1000)
			found = true
			break
		}
		if found do break
	}
	testing.expect(t, found)
}

@(test)
marine_migration_competing_lineages_and_reciprocal_capacity :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 3))
	defer marine_ecology_deinit(&state)
	state.lineage_count = 11
	for index in 4 ..< 11 {
		state.lineages[index] = {traits = state.lineages[0].traits, parent = 1}
		state.cells[2].cohorts[index - 4] = {lineage = u32(index + 1), mass = 100}
	}
	state.cells[0].cohorts[7] = {lineage = 3, mass = 10000, reserve = 1000}
	state.cells[1].cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	forcing := [3]Ecology_Environment{{water_depth_mm = 10000}, {water_depth_mm = 10000}, {water_depth_mm = 10000}}
	neighbours := [3][4]u32{{2, 2, 2, 2}, {2, 2, 2, 2}, {2, 2, 2, 2}}
	testing.expect(t, marine_migrate(&state, neighbours[:], forcing[:]))
	testing.expect(t, state.cells[2].cohorts[7].lineage == 2)
	testing.expect(t, state.cells[0].cohorts[7].mass == 10000)
	testing.expect(t, marine_total_mass(&state) == 20700)
	state.cells[0] = {}
	state.cells[1] = {}
	state.cells[2] = {}
	for &cell in state.cells[:2] {
		cell.inorganic = MARINE_MAX_CELL_MASS - 10000
		cell.cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	}
	neighbours[0] = {1, 1, 1, 1}
	neighbours[1] = {0, 0, 0, 0}
	before_first, before_second := state.cells[0], state.cells[1]
	testing.expect(t, marine_migrate(&state, neighbours[:], forcing[:]))
	testing.expect(t, state.cells[0] == before_first && state.cells[1] == before_second)
	testing.expect(t, marine_ecology_valid(&state))
}

@(test)
marine_inheritance_seed_bounds_and_controls :: proc(t: ^testing.T) {
	first, second: Marine_Ecology
	testing.expect(t, marine_ecology_init(&first, 54019, context.allocator, 1))
	testing.expect(t, marine_ecology_init(&second, 54019, context.allocator, 1))
	defer marine_ecology_deinit(&first)
	defer marine_ecology_deinit(&second)
	for index in 0 ..< 4 do testing.expect(t, first.lineages[index] == second.lineages[index])
	varied := false
	for seed in 1 ..< 5 {
		candidate: Marine_Ecology
		testing.expect(t, marine_ecology_init(&candidate, u64(seed), context.allocator, 1))
		for index in 0 ..< 4 {
			traits, baseline := candidate.lineages[index].traits, first.lineages[index].traits
			varied ||= traits != baseline
			testing.expect(t, traits.guild == baseline.guild && traits.body == baseline.body)
		}
		testing.expect(t, marine_ecology_valid(&candidate))
		marine_ecology_deinit(&candidate)
	}
	testing.expect(t, varied)
	marine_seed_cell(&first.cells[0], 1000000)
	marine_seed_cell(&second.cells[0], 1000000)
	second.mutation_enabled = false
	forcing := [1]Ecology_Environment{{water_depth_mm = 10000, surface_par = 1000, temperature_mk = 290000, dissolved_oxygen = 1000}}
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 2400))
	testing.expect(t, marine_ecology_advance_fixture(&second, forcing[:], 2400))
	testing.expect(t, second.lineage_count == 4 && second.birth_serial > 0 && first.lineage_count > 4)
	for lineage, index in first.lineages[4:first.lineage_count] {
		testing.expect(t, lineage.parent > 0 && lineage.parent <= u32(index + 4))
		parent := first.lineages[lineage.parent - 1].traits
		traits := lineage.traits
		testing.expect(t, traits.guild == parent.guild && traits.body == parent.body)
		values := [6]i32{i32(traits.adult_mass), i32(traits.elongation), i32(traits.appendages), i32(traits.armour), i32(traits.oxygen_tolerance), i32(traits.feeding_specialization)}
		parents := [6]i32{i32(parent.adult_mass), i32(parent.elongation), i32(parent.appendages), i32(parent.armour), i32(parent.oxygen_tolerance), i32(parent.feeding_specialization)}
		changed := 0
		for value, trait_index in values {
			if value != parents[trait_index] do changed += 1
			testing.expect(t, abs(value - parents[trait_index]) <= 20)
		}
		testing.expect(t, changed <= 1)
	}
	testing.expect(t, marine_ecology_valid(&first) && marine_ecology_valid(&second))
	testing.expect(t, marine_total_mass(&first) == marine_total_mass(&second))
}

@(test)
marine_birth_controls_and_capacity :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 54019, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	cell := &state.cells[0]
	cell.cohorts[0] = {lineage = 2, mass = 10000, reserve = 1000}
	marine_birth(&state, cell, 0)
	testing.expect(t, state.birth_serial == 0)
	cell.cohorts[0].age = MARINE_GENERATION_STEPS
	state.mutation_enabled = false
	marine_birth(&state, cell, 0)
	testing.expect(t, state.lineage_count == 4 && cell.cohorts[0].mass == 10000)
	state.mutation_enabled = true
	state.lineage_count = MARINE_MAX_LINEAGES
	for _ in 0 ..< 256 {
		cell.cohorts[0].reserve = 1000
		marine_birth(&state, cell, 0)
	}
	testing.expect(t, state.suppressed_mutations > 0)
	testing.expect(t, state.lineage_count == MARINE_MAX_LINEAGES)
	testing.expect(t, marine_total_mass(&state) == 10000)
	state.suppressed_mutations = max(u64)
	for _ in 0 ..< 256 {
		cell.cohorts[0].reserve = 1000
		marine_birth(&state, cell, 0)
	}
	testing.expect(t, state.suppressed_mutations == max(u64))
	state.birth_serial = max(u64)
	cell.cohorts[0].reserve = 1000
	before := cell^
	marine_birth(&state, cell, 0)
	testing.expect(t, state.birth_serial == max(u64) && cell^ == before)
	state.lineage_count = 4
	state.global_extinctions = max(u64)
	marine_demography(&state)
	testing.expect(t, state.global_extinctions == max(u64))
}

@(test)
marine_establishment_requires_continuous_occupancy :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	state.lineages[0].established = false
	state.cells[0].cohorts[0] = {lineage = 1, mass = 100}
	for _ in 0 ..< 71 do marine_demography(&state)
	testing.expect(t, !state.lineages[0].established)
	state.cells[0].cohorts[0] = {}
	marine_demography(&state)
	testing.expect(t, state.lineages[0].extinct && state.lineages[0].occupied_steps == 0)
	state.cells[0].cohorts[0] = {lineage = 1, mass = 100}
	marine_demography(&state)
	testing.expect(t, !state.lineages[0].extinct && !state.lineages[0].established)
	for _ in 0 ..< 71 do marine_demography(&state)
	testing.expect(t, state.lineages[0].established)
}
