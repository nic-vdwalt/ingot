package shared

import "core:mem"
import "core:testing"

@(test)
flora_morphology_family_boundaries :: proc(t: ^testing.T) {
	for form in Flora_Growth_Form {
		lineage := _flora_founder(42, form)
		testing.expect(t, _flora_morphology_valid(&lineage))
		for mask in u8(0) ..< u8(8) {
			lineage.stature = 500 if mask & 1 != 0 else 499
			lineage.crown_spread = 500 if mask & 2 != 0 else 499
			lineage.branch_density = 500 if mask & 4 != 0 else 499
			expected := (mask & 1) | ((mask & 4) >> 1)
			if form == .Shrub do expected = mask >> 1
			if form == .Tree do expected = mask
			testing.expect_value(t, flora_morphology_family(&lineage), expected)
		}
	}
}

@(test)
flora_morphology_resource_tradeoffs :: proc(t: ^testing.T) {
	lineage := _flora_founder(42, .Tree)
	lineage.stature = 100
	lineage.crown_spread = 100
	lineage.branch_density = 100
	low_capture := _flora_resource_score(&lineage, 180, 100, 100_000, 0)
	low_cost := _flora_resource_score(&lineage, 180, 1000, 100_000, 0)
	lineage.stature = 900
	lineage.crown_spread = 900
	lineage.branch_density = 900
	testing.expect(t, _flora_resource_score(&lineage, 180, 100, 100_000, 0) > low_capture)
	testing.expect(t, _flora_resource_score(&lineage, 180, 1000, 100_000, 0) < low_cost)
	lineage.wood_strength = 1
	weak := _flora_fitness(&lineage, lineage.temperature_optimum, lineage.moisture_optimum, 1000, 240, 1000)
	lineage.wood_strength = 1000
	testing.expect(t, _flora_fitness(&lineage, lineage.temperature_optimum, lineage.moisture_optimum, 1000, 240, 1000) > weak)
}

@(test)
flora_ecology_traits_control_resource_limits :: proc(t: ^testing.T) {
	lineage := _flora_founder(42, .Grass)
	baseline := _flora_resource_score(&lineage, 100, 200, 27_000, 4_000)
	lineage.shade_tolerance = 1000
	testing.expect(t, _flora_resource_score(&lineage, 100, 200, 27_000, 4_000) > baseline)
	for channel in 0 ..< 3 {
		moisture := u8(0) if channel == 0 else u8(100)
		light := u16(0) if channel == 1 else u16(1000)
		nutrients := u32(0) if channel == 2 else u32(100_000)
		testing.expect_value(t, _flora_resource_score(&lineage, moisture, light, nutrients, 0), u32(0))
	}
	lineage.root_depth = 100
	shallow := _flora_resource_score(&lineage, 30, 1000, 100_000, 0)
	lineage.root_depth = 1000
	testing.expect(t, _flora_resource_score(&lineage, 30, 1000, 100_000, 0) > shallow)
	lineage.nutrient_demand = 100
	frugal := _flora_resource_score(&lineage, 255, 1000, 10_000, 0)
	lineage.nutrient_demand = 1000
	testing.expect(t, _flora_resource_score(&lineage, 255, 1000, 10_000, 0) < frugal)
	cohort := Flora_Cohort{ground_cover = 10_000, age_steps = 1000}
	lineage.longevity = 100
	short_lived := _flora_turnover(&cohort, &lineage)
	lineage.longevity = 1000
	testing.expect(t, _flora_turnover(&cohort, &lineage) < short_lived)
}

@(test)
flora_ecology_starts_inoculated_deterministically :: proc(t: ^testing.T) {
	first := new(World)
	second := new(World)
	defer free(first)
	defer free(second)
	testing.expect(t, world_init(first))
	testing.expect(t, world_init(second))
	defer world_deinit(first)
	defer world_deinit(second)
	testing.expect(t, !first.flora_ecology.sterile)
	testing.expect_value(t, first.flora_ecology.lineage_count, u32(FLORA_FOUNDER_COUNT))
	for index in 0 ..< FLORA_FOUNDER_COUNT {
		lineage := first.flora_ecology.lineages[index]
		slot, indexed := first.flora_ecology.lineage_slots[lineage.id]
		testing.expect(t, indexed)
		testing.expect_value(t, slot, u32(index))
		resolved, found := flora_ecology_lineage(&first.flora_ecology, lineage.id)
		testing.expect(t, found)
		testing.expect(t, resolved == &first.flora_ecology.lineages[index])
	}
	testing.expect_value(t, first.flora_ecology.diagnostics.occupied_cells, second.flora_ecology.diagnostics.occupied_cells)
	testing.expect(t, mem.compare(mem.slice_to_bytes(first.flora_ecology.cells), mem.slice_to_bytes(second.flora_ecology.cells)) == 0)
	testing.expect(t, mem.compare(mem.slice_to_bytes(first.flora_ecology.lineages), mem.slice_to_bytes(second.flora_ecology.lineages)) == 0)
}

