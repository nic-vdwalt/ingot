package shared

import "core:testing"
import "core:mem"

Marine_Test_Allocator :: struct {
	backing: mem.Allocator,
	calls, fail_at, outstanding: int,
}

marine_test_allocator_proc :: proc(data: rawptr, mode: mem.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, loc := #caller_location) -> ([]byte, mem.Allocator_Error) {
	tracker := cast(^Marine_Test_Allocator)data
	if mode == .Alloc {
		tracker.calls += 1
		if tracker.calls == tracker.fail_at do return nil, .Out_Of_Memory
	}
	result, err := tracker.backing.procedure(tracker.backing.data, mode, size, alignment, old_memory, old_size, loc)
	if err == nil {
		if mode == .Alloc && len(result) > 0 do tracker.outstanding += 1
		if mode == .Free && old_memory != nil do tracker.outstanding -= 1
	}
	return result, err
}

@(test)
marine_allocation_failure_is_transactional :: proc(t: ^testing.T) {
	for failure in 1 ..= 3 {
		tracker := Marine_Test_Allocator{backing = context.allocator, fail_at = failure}
		allocator := mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
		state: Marine_Ecology
		testing.expect(t, !marine_ecology_init(&state, 42, allocator, 1))
		marine_ecology_deinit(&state)
		testing.expect(t, tracker.outstanding == 0 && tracker.calls == failure)
	}
	tracker := Marine_Test_Allocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, allocator, 1))
	marine_seed_cell(&state.cells[0], 1000000)
	forcing := [1]Ecology_Environment{{water_depth_mm = 10000}}
	neighbours := [1][4]u32{{0, 0, 0, 0}}
	before := state.cells[0]
	lineages := make([]Marine_Lineage, int(state.lineage_count))
	defer delete(lineages)
	copy(lineages, state.lineages[:state.lineage_count])
	for direct in 0 ..< 2 {
		tracker.fail_at = tracker.calls + 1
		if direct == 0 {
			testing.expect(t, !marine_migrate(&state, neighbours[:], forcing[:]))
		} else {
			testing.expect(t, !marine_ecology_advance_fixture(&state, forcing[:], 5, neighbours[:]))
		}
		testing.expect(t, state.cells[0] == before && tracker.outstanding == 3)
		testing.expect(t, state.step == 0 && state.elapsed_seconds == 0 && state.revision == 0 && state.birth_serial == 0)
		testing.expect(t, !state.frozen && state.lineage_count == 4 && state.guild_mass == [3]u64{})
		testing.expect(t, state.local_extinctions == 0 && state.global_extinctions == 0 && state.suppressed_mutations == 0)
		for lineage, index in lineages do testing.expect(t, lineage == state.lineages[index])
	}
	tracker.fail_at = 0
	calls := tracker.calls
	testing.expect(t, marine_ecology_advance_fixture(&state, forcing[:], 5, neighbours[:]))
	testing.expect(t, tracker.calls == calls + 1 && tracker.outstanding == 3 && state.step == 5)
	testing.expect(t, marine_diagnostics_valid(&state))
	state.guild_mass[0] += 1
	testing.expect(t, !marine_diagnostics_valid(&state))
	state.guild_mass[0] -= 1
	state.lineages[0].extinct = true
	testing.expect(t, !marine_diagnostics_valid(&state))
	marine_ecology_deinit(&state)
	testing.expect(t, tracker.outstanding == 0)
}

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
