package shared

import "core:mem"

FLORA_COHORTS_PER_CELL :: 3
FLORA_LINEAGE_CAPACITY :: 4096
FLORA_COVER_SCALE :: u16(10_000)
FLORA_BIOMASS_SCALE :: u32(1_000_000)
FLORA_ECOLOGY_CADENCE_TICKS :: u64(12)
FLORA_SUCCESSION_STEPS :: u32(48)
FLORA_FOUNDER_COUNT :: 6
FLORA_MORPHOLOGY_TRAIT_MIN :: u16(1)
FLORA_MORPHOLOGY_TRAIT_MAX :: u16(1000)
FLORA_GROUND_FAMILY_COUNT :: u8(4)
FLORA_SHRUB_FAMILY_COUNT :: u8(4)
FLORA_TREE_FAMILY_COUNT :: u8(8)

Flora_Growth_Form :: enum u8 {
	Pioneer,
	Groundcover,
	Grass,
	Reed,
	Shrub,
	Tree,
}

Flora_Lineage :: struct {
	id:                    Lineage_Id,
	parent:                Lineage_Id,
	founder:               Lineage_Id,
	birth_step:            u64,
	generation:            u16,
	form:                  Flora_Growth_Form,
	temperature_optimum:   u8,
	temperature_tolerance: u8,
	moisture_optimum:      u8,
	moisture_tolerance:    u8,
	light_demand:          u16,
	shade_tolerance:       u16,
	root_depth:            u16,
	nutrient_demand:       u16,
	colonisation:          u16,
	competition:           u16,
	disturbance_tolerance: u16,
	longevity:             u16,
	mutation_rate_ppm:     u32,
	stature:               u16,
	crown_spread:          u16,
	branch_density:        u16,
	wood_strength:         u16,
}

Flora_Cohort :: struct {
	lineage:      Lineage_Id,
	ground_cover: u16,
	canopy_cover: u16,
	root_cover:   u16,
	biomass:      u32,
	propagules:   u32,
	age_steps:    u32,
}

Flora_Cell :: struct {
	cohorts:          [FLORA_COHORTS_PER_CELL]Flora_Cohort,
	bare_ground:      u16,
	nutrients:        u32,
	soil_water:       u32,
	disturbance:      u16,
	succession_steps: u32,
	founder_reserve: [FLORA_FOUNDER_COUNT]u16,
}

Flora_Ecology_Diagnostics :: struct {
	occupied_cells: u32,
	lineages:       u32,
	pioneer_cover:  u64,
	grass_cover:    u64,
	shrub_cover:    u64,
	tree_cover:     u64,
	total_biomass:  u64,
	extinctions:    u64,
	mutations:      u64,
	steps:          u64,
	registry_bytes: u64,
	allocation_failures: u64,
}

Flora_Ecology :: struct {
	cells:             []Flora_Cell,
	next_cells:        []Flora_Cell,
	lineages:          []Flora_Lineage,
	lineage_slots:     map[Lineage_Id]u32,
	lineage_count:     u32,
	next_lineage_salt: u64,
	step:              u64,
	revision:          u64,
	sterile:           bool,
	allocator:         mem.Allocator,
	diagnostics:       Flora_Ecology_Diagnostics,
}

Flora_Visual_Sample :: struct {
	lineage:          Lineage_Id,
	form:             Flora_Growth_Form,
	cover:            u16,
	biomass:          u32,
	age_steps:        u32,
	morphology_family: u8,
	stature:          u16,
}

flora_ecology_init :: proc(state: ^Flora_Ecology, seed: u64, allocator := context.allocator) -> bool {
	assert(state != nil, "flora ecology init: nil state")
	state^ = {}
	state.allocator = allocator
	state.cells = make([]Flora_Cell, PLANET_SIM_CELL_COUNT, allocator)
	state.next_cells = make([]Flora_Cell, PLANET_SIM_CELL_COUNT, allocator)
	state.lineages = make([]Flora_Lineage, FLORA_LINEAGE_CAPACITY, allocator)
	state.lineage_slots = make(map[Lineage_Id]u32, FLORA_LINEAGE_CAPACITY, allocator)
	state.next_lineage_salt = ecology_hash_mix(seed ~ 0x464c4f5241)
	flora_ecology_sterilize(state)
	return true
}

flora_ecology_deinit :: proc(state: ^Flora_Ecology, allocator := context.allocator) {
	assert(state != nil, "flora ecology deinit: nil state")
	delete(state.lineage_slots)
	delete(state.lineages, allocator)
	delete(state.next_cells, allocator)
	delete(state.cells, allocator)
	state^ = {}
}

