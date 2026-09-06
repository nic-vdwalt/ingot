package shared

import "core:testing"

@(test)
marine_transfer_is_bounded_and_conservative :: proc(t: ^testing.T) {
	available := u64(7)
	received := u64(3)
	moved := marine_transfer(&available, &received, 20)
	testing.expect(t, moved == 7 && available == 0 && received == 10)
}

@(test)
marine_founders_preserve_initial_mass :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 54019, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1_000_000)
	testing.expect(t, marine_total_mass(&state) == 1_000_000)
	for cohort in state.cells[0].cohorts[:4] {
		testing.expect(t, cohort.mass == 10_000)
		testing.expect(t, cohort.lineage > 0 && cohort.lineage <= 4)
	}
	testing.expect(t, !marine_shallow_habitat({land = true, water_depth_mm = 10_000}))
	testing.expect(t, marine_shallow_habitat({water_depth_mm = 10_000}))
	testing.expect(t, !marine_shallow_habitat({water_depth_mm = 200_001}))
}
