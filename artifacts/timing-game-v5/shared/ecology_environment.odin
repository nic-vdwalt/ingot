package shared

Ecology_Environment :: struct {
	land:                    bool,
	soil_water:              u32,
	soil_nutrients:          u32,
	slope:                   u16,
	biome:                   Biome_Id,
	temperature_mk:          i32,
	bottom_temperature_mk:   i32,
	chemistry:               u32,
	water_depth_mm:          u32,
	current_speed:           u32,
	tide_mm:                 i32,
	surface_par:             u32,
	benthic_par:             u32,
	salinity:                u32,
	dissolved_oxygen:        u32,
	inorganic_carbon:        u32,
	hydrogen_sulfide:        u32,
	hydrogen:                u32,
	methane:                 u32,
	ferrous_iron:            u32,
	nitrate:                 u32,
	ammonium:                u32,
	phosphate:               u32,
	organic_carbon:          u32,
	turbidity:               u32,
	pathway_energy:          [BIOGEO_PATHWAY_COUNT]u32,
}

ecology_environment_at_cell :: proc(world: ^World, index: int) -> Ecology_Environment {
	assert(world != nil && index >= 0 && index < PLANET_SIM_CELL_COUNT, "ecology_environment_at_cell: invalid input")
	ocean := &world.planetary.ocean
	if ocean.mean_depth_mm[index] == 0 {
		habitat := flora_habitat_at_cell(world, index)
		return {
			land = habitat.land,
			soil_water = habitat.soil_water,
			soil_nutrients = habitat.nutrients,
			slope = habitat.slope,
			biome = habitat.biome,
			temperature_mk = habitat.temperature_mk,
			surface_par = habitat.par,
		}
	}
	state := &world.planetary.biogeochemistry
	energy := state.pathway_energy[index]
	chemistry := energy[0]
	for value in energy do chemistry = max(chemistry, value)
	current_east, current_north := ocean_column_transport(ocean, index)
	return {
		temperature_mk = ocean.temperature[index],
		bottom_temperature_mk = state.bottom_temperature_mk[index],
		chemistry = chemistry,
		water_depth_mm = ocean.mean_depth_mm[index],
		current_speed = u32(abs(current_east) + abs(current_north)),
		tide_mm = ocean.surface_mm[index],
		surface_par = state.surface_par[index],
		benthic_par = state.benthic_par[index],
		salinity = state.salinity[index],
		dissolved_oxygen = state.dissolved_oxygen[index],
		inorganic_carbon = state.dissolved_inorganic_carbon[index],
		hydrogen_sulfide = state.hydrogen_sulfide[index],
		hydrogen = state.hydrogen[index],
		methane = state.methane[index],
		ferrous_iron = state.ferrous_iron[index],
		nitrate = state.nitrate[index],
		ammonium = state.ammonium[index],
		phosphate = state.phosphate[index],
		organic_carbon = state.dissolved_organic_carbon[index],
		turbidity = state.turbidity[index],
		pathway_energy = energy,
	}
}

ecology_environment_at_transform :: proc(world: ^World, transform: ^Transform) -> Ecology_Environment {
	assert(world != nil && transform != nil, "ecology environment: nil input")
	return ecology_environment_at_cell(world, planetary_sample_index(transform.up))
}