flora_ecology_sterilize :: proc(state: ^Flora_Ecology) {
	assert(state != nil, "flora ecology sterilize: nil state")
	mem.zero_slice(state.cells)
	mem.zero_slice(state.next_cells)
	mem.zero_slice(state.lineages)
	clear(&state.lineage_slots)
	for &cell in state.cells do cell.bare_ground = FLORA_COVER_SCALE
	state.lineage_count = 0
	state.step = 0
	state.revision += 1
	state.sterile = true
	state.diagnostics = {}
}

_flora_founder :: proc(seed: u64, form: Flora_Growth_Form) -> Flora_Lineage {
	value := ecology_hash_mix(seed ~ (u64(form) + 1) * 0x9e3779b97f4a7c15)
	id := Lineage_Id(value if value != 0 else 1)
	moisture := [FLORA_FOUNDER_COUNT]u8{90, 120, 135, 205, 145, 150}
	temperature := [FLORA_FOUNDER_COUNT]u8{120, 130, 145, 140, 145, 135}
	colonisation := [FLORA_FOUNDER_COUNT]u16{900, 760, 700, 720, 400, 240}
	competition := [FLORA_FOUNDER_COUNT]u16{260, 350, 500, 470, 680, 850}
	stature := [FLORA_FOUNDER_COUNT]u16{180, 240, 420, 650, 620, 820}
	crown_spread := [FLORA_FOUNDER_COUNT]u16{420, 650, 360, 280, 720, 560}
	branch_density := [FLORA_FOUNDER_COUNT]u16{760, 820, 680, 540, 700, 620}
	wood_strength := [FLORA_FOUNDER_COUNT]u16{120, 160, 180, 220, 610, 820}
	return {
		id = id,
		founder = id,
		form = form,
		temperature_optimum = temperature[form],
		temperature_tolerance = 80,
		moisture_optimum = moisture[form],
		moisture_tolerance = 95,
		light_demand = u16(760 - int(form) * 75),
		shade_tolerance = u16(240 + int(form) * 110),
		root_depth = u16(180 + int(form) * 130),
		nutrient_demand = u16(180 + int(form) * 90),
		colonisation = colonisation[form],
		competition = competition[form],
		disturbance_tolerance = u16(900 - int(form) * 130),
		longevity = u16(80 + int(form) * 180),
		mutation_rate_ppm = 2_000,
		stature = stature[form],
		crown_spread = crown_spread[form],
		branch_density = branch_density[form],
		wood_strength = wood_strength[form],
	}
}

flora_ecology_inoculate :: proc(state: ^Flora_Ecology, world: ^World) -> bool {
	assert(state != nil && world != nil, "flora ecology inoculate: nil input")
	if !state.sterile do return false
	for form in Flora_Growth_Form {
		state.lineages[state.lineage_count] = _flora_founder(world.foundation.seed, form)
		state.lineage_slots[state.lineages[state.lineage_count].id] = state.lineage_count
		state.lineage_count += 1
	}
	pioneer := state.lineages[Flora_Growth_Form.Pioneer]
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if world.planetary.ocean.mean_depth_mm[index] != 0 do continue
		state.cells[index].nutrients = 27_000
		habitat := flora_habitat_at_cell(world, index)
		for founder in state.lineages[:state.lineage_count] {
			candidate := founder
			if flora_establishment_score(&candidate, habitat, &state.cells[index]) >= 220 {
				state.cells[index].founder_reserve[founder.form] = 4000
			}
		}
		hash := ecology_hash_mix(world.foundation.seed ~ u64(index) * 0x9e3779b97f4a7c15)
		if hash % 257 != 0 do continue
		cover := u16(100 + hash % 201)
		state.cells[index].cohorts[0] = {
			lineage = pioneer.id,
			ground_cover = cover,
			root_cover = cover,
			biomass = u32(cover) * 20,
			propagules = u32(cover),
		}
		state.cells[index].bare_ground = FLORA_COVER_SCALE - cover
	}
	state.sterile = false
	state.revision += 1
	flora_ecology_diagnostics_update(state)
	return true
}

flora_ecology_lineage :: proc(state: ^Flora_Ecology, id: Lineage_Id) -> (^Flora_Lineage, bool) {
	assert(state != nil, "flora ecology lineage: nil state")
	slot, found := state.lineage_slots[id]
	if !found || slot >= state.lineage_count do return nil, false
	lineage := &state.lineages[slot]
	if lineage.id != id do return nil, false
	return lineage, true
}

_flora_lineage_slots_rebuild :: proc(state: ^Flora_Ecology) -> bool {
	clear(&state.lineage_slots)
	for index in 0 ..< int(state.lineage_count) {
		id := state.lineages[index].id
		if id == Lineage_Id(0) do return false
		if _, duplicate := state.lineage_slots[id]; duplicate do return false
		state.lineage_slots[id] = u32(index)
	}
	return true
}

