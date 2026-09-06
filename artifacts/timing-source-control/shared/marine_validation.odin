package shared

marine_ecology_valid :: proc(state: ^Marine_Ecology) -> bool {
	if state == nil || len(state.cells) == 0 || len(state.cells) > PLANET_SIM_CELL_COUNT do return false
	if len(state.scratch) != len(state.cells) || len(state.lineages) != MARINE_MAX_LINEAGES do return false
	if state.lineage_count < 4 || state.lineage_count > MARINE_MAX_LINEAGES do return false
	if state.step > max(u64) / MARINE_STEP_SECONDS || state.elapsed_seconds != state.step * MARINE_STEP_SECONDS do return false
	for lineage, index in state.lineages[:state.lineage_count] {
		traits := lineage.traits
		if u8(traits.guild) > u8(Marine_Guild.Predator) || u8(traits.body) > u8(Marine_Body.Armoured) do return false
		if traits.adult_mass < 50 || traits.adult_mass > 1000 do return false
		if traits.elongation < 1 || traits.elongation > 1000 || traits.appendages < 1 || traits.appendages > 1000 do return false
		if traits.armour > 1000 || traits.oxygen_tolerance < 1 || traits.oxygen_tolerance > 1000 do return false
		if traits.feeding_specialization < 1 || traits.feeding_specialization > 1000 do return false
		if lineage.parent > u32(index) || lineage.born > state.step do return false
		if index < 4 && lineage.parent != 0 do return false
		if index >= 4 && lineage.parent == 0 do return false
	}
	for cell in state.cells {
		remaining := MARINE_MAX_CELL_MASS
		pools := [4]u64{cell.inorganic, cell.producers, cell.suspended, cell.deposited}
		for pool in pools {
			if pool > remaining do return false
			remaining -= pool
		}
		for cohort, slot in cell.cohorts {
			if cohort.mass > remaining || cohort.reserve > cohort.mass do return false
			remaining -= cohort.mass
			if cohort.lineage > state.lineage_count do return false
			if cohort.mass == 0 do continue
			if cohort.lineage == 0 do return false
			for prior, prior_slot in cell.cohorts do if prior_slot < slot && prior.mass > 0 && prior.lineage == cohort.lineage do return false
		}
	}
	if state.initial_mass != 0 && state.initial_mass != marine_total_mass(state) do return false
	return true
}

marine_diagnostics_valid :: proc(state: ^Marine_Ecology) -> bool {
	if !marine_ecology_valid(state) do return false
	occupied: [MARINE_MAX_LINEAGES]bool
	guild_mass: [3]u64
	for cell in state.cells do for cohort in cell.cohorts {
		if cohort.mass == 0 do continue
		occupied[cohort.lineage - 1] = true
		guild_mass[int(state.lineages[cohort.lineage - 1].traits.guild)] += cohort.mass
	}
	if guild_mass != state.guild_mass do return false
	for lineage, index in state.lineages[:state.lineage_count] {
		if lineage.extinct == occupied[index] do return false
		if lineage.extinct && lineage.occupied_steps != 0 do return false
	}
	return true
}

marine_inputs_valid :: proc(state: ^Marine_Ecology, forcing: []Ecology_Environment, neighbours: [][4]u32, require_neighbours: bool) -> bool {
	if state == nil || len(forcing) != len(state.cells) do return false
	for environment in forcing {
		if environment.temperature_mk < 0 || environment.bottom_temperature_mk < 0 do return false
	}
	if len(neighbours) == 0 do return !require_neighbours
	if len(neighbours) != len(state.cells) do return false
	for adjacent in neighbours do for target in adjacent do if u64(target) >= u64(len(state.cells)) do return false
	return true
}
