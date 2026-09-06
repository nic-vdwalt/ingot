package shared

Volcanic_Centre :: struct {
	cell:              u32,
	chamber_mass:      u64,
	pressure_kpa:      u32,
	roof_strength_kpa: u32,
	volatile_ppm:      u32,
	sequence:          u32,
	active:            bool,
}

Volcanism_State :: struct {
	centres: [MAX_VOLCANIC_CENTRES]Volcanic_Centre,
	count:   u16,
	lava_mm: []u32,
	ash:     []u32,
	revision: u64,
}

volcanism_init :: proc(
	state: ^Volcanism_State,
	geology: ^Geology_State,
	allocator := context.allocator,
) {
	assert(state != nil && geology != nil, "volcanism_init: nil input")
	state^ = {}
	state.lava_mm = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	state.ash = make([]u32, PLANET_SIM_CELL_COUNT, allocator)
	selected: [MAX_VOLCANIC_CENTRES]u32
	selected_count := 0
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if geology.magma_supply[index] < 250 do continue
		insert := selected_count
		for insert > 0 && geology.magma_supply[index] > geology.magma_supply[selected[insert - 1]] do insert -= 1
		if insert >= MAX_VOLCANIC_CENTRES do continue
		limit := min(selected_count, MAX_VOLCANIC_CENTRES - 1)
		for move := limit; move > insert; move -= 1 do selected[move] = selected[move - 1]
		selected[insert] = u32(index)
		selected_count = min(selected_count + 1, MAX_VOLCANIC_CENTRES)
	}
	for selected_index in 0 ..< selected_count {
		index := int(selected[selected_index])
		state.centres[state.count] = {
			cell              = u32(index),
			chamber_mass      = 1_000_000,
			pressure_kpa      = 1_000,
			roof_strength_kpa = 50_000 + u32(index % 20_000),
			volatile_ppm      = 20_000 + u32(index % 50_000),
			active            = true,
		}
		state.count += 1
	}
}

volcanism_deinit :: proc(state: ^Volcanism_State, allocator := context.allocator) {
	assert(state != nil, "volcanism_deinit: nil state")
	delete(state.ash, allocator)
	delete(state.lava_mm, allocator)
	state^ = {}
}

volcanism_step :: proc(planet: ^Planetary_State) {
	assert(planet != nil, "volcanism_step: nil planet")
	state := &planet.volcanism
	for index in 0 ..< int(state.count) {
		centre := &state.centres[index]
		if !centre.active do continue
		supply := planet.geology.magma_supply[centre.cell]
		centre.chamber_mass += u64(supply)
		centre.pressure_kpa = min(
			centre.pressure_kpa + supply / 8 + centre.volatile_ppm / 100_000,
			u32(200_000),
		)
		if centre.pressure_kpa < centre.roof_strength_kpa do continue
		magnitude := u32(min(centre.chamber_mass / 100_000, u64(8_000)))
		explosive := centre.volatile_ppm > 45_000
		if explosive {
			state.ash[centre.cell] = min(
				state.ash[centre.cell] + magnitude * 100,
				CLIMATE_MAX_WATER,
			)
			planet.climate.volcanic_aerosol[centre.cell] = min(
				planet.climate.volcanic_aerosol[centre.cell] + magnitude * 100,
				CLIMATE_MAX_WATER,
			)
			state.revision += 1
			_ = planetary_event_push(&planet.events, .Eruption, centre.cell, magnitude, 8)
			_ = planetary_event_push(&planet.events, .Ash, centre.cell, magnitude, 16)
		} else {
			state.lava_mm[centre.cell] = min(
				state.lava_mm[centre.cell] + magnitude * 10,
				u32(100_000),
			)
			state.revision += 1
			_ = planetary_event_push(&planet.events, .Lava, centre.cell, magnitude, 24)
		}
		released := min(centre.chamber_mass, u64(magnitude) * 100_000)
		centre.chamber_mass -= released
		centre.pressure_kpa /= 4
		centre.sequence += 1
	}
}

volcanism_apply_lava :: proc(world: ^World) {
	assert(world != nil, "volcanism_apply_lava: nil world")
	state := &world.planetary.volcanism
	tectonics := &world.planetary.tectonics
	for index in 0 ..< int(state.count) {
		centre := &state.centres[index]
		if !centre.active || state.lava_mm[centre.cell] == 0 do continue
		cell := int(centre.cell)
		addition := i32(min(state.lava_mm[cell] / 4_000, u32(4)))
		if addition == 0 do continue
		flora_disturb_cell(world, cell, 10000)
		tectonics.uplift_fixed[cell] = min(
			tectonics.uplift_fixed[cell] + addition,
			TECTONIC_UPLIFT_MAX_FIXED,
		)
		state.lava_mm[cell] -= min(state.lava_mm[cell], u32(addition * 4_000))
	}
}

volcanism_reconcile :: proc(world: ^World) {
	assert(world != nil, "volcanism_reconcile: nil world")
	state := &world.planetary.volcanism
	for index in 0 ..< int(state.count) {
		centre := &state.centres[index]
		if world.planetary.geology.magma_supply[centre.cell] < 100 do centre.active = false
	}
}

mogi_vertical_displacement_micro :: proc(volume_change_m3: i64, depth_m, radius_m: u32) -> i64 {
	assert(depth_m > 0, "mogi_vertical_displacement_micro: zero depth")
	distance_squared := u64(depth_m) * u64(depth_m) + u64(radius_m) * u64(radius_m)
	distance_cubed := distance_squared * max(integer_sqrt(distance_squared), u64(1))
	return volume_change_m3 * i64(depth_m) * 1_000_000 / i64(max(distance_cubed, u64(1)))
}