_flora_mutate_u8 :: proc(value: u8, hash: u64, shift: uint, radius: i32) -> u8 {
	delta := i32((hash >> shift) % u64(radius * 2 + 1)) - radius
	return u8(clamp(i32(value) + delta, 0, 255))
}

_flora_mutate_u16 :: proc(value: u16, hash: u64, shift: uint, radius, minimum, maximum: i32) -> u16 {
	delta := i32((hash >> shift) % u64(radius * 2 + 1)) - radius
	return u16(clamp(i32(value) + delta, minimum, maximum))
}

flora_morphology_family :: proc(lineage: ^Flora_Lineage) -> u8 {
	assert(lineage != nil, "flora morphology family: nil lineage")
	stature_high := u8(1) if lineage.stature >= 500 else u8(0)
	spread_high := u8(1) if lineage.crown_spread >= 500 else u8(0)
	density_high := u8(1) if lineage.branch_density >= 500 else u8(0)
	switch lineage.form {
	case .Pioneer, .Groundcover, .Grass, .Reed:
		return stature_high | density_high << 1
	case .Shrub:
		return spread_high | density_high << 1
	case .Tree:
		return stature_high | spread_high << 1 | density_high << 2
	}
	return 0
}

_flora_morphology_valid :: proc(lineage: ^Flora_Lineage) -> bool {
	return lineage.stature >= FLORA_MORPHOLOGY_TRAIT_MIN && lineage.stature <= FLORA_MORPHOLOGY_TRAIT_MAX &&
		lineage.crown_spread >= FLORA_MORPHOLOGY_TRAIT_MIN && lineage.crown_spread <= FLORA_MORPHOLOGY_TRAIT_MAX &&
		lineage.branch_density >= FLORA_MORPHOLOGY_TRAIT_MIN && lineage.branch_density <= FLORA_MORPHOLOGY_TRAIT_MAX &&
		lineage.wood_strength >= FLORA_MORPHOLOGY_TRAIT_MIN && lineage.wood_strength <= FLORA_MORPHOLOGY_TRAIT_MAX
}

_flora_registry_reserve :: proc(state: ^Flora_Ecology, required: int) -> bool {
	if required <= len(state.lineages) do return true
	if required > int(max(u32)) || len(state.lineages) > max(int) / 2 / size_of(Flora_Lineage) {
		state.diagnostics.allocation_failures += 1
		return false
	}
	capacity := max(required, max(FLORA_LINEAGE_CAPACITY, len(state.lineages) * 2))
	storage, err := make([]Flora_Lineage, capacity, state.allocator)
	if err != nil {
		state.diagnostics.allocation_failures += 1
		return false
	}
	copy(storage, state.lineages)
	delete(state.lineages, state.allocator)
	state.lineages = storage
	state.diagnostics.registry_bytes = u64(capacity) * size_of(Flora_Lineage)
	return true
}

