package shared

BIOGEO_CONCENTRATION_SCALE :: u32(1_000_000)
BIOGEO_MAX_CONCENTRATION :: u32(4_000_000)
BIOGEO_IRRADIANCE_SCALE :: u32(1_000)
BIOGEO_MAX_IRRADIANCE :: u32(2_000_000)
BIOGEO_PATHWAY_COUNT :: 4

Biogeochemical_Pathway :: enum u8 {
	Sulfur_Oxidation,
	Methanotrophy,
	Iron_Oxidation,
	Hydrogen_Oxidation,
}

Biogeochemistry_Diagnostics :: struct {
	total_oxygen:           u64,
	total_inorganic_carbon: u64,
	total_sulfide:          u64,
	total_phosphate:        u64,
	source_total:           u64,
	sink_total:             u64,
	transport_residual:     i64,
	oxygenated_cells:       u32,
	anoxic_cells:           u32,
	mean_surface_par:       u32,
	mean_benthic_par:       u32,
	steps:                  u64,
}

Biogeochemistry_State :: struct {
	salinity:                   []u32,
	dissolved_oxygen:           []u32,
	dissolved_inorganic_carbon: []u32,
	hydrogen_sulfide:           []u32,
	hydrogen:                   []u32,
	methane:                    []u32,
	ferrous_iron:               []u32,
	nitrate:                    []u32,
	ammonium:                   []u32,
	phosphate:                  []u32,
	dissolved_organic_carbon:   []u32,
	turbidity:                  []u32,
	surface_par:                []u32,
	benthic_par:                []u32,
	bottom_temperature_mk:      []i32,
	pathway_energy:             [][BIOGEO_PATHWAY_COUNT]u32,
	transport_scratch:          [12][]i64,
	transport_flow:             []i64,
	diagnostics:                Biogeochemistry_Diagnostics,
	revision:                   u64,
}

biogeochemistry_init :: proc(
	state: ^Biogeochemistry_State,
	planet: ^Planetary_State,
	seed: u64,
	allocator := context.allocator,
) {
	assert(state != nil && planet != nil, "biogeochemistry_init: nil input")
	state^ = {}
	state.salinity = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.dissolved_oxygen = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.dissolved_inorganic_carbon = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.hydrogen_sulfide = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.hydrogen = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.methane = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.ferrous_iron = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.nitrate = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.ammonium = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.phosphate = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.dissolved_organic_carbon = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.turbidity = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.surface_par = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.benthic_par = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.bottom_temperature_mk = make([]i32, PLANET_SIM_CELL_COUNT, allocator)
	state.pathway_energy = make([][BIOGEO_PATHWAY_COUNT]u32, PLANET_SIM_CELL_COUNT, allocator)
	for &scratch in state.transport_scratch {
		scratch = make([]i64, PLANET_SIM_CELL_COUNT, allocator)
	}
	state.transport_flow = make([]i64, len(planet.grid.canonical_edges), allocator)
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		hash := geology_hash(seed ~ 0x7f4a7c159e3779b9, u64(index))
		latitude := u32(abs(planet.grid.latitude_microdegrees[index]))
		depth_factor := min(planet.ocean.mean_depth_mm[index] / 100_000, u32(200_000))
		state.salinity[index] = clamp(u32(34_000 + hash % 2_001), u32(30_000), u32(40_000))
		state.dissolved_oxygen[index] = clamp(
			u32(210_000 + latitude / 2_000),
			u32(150_000),
			u32(300_000),
		)
		state.dissolved_inorganic_carbon[index] = 2_000_000 + depth_factor
		state.nitrate[index] = 25_000 + depth_factor / 8
		state.ammonium[index] = 2_000 + u32((hash >> 16) % 2_000)
		state.phosphate[index] = 2_000 + depth_factor / 64
		state.dissolved_organic_carbon[index] = 60_000 + u32((hash >> 32) % 20_000)
		state.turbidity[index] = 10_000 + u32((hash >> 48) % 10_000)
		state.bottom_temperature_mk[index] = planet.ocean.temperature[index]
	}
	assert(biogeochemistry_valid(state, planet), "biogeochemistry_init: invalid state")
}

