package shared

flora_disturb_cell :: proc(world: ^World, index: int, severity: u16) {
	state := &world.flora_ecology
	if state.sterile || index >= len(state.cells) do return
	cell := &state.cells[index]
	cell.disturbance = max(cell.disturbance, min(severity, u16(10000)))
	cell.succession_steps = 0
	state.revision += 1
}

Flora_Habitat :: struct {
	land: bool,
	temperature_mk: i32,
	soil_water, nutrients, par: u32,
	temperature, moisture: u8,
	light: u16,
	mean_temperature, mean_moisture: u8,
	mean_light: u16,
	slope, snow: u16,
	biome: Biome_Id,
}

flora_habitat_at_cell :: proc(world: ^World, index: int) -> Flora_Habitat {
	climate := &world.planetary.climate
	terrain_index := planet_index(planet_sim_terrain_coord(planet_sim_coord_for_index(index)))
	habitat := Flora_Habitat{
		land = world.planetary.ocean.mean_depth_mm[index] == 0,
		temperature_mk = climate.temperature[index],
		soil_water = climate.soil_water[index],
		par = climate.photosynthetic_radiation[index],
		slope = world.foundation.slope[terrain_index],
		snow = u16(min(climate.snow[index] / 100, u32(1000))),
		biome = world.foundation.primary_biome[terrain_index],
	}
	if index < len(world.flora_ecology.cells) do habitat.nutrients = world.flora_ecology.cells[index].nutrients
	habitat.temperature = u8(clamp((habitat.temperature_mk - 220 * PLANET_TEMPERATURE_SCALE) / (120 * PLANET_TEMPERATURE_SCALE / 255), 0, 255))
	habitat.moisture = u8(min(u64(habitat.soil_water) * 255 / u64(PLANET_HUMIDITY_SCALE), 255))
	habitat.light = u16(min(habitat.par / 1000, u32(1000)))
	habitat.mean_temperature, habitat.mean_moisture, habitat.mean_light = habitat.temperature, habitat.moisture, habitat.light
	if index < len(world.biome_environment.cells) {
		cell := world.biome_environment.cells[index]
		habitat.mean_temperature = u8(clamp((cell.mean[0] - 220 * PLANET_TEMPERATURE_SCALE) / (120 * PLANET_TEMPERATURE_SCALE / 255), 0, 255))
		habitat.mean_moisture = u8(clamp(i64(cell.mean[1]) * 255 / i64(PLANET_HUMIDITY_SCALE), 0, 255))
		habitat.mean_light = u16(clamp(cell.mean[3] / 1000, 0, 1000))
		habitat.biome = cell.dominant
	}
	return habitat
}

flora_establishment_score :: proc(lineage: ^Flora_Lineage, habitat: Flora_Habitat, cell: ^Flora_Cell) -> u32 {
	if !habitat.land do return 0
	canopy: u32
	for cohort in cell.cohorts do canopy += u32(cohort.canopy_cover)
	current := _flora_fitness(lineage, habitat.temperature, habitat.moisture, habitat.light, cell.succession_steps, cell.disturbance)
	climate := _flora_fitness(lineage, habitat.mean_temperature, habitat.mean_moisture, habitat.mean_light, cell.succession_steps, cell.disturbance)
	resources := _flora_resource_score(lineage, habitat.moisture, habitat.light, cell.nutrients, canopy)
	exposure := 1000 - min(u32(habitat.slope) * 2, u32(1000))
	return min(current, climate) * resources / 1000 * exposure / 1000 * (1000 - u32(habitat.snow)) / 1000
}