flora_ecology_mutate_lineage :: proc(
	state: ^Flora_Ecology,
	parent_id: Lineage_Id,
	world_seed: u64,
	cell_index: int,
	habitat: ^Flora_Habitat = nil,
	destination: ^Flora_Cell = nil,
) -> (Lineage_Id, bool) {
	assert(state != nil, "flora ecology mutate: nil state")
	parent, found := flora_ecology_lineage(state, parent_id)
	if !found do return parent_id, false
	hash := ecology_hash_mix(
		world_seed ~ u64(parent_id) ~ state.step * 0x9e3779b97f4a7c15 ~
		u64(cell_index + 1) * 0xbf58476d1ce4e5b9 ~ state.next_lineage_salt,
	)
	id_hash := ecology_hash_mix(hash ~ 0x4d55544154494f4e)
	if id_hash == 0 do id_hash = 1
	id := Lineage_Id(id_hash)
	if _, duplicate := flora_ecology_lineage(state, id); duplicate do return parent_id, false
	child := parent^
	child.id = id
	child.parent = parent.id
	child.founder = parent.founder
	child.birth_step = state.step
	child.generation = u16(min(u32(parent.generation) + 1, u32(max(u16))))
	child.temperature_optimum = _flora_mutate_u8(parent.temperature_optimum, hash, 8, 8)
	child.temperature_tolerance = _flora_mutate_u8(parent.temperature_tolerance, hash, 13, 5)
	child.moisture_optimum = _flora_mutate_u8(parent.moisture_optimum, hash, 18, 8)
	child.moisture_tolerance = _flora_mutate_u8(parent.moisture_tolerance, hash, 23, 5)
	child.light_demand = _flora_mutate_u16(parent.light_demand, hash, 28, 45, 1, 1000)
	child.shade_tolerance = _flora_mutate_u16(parent.shade_tolerance, hash, 34, 45, 1, 1000)
	child.root_depth = _flora_mutate_u16(parent.root_depth, hash, 40, 35, 1, 2000)
	child.nutrient_demand = _flora_mutate_u16(parent.nutrient_demand, hash, 46, 35, 1, 1000)
	child.colonisation = _flora_mutate_u16(parent.colonisation, hash, 12, 30, 1, 1000)
	child.competition = _flora_mutate_u16(parent.competition, hash, 20, 30, 1, 1000)
	child.disturbance_tolerance = _flora_mutate_u16(parent.disturbance_tolerance, hash, 36, 35, 1, 1000)
	child.longevity = _flora_mutate_u16(parent.longevity, hash, 48, 40, 1, 4000)
	child.mutation_rate_ppm = u32(clamp(i64(parent.mutation_rate_ppm) + i64(i32(hash % 401) - 200), i64(100), i64(20_000)))
	morphology_hash := ecology_hash_mix(hash ~ 0x4d4f5250484f4c4f)
	child.stature = _flora_mutate_u16(parent.stature, morphology_hash, 0, 45, 1, 1000)
	child.crown_spread = _flora_mutate_u16(parent.crown_spread, morphology_hash, 12, 45, 1, 1000)
	child.branch_density = _flora_mutate_u16(parent.branch_density, morphology_hash, 24, 45, 1, 1000)
	child.wood_strength = _flora_mutate_u16(parent.wood_strength, morphology_hash, 36, 45, 1, 1000)
	if habitat != nil && destination != nil && flora_establishment_score(&child, habitat^, destination) < 220 do return parent_id, false
	if !_flora_registry_reserve(state, int(state.lineage_count) + 1) do return parent_id, false
	state.lineages[state.lineage_count] = child
	state.lineage_slots[id] = state.lineage_count
	state.lineage_count += 1
	state.next_lineage_salt = ecology_hash_mix(state.next_lineage_salt + 0x9e3779b97f4a7c15)
	state.diagnostics.mutations += 1
	return id, true
}

_flora_environment_channels :: proc(world: ^World, index: int) -> (temperature, moisture: u8, light: u16, land: bool) {
	habitat := flora_habitat_at_cell(world, index)
	return habitat.temperature, habitat.moisture, habitat.light, habitat.land
}

_flora_fitness :: proc(lineage: ^Flora_Lineage, temperature, moisture: u8, light: u16, succession: u32, disturbance: u16) -> u32 {
	temperature_distance := u32(abs(i32(temperature) - i32(lineage.temperature_optimum)))
	moisture_distance := u32(abs(i32(moisture) - i32(lineage.moisture_optimum)))
	if temperature_distance > u32(lineage.temperature_tolerance) || moisture_distance > u32(lineage.moisture_tolerance) do return 0
	temperature_score := 1000 - temperature_distance * 1000 / max(u32(lineage.temperature_tolerance), 1)
	moisture_score := 1000 - moisture_distance * 1000 / max(u32(lineage.moisture_tolerance), 1)
	light_score := min(u32(light) * 1000 / max(u32(lineage.light_demand), 1), u32(1000))
	stage_score := u32(900) + min(succession, FLORA_SUCCESSION_STEPS) * 100 / FLORA_SUCCESSION_STEPS
	structural_tolerance := (u32(lineage.disturbance_tolerance) + u32(lineage.wood_strength)) / 2
	disturbance_score := u32(1000) - min(u32(disturbance) * (1000 - structural_tolerance) / 10_000, u32(900))
	return (temperature_score + moisture_score + light_score + stage_score + disturbance_score) / 5
}

_flora_resource_score :: proc(lineage: ^Flora_Lineage, moisture: u8, light: u16, nutrients: u32, canopy: u32) -> u32 {
	available_light := u32(light) * (10_000 - min(canopy, 9_000)) / 10_000
	light_required := max(u32(lineage.light_demand) * (1000 - u32(lineage.shade_tolerance) / 2) / 1000, 1)
	light_capture := 700 + u32(lineage.stature) / 5 + u32(lineage.crown_spread) / 10 + u32(lineage.branch_density) / 10
	light_score := min(available_light * light_capture / light_required, 1000)
	root_access := 500 + u32(lineage.root_depth) * 1000 / (u32(lineage.root_depth) + 500)
	water_score := min(u32(moisture) * root_access / 100, 1000)
	nutrient_score := u32(min(u64(nutrients) * 1000 / max(u64(lineage.nutrient_demand) * 100, 1), 1000))
	maintenance := 1000 + u32(lineage.root_depth) / 8 + u32(lineage.nutrient_demand) / 4 +
		u32(lineage.stature) / 6 + u32(lineage.crown_spread) / 8 + u32(lineage.branch_density) / 8
	return min(light_score, water_score, nutrient_score) * 1000 / maintenance
}