biogeochemistry_deinit :: proc(state: ^Biogeochemistry_State, allocator := context.allocator) {
	assert(state != nil, "biogeochemistry_deinit: nil state")
	delete(state.transport_flow, allocator)
	for scratch in state.transport_scratch do delete(scratch, allocator)
	delete(state.pathway_energy, allocator)
	delete(state.bottom_temperature_mk, allocator)
	delete(state.benthic_par, allocator)
	delete(state.surface_par, allocator)
	delete(state.turbidity, allocator)
	delete(state.dissolved_organic_carbon, allocator)
	delete(state.phosphate, allocator)
	delete(state.ammonium, allocator)
	delete(state.nitrate, allocator)
	delete(state.ferrous_iron, allocator)
	delete(state.methane, allocator)
	delete(state.hydrogen, allocator)
	delete(state.hydrogen_sulfide, allocator)
	delete(state.dissolved_inorganic_carbon, allocator)
	delete(state.dissolved_oxygen, allocator)
	delete(state.salinity, allocator)
	state^ = {}
}

biogeochemistry_valid :: proc(state: ^Biogeochemistry_State, planet: ^Planetary_State) -> bool {
	if state == nil || planet == nil do return false
	if len(state.salinity) != PLANET_SIM_CELL_COUNT ||
	   len(state.dissolved_oxygen) != PLANET_SIM_CELL_COUNT ||
	   len(state.dissolved_inorganic_carbon) != PLANET_SIM_CELL_COUNT ||
	   len(state.hydrogen_sulfide) != PLANET_SIM_CELL_COUNT ||
	   len(state.hydrogen) != PLANET_SIM_CELL_COUNT ||
	   len(state.methane) != PLANET_SIM_CELL_COUNT ||
	   len(state.ferrous_iron) != PLANET_SIM_CELL_COUNT ||
	   len(state.nitrate) != PLANET_SIM_CELL_COUNT ||
	   len(state.ammonium) != PLANET_SIM_CELL_COUNT ||
	   len(state.phosphate) != PLANET_SIM_CELL_COUNT ||
	   len(state.dissolved_organic_carbon) != PLANET_SIM_CELL_COUNT ||
	   len(state.turbidity) != PLANET_SIM_CELL_COUNT ||
	   len(state.surface_par) != PLANET_SIM_CELL_COUNT ||
	   len(state.benthic_par) != PLANET_SIM_CELL_COUNT ||
	   len(state.bottom_temperature_mk) != PLANET_SIM_CELL_COUNT ||
	   len(state.pathway_energy) != PLANET_SIM_CELL_COUNT {
		return false
	}
	for scratch in state.transport_scratch {
		if len(scratch) != PLANET_SIM_CELL_COUNT do return false
	}
	if len(state.transport_flow) != len(planet.grid.canonical_edges) do return false
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 &&
		   (state.salinity[index] != 0 ||
				   state.dissolved_oxygen[index] != 0 ||
				   state.dissolved_inorganic_carbon[index] != 0) {
			return false
		}
	}
	return true
}

biogeochemistry_fields :: proc(state: ^Biogeochemistry_State) -> [12][]u32 {
	assert(state != nil, "biogeochemistry_fields: nil state")
	return {
		state.salinity,
		state.dissolved_oxygen,
		state.dissolved_inorganic_carbon,
		state.hydrogen_sulfide,
		state.hydrogen,
		state.methane,
		state.ferrous_iron,
		state.nitrate,
		state.ammonium,
		state.phosphate,
		state.dissolved_organic_carbon,
		state.turbidity,
	}
}

biogeochemistry_reaction_extent :: proc(oxidant, reductant, divisor: u32) -> u32 {
	assert(divisor > 0, "biogeochemistry_reaction_extent: zero divisor")
	return min(oxidant, reductant) / divisor
}

biogeochemistry_reaction_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "biogeochemistry_reaction_step: nil planet")
	biogeochemistry_reaction_range(planet, 0, PLANET_SIM_CELL_COUNT)
	planet.biogeochemistry.revision += 1
}

