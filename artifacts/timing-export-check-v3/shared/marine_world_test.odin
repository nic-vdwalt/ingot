package shared

import "core:mem"
import "core:testing"
import ecs "ingot:ecs"

@(test)
marine_world_cadence_and_snapshot :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.marine_ecology
	testing.expect(t, len(state.cells) == PLANET_SIM_CELL_COUNT)
	testing.expect(t, marine_total_mass(state) == state.initial_mass)
	world_ecology_step(world, 1)
	testing.expect(t, state.step == 0)
	world_ecology_step(world, MARINE_CADENCE_TICKS)
	testing.expect(t, state.step == 1 && state.elapsed_seconds == MARINE_STEP_SECONDS && !state.frozen)
	buffer := make([]u8, world_snapshot_size(world))
	defer delete(buffer)
	_, ok := world_snapshot_write(world, buffer)
	testing.expect(t, ok)
	world_ecology_step(world, 2 * MARINE_CADENCE_TICKS)
	mass, serial := marine_total_mass(state), state.birth_serial
	expected := make([]u8, marine_ecology_snapshot_size(state))
	defer delete(expected)
	_, expected_ok := marine_ecology_snapshot_write(state, expected)
	testing.expect(t, expected_ok)
	testing.expect(t, world_snapshot_read(world, buffer))
	testing.expect(t, state.step == 1)
	world_ecology_step(world, 2 * MARINE_CADENCE_TICKS)
	testing.expect(t, state.step == 2 && marine_total_mass(state) == mass && state.birth_serial == serial)
	actual := make([]u8, marine_ecology_snapshot_size(state))
	defer delete(actual)
	_, actual_ok := marine_ecology_snapshot_write(state, actual)
	testing.expect(t, actual_ok && len(actual) == len(expected))
	if len(actual) == len(expected) {
		for value, index in expected do testing.expect(t, value == actual[index])
	}
	testing.expect(t, marine_diagnostics_valid(state))
	testing.expect(t, len(state.cells) == PLANET_SIM_CELL_COUNT && len(state.scratch) == PLANET_SIM_CELL_COUNT && len(state.lineages) == MARINE_MAX_LINEAGES)
	testing.expect(t, state.allocator.procedure == world.allocator.procedure && state.allocator.data == world.allocator.data)
}

@(test)
marine_world_initial_inoculation_diagnostics :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.marine_ecology
	expected_mass: u64
	expected_guilds: [3]u64
	for &cell, index in state.cells {
		if marine_shallow_habitat(ecology_environment_at_cell(world, index)) {
			amount := u64(min(u128(world.planetary.grid.cell_area_m2[index]) * 1000, u128(MARINE_MAX_CELL_MASS)))
			expected_mass += amount
			testing.expect(t, marine_cell_mass(&cell) == amount)
			for cohort, founder in cell.cohorts[:4] {
				testing.expect(t, cohort.lineage == u32(founder + 1) && cohort.mass == amount / 100)
				expected_guilds[int(state.lineages[founder].traits.guild)] += amount / 100
			}
		} else {
			testing.expect(t, marine_cell_mass(&cell) == 0)
		}
	}
	testing.expect(t, state.initial_mass == expected_mass && state.guild_mass == expected_guilds)
	testing.expect(t, marine_diagnostics_valid(state))
	testing.expect(t, state.step == 0 && state.elapsed_seconds == 0 && state.revision == 0 && state.global_extinctions == 0 && state.local_extinctions == 0)
	for lineage in state.lineages[:state.lineage_count] do testing.expect(t, lineage.occupied_steps == 0 && lineage.established)
	for &depth in world.planetary.ocean.mean_depth_mm do depth = 200001
	for scenario in 0 ..< 2 {
		fresh: Marine_Ecology
		testing.expect(t, marine_ecology_init(&fresh, 42))
		if scenario == 0 {
			depths := [4]u32{999, 1000, 200000, 200001}
			for depth, index in depths do world.planetary.ocean.mean_depth_mm[index] = depth
		} else {
			for &depth in world.planetary.ocean.mean_depth_mm do depth = 200001
		}
		testing.expect(t, marine_ecology_inoculate(&fresh, world))
		testing.expect(t, marine_diagnostics_valid(&fresh))
		for &cell, index in fresh.cells {
			if scenario == 0 && (index == 1 || index == 2) {
				testing.expect(t, marine_cell_mass(&cell) > 0)
			} else {
				testing.expect(t, marine_cell_mass(&cell) == 0)
			}
		}
		testing.expect(t, fresh.step == 0 && fresh.elapsed_seconds == 0 && fresh.global_extinctions == 0 && fresh.local_extinctions == 0)
		for lineage in fresh.lineages[:fresh.lineage_count] {
			testing.expect(t, lineage.occupied_steps == 0 && lineage.established)
			if scenario == 1 do testing.expect(t, lineage.extinct)
		}
		buffer := make([]u8, marine_ecology_snapshot_size(&fresh))
		_, ok := marine_ecology_snapshot_write(&fresh, buffer)
		testing.expect(t, ok && marine_ecology_snapshot_read(&fresh, buffer))
		testing.expect(t, marine_diagnostics_valid(&fresh))
		if scenario == 1 do testing.expect(t, fresh.initial_mass == 0 && marine_total_mass(&fresh) == 0)
		delete(buffer)
		marine_ecology_deinit(&fresh)
	}
}