_flora_turnover :: proc(cohort: ^Flora_Cohort, lineage: ^Flora_Lineage) -> u32 {
	return u32(u64(cohort.ground_cover) * min(u64(cohort.age_steps), u64(lineage.longevity)) /
		max(u64(lineage.longevity) * u64(lineage.longevity) * 4, 1))
}

_flora_cover_normalize :: proc(cell: ^Flora_Cell) {
	total: u32
	for cohort in cell.cohorts do total += u32(cohort.ground_cover)
	if total > u32(FLORA_COVER_SCALE) {
		for &cohort in cell.cohorts {
			cohort.ground_cover = u16(u32(cohort.ground_cover) * u32(FLORA_COVER_SCALE) / total)
			cohort.root_cover = min(cohort.root_cover, cohort.ground_cover)
			cohort.canopy_cover = u16(u32(cohort.canopy_cover) * u32(FLORA_COVER_SCALE) / total)
		}
		total = 0
		for cohort in cell.cohorts do total += u32(cohort.ground_cover)
	}
	cell.bare_ground = u16(u32(FLORA_COVER_SCALE) - total)
}

_flora_weakest_slot :: proc(state: ^Flora_Ecology, cell: ^Flora_Cell) -> (slot: int, score: u32) {
	slot = 0
	score = max(u32)
	for index in 0 ..< FLORA_COHORTS_PER_CELL {
		cohort := cell.cohorts[index]
		if cohort.lineage == Lineage_Id(0) do return index, 0
		lineage, found := flora_ecology_lineage(state, cohort.lineage)
		if !found do return index, 0
		value := u32(cohort.ground_cover) * u32(lineage.competition)
		if value < score {
			score = value
			slot = index
		}
	}
	return
}

_flora_recruitment_pressure :: proc(state: ^Flora_Ecology, id: Lineage_Id, propagules: u32, habitat: Flora_Habitat, cell: ^Flora_Cell) -> u32 {
	for cohort in cell.cohorts do if cohort.lineage == id do return 0
	lineage, found := flora_ecology_lineage(state, id)
	if !found do return 0
	fitness := flora_establishment_score(lineage, habitat, cell)
	if fitness < 220 do return 0
	return u32(min(u64(propagules) * u64(lineage.colonisation) * u64(fitness) / 1_000_000, u64(max(u32))))
}