// biogeochemistry_reaction_range applies the per-cell reactions to one cell
// range; cells are independent so ranges can run concurrently.
biogeochemistry_reaction_range :: proc(planet: ^Planetary_State, start, end: int) {
	state := &planet.biogeochemistry
	for index in start ..< end {
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		wind := u32(abs(planet.climate.wind_east[index]) + abs(planet.climate.wind_north[index]))
		ice := planet.climate.sea_ice[index]
		oxygen_target := u32(
			clamp(
				i64(260_000) - i64(planet.ocean.temperature[index] - 273_000) * 4,
				i64(120_000),
				i64(350_000),
			),
		)
		gas_rate := max(u32(1), min(wind / 2_000 + 1, u32(16)))
		gas_rate = gas_rate * (CLIMATE_MAX_WATER - ice) / CLIMATE_MAX_WATER
		if state.dissolved_oxygen[index] < oxygen_target {
			state.dissolved_oxygen[index] += min(
				(oxygen_target - state.dissolved_oxygen[index]) / 512 * gas_rate,
				u32(2_000),
			)
		}
		sulfide_oxidation := biogeochemistry_reaction_extent(
			state.dissolved_oxygen[index],
			state.hydrogen_sulfide[index],
			128,
		)
		methane_oxidation := biogeochemistry_reaction_extent(
			state.dissolved_oxygen[index] - min(state.dissolved_oxygen[index], sulfide_oxidation),
			state.methane[index],
			256,
		)
		iron_oxidation := biogeochemistry_reaction_extent(
			state.dissolved_oxygen[index] -
			min(state.dissolved_oxygen[index], sulfide_oxidation + methane_oxidation),
			state.ferrous_iron[index],
			192,
		)
		ammonium_oxidation := biogeochemistry_reaction_extent(
			state.dissolved_oxygen[index] -
			min(
				state.dissolved_oxygen[index],
				sulfide_oxidation + methane_oxidation + iron_oxidation,
			),
			state.ammonium[index],
			512,
		)
		organic_remineralization := biogeochemistry_reaction_extent(
			state.dissolved_oxygen[index] -
			min(
				state.dissolved_oxygen[index],
				sulfide_oxidation + methane_oxidation + iron_oxidation + ammonium_oxidation,
			),
			state.dissolved_organic_carbon[index],
			1_024,
		)
		oxygen_used := min(
			state.dissolved_oxygen[index],
			sulfide_oxidation +
			methane_oxidation +
			iron_oxidation +
			ammonium_oxidation +
			organic_remineralization,
		)
		state.dissolved_oxygen[index] -= oxygen_used
		state.hydrogen_sulfide[index] -= min(state.hydrogen_sulfide[index], sulfide_oxidation)
		state.methane[index] -= min(state.methane[index], methane_oxidation)
		state.ferrous_iron[index] -= min(state.ferrous_iron[index], iron_oxidation)
		state.ammonium[index] -= min(state.ammonium[index], ammonium_oxidation)
		state.nitrate[index] = min(
			state.nitrate[index] + ammonium_oxidation,
			BIOGEO_MAX_CONCENTRATION,
		)
		state.dissolved_organic_carbon[index] -= min(
			state.dissolved_organic_carbon[index],
			organic_remineralization,
		)
		state.dissolved_inorganic_carbon[index] = min(
			state.dissolved_inorganic_carbon[index] + methane_oxidation + organic_remineralization,
			BIOGEO_MAX_CONCENTRATION,
		)
		state.ammonium[index] = min(
			state.ammonium[index] + organic_remineralization / 8,
			BIOGEO_MAX_CONCENTRATION,
		)
		state.phosphate[index] = min(
			state.phosphate[index] + organic_remineralization / 64,
			BIOGEO_MAX_CONCENTRATION,
		)
		geothermal_delta := i64(planet.geology.heat_flux_mw_m2[index]) / 20
		depth_insulation := i64(min(planet.ocean.mean_depth_mm[index] / 100_000, u32(5_000)))
		state.bottom_temperature_mk[index] = planet_saturating_i32(
			i64(planet.ocean.temperature[index]) + geothermal_delta + depth_insulation,
			PLANET_MIN_TEMPERATURE,
			PLANET_MAX_TEMPERATURE,
		)
		state.pathway_energy[index][int(Biogeochemical_Pathway.Sulfur_Oxidation)] = min(
			state.dissolved_oxygen[index],
			state.hydrogen_sulfide[index],
		)
		state.pathway_energy[index][int(Biogeochemical_Pathway.Methanotrophy)] = min(
			state.dissolved_oxygen[index],
			state.methane[index],
		)
		state.pathway_energy[index][int(Biogeochemical_Pathway.Iron_Oxidation)] = min(
			state.dissolved_oxygen[index],
			state.ferrous_iron[index],
		)
		state.pathway_energy[index][int(Biogeochemical_Pathway.Hydrogen_Oxidation)] = min(
			state.dissolved_oxygen[index],
			state.hydrogen[index],
		)
	}
}

biogeochemistry_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "biogeochemistry_step: nil planet")
	biogeochemistry_radiation_step(planet)
	biogeochemistry_reaction_step(planet)
}