@(test)
marine_world_live_cadence_and_forcing :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	marine_ecology_step_state(&world.marine_ecology, world)
	testing.expect(t, world.marine_ecology.step == 0 && len(world.marine_ecology.cells) == 0)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.marine_ecology
	for tick in u64(1) ..= 24 {
		before_bytes := make([]u8, marine_ecology_snapshot_size(state))
		_, before_ok := marine_ecology_snapshot_write(state, before_bytes)
		testing.expect(t, before_ok)
		before_step, before_revision := state.step, state.revision
		before_serial, before_mass := state.birth_serial, marine_total_mass(state)
		world_ecology_step(world, tick)
		testing.expect(t, state.step == tick / MARINE_CADENCE_TICKS)
		if tick % MARINE_CADENCE_TICKS != 0 {
			testing.expect(t, state.step == before_step && state.revision == before_revision && state.birth_serial == before_serial && marine_total_mass(state) == before_mass)
			after_bytes := make([]u8, marine_ecology_snapshot_size(state))
			_, after_ok := marine_ecology_snapshot_write(state, after_bytes)
			testing.expect(t, after_ok && len(before_bytes) == len(after_bytes))
			if len(before_bytes) == len(after_bytes) {
				for value, index in before_bytes do testing.expect(t, value == after_bytes[index])
			}
			delete(after_bytes)
		}
		delete(before_bytes)
	}
	testing.expect(t, state.elapsed_seconds == 2 * MARINE_STEP_SECONDS && !state.frozen)
	for &depth, index in world.planetary.ocean.mean_depth_mm {
		depth = 10000
		if index % 2 == 0 do depth = 200001
		world.planetary.biogeochemistry.surface_par[index] = 0
		world.planetary.biogeochemistry.dissolved_oxygen[index] = 0
	}
	forcing := make([]Ecology_Environment, PLANET_SIM_CELL_COUNT)
	defer delete(forcing)
	for &environment, index in forcing {
		environment = ecology_environment_at_cell(world, index)
		testing.expect(t, environment.surface_par == 0 && environment.dissolved_oxygen == 0)
		testing.expect(t, environment.water_depth_mm == world.planetary.ocean.mean_depth_mm[index])
	}
	buffer := make([]u8, marine_ecology_snapshot_size(state))
	defer delete(buffer)
	_, saved := marine_ecology_snapshot_write(state, buffer)
	testing.expect(t, saved)
	fixture: Marine_Ecology
	testing.expect(t, marine_ecology_snapshot_read(&fixture, buffer))
	defer marine_ecology_deinit(&fixture)
	testing.expect(t, marine_ecology_advance_fixture(&fixture, forcing, 1, world.planetary.grid.neighbours))
	marine_ecology_step_state(state, world)
	testing.expect(t, fixture.frozen && !state.frozen)
	fixture.frozen = false
	expected := make([]u8, marine_ecology_snapshot_size(&fixture))
	actual := make([]u8, marine_ecology_snapshot_size(state))
	defer delete(expected)
	defer delete(actual)
	_, expected_ok := marine_ecology_snapshot_write(&fixture, expected)
	_, actual_ok := marine_ecology_snapshot_write(state, actual)
	testing.expect(t, expected_ok && actual_ok && len(expected) == len(actual))
	if len(expected) == len(actual) {
		for value, index in expected do testing.expect(t, value == actual[index])
	}
	testing.expect(t, marine_diagnostics_valid(state) && marine_diagnostics_valid(&fixture))
}