flora_ecology_step_state :: proc(state: ^Flora_Ecology, world: ^World) {
	assert(state != nil && world != nil, "flora ecology step: nil input")
	if state.sterile do return
	copy(state.next_cells, state.cells)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		temperature, moisture, light, land := _flora_environment_channels(world, index)
		target := &state.next_cells[index]
		if !land {
			target^ = {bare_ground = FLORA_COVER_SCALE}
			continue
		}
		target.soil_water = u32(moisture) * FLORA_BIOMASS_SCALE / 255
		if target.disturbance > 0 do target.disturbance -= 1
		occupied := false
		for cohort_index in 0 ..< FLORA_COHORTS_PER_CELL {
			cohort := &target.cohorts[cohort_index]
			if cohort.lineage == Lineage_Id(0) do continue
			lineage, found := flora_ecology_lineage(state, cohort.lineage)
			if !found {
				cohort^ = {}
				continue
			}
			canopy: u32
			for previous in state.cells[index].cohorts {
				if previous.lineage != cohort.lineage do canopy += u32(previous.canopy_cover)
			}
			resources := _flora_resource_score(lineage, moisture, light, target.nutrients, canopy)
			fitness := _flora_fitness(lineage, temperature, moisture, light, target.succession_steps, target.disturbance) * resources / 1000
			turnover := min(_flora_turnover(cohort, lineage), u32(cohort.ground_cover))
			if turnover > 0 {
				cohort.biomass = u32(u64(cohort.biomass) * u64(u32(cohort.ground_cover) - turnover) / u64(cohort.ground_cover))
				cohort.ground_cover -= u16(turnover)
			}
			if fitness < 220 {
				loss := min(u32(cohort.ground_cover), u32(8 + (220 - fitness) / 12))
				cohort.ground_cover -= u16(loss)
				cohort.biomass = u32(u64(cohort.biomass) * u64(cohort.ground_cover) / max(u64(cohort.ground_cover) + u64(loss), 1))
			} else {
				crown_competition := u32(lineage.competition) * (750 + u32(lineage.crown_spread) / 4) / 1000
				gain := min(u32(FLORA_COVER_SCALE - cohort.ground_cover), 2 + fitness * crown_competition / 60_000)
				cohort.ground_cover += u16(gain)
				biomass_factor := 750 + u32(lineage.branch_density) / 4
				cohort.biomass = min(cohort.biomass + gain * (10 + u32(lineage.form) * 8) * biomass_factor / 1000, FLORA_BIOMASS_SCALE)
			}
			if cohort.ground_cover == 0 {
				cohort^ = {}
				state.diagnostics.extinctions += 1
				continue
			}
			cohort.root_cover = cohort.ground_cover
			canopy_form := u32(lineage.form) * (500 + u32(lineage.crown_spread) / 2) / 1000
			cohort.canopy_cover = u16(min(u32(cohort.ground_cover) * canopy_form / u32(Flora_Growth_Form.Tree), u32(cohort.ground_cover)))
			cohort.propagules = min(cohort.biomass / 20 + u32(cohort.ground_cover) * u32(lineage.colonisation) / 1000, FLORA_BIOMASS_SCALE)
			cohort.age_steps = u32(min(u64(cohort.age_steps) + 1, u64(max(u32))))
			occupied = true
		}
		if occupied do target.succession_steps = u32(min(u64(target.succession_steps) + 1, u64(max(u32))))
		_flora_cover_normalize(target)
	}
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		target := &state.next_cells[index]
		if world.planetary.ocean.mean_depth_mm[index] != 0 do continue
		coord := planet_sim_coord_for_index(index)
		best_lineage := Lineage_Id(0)
		best_pressure: u32
		reserve_form := -1
		habitat := flora_habitat_at_cell(world, index)
		for edge in 0 ..< PLANET_SIM_EDGE_COUNT {
			neighbour_index := int(world.planetary.grid.neighbours[index][edge])
			for cohort in state.cells[neighbour_index].cohorts {
				if cohort.lineage == Lineage_Id(0) do continue
				lineage, found := flora_ecology_lineage(state, cohort.lineage)
				if !found do continue
				pressure := _flora_recruitment_pressure(state, lineage.id, cohort.propagules, habitat, target)
				if pressure > best_pressure || pressure == best_pressure && u64(cohort.lineage) < u64(best_lineage) {
					best_pressure = pressure
					best_lineage = cohort.lineage
				}
			}
		}
		for form in Flora_Growth_Form {
			reserve := target.founder_reserve[form]
			if reserve == 0 do continue
			founder := _flora_founder(world.foundation.seed, form)
			pressure := _flora_recruitment_pressure(state, founder.id, u32(reserve), habitat, target)
			if pressure > best_pressure || pressure == best_pressure && u64(founder.id) < u64(best_lineage) {
				best_pressure, best_lineage, reserve_form = pressure, founder.id, int(form)
			}
		}
		if best_lineage == Lineage_Id(0) || best_pressure < 250 do continue
		already := false
		for cohort in target.cohorts do already = already || cohort.lineage == best_lineage
		if already do continue
		slot, weakest := _flora_weakest_slot(state, target)
		if weakest > 0 && best_pressure <= weakest / 8 + 500 do continue
		parent, parent_found := flora_ecology_lineage(state, best_lineage)
		if parent_found {
			mutation_roll := ecology_hash_mix(
				world.foundation.seed ~ state.step * 0x9e3779b97f4a7c15 ~
				u64(planet_sim_index(coord) + 1) * 0xbf58476d1ce4e5b9 ~ u64(best_lineage),
			) % 1_000_000
			if mutation_roll < u64(parent.mutation_rate_ppm) {
				if child, mutated := flora_ecology_mutate_lineage(
					state,
					best_lineage,
					world.foundation.seed,
					index,
					&habitat,
					target,
				); mutated {
					best_lineage = child
				}
			}
		}
		if reserve_form >= 0 do target.founder_reserve[reserve_form] -= min(target.founder_reserve[reserve_form], u16(1000))
		cover := u16(min(best_pressure / 100, u32(240)))
		target.cohorts[slot] = {
			lineage = best_lineage,
			ground_cover = max(cover, u16(25)),
			root_cover = max(cover, u16(25)),
			biomass = u32(max(cover, u16(25))) * 12,
		}
		_flora_cover_normalize(target)
	}
	temporary := state.cells
	state.cells = state.next_cells
	state.next_cells = temporary
	state.step += 1
	state.revision += 1
	state.diagnostics.steps += 1
	flora_ecology_diagnostics_update(state)
}

