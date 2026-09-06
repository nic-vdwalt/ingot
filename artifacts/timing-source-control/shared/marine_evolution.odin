package shared

import "core:slice"

marine_birth :: proc(state: ^Marine_Ecology, cell: ^Marine_Cell, cell_index: int) {
	for parent_index in 0 ..< MARINE_COHORTS_PER_CELL {
		parent := &cell.cohorts[parent_index]
		if parent.mass == 0 || parent.age == 0 || parent.age % MARINE_GENERATION_STEPS != 0 do continue
		traits := state.lineages[parent.lineage - 1].traits
		if parent.reserve < u64(traits.adult_mass) do continue
		if state.birth_serial == max(u64) do return
		state.birth_serial += 1
		hash := ecology_hash_mix(state.seed)
		hash = ecology_hash_mix(hash ~ state.step)
		hash = ecology_hash_mix(hash ~ u64(cell_index))
		hash = ecology_hash_mix(hash ~ u64(parent.lineage))
		hash = ecology_hash_mix(hash ~ state.birth_serial)
		if !state.mutation_enabled || hash % 8 != 0 {
			parent.reserve = 0
			continue
		}
		vacant := -1
		for cohort, index in cell.cohorts do if cohort.mass == 0 { vacant = index; break }
		if vacant < 0 || state.lineage_count >= MARINE_MAX_LINEAGES {
			state.suppressed_mutations = min(state.suppressed_mutations, max(u64) - 1) + 1
			parent.reserve = 0
			continue
		}
		mutated := traits
		delta := i32(20)
		if hash & 256 != 0 do delta = -delta
		switch (hash >> 10) % 6 {
		case 0: mutated.adult_mass = u32(clamp(i32(traits.adult_mass) + delta, 50, 1000))
		case 1: mutated.elongation = u16(clamp(i32(traits.elongation) + delta, 1, 1000))
		case 2: mutated.appendages = u16(clamp(i32(traits.appendages) + delta, 1, 1000))
		case 3: mutated.armour = u16(clamp(i32(traits.armour) + delta, 0, 1000))
		case 4: mutated.oxygen_tolerance = u16(clamp(i32(traits.oxygen_tolerance) + delta, 1, 1000))
		case 5: mutated.feeding_specialization = u16(clamp(i32(traits.feeding_specialization) + delta, 1, 1000))
		}
		state.lineages[state.lineage_count] = {traits = mutated, parent = parent.lineage, born = state.step}
		state.lineage_count += 1
		offspring := &cell.cohorts[vacant]
		offspring^ = {lineage = state.lineage_count}
		marine_transfer(&parent.mass, &offspring.mass, parent.reserve)
		parent.reserve = 0
	}
}

marine_demography :: proc(state: ^Marine_Ecology) {
	occupied: [MARINE_MAX_LINEAGES]bool
	state.guild_mass = {}
	for cell in state.cells {
		for cohort in cell.cohorts {
			if cohort.mass == 0 do continue
			occupied[cohort.lineage - 1] = true
			traits := state.lineages[cohort.lineage - 1].traits
			state.guild_mass[int(traits.guild)] += cohort.mass
		}
	}
	for &lineage, index in state.lineages[:state.lineage_count] {
		if occupied[index] {
			lineage.extinct = false
			lineage.occupied_steps = min(lineage.occupied_steps, max(u64) - 1) + 1
			if lineage.occupied_steps >= 3 * MARINE_GENERATION_STEPS do lineage.established = true
		} else if !lineage.extinct {
			lineage.occupied_steps = 0
			lineage.extinct = true
			state.global_extinctions = min(state.global_extinctions, max(u64) - 1) + 1
		}
	}
}

Marine_Migrant :: struct {
	source, slot, target: int,
	lineage: u32,
	requested, accepted: u64,
}

marine_migrant_less :: proc(first, second: Marine_Migrant) -> bool {
	if first.target != second.target do return first.target < second.target
	if first.lineage != second.lineage do return first.lineage < second.lineage
	return first.source < second.source
}

marine_migrate :: proc(state: ^Marine_Ecology, neighbours: [][4]u32, forcing: []Ecology_Environment) -> bool {
	if !marine_ecology_valid(state) do return false
	if !marine_inputs_valid(state, forcing, neighbours, true) do return false
	migrants, allocation_error := make([]Marine_Migrant, len(state.cells) * MARINE_COHORTS_PER_CELL, state.allocator)
	if allocation_error != nil do return false
	defer delete(migrants, state.allocator)
	marine_migrate_with_workspace(state, neighbours, forcing, migrants)
	return true
}

marine_migrate_with_workspace :: proc(state: ^Marine_Ecology, neighbours: [][4]u32, forcing: []Ecology_Environment, workspace: []Marine_Migrant) {
	migrants := workspace
	count := 0
	for cell, source_index in state.cells {
		for cohort, slot in cell.cohorts {
			if cohort.mass == 0 do continue
			traits := state.lineages[cohort.lineage - 1].traits
			if traits.body == .Sessile do continue
			target := int(neighbours[source_index][int((state.step % 4 + u64(cohort.lineage) % 4) % 4)])
			if target == source_index || !marine_shallow_habitat(forcing[target]) do continue
			amount := cohort.reserve * u64(1000 - traits.armour / 2) / 10_000
			if amount == 0 do continue
			migrants[count] = {source = source_index, slot = slot, target = target, lineage = cohort.lineage, requested = amount}
			count += 1
		}
	}
	migrants = migrants[:count]
	slice.sort_by(migrants, marine_migrant_less)
	copy(state.scratch, state.cells)
	for start := 0; start < count; {
		end := start + 1
		target, lineage := migrants[start].target, migrants[start].lineage
		total := migrants[start].requested
		for end < count && migrants[end].target == target && migrants[end].lineage == lineage {
			total += migrants[end].requested
			end += 1
		}
		vacant := -1
		for candidate, index in state.scratch[target].cohorts {
			if candidate.mass > 0 && candidate.lineage == lineage { vacant = index; break }
			if candidate.mass == 0 && vacant < 0 do vacant = index
		}
		if vacant >= 0 {
			accepted := min(total, MARINE_MAX_CELL_MASS - marine_cell_mass(&state.scratch[target]))
			remaining := accepted
			for &migrant in migrants[start:end] {
				migrant.accepted = u64(u128(accepted) * u128(migrant.requested) / u128(total))
				remaining -= migrant.accepted
			}
			for &migrant in migrants[start:end] {
				if remaining == 0 do break
				if migrant.accepted < migrant.requested {
					migrant.accepted += 1
					remaining -= 1
				}
			}
			if accepted > 0 {
				destination := &state.scratch[target].cohorts[vacant]
				if destination.mass == 0 do destination^ = {lineage = lineage}
				destination.mass += accepted
				destination.reserve += accepted
			}
		}
		start = end
	}
	for migrant in migrants {
		source := &state.scratch[migrant.source].cohorts[migrant.slot]
		source.mass -= migrant.accepted
		source.reserve -= migrant.accepted
	}
	state.cells, state.scratch = state.scratch, state.cells
}
