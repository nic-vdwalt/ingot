package shared

import "core:testing"

@(test)
biogeochemistry_initialization_is_bounded_and_dry_cells_are_zero :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	testing.expect(t, biogeochemistry_valid(&world.planetary.biogeochemistry, &world.planetary))
	for depth, index in world.planetary.ocean.mean_depth_mm {
		if depth == 0 do testing.expect_value(t, world.planetary.biogeochemistry.dissolved_oxygen[index], u32(0))
	}
}

@(test)
benthic_light_falls_with_depth_and_turbidity :: proc(t: ^testing.T) {
	clear_shallow := biogeochemistry_light_attenuation(500_000, 1_000, 1_000, 1_000, 0)
	clear_deep := biogeochemistry_light_attenuation(500_000, 1_000_000, 1_000, 1_000, 0)
	turbid_shallow := biogeochemistry_light_attenuation(500_000, 1_000, 500_000, 1_000, 0)
	testing.expect(t, clear_shallow > clear_deep)
	testing.expect(t, clear_shallow > turbid_shallow)
	testing.expect_value(t, biogeochemistry_light_attenuation(0, 1_000, 0, 0, 0), u32(0))
}

@(test)
chemical_energy_requires_both_reactants :: proc(t: ^testing.T) {
	testing.expect_value(t, biogeochemistry_reaction_extent(100, 0, 2), u32(0))
	testing.expect_value(t, biogeochemistry_reaction_extent(0, 100, 2), u32(0))
	testing.expect(t, biogeochemistry_reaction_extent(200, 100, 2) > biogeochemistry_reaction_extent(200, 50, 2))
}