flora_ecology_visual_sample_state :: proc(state: ^Flora_Ecology, direction: [3]f32, selector: u16) -> (Flora_Visual_Sample, bool) {
	assert(state != nil, "flora ecology visual sample: nil state")
	remaining := selector
	index := planetary_sample_index(direction)
	cell := &state.cells[index]
	for cohort in cell.cohorts {
		if cohort.lineage == Lineage_Id(0) do continue
		cover := cohort.ground_cover
		if remaining >= cover {
			remaining -= cover
			continue
		}
		lineage, found := flora_ecology_lineage(state, cohort.lineage)
		if !found do return {}, false
		return {
			lineage = cohort.lineage,
			form = lineage.form,
			cover = cover,
			biomass = cohort.biomass,
			age_steps = cohort.age_steps,
			morphology_family = flora_morphology_family(lineage),
			stature = lineage.stature,
		}, true
	}
	return {}, false
}

flora_ecology_diagnostics_update :: proc(state: ^Flora_Ecology) {
	assert(state != nil, "flora ecology diagnostics: nil state")
	mutations := state.diagnostics.mutations
	extinctions := state.diagnostics.extinctions
	steps := state.diagnostics.steps
	state.diagnostics = {
		lineages = state.lineage_count,
		mutations = mutations,
		extinctions = extinctions,
		steps = steps,
		registry_bytes = u64(len(state.lineages)) * size_of(Flora_Lineage),
		allocation_failures = state.diagnostics.allocation_failures,
	}
	for cell in state.cells {
		occupied := false
		for cohort in cell.cohorts {
			if cohort.lineage == Lineage_Id(0) do continue
			lineage, found := flora_ecology_lineage(state, cohort.lineage)
			if !found do continue
			occupied = true
			state.diagnostics.total_biomass += u64(cohort.biomass)
			switch lineage.form {
			case .Pioneer, .Groundcover: state.diagnostics.pioneer_cover += u64(cohort.ground_cover)
			case .Grass, .Reed: state.diagnostics.grass_cover += u64(cohort.ground_cover)
			case .Shrub: state.diagnostics.shrub_cover += u64(cohort.ground_cover)
			case .Tree: state.diagnostics.tree_cover += u64(cohort.ground_cover)
			}
		}
		if occupied do state.diagnostics.occupied_cells += 1
	}
}

flora_ecology_snapshot_size :: proc(state: ^Flora_Ecology) -> int {
	assert(state != nil, "flora ecology snapshot size: nil state")
	return size_of(state.lineage_count) + size_of(state.next_lineage_salt) + size_of(state.step) +
		size_of(state.revision) + size_of(state.sterile) + size_of(state.diagnostics) +
		len(state.cells) * size_of(Flora_Cell) + int(state.lineage_count) * size_of(Flora_Lineage) + size_of(u64)
}

_flora_snapshot_put :: proc(buffer: []u8, cursor: ^int, bytes: []u8) -> bool {
	if cursor^ + len(bytes) > len(buffer) do return false
	copy(buffer[cursor^:], bytes)
	cursor^ += len(bytes)
	return true
}

flora_ecology_snapshot_write :: proc(state: ^Flora_Ecology, buffer: []u8) -> (written: int, ok: bool) {
	assert(state != nil, "flora ecology snapshot write: nil state")
	if len(buffer) < flora_ecology_snapshot_size(state) do return 0, false
	cursor := 0
	ok = _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.lineage_count))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.next_lineage_salt))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.step))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.revision))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.sterile))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&state.diagnostics))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.cells))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.slice_to_bytes(state.lineages[:state.lineage_count]))
	payload_size := u64(flora_ecology_snapshot_size(state))
	ok = ok && _flora_snapshot_put(buffer, &cursor, mem.ptr_to_bytes(&payload_size))
	if !ok do return 0, false
	return cursor, true
}

flora_ecology_snapshot_read :: proc(state: ^Flora_Ecology, buffer: []u8) -> bool {
	temporary: Flora_Ecology
	if !flora_ecology_init(&temporary, 0, state.allocator) do return false
	defer flora_ecology_deinit(&temporary, state.allocator)
	if !_flora_snapshot_read_into(&temporary, buffer) do return false
	previous := state^
	state^ = temporary
	temporary = previous
	return true
}