@(test)
marine_initial_diagnostics_preserves_history :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1_000_000)
	state.initial_mass = 1_000_000
	state.birth_serial = 17
	state.local_extinctions = 3
	state.global_extinctions = 2
	state.suppressed_mutations = 7
	state.lineages[0].occupied_steps = 13
	state.lineages[1].established = false
	before := state
	cell := state.cells[0]
	scratch := state.scratch[0]
	lineages: [4]Marine_Lineage
	copy(lineages[:], state.lineages[:4])
	marine_initial_diagnostics(&state)
	testing.expect(t, state.cells[0] == cell && state.scratch[0] == scratch)
	testing.expect(t, state.guild_mass == [3]u64{10000, 20000, 10000})
	testing.expect(t, state.seed == before.seed && state.step == before.step && state.elapsed_seconds == before.elapsed_seconds)
	testing.expect(t, state.revision == before.revision && state.initial_mass == before.initial_mass && state.birth_serial == before.birth_serial)
	testing.expect(t, state.local_extinctions == before.local_extinctions && state.global_extinctions == before.global_extinctions && state.suppressed_mutations == before.suppressed_mutations)
	testing.expect(t, state.mutation_enabled == before.mutation_enabled && state.frozen == before.frozen)
	for lineage, index in lineages {
		testing.expect(t, state.lineages[index].traits == lineage.traits && state.lineages[index].parent == lineage.parent && state.lineages[index].born == lineage.born)
		testing.expect(t, state.lineages[index].occupied_steps == lineage.occupied_steps && state.lineages[index].established == lineage.established && !state.lineages[index].extinct)
	}
	testing.expect(t, marine_diagnostics_valid(&state))
}

marine_world_expect_rejected :: proc(t: ^testing.T, world: ^World, corrupt, baseline, actual: []u8) {
	before := world.marine_ecology
	testing.expect(t, !world_snapshot_read(world, corrupt))
	testing.expect(t, raw_data(world.marine_ecology.cells) == raw_data(before.cells) && raw_data(world.marine_ecology.lineages) == raw_data(before.lineages))
	testing.expect(t, world.marine_ecology.allocator.procedure == before.allocator.procedure && world.marine_ecology.allocator.data == before.allocator.data)
	written, ok := world_snapshot_write(world, actual)
	testing.expect(t, ok && written == len(baseline))
	equal := true
	for value, index in baseline do if value != actual[index] { equal = false; break }
	testing.expect(t, equal)
}

