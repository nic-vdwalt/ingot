package shared

import ecs "ingot:ecs"

Hydrothermal_Vent_State :: enum u8 {
	Active,
	Dormant,
	Extinct,
}

Hydrothermal_Vent :: struct {
	cell:            u32,
	temperature_mk:  i32,
	mass_flux_g_s:   u32,
	buoyancy_flux:   u32,
	chemistry:       u32,
	chimney_mm:      u32,
	plume_height_mm: u32,
	birth_tick:      u64,
	age_steps:       u64,
	stability:       u32,
	capacity:        u64,
	ph_milli:        u32,
	redox_millivolts: i32,
	heat_flux:       u32,
	sulfide_flux:    u32,
	hydrogen_flux:   u32,
	methane_flux:    u32,
	iron_flux:       u32,
	ammonium_flux:   u32,
	phosphate_flux:  u32,
	carbon_flux:     u32,
	turbidity_flux:  u32,
	cumulative_output: u64,
	state:           Hydrothermal_Vent_State,
	active:          bool,
}

hydrothermal_vent_at_coord :: proc(world: ^World, coord: Planet_Coord) -> (ecs.Entity, bool) {
	assert(world != nil, "hydrothermal_vent_at_coord: nil world")
	assert(planet_coord_valid(coord), "hydrothermal_vent_at_coord: invalid coordinate")
	canonical := planet_canonical(coord)
	for index in 0 ..< ecs.set_len(&world.hydrothermal_vents) {
		entity := world.hydrothermal_vents.header.entities[index]
		transform, located := ecs.get(&world.transforms, entity)
		if !located do continue
		other := planet_canonical({transform.face, transform.grid_x, transform.grid_y})
		if other == canonical do return entity, true
	}
	return ecs.ENTITY_NIL, false
}

hydrothermal_init :: proc(world: ^World) -> bool {
	assert(world != nil, "hydrothermal_init: nil world")
	planet := &world.planetary
	for index in 0 ..< PLANET_SIM_CELL_COUNT {
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		if planet.geology.boundary[index] != .Ridge do continue
		rayleigh := hydrothermal_rayleigh_darcy(
			planet.geology.heat_flux_mw_m2[index],
			planet.geology.permeability_nano[index],
		)
		if rayleigh < 1_000 do continue
		if int(ecs.set_len(&world.hydrothermal_vents)) >= MAX_HYDROTHERMAL_VENTS do break
		entity, created := ecs.create_entity(&world.pool)
		if !created do return false
		coord := planet_sim_terrain_coord(planet_sim_coord_for_index(index))
		transform := planet_transform_make(coord, terrain_height_at_coord(world, coord))
		heat := planet.geology.heat_flux_mw_m2[index]
		permeability := planet.geology.permeability_nano[index]
		hydration := planet.geology.hydration_ppm[index]
		vent := Hydrothermal_Vent {
			cell              = u32(index),
			temperature_mk    = 623 * PLANET_TEMPERATURE_SCALE,
			mass_flux_g_s     = 10_000 + permeability * 10,
			buoyancy_flux     = heat * 10,
			chemistry         = 100_000,
			stability         = min(500_000 + permeability * 400, u32(1_000_000)),
			capacity          = u64(heat + hydration + permeability) * 100_000,
			ph_milli          = 5_500 + u32(index % 1_000),
			redox_millivolts  = -250,
			heat_flux         = heat,
			sulfide_flux      = 4_000 + hydration / 20,
			hydrogen_flux     = 1_000 + permeability,
			methane_flux      = 500 + hydration / 100,
			iron_flux         = 2_000 + heat,
			ammonium_flux     = 400 + hydration / 200,
			phosphate_flux    = 100 + heat / 10,
			carbon_flux       = 2_000 + hydration / 50,
			turbidity_flux    = 1_000 + permeability,
			state             = .Active,
			active            = true,
		}
		added := ecs.add(&world.transforms, entity, transform)
		added = added && ecs.add(&world.hydrothermal_vents, entity, vent)
		net_id := _allocate_net_id(world)
		added = added && ecs.add(&world.net_ids, entity, net_id)
		if !added {
			_ = ecs.destroy_entity(&world.pool, entity)
			return false
		}
		world_net_index_add(world, entity, net_id)
	}
	return true
}

