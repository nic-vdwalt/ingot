package shared

import "core:testing"
import ecs "ingot:ecs"

@(test)
geothermal_flux_falls_with_crust_age :: proc(t: ^testing.T) {
	young := geothermal_heat_flux(1_000, .Intraplate)
	old := geothermal_heat_flux(100_000, .Intraplate)
	testing.expect(t, young > old)
}

@(test)
hydrothermal_plume_grows_with_buoyancy :: proc(t: ^testing.T) {
	low := hydrothermal_plume_height_mm(1_000, 1_000)
	high := hydrothermal_plume_height_mm(10_000, 1_000)
	testing.expect(t, high > low)
}

@(test)
hydrothermal_vents_are_stable_ecs_entities :: proc(t: ^testing.T) {
	world := new(World)
	defer free(world)
	testing.expect(t, world_init(world))
	defer world_deinit(world)
	testing.expect(t, ecs.set_len(&world.hydrothermal_vents) > 0)
	entity := world.hydrothermal_vents.header.entities[0]
	vent := world.hydrothermal_vents.items[0]
	testing.expect(t, vent.active)
	id, has_id := world_net_id_for_entity(world, entity)
	testing.expect(t, has_id)
	resolved, found := world_entity_by_net_id(world, id)
	testing.expect(t, found)
	testing.expect_value(t, resolved, entity)
	before := world.planetary.biogeochemistry.hydrogen_sulfide[vent.cell]
	hydrothermal_step(world)
	testing.expect(t, world.planetary.biogeochemistry.hydrogen_sulfide[vent.cell] >= before)
}

@(test)
mogi_displacement_falls_with_distance :: proc(t: ^testing.T) {
	near := abs(mogi_vertical_displacement_micro(1_000_000, 2_000, 0))
	far := abs(mogi_vertical_displacement_micro(1_000_000, 2_000, 4_000))
	testing.expect(t, near > far)
}