@(test)
marine_world_rejects_invalid_nested_payloads :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	world_ecology_step(world, MARINE_CADENCE_TICKS)
	baseline := make([]u8, world_snapshot_size(world))
	corrupt := make([]u8, len(baseline))
	actual := make([]u8, len(baseline))
	defer delete(baseline)
	defer delete(corrupt)
	defer delete(actual)
	_, saved := world_snapshot_write(world, baseline)
	testing.expect(t, saved)
	cursor := len(baseline) - 8
	flora_length: u64
	testing.expect(t, marine_snapshot_scalar(baseline, &cursor, &flora_length, true))
	flora_start := len(baseline) - int(flora_length)
	cursor = flora_start - 8
	marine_length: u64
	testing.expect(t, marine_snapshot_scalar(baseline, &cursor, &marine_length, true))
	marine_start := flora_start - int(marine_length)
	footers := [2]int{len(baseline) - 8, flora_start - 8}
	for footer in footers {
		values := [5]u64{0, 7, max(u64), u64(len(baseline) + 8), u64(flora_start)}
		for value in values {
			copy(corrupt, baseline)
			cursor = footer
			word := value
			testing.expect(t, marine_snapshot_scalar(corrupt, &cursor, &word, false))
			marine_world_expect_rejected(t, world, corrupt, baseline, actual)
		}
	}
	boundaries := [5]int{7, marine_start, flora_start - 1, flora_start, len(baseline) - 1}
	for boundary in boundaries do marine_world_expect_rejected(t, world, baseline[:boundary], baseline, actual)
	cell_word := 17 + int(world.marine_ecology.lineage_count) * 13
	variants := [3][2]u64{{0, 2}, {12, max(u64)}, {u64(cell_word + 6), max(u64)}}
	for variant in variants {
		copy(corrupt, baseline)
		cursor = marine_start + int(variant[0] * 8)
		word := variant[1]
		testing.expect(t, marine_snapshot_scalar(corrupt, &cursor, &word, false))
		marine_world_expect_rejected(t, world, corrupt, baseline, actual)
	}
	copy(corrupt, baseline)
	version_offset := ecs.snapshot_size(&world.pool)
	version := u32(32)
	copy(corrupt[version_offset:version_offset + 4], mem.ptr_to_bytes(&version))
	marine_world_expect_rejected(t, world, corrupt, baseline, actual)
	fixture: Marine_Ecology
	testing.expect(t, marine_ecology_init(&fixture, 42, context.allocator, 1))
	defer marine_ecology_deinit(&fixture)
	marine_seed_cell(&fixture.cells[0], 1000000)
	marine_initial_diagnostics(&fixture)
	fixture_bytes := make([]u8, marine_ecology_snapshot_size(&fixture))
	defer delete(fixture_bytes)
	_, fixture_ok := marine_ecology_snapshot_write(&fixture, fixture_bytes)
	testing.expect(t, fixture_ok && marine_ecology_snapshot_read(&fixture, fixture_bytes))
	spliced := make([]u8, marine_start + len(fixture_bytes) + int(flora_length))
	defer delete(spliced)
	copy(spliced, baseline[:marine_start])
	copy(spliced[marine_start:], fixture_bytes)
	copy(spliced[marine_start + len(fixture_bytes):], baseline[flora_start:])
	marine_world_expect_rejected(t, world, spliced, baseline, actual)
	owner := world.allocator
	for failure in 1 ..= 3 {
		tracker := Marine_Test_Allocator{backing = owner, fail_at = failure}
		world.allocator = mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
		marine_world_expect_rejected(t, world, baseline, baseline, actual)
		world.allocator = owner
		testing.expect(t, tracker.outstanding == 0 && tracker.calls == failure)
	}
	testing.expect(t, world_snapshot_read(world, baseline))
	testing.expect(t, world.marine_ecology.allocator.procedure == owner.procedure && world.marine_ecology.allocator.data == owner.data)
	copy(corrupt, baseline)
	for &value in corrupt[flora_start:flora_start + 8] do value = 255
	before := world.marine_ecology
	marine_before := make([]u8, marine_ecology_snapshot_size(&world.marine_ecology))
	marine_after := make([]u8, len(marine_before))
	defer delete(marine_before)
	defer delete(marine_after)
	_, before_ok := marine_ecology_snapshot_write(&world.marine_ecology, marine_before)
	testing.expect(t, before_ok && !world_snapshot_read(world, corrupt))
	testing.expect(t, raw_data(world.marine_ecology.cells) == raw_data(before.cells) && raw_data(world.marine_ecology.lineages) == raw_data(before.lineages))
	testing.expect(t, world.marine_ecology.step == before.step && world.marine_ecology.birth_serial == before.birth_serial)
	_, after_ok := marine_ecology_snapshot_write(&world.marine_ecology, marine_after)
	testing.expect(t, after_ok)
	for value, index in marine_before do testing.expect(t, value == marine_after[index])
}

@(test)
marine_world_step_zero_snapshot_cache_compatibility :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.marine_ecology
	mass, seed := state.initial_mass, state.seed
	state.guild_mass = {}
	for &lineage in state.lineages[:state.lineage_count] do lineage.extinct = false
	buffer := make([]u8, world_snapshot_size(world))
	defer delete(buffer)
	_, ok := world_snapshot_write(world, buffer)
	testing.expect(t, ok && world_snapshot_read(world, buffer))
	testing.expect(t, marine_diagnostics_valid(state) && state.initial_mass == mass && state.seed == seed)
	testing.expect(t, state.step == 0 && state.elapsed_seconds == 0 && state.birth_serial == 0 && state.global_extinctions == 0 && state.local_extinctions == 0)
	for lineage in state.lineages[:state.lineage_count] do testing.expect(t, lineage.occupied_steps == 0 && lineage.established)
	state.lineages[0].occupied_steps = 1
	_, history_saved := world_snapshot_write(world, buffer)
	testing.expect(t, history_saved)
	state.lineages[0].occupied_steps = 0
	before := state.cells[0]
	testing.expect(t, !world_snapshot_read(world, buffer))
	testing.expect(t, state.cells[0] == before && state.lineages[0].occupied_steps == 0)
	counters := [4]^u64{&state.birth_serial, &state.local_extinctions, &state.global_extinctions, &state.suppressed_mutations}
	for counter in counters {
		counter^ = 1
		_, counter_saved := world_snapshot_write(world, buffer)
		testing.expect(t, counter_saved)
		counter^ = 0
		testing.expect(t, !world_snapshot_read(world, buffer))
		testing.expect(t, counter^ == 0 && state.cells[0] == before && state.step == 0)
	}
}
