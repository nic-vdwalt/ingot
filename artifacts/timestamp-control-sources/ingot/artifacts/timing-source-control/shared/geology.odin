package shared

MAX_VOLCANIC_CENTRES :: 128
MAX_HYDROTHERMAL_VENTS :: 256

Plate_Boundary :: enum u8 {
	Intraplate,
	Ridge,
	Subduction,
	Collision,
	Transform,
}

Geology_State :: struct {
	crust_age_ka:          []u32,
	crust_thickness_m:     []u32,
	permeability_nano:     []u32,
	hydration_ppm:         []u32,
	heat_flux_mw_m2:       []u32,
	plate_id:              []u8,
	crust:                 []Plate_Crust,
	boundary:              []Plate_Boundary,
	boundary_strength:     []u8,
	magma_supply:          []u32,
	revision:              u64,
	mantle_temperature_mk: i32,
	core_temperature_mk:   i32,
	radiogenic_tw_milli:   u32,
	primordial_tw_milli:   u32,
}

geology_init :: proc(state: ^Geology_State, foundation: ^Planet_Foundation, allocator := context.allocator) {
	assert(state != nil && foundation != nil, "geology_init: nil input")
	state^ = {}
	state.crust_age_ka = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.crust_thickness_m = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.permeability_nano = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.hydration_ppm = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.heat_flux_mw_m2 = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.plate_id = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	state.crust = make([]Plate_Crust, PLANET_SIM_CELL_COUNT, allocator)
	state.boundary = make([]Plate_Boundary, PLANET_SIM_CELL_COUNT, allocator)
	state.boundary_strength = make([]u8, PLANET_SIM_CELL_COUNT, allocator)
	state.magma_supply = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.mantle_temperature_mk = 1_623 * PLANET_TEMPERATURE_SCALE
	state.core_temperature_mk = 5_300 * PLANET_TEMPERATURE_SCALE
	state.radiogenic_tw_milli = 23_000
	state.primordial_tw_milli = 24_000
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		direction := planet_sim_direction(planet_sim_coord_for_index(index))
		sample := lithosphere_sample(&foundation.lithosphere, direction)
		fraction := tectonic_genesis_continents(&foundation.lithosphere, direction)
		strength := _terrain_unit_to_u8(sample.boundary_strength)
		state.plate_id[index] = sample.plate_id
		state.crust[index] = sample.crust
		state.boundary[index] = sample.boundary
		state.boundary_strength[index] = strength
		state.crust_age_ka[index] = tectonic_genesis_ocean_age(sample)
		state.crust_thickness_m[index] = u32(7_000 + fraction * 31_000)
		state.permeability_nano[index] = 20 + u32(sample.boundary_strength * 980)
		state.hydration_ppm[index] = u32(10_000 + sample.boundary_strength * 90_000)
		if sample.crust == .Oceanic do state.hydration_ppm[index] = min(state.hydration_ppm[index] + 35_000, u32(100_000))
		state.heat_flux_mw_m2[index] = geothermal_heat_flux(
			state.crust_age_ka[index],
			state.boundary[index],
		)
		state.magma_supply[index] = 20
		if sample.boundary == .Ridge do state.magma_supply[index] = 200 + u32(sample.divergence * 300)
		if sample.role == .Overriding {
			arc := _lithosphere_kernel(sample.boundary_distance, 82, 48)
			state.magma_supply[index] = 250 + u32(sample.convergence * arc * 350)
		}
	}
}

@(private)
_geology_refresh_cell :: proc(state: ^Geology_State, tectonics: ^Tectonic_State, index: int) {
	assert(state != nil && tectonics != nil, "_geology_refresh_cell: nil input")
	assert(index >= 0 && index < PLANET_SIM_CELL_COUNT, "_geology_refresh_cell: index")
	strength := u32(tectonics.boundary_strength[index])
	state.permeability_nano[index] = 20 + strength * 980 / 255
	state.hydration_ppm[index] = 10_000 + strength * 90_000 / 255
	if state.crust[index] == .Oceanic {
		state.hydration_ppm[index] = min(state.hydration_ppm[index] + 35_000, u32(100_000))
	}
	state.heat_flux_mw_m2[index] = geothermal_heat_flux(
		state.crust_age_ka[index],
		state.boundary[index],
	)
	state.magma_supply[index] = 20
	if state.boundary[index] == .Ridge do state.magma_supply[index] = 200 + strength
	if tectonics.role[index] == .Overriding do state.magma_supply[index] = 250 + strength * 350 / 255
}

geology_tectonic_step :: proc(state: ^Geology_State, tectonics: ^Tectonic_State) {
	assert(state != nil && tectonics != nil, "geology_tectonic_step: nil input")
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		state.plate_id[index] = tectonics.plate_id[index]
		state.crust[index] = tectonics.crust[index]
		state.boundary[index] = tectonics.boundary[index]
		state.boundary_strength[index] = tectonics.boundary_strength[index]
		state.crust_age_ka[index] = tectonics.crust_age_ka[index]
		state.crust_thickness_m[index] = tectonics.crust_thickness_m[index]
		_geology_refresh_cell(state, tectonics, index)
	}
	state.revision += 1
}

geology_deinit :: proc(state: ^Geology_State, allocator := context.allocator) {
	assert(state != nil, "geology_deinit: nil state")
	delete(state.magma_supply, allocator)
	delete(state.boundary_strength, allocator)
	delete(state.boundary, allocator)
	delete(state.crust, allocator)
	delete(state.plate_id, allocator)
	delete(state.heat_flux_mw_m2, allocator)
	delete(state.hydration_ppm, allocator)
	delete(state.permeability_nano, allocator)
	delete(state.crust_thickness_m, allocator)
	delete(state.crust_age_ka, allocator)
	state^ = {}
}

geology_hash :: proc(seed, index: u64) -> u64 {
	value := seed + index * 0x9e3779b97f4a7c15
	value = (value ~ (value >> 30)) * 0xbf58476d1ce4e5b9
	value = (value ~ (value >> 27)) * 0x94d049bb133111eb
	return value ~ (value >> 31)
}
