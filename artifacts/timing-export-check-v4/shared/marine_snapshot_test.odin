package shared

import "core:mem"
import "core:testing"

@(test)
marine_snapshot_roundtrip_continuation_and_rejection :: proc(t: ^testing.T) {
	first, restored: Marine_Ecology
	testing.expect(t, marine_ecology_init(&first, 54019, context.allocator, 1))
	testing.expect(t, marine_ecology_init(&restored, 0, context.allocator, 1))
	defer marine_ecology_deinit(&first)
	defer marine_ecology_deinit(&restored)
	marine_seed_cell(&first.cells[0], 1000000)
	first.initial_mass = 1000000
	forcing := [1]Ecology_Environment{{water_depth_mm = 10000, surface_par = 1000, temperature_mk = 290000, dissolved_oxygen = 1000}}
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 500))
	buffer := make([]u8, marine_ecology_snapshot_size(&first))
	defer delete(buffer)
	written, ok := marine_ecology_snapshot_write(&first, buffer)
	testing.expect(t, ok && written == len(buffer))
	testing.expect(t, marine_ecology_snapshot_read(&restored, buffer))
	testing.expect(t, first.cells[0] == restored.cells[0])
	testing.expect(t, marine_ecology_advance_fixture(&first, forcing[:], 500))
	testing.expect(t, marine_ecology_advance_fixture(&restored, forcing[:], 500))
	testing.expect(t, first.cells[0] == restored.cells[0] && first.birth_serial == restored.birth_serial)
	testing.expect(t, first.lineage_count == restored.lineage_count)
	for lineage, index in first.lineages[:first.lineage_count] do testing.expect(t, lineage == restored.lineages[index])
	before := restored.cells[0]
	testing.expect(t, !marine_ecology_snapshot_read(&restored, buffer[:len(buffer)-1]))
	buffer[len(buffer)-1] = 255
	testing.expect(t, !marine_ecology_snapshot_read(&restored, buffer))
	testing.expect(t, restored.cells[0] == before)
}

marine_snapshot_expect_unchanged :: proc(t: ^testing.T, state, before: ^Marine_Ecology, cells, scratch: []Marine_Cell, lineages: []Marine_Lineage) {
	testing.expect(t, raw_data(state.cells) == raw_data(before.cells) && raw_data(state.scratch) == raw_data(before.scratch) && raw_data(state.lineages) == raw_data(before.lineages))
	testing.expect(t, state.allocator.procedure == before.allocator.procedure && state.allocator.data == before.allocator.data)
	testing.expect(t, state.lineage_count == before.lineage_count && state.seed == before.seed && state.step == before.step && state.elapsed_seconds == before.elapsed_seconds)
	testing.expect(t, state.birth_serial == before.birth_serial && state.revision == before.revision && state.initial_mass == before.initial_mass)
	testing.expect(t, state.suppressed_mutations == before.suppressed_mutations && state.local_extinctions == before.local_extinctions && state.global_extinctions == before.global_extinctions)
	testing.expect(t, state.guild_mass == before.guild_mass && state.mutation_enabled == before.mutation_enabled && state.frozen == before.frozen)
	testing.expect(t, len(state.cells) == len(cells) && len(state.scratch) == len(scratch) && len(state.lineages) == len(lineages))
	for value, index in cells do testing.expect(t, state.cells[index] == value)
	for value, index in scratch do testing.expect(t, state.scratch[index] == value)
	for value, index in lineages do testing.expect(t, state.lineages[index] == value)
}

@(test)
marine_snapshot_retains_destination_allocator :: proc(t: ^testing.T) {
	tracker := Marine_Test_Allocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
	state: Marine_Ecology
	if !marine_ecology_init(&state, 42, allocator, 1) {
		testing.expect(t, false)
		return
	}
	marine_seed_cell(&state.cells[0], 1_000_000)
	buffer := make([]u8, marine_ecology_snapshot_size(&state))
	defer delete(buffer)
	_, written := marine_ecology_snapshot_write(&state, buffer)
	testing.expect(t, written)
	testing.expect(t, marine_ecology_snapshot_read(&state, buffer))
	testing.expect(t, state.allocator.procedure == allocator.procedure && state.allocator.data == allocator.data)
	testing.expect(t, tracker.outstanding == 3 && tracker.calls == 6)
	marine_ecology_deinit(&state)
	testing.expect(t, tracker.outstanding == 0)
}

@(test)
marine_snapshot_write_is_read_only :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1_000_000)
	before := state
	cells := make([]Marine_Cell, len(state.cells))
	scratch := make([]Marine_Cell, len(state.scratch))
	lineages := make([]Marine_Lineage, len(state.lineages))
	defer delete(cells)
	defer delete(scratch)
	defer delete(lineages)
	copy(cells, state.cells)
	copy(scratch, state.scratch)
	copy(lineages, state.lineages)
	size := marine_ecology_snapshot_size(&state)
	buffer := make([]u8, size + 8)
	expected := make([]u8, size)
	defer delete(buffer)
	defer delete(expected)
	_, expected_ok := marine_ecology_snapshot_write(&state, expected)
	testing.expect(t, expected_ok)
	for _ in 0 ..< 3 {
		for &value in buffer do value = 173
		written, ok := marine_ecology_snapshot_write(&state, buffer)
		testing.expect(t, ok && written == size)
		for value, index in expected do testing.expect(t, buffer[index] == value)
		for value in buffer[size:] do testing.expect(t, value == 173)
		marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
	}
	_, short_ok := marine_ecology_snapshot_write(&state, buffer[:size - 1])
	testing.expect(t, !short_ok)
	marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
	state.cells[0].cohorts[0].lineage = state.lineage_count + 1
	cells[0] = state.cells[0]
	_, invalid_ok := marine_ecology_snapshot_write(&state, buffer)
	testing.expect(t, !invalid_ok)
	marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
}