@(test)
flora_ecology_normalization_preserves_canopy_proportions :: proc(t: ^testing.T) {
	cell := Flora_Cell{cohorts = {
		{ground_cover = 10_000, root_cover = 10_000, canopy_cover = 10_000},
		{ground_cover = 10_000, root_cover = 10_000, canopy_cover = 6_000},
		{},
	}}
	_flora_cover_normalize(&cell)
	testing.expect_value(t, cell.cohorts[0].ground_cover, u16(5_000))
	testing.expect_value(t, cell.cohorts[0].canopy_cover, u16(5_000))
	testing.expect_value(t, cell.cohorts[1].canopy_cover, u16(3_000))
	testing.expect_value(t, cell.bare_ground, u16(0))
	before := cell
	_flora_cover_normalize(&cell)
	testing.expect_value(t, cell, before)
}

@(test)
flora_ecology_mature_biomass_decay_uses_wide_intermediate :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	state := &world.flora_ecology
	index := -1
	for candidate in 0 ..< PLANET_SIM_CELL_COUNT {
		if world.planetary.ocean.mean_depth_mm[candidate] == 0 {
			index = candidate
			break
		}
	}
	testing.expect(t, index >= 0)
	if index < 0 do return
	parent := &state.lineages[0]
	temperature, _, _, _ := _flora_environment_channels(world, index)
	parent.temperature_optimum = 255 if temperature < 128 else 0
	parent.temperature_tolerance = 1
	state.cells[index] = {cohorts = {{lineage = parent.id, ground_cover = 10_000, biomass = 1_000_000}, {}, {}}}
	flora_ecology_step_state(state, world)
	testing.expect_value(t, state.cells[index].cohorts[0].biomass, u32(997_400))
}

@(test)
flora_ecology_explicit_sterilize_clears_default_population :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	revision := world.flora_ecology.revision
	flora_ecology_sterilize(&world.flora_ecology)
	testing.expect(t, world.flora_ecology.sterile)
	testing.expect(t, world.flora_ecology.revision > revision)
	testing.expect_value(t, world.flora_ecology.lineage_count, u32(0))
	testing.expect_value(t, world.flora_ecology.diagnostics.occupied_cells, u32(0))
}

@(test)
flora_ecology_spreads_and_preserves_cover_bounds :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	before := world.flora_ecology.diagnostics.occupied_cells
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		world.planetary.climate.photosynthetic_radiation[index] = 800_000
		world.planetary.climate.soil_water[index] = PLANET_HUMIDITY_SCALE / 2
		world.planetary.climate.temperature[index] = 276 * PLANET_TEMPERATURE_SCALE
	}
	for _ in 0 ..< 32 do flora_ecology_step_state(&world.flora_ecology, world)
	testing.expect(t, world.flora_ecology.diagnostics.occupied_cells >= before)
	for cell in world.flora_ecology.cells {
		total: u32
		for cohort in cell.cohorts do total += u32(cohort.ground_cover)
		testing.expect(t, total <= u32(FLORA_COVER_SCALE))
		testing.expect_value(t, u32(cell.bare_ground) + total, u32(FLORA_COVER_SCALE))
	}
}

@(test)
flora_ecology_mutation_is_deterministic_bounded_and_records_ancestry :: proc(t: ^testing.T) {
	first := new(World)
	second := new(World)
	defer free(first)
	defer free(second)
	testing.expect(t, world_init(first))
	testing.expect(t, world_init(second))
	defer world_deinit(first)
	defer world_deinit(second)
	parent := first.flora_ecology.lineages[Flora_Growth_Form.Grass]
	first_id, first_ok := flora_ecology_mutate_lineage(&first.flora_ecology, parent.id, first.foundation.seed, 42)
	second_id, second_ok := flora_ecology_mutate_lineage(&second.flora_ecology, parent.id, second.foundation.seed, 42)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, second_id, first_id)
	child, found := flora_ecology_lineage(&first.flora_ecology, first_id)
	testing.expect(t, found)
	testing.expect_value(t, child.parent, parent.id)
	testing.expect_value(t, child.founder, parent.founder)
	testing.expect_value(t, child.generation, parent.generation + 1)
	testing.expect(t, abs(i32(child.temperature_optimum) - i32(parent.temperature_optimum)) <= 8)
	testing.expect(t, abs(i32(child.moisture_optimum) - i32(parent.moisture_optimum)) <= 8)
	testing.expect(t, child.colonisation >= 1 && child.colonisation <= 1000)
	testing.expect(t, _flora_morphology_valid(child))
	testing.expect(t, abs(i32(child.stature) - i32(parent.stature)) <= 45)
	testing.expect(t, abs(i32(child.crown_spread) - i32(parent.crown_spread)) <= 45)
	testing.expect(t, abs(i32(child.branch_density) - i32(parent.branch_density)) <= 45)
	testing.expect(t, abs(i32(child.wood_strength) - i32(parent.wood_strength)) <= 45)
	slot, indexed := first.flora_ecology.lineage_slots[first_id]
	testing.expect(t, indexed)
	testing.expect_value(t, slot, first.flora_ecology.lineage_count - 1)
	testing.expect_value(t, first.flora_ecology.diagnostics.mutations, u64(1))
}

