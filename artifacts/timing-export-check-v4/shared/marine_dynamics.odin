package shared

marine_allocate :: proc(supply: u64, requests: [MARINE_COHORTS_PER_CELL]u64, keys := [MARINE_COHORTS_PER_CELL]u32{}) -> [MARINE_COHORTS_PER_CELL]u64 {
	total: u64
	for request in requests {
		assert(request <= MARINE_MAX_CELL_MASS)
		total += request
	}
	result: [MARINE_COHORTS_PER_CELL]u64
	if total == 0 do return result
	budget := min(supply, total)
	remaining := budget
	for request, index in requests {
		result[index] = u64(u128(budget) * u128(request) / u128(total))
		remaining -= result[index]
	}
	awarded: [MARINE_COHORTS_PER_CELL]bool
	for remaining > 0 {
		chosen := -1
		for request, index in requests {
			if awarded[index] || result[index] >= request do continue
			if chosen < 0 || keys[index] < keys[chosen] do chosen = index
		}
		assert(chosen >= 0)
		result[chosen] += 1
		awarded[chosen] = true
		remaining -= 1
	}
	return result
}

marine_feed_pool :: proc(cell: ^Marine_Cell, source: ^u64, supply: u64, requests: [MARINE_COHORTS_PER_CELL]u64, gains: ^[MARINE_COHORTS_PER_CELL]u64, waste: ^u64) {
	keys: [MARINE_COHORTS_PER_CELL]u32
	for cohort, index in cell.cohorts do keys[index] = cohort.lineage
	allocation := marine_allocate(supply, requests, keys)
	for amount, index in allocation {
		assert(source^ >= amount)
		source^ -= amount
		gains[index] += amount - amount / 4
		waste^ += amount / 4
	}
}

marine_cell_step :: proc(state: ^Marine_Ecology, cell: ^Marine_Cell, environment: Ecology_Environment) {
	before := marine_cell_mass(cell)
	if !marine_shallow_habitat(environment) {
		marine_transfer(&cell.producers, &cell.deposited, cell.producers)
		for &cohort in cell.cohorts {
			if cohort.mass > 0 do state.local_extinctions = min(state.local_extinctions, max(u64) - 1) + 1
			marine_transfer(&cohort.mass, &cell.deposited, cohort.mass)
			cohort = {}
		}
		return
	}
	if environment.surface_par > 0 && environment.temperature_mk >= 273_000 && environment.temperature_mk <= 310_000 {
		marine_transfer(&cell.inorganic, &cell.producers, cell.producers / 5)
	}
	marine_transfer(&cell.producers, &cell.suspended, cell.producers / 100)
	marine_transfer(&cell.producers, &cell.inorganic, cell.producers / 200)
	producer_requests, suspended_requests, deposit_requests: [MARINE_COHORTS_PER_CELL]u64
	prey_requests: [MARINE_COHORTS_PER_CELL][MARINE_COHORTS_PER_CELL]u64
	for cohort, index in cell.cohorts {
		if cohort.mass == 0 do continue
		traits := state.lineages[cohort.lineage - 1].traits
		request := cohort.mass * u64(750 + traits.feeding_specialization / 2) / 16_000
		if environment.dissolved_oxygen == 0 do request /= 4
		switch traits.guild {
		case .Suspension:
			producer_requests[index] = request / 2
			suspended_requests[index] = request - request / 2
		case .Deposit:
			deposit_requests[index] = request
		case .Predator:
			for prey, prey_index in cell.cohorts {
				if prey.mass == 0 do continue
				prey_traits := state.lineages[prey.lineage - 1].traits
				if prey_traits.guild == .Predator do continue
				prey_requests[prey_index][index] = min(prey.mass / 100, request * u64(1000 - prey_traits.armour / 2) / 4000)
			}
		}
	}
	gains: [MARINE_COHORTS_PER_CELL]u64
	waste: u64
	marine_feed_pool(cell, &cell.producers, cell.producers / 20, producer_requests, &gains, &waste)
	marine_feed_pool(cell, &cell.suspended, cell.suspended / 20, suspended_requests, &gains, &waste)
	marine_feed_pool(cell, &cell.deposited, cell.deposited, deposit_requests, &gains, &waste)
	for requests, prey_index in prey_requests {
		prey := &cell.cohorts[prey_index]
		marine_feed_pool(cell, &prey.mass, prey.mass / 20, requests, &gains, &waste)
		prey.reserve = min(prey.reserve, prey.mass)
	}
	cell.deposited += waste
	for gain, index in gains {
		cell.cohorts[index].mass += gain
		cell.cohorts[index].reserve += gain / 4
	}
	for &cohort in cell.cohorts {
		if cohort.mass == 0 {
			if cohort.lineage != 0 do state.local_extinctions = min(state.local_extinctions, max(u64) - 1) + 1
			cohort = {}
			continue
		}
		traits := state.lineages[cohort.lineage - 1].traits
		cost := cohort.mass * (20 + u64(traits.adult_mass / 100) + u64(traits.armour / 100 + traits.appendages / 100 + traits.oxygen_tolerance / 100 + traits.elongation / 250)) / 10_000
		marine_transfer(&cohort.mass, &cell.inorganic, max(u64(1), cost))
		stress := cohort.mass / 500
		if environment.dissolved_oxygen == 0 do stress += cohort.mass * u64(1000 - traits.oxygen_tolerance) / 10_000
		marine_transfer(&cohort.mass, &cell.deposited, stress)
		cohort.reserve = min(cohort.reserve, cohort.mass)
		cohort.age = min(cohort.age, max(u64) - 1) + 1
		if cohort.mass == 0 {
			state.local_extinctions = min(state.local_extinctions, max(u64) - 1) + 1
			cohort = {}
		}
	}
	marine_transfer(&cell.suspended, &cell.deposited, cell.suspended / 100)
	marine_transfer(&cell.deposited, &cell.inorganic, cell.deposited / 50)
	assert(marine_cell_mass(cell) == before)
}

marine_ecology_advance_fixture :: proc(state: ^Marine_Ecology, forcing: []Ecology_Environment, steps: u32, neighbours: [][4]u32 = nil) -> bool {
	if !marine_ecology_valid(state) do return false
	if steps > 100_000 || !marine_inputs_valid(state, forcing, neighbours, false) do return false
	if state.revision > max(u64) - u64(steps) do return false
	birth_bound := u64(steps) * u64(len(state.cells)) * MARINE_COHORTS_PER_CELL
	if state.birth_serial > max(u64) - birth_bound do return false
	if state.elapsed_seconds > max(u64) - u64(steps) * MARINE_STEP_SECONDS do return false
	migrants: []Marine_Migrant
	if steps > 0 && len(neighbours) != 0 {
		storage, allocation_error := make([]Marine_Migrant, len(state.cells) * MARINE_COHORTS_PER_CELL, state.allocator)
		if allocation_error != nil do return false
		migrants = storage
	}
	defer delete(migrants, state.allocator)
	for _ in 0 ..< steps {
		copy(state.scratch, state.cells)
		for &cell, index in state.scratch {
			marine_cell_step(state, &cell, forcing[index])
			marine_birth(state, &cell, index)
		}
		state.cells, state.scratch = state.scratch, state.cells
		if len(neighbours) != 0 {
			marine_migrate_with_workspace(state, neighbours, forcing, migrants)
		}
		marine_demography(state)
		state.step += 1
		state.elapsed_seconds += MARINE_STEP_SECONDS
		state.revision += 1
		assert(marine_diagnostics_valid(state))
	}
	state.frozen = true
	return true
}