_flora_snapshot_read_into :: proc(state: ^Flora_Ecology, buffer: []u8) -> bool {
	if len(buffer) < flora_ecology_snapshot_size(state) do return false
	cursor := 0
	copy(mem.ptr_to_bytes(&state.lineage_count), buffer[cursor:cursor + size_of(state.lineage_count)])
	cursor += size_of(state.lineage_count)
	if u64(state.lineage_count) > u64(len(buffer)) / size_of(Flora_Lineage) do return false
	if len(buffer) != flora_ecology_snapshot_size(state) do return false
	if !_flora_registry_reserve(state, int(state.lineage_count)) do return false
	copy(mem.ptr_to_bytes(&state.next_lineage_salt), buffer[cursor:cursor + size_of(state.next_lineage_salt)])
	cursor += size_of(state.next_lineage_salt)
	copy(mem.ptr_to_bytes(&state.step), buffer[cursor:cursor + size_of(state.step)])
	cursor += size_of(state.step)
	copy(mem.ptr_to_bytes(&state.revision), buffer[cursor:cursor + size_of(state.revision)])
	cursor += size_of(state.revision)
	copy(mem.ptr_to_bytes(&state.sterile), buffer[cursor:cursor + size_of(state.sterile)])
	cursor += size_of(state.sterile)
	copy(mem.ptr_to_bytes(&state.diagnostics), buffer[cursor:cursor + size_of(state.diagnostics)])
	cursor += size_of(state.diagnostics)
	cell_bytes := len(state.cells) * size_of(Flora_Cell)
	if cursor + cell_bytes + int(state.lineage_count) * size_of(Flora_Lineage) + size_of(u64) != len(buffer) do return false
	copy(mem.slice_to_bytes(state.cells), buffer[cursor:cursor + cell_bytes])
	cursor += cell_bytes
	lineage_bytes := int(state.lineage_count) * size_of(Flora_Lineage)
	copy(mem.slice_to_bytes(state.lineages[:state.lineage_count]), buffer[cursor:cursor + lineage_bytes])
	payload_size: u64
	copy(mem.ptr_to_bytes(&payload_size), buffer[len(buffer) - size_of(u64):])
	if payload_size != u64(len(buffer)) do return false
	if !_flora_lineage_slots_rebuild(state) do return false
	for &lineage, index in state.lineages[:state.lineage_count] {
		if u8(lineage.form) > u8(Flora_Growth_Form.Tree) || !_flora_morphology_valid(&lineage) do return false
		family := flora_morphology_family(&lineage)
		if lineage.form <= .Reed && family >= FLORA_GROUND_FAMILY_COUNT do return false
		if lineage.form == .Shrub && family >= FLORA_SHRUB_FAMILY_COUNT do return false
		if lineage.form == .Tree && family >= FLORA_TREE_FAMILY_COUNT do return false
		if lineage.light_demand < 1 || lineage.light_demand > 1000 || lineage.shade_tolerance < 1 || lineage.shade_tolerance > 1000 do return false
		if lineage.root_depth < 1 || lineage.root_depth > 2000 || lineage.nutrient_demand < 1 || lineage.nutrient_demand > 1000 do return false
		if lineage.colonisation < 1 || lineage.colonisation > 1000 || lineage.competition < 1 || lineage.competition > 1000 do return false
		if lineage.disturbance_tolerance < 1 || lineage.disturbance_tolerance > 1000 || lineage.longevity < 1 || lineage.longevity > 4000 do return false
		if lineage.mutation_rate_ppm < 100 || lineage.mutation_rate_ppm > 20_000 do return false
		founder_slot, found := state.lineage_slots[lineage.founder]
		if !found || founder_slot > u32(index) do return false
		if lineage.parent != Lineage_Id(0) {
			parent_slot, parent_found := state.lineage_slots[lineage.parent]
			if !parent_found || parent_slot >= u32(index) do return false
			if state.lineages[parent_slot].founder != lineage.founder do return false
		} else if lineage.founder != lineage.id { return false }
	}
	mem.zero_slice(state.next_cells)
	for cell in state.cells {
		for reserve, form in cell.founder_reserve {
			if reserve > 4000 || state.sterile && reserve != 0 do return false
			if reserve > 0 {
				found := false
				for lineage in state.lineages[:state.lineage_count] do found = found || lineage.parent == Lineage_Id(0) && int(lineage.form) == form
				if !found do return false
			}
		}
		total: u32
		for cohort in cell.cohorts {
			if cohort.biomass > FLORA_BIOMASS_SCALE || cohort.root_cover > cohort.ground_cover || cohort.canopy_cover > cohort.ground_cover do return false
			if cohort.lineage == Lineage_Id(0) {
				if cohort.ground_cover != 0 do return false
				continue
			}
			if _, found := flora_ecology_lineage(state, cohort.lineage); !found do return false
			total += u32(cohort.ground_cover)
		}
		if total + u32(cell.bare_ground) != u32(FLORA_COVER_SCALE) do return false
	}
	return true
}
