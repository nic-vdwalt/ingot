package shared

import "core:mem"

MARINE_COHORTS_PER_CELL :: 8
MARINE_MAX_LINEAGES :: 4096
MARINE_STEP_SECONDS :: u64(3600)
MARINE_CADENCE_TICKS :: u64(12)
MARINE_MAX_CELL_MASS :: u64(1_000_000_000)
MARINE_GENERATION_STEPS :: u64(24)

Marine_Guild :: enum u8 { Suspension, Deposit, Predator }
Marine_Body :: enum u8 { Sessile, Worm, Lobopodian, Armoured }
Marine_Traits :: struct {
	guild: Marine_Guild,
	body: Marine_Body,
	adult_mass: u32,
	elongation, appendages, armour, oxygen_tolerance, feeding_specialization: u16,
}
Marine_Cohort :: struct {
	lineage: u32,
	mass, reserve, age: u64,
}
Marine_Cell :: struct {
	inorganic, producers, suspended, deposited: u64,
	cohorts: [MARINE_COHORTS_PER_CELL]Marine_Cohort,
}
Marine_Lineage :: struct {
	traits: Marine_Traits,
	parent: u32,
	born, occupied_steps: u64,
	established, extinct: bool,
}
Marine_Ecology :: struct {
	cells, scratch: []Marine_Cell,
	lineages: []Marine_Lineage,
	lineage_count: u32,
	seed, step, elapsed_seconds, birth_serial, revision, initial_mass: u64,
	suppressed_mutations, local_extinctions, global_extinctions: u64,
	guild_mass: [3]u64,
	mutation_enabled: bool,
	frozen: bool,
	allocator: mem.Allocator,
}
marine_transfer :: proc(source, destination: ^u64, requested: u64) -> u64 {
	assert(source != nil && destination != nil && source != destination)
	amount := min(source^, requested)
	assert(destination^ <= max(u64) - amount)
	source^ -= amount
	destination^ += amount
	return amount
}
marine_morphology_family :: proc(traits: Marine_Traits) -> u8 {
	return u8(traits.body)
}
marine_shallow_habitat :: proc(environment: Ecology_Environment) -> bool {
	return !environment.land && environment.water_depth_mm >= 1_000 && environment.water_depth_mm <= 200_000
}
marine_cell_mass :: proc(cell: ^Marine_Cell) -> u64 {
	mass := cell.inorganic + cell.producers + cell.suspended + cell.deposited
	for cohort in cell.cohorts do mass += cohort.mass
	return mass
}
marine_total_mass :: proc(state: ^Marine_Ecology) -> u64 {
	mass: u64
	for &cell in state.cells do mass += marine_cell_mass(&cell)
	return mass
}
marine_ecology_init :: proc(state: ^Marine_Ecology, seed: u64, allocator := context.allocator, cell_count := PLANET_SIM_CELL_COUNT) -> bool {
	if state == nil || cell_count <= 0 || cell_count > PLANET_SIM_CELL_COUNT do return false
	state^ = {seed = seed, allocator = allocator, mutation_enabled = true}
	cells, cells_error := make([]Marine_Cell, cell_count, allocator)
	if cells_error != nil do return false
	state.cells = cells
	scratch, scratch_error := make([]Marine_Cell, cell_count, allocator)
	if scratch_error != nil {
		marine_ecology_deinit(state)
		return false
	}
	state.scratch = scratch
	lineages, lineages_error := make([]Marine_Lineage, MARINE_MAX_LINEAGES, allocator)
	if lineages_error != nil {
		marine_ecology_deinit(state)
		return false
	}
	state.lineages = lineages
	state.lineage_count = 4
	for index in 0 ..< 4 {
		guild: Marine_Guild = .Deposit
		if index == 0 do guild = .Suspension
		if index == 3 do guild = .Predator
		hash := ecology_hash_mix(ecology_hash_mix(seed) ~ u64(index + 1))
		variation := i32(hash % 41) - 20
		state.lineages[index].traits = {guild, Marine_Body(index), u32(100 + variation), u16(500 + variation), u16(200 + index * 100), u16(index * 100), u16(300 - variation), u16(500 - variation)}
		state.lineages[index].established = true
	}
	return true
}
marine_ecology_deinit :: proc(state: ^Marine_Ecology, allocator := context.allocator) {
	owner := state.allocator
	if len(state.cells) > 0 do delete(state.cells, owner)
	if len(state.scratch) > 0 do delete(state.scratch, owner)
	if len(state.lineages) > 0 do delete(state.lineages, owner)
	state^ = {}
}
marine_seed_cell :: proc(cell: ^Marine_Cell, amount: u64) {
	assert(amount <= MARINE_MAX_CELL_MASS)
	cell^ = {}
	cell.inorganic = amount
	marine_transfer(&cell.inorganic, &cell.producers, amount / 4)
	marine_transfer(&cell.inorganic, &cell.suspended, amount / 8)
	marine_transfer(&cell.inorganic, &cell.deposited, amount / 4)
	for &cohort, index in cell.cohorts[:4] {
		cohort.lineage = u32(index + 1)
		marine_transfer(&cell.inorganic, &cohort.mass, amount / 100)
	}
}