@(test)
marine_snapshot_decode_allocation_failures :: proc(t: ^testing.T) {
	tracker := Marine_Test_Allocator{backing = context.allocator}
	allocator := mem.Allocator{procedure = marine_test_allocator_proc, data = &tracker}
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, allocator, 1))
	marine_seed_cell(&state.cells[0], 1_000_000)
	before := state
	cells := make([]Marine_Cell, len(state.cells))
	scratch := make([]Marine_Cell, len(state.scratch))
	lineages := make([]Marine_Lineage, len(state.lineages))
	defer delete(cells)
	defer delete(scratch)
	defer delete(lineages)
	copy(cells, state.cells)
	copy(scratch, state.scratch)
	copy(lineages, state.lineages)
	buffer := make([]u8, marine_ecology_snapshot_size(&state))
	defer delete(buffer)
	_, written := marine_ecology_snapshot_write(&state, buffer)
	testing.expect(t, written)
	for failure in 1 ..= 3 {
		tracker.fail_at = tracker.calls + failure
		testing.expect(t, !marine_ecology_snapshot_read(&state, buffer))
		testing.expect(t, tracker.outstanding == 3)
		marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
	}
	tracker.fail_at = 0
	other := Marine_Test_Allocator{backing = context.allocator}
	other_allocator := mem.Allocator{procedure = marine_test_allocator_proc, data = &other}
	testing.expect(t, marine_ecology_snapshot_read(&state, buffer, other_allocator))
	testing.expect(t, tracker.outstanding == 0 && other.outstanding == 3)
	testing.expect(t, state.allocator.data == other_allocator.data)
	marine_ecology_deinit(&state)
	testing.expect(t, other.outstanding == 0)
	for explicit in 0 ..< 2 {
		empty: Marine_Ecology
		if explicit == 0 {
			testing.expect(t, marine_ecology_snapshot_read(&empty, buffer))
			testing.expect(t, empty.allocator.procedure == context.allocator.procedure && empty.allocator.data == context.allocator.data)
		} else {
			testing.expect(t, marine_ecology_snapshot_read(&empty, buffer, other_allocator))
			testing.expect(t, empty.allocator.data == other_allocator.data)
		}
		marine_ecology_deinit(&empty)
	}
	testing.expect(t, other.outstanding == 0 && !marine_ecology_snapshot_read(nil, buffer))
}

@(test)
marine_snapshot_rejects_malformed_words :: proc(t: ^testing.T) {
	state: Marine_Ecology
	testing.expect(t, marine_ecology_init(&state, 42, context.allocator, 1))
	defer marine_ecology_deinit(&state)
	marine_seed_cell(&state.cells[0], 1_000_000)
	state.initial_mass = 1_000_000
	before := state
	cells := make([]Marine_Cell, len(state.cells))
	scratch := make([]Marine_Cell, len(state.scratch))
	lineages := make([]Marine_Lineage, len(state.lineages))
	defer delete(cells)
	defer delete(scratch)
	defer delete(lineages)
	copy(cells, state.cells)
	copy(scratch, state.scratch)
	copy(lineages, state.lineages)
	buffer := make([]u8, marine_ecology_snapshot_size(&state))
	corrupt := make([]u8, len(buffer))
	defer delete(buffer)
	defer delete(corrupt)
	_, written := marine_ecology_snapshot_write(&state, buffer)
	testing.expect(t, written)
	cell_word := 17 + 4 * 13
	variants := [][2]u64{
		{0, 2}, {1, 0}, {1, PLANET_SIM_CELL_COUNT + 1}, {1, max(u64)},
		{2, 3}, {2, MARINE_MAX_LINEAGES + 1}, {15, 2}, {16, 2},
		{17 + 8, 1}, {u64(cell_word + 4), 5}, {u64(cell_word + 6), 1_000_001},
		{u64(len(buffer) / 8 - 2), 1}, {u64(len(buffer) / 8 - 1), 7},
		{u64(len(buffer) / 8 - 1), u64(len(buffer) + 8)},
		{u64(len(buffer) / 8 - 1), max(u64)}, {8, 999_999},
	}
	for variant in variants {
		copy(corrupt, buffer)
		cursor := int(variant[0] * 8)
		value := variant[1]
		testing.expect(t, marine_snapshot_scalar(corrupt, &cursor, &value, false))
		testing.expect(t, !marine_ecology_snapshot_read(&state, corrupt))
		marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
	}
	testing.expect(t, !marine_ecology_snapshot_read(&state, buffer[:len(buffer) - 1]))
	marine_snapshot_expect_unchanged(t, &state, &before, cells, scratch, lineages)
}