hydrothermal_reconcile :: proc(world: ^World) -> bool {
	assert(world != nil, "hydrothermal_reconcile: nil world")
	for index in 0 ..< ecs.set_len(&world.hydrothermal_vents) {
		vent := &world.hydrothermal_vents.items[index]
		cell := int(vent.cell)
		if world.planetary.geology.boundary[cell] != .Ridge {
			vent.state = .Extinct
			vent.active = false
			continue
		}
		vent.heat_flux = world.planetary.geology.heat_flux_mw_m2[cell]
		coord := planet_sim_terrain_coord(planet_sim_coord_for_index(cell))
		entity := world.hydrothermal_vents.header.entities[index]
		if transform, found := ecs.get(&world.transforms, entity); found {
			transform^ = planet_transform_make(coord, terrain_height_at_coord(world, coord))
		}
	}
	return true
}

hydrothermal_rayleigh_darcy :: proc(heat_flux_mw_m2, permeability_nano: u32) -> u32 {
	return u32(min(u64(heat_flux_mw_m2) * u64(permeability_nano) / 10, u64(max(u32))))
}

hydrothermal_plume_height_mm :: proc(buoyancy_flux, stratification: u32) -> u32 {
	return u32(
		min(
			integer_sqrt(u64(buoyancy_flux) * 1_000_000) *
			100 /
			max(u64(integer_sqrt(u64(stratification) + 1)), u64(1)),
			u64(2_000_000),
		),
	)
}

hydrothermal_inject :: proc(planet: ^Planetary_State, vent: ^Hydrothermal_Vent) {
	assert(planet != nil && vent != nil, "hydrothermal_inject: nil input")
	centre := int(vent.cell)
	cells := [5]u32{vent.cell, planet.grid.neighbours[centre][0], planet.grid.neighbours[centre][1], planet.grid.neighbours[centre][2], planet.grid.neighbours[centre][3]}
	weights := [5]u32{500, 125, 125, 125, 125}
	state := &planet.biogeochemistry
	for cell, offset in cells {
		index := int(cell)
		if planet.ocean.mean_depth_mm[index] == 0 do continue
		weight := weights[offset]
		state.hydrogen_sulfide[index] = min(state.hydrogen_sulfide[index] + vent.sulfide_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.hydrogen[index] = min(state.hydrogen[index] + vent.hydrogen_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.methane[index] = min(state.methane[index] + vent.methane_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.ferrous_iron[index] = min(state.ferrous_iron[index] + vent.iron_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.ammonium[index] = min(state.ammonium[index] + vent.ammonium_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.phosphate[index] = min(state.phosphate[index] + vent.phosphate_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.dissolved_inorganic_carbon[index] = min(state.dissolved_inorganic_carbon[index] + vent.carbon_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.turbidity[index] = min(state.turbidity[index] + vent.turbidity_flux * weight / 1_000, BIOGEO_MAX_CONCENTRATION)
		state.bottom_temperature_mk[index] = planet_saturating_i32(i64(state.bottom_temperature_mk[index]) + i64(vent.heat_flux * weight / 1_000), PLANET_MIN_TEMPERATURE, PLANET_MAX_TEMPERATURE)
	}
}

hydrothermal_step :: proc(world: ^World) {
	assert(world != nil, "hydrothermal_step: nil world")
	planet := &world.planetary
	for index in 0 ..< ecs.set_len(&world.hydrothermal_vents) {
		vent := &world.hydrothermal_vents.items[index]
		if vent.state == .Extinct do continue
		vent.age_steps += 1
		if vent.capacity <= u64(vent.mass_flux_g_s) {
			vent.capacity = 0
			vent.state = .Extinct
			vent.active = false
			continue
		}
		vent.capacity -= u64(vent.mass_flux_g_s)
		if vent.stability < 100_000 {
			vent.state = .Dormant
			vent.active = false
		} else {
			vent.state = .Active
			vent.active = true
		}
		if !vent.active do continue
		vent.plume_height_mm = hydrothermal_plume_height_mm(vent.buoyancy_flux, 1_000)
		vent.chimney_mm = min(vent.chimney_mm + max(vent.mass_flux_g_s / 10_000, u32(1)), u32(60_000))
		hydrothermal_inject(planet, vent)
		output := u64(vent.sulfide_flux + vent.hydrogen_flux + vent.methane_flux + vent.iron_flux + vent.ammonium_flux + vent.phosphate_flux + vent.carbon_flux)
		vent.cumulative_output += output
		planet.biogeochemistry.diagnostics.source_total += output
		_ = planetary_event_push(&planet.events, .Vent, vent.cell, vent.buoyancy_flux, 1)
	}
}
