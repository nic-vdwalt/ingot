package main

import "../shared"

Planet_Material_Controls :: struct {
	living, organic, sediment: f32,
}

planet_material_flora_cover :: proc(world: ^shared.World, direction: [3]f32) -> (ground, canopy: f32) {
	cell := &world.flora_ecology.cells[shared.planetary_sample_index(direction)]
	for cohort in cell.cohorts {
		lineage, found := shared.flora_ecology_lineage(&world.flora_ecology, cohort.lineage)
		if !found do continue
		switch lineage.form {
		case .Pioneer, .Groundcover, .Grass, .Reed:
			ground += f32(cohort.ground_cover) / f32(shared.FLORA_COVER_SCALE)
		case .Shrub, .Tree:
			canopy += f32(cohort.canopy_cover) / f32(shared.FLORA_COVER_SCALE)
		}
	}
	return clamp(ground, 0, 1), clamp(canopy, 0, 1)
}

planet_material_controls :: proc(biome: shared.Biome_Id, ground, canopy, moisture, shore: f32) -> Planet_Material_Controls {
	living := clamp(ground, 0, 1)
	organic := clamp(canopy, 0, 1) * (0.25 + clamp(moisture, 0, 1) * 0.5)
	sediment := clamp(shore, 0, 1)
	switch biome {
	case .Desert: sediment = max(sediment, 0.85)
	case .Coast, .Ocean, .Lake: sediment = 1
	case .Wetland: organic *= 1.3
	case .Grassland, .Savannah, .Forest, .Taiga, .Tundra, .Snowlands, .Mountain:
	}
	organic = min(organic, 1 - living)
	sediment *= max(1 - living - organic, 0)
	return {living, organic, sediment}
}

planet_material_pack :: proc(value: Planet_Material_Controls) -> [3]u8 {
	living := u8(clamp(value.living, 0, 1) * 255)
	organic := u8(clamp(value.organic, 0, 1) * 255)
	organic = min(organic, 255 - living)
	sediment := u8(clamp(value.sediment, 0, 1) * 255)
	sediment = min(sediment, 255 - living - organic)
	return {living, organic, sediment}
}
