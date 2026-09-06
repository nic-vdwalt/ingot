package shared

import "core:testing"

@(test)
marine_validation_rejects_invalid_state_without_advancing :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1000000)
	testing.expect(t, marine_ecology_valid(&state))
	forcing := [1]Ecology_Environment{{water_depth_mm = 10000}}
	state.cells[0].cohorts[0].reserve = max(u64)
	before := state.cells[0]
	testing.expect(t, !marine_ecology_advance_fixture(&state, forcing[:], 1))
	testing.expect(t, state.cells[0] == before && state.step == 0)
	state.cells[0].cohorts[0].reserve = 0
	state.cells[0].inorganic = max(u64)
	testing.expect(t, !marine_ecology_valid(&state))
	marine_seed_cell(&state.cells[0], 1000000)
	state.lineages[0].parent = 1
	testing.expect(t, !marine_ecology_valid(&state))
	state.lineages[0].parent = 0
	state.cells[0].cohorts[1].lineage = 1
	testing.expect(t, !marine_ecology_valid(&state))
	state.cells[0].cohorts[1].lineage = 2
	state.elapsed_seconds = 1
	testing.expect(t, !marine_ecology_valid(&state))
	state.elapsed_seconds = 0
	state.initial_mass = 999999
	before = state.cells[0]
	testing.expect(t, !marine_ecology_advance_fixture(&state, forcing[:], 1))
	testing.expect(t, state.cells[0] == before && state.step == 0)
	state.initial_mass = 1000000
	testing.expect(t, marine_ecology_valid(&state))
	neighbours := [1][4]u32{{0, 0, 0, 0}}
	for variant in 0 ..< 4 {
		if variant == 0 do state.cells[0].cohorts[0].reserve = max(u64)
		if variant == 1 do neighbours[0][0] = 1
		if variant == 2 do forcing[0].temperature_mk = -1
		if variant == 3 do forcing[0].bottom_temperature_mk = -1
		before_state := state
		before = state.cells[0]
		lineages := make([]Marine_Lineage, int(state.lineage_count))
		copy(lineages, state.lineages[:state.lineage_count])
		testing.expect(t, !marine_migrate(&state, neighbours[:], forcing[:]))
		testing.expect(t, state.cells[0] == before && state.lineage_count == before_state.lineage_count)
		testing.expect(t, state.step == before_state.step && state.elapsed_seconds == before_state.elapsed_seconds)
		testing.expect(t, state.birth_serial == before_state.birth_serial && state.revision == before_state.revision)
		testing.expect(t, state.local_extinctions == before_state.local_extinctions && state.global_extinctions == before_state.global_extinctions)
		testing.expect(t, state.suppressed_mutations == before_state.suppressed_mutations && state.guild_mass == before_state.guild_mass)
		testing.expect(t, state.frozen == before_state.frozen && state.initial_mass == before_state.initial_mass)
		for lineage, index in lineages do testing.expect(t, lineage == state.lineages[index])
		delete(lineages)
		state.cells[0].cohorts[0].reserve = 0
		neighbours[0][0] = 0
		forcing[0].temperature_mk = 0
		forcing[0].bottom_temperature_mk = 0
	}
}