@(test)
flora_ecology_mutation_grows_registry_and_rejects_corrupt_snapshots :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	parent := world.flora_ecology.lineages[0].id
	for index in 0 ..< FLORA_LINEAGE_CAPACITY + 10 {
		id, mutated := flora_ecology_mutate_lineage(&world.flora_ecology, parent, world.foundation.seed, index)
		testing.expect(t, mutated)
		child, found := flora_ecology_lineage(&world.flora_ecology, id)
		testing.expect(t, found)
		if found do testing.expect_value(t, child.parent, parent)
	}
	testing.expect(t, world.flora_ecology.lineage_count > FLORA_LINEAGE_CAPACITY)
	buffer := make([]u8, flora_ecology_snapshot_size(&world.flora_ecology))
	defer delete(buffer)
	_, written := flora_ecology_snapshot_write(&world.flora_ecology, buffer)
	testing.expect(t, written)
	testing.expect(t, flora_ecology_snapshot_read(&world.flora_ecology, buffer))
	before := world.flora_ecology.lineage_count
	buffer[0] = 255
	testing.expect(t, !flora_ecology_snapshot_read(&world.flora_ecology, buffer))
	testing.expect_value(t, world.flora_ecology.lineage_count, before)
}

@(test)
flora_ecology_snapshot_round_trip_continues_identically :: proc(t: ^testing.T) {
	source := new(World)
	target := new(World)
	defer free(source)
	defer free(target)
	testing.expect(t, world_init(source))
	testing.expect(t, world_init(target))
	defer world_deinit(source)
	defer world_deinit(target)
	for _ in 0 ..< 8 do flora_ecology_step_state(&source.flora_ecology, source)
	buffer := make([]u8, world_snapshot_size(source))
	defer delete(buffer)
	_, written := world_snapshot_write(source, buffer)
	testing.expect(t, written)
	clear(&target.flora_ecology.lineage_slots)
	testing.expect(t, world_snapshot_read(target, buffer))
	testing.expect_value(t, len(target.flora_ecology.lineage_slots), int(target.flora_ecology.lineage_count))
	for index in 0 ..< int(target.flora_ecology.lineage_count) {
		lineage := target.flora_ecology.lineages[index]
		slot, indexed := target.flora_ecology.lineage_slots[lineage.id]
		testing.expect(t, indexed)
		testing.expect_value(t, slot, u32(index))
	}
	testing.expect_value(t, target.flora_ecology.step, source.flora_ecology.step)
	testing.expect_value(t, target.flora_ecology.revision, source.flora_ecology.revision)
	testing.expect(t, mem.compare(mem.slice_to_bytes(target.flora_ecology.cells), mem.slice_to_bytes(source.flora_ecology.cells)) == 0)
	flora_ecology_step_state(&source.flora_ecology, source)
	flora_ecology_step_state(&target.flora_ecology, target)
	testing.expect(t, mem.compare(mem.slice_to_bytes(target.flora_ecology.cells), mem.slice_to_bytes(source.flora_ecology.cells)) == 0)
}

@(test)
flora_ecology_visual_selection_is_stable_and_sterilize_clears_it :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	index := -1
	for candidate in 0 ..< PLANET_SIM_CELL_COUNT {
		if world.flora_ecology.cells[candidate].cohorts[0].lineage != Lineage_Id(0) {
			index = candidate
			break
		}
	}
	testing.expect(t, index >= 0)
	direction := planet_sim_direction(planet_sim_coord_for_index(index))
	first, found := flora_ecology_visual_sample_state(&world.flora_ecology, direction, 0)
	second, repeated := flora_ecology_visual_sample_state(&world.flora_ecology, direction, 0)
	testing.expect(t, found && repeated)
	testing.expect_value(t, second, first)
	flora_ecology_sterilize(&world.flora_ecology)
	_, found = flora_ecology_visual_sample_state(&world.flora_ecology, direction, 0)
	testing.expect(t, !found)
}
