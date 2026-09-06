package main

import shared "../shared"
import "core:fmt"
import ecs "ingot:ecs"
import rl "ingot:gfx"

DEBUG_ENTITY_SECTION_BUILDING :: Debug_Extension_Section_Key.Section_0
DEBUG_ENTITY_SECTION_RESOURCE :: Debug_Extension_Section_Key.Section_1
DEBUG_ENTITY_SECTION_RELATIONSHIPS :: Debug_Extension_Section_Key.Section_2
DEBUG_ENTITY_SECTION_VENT :: Debug_Extension_Section_Key.Section_3
DEBUG_ENTITY_SECTION_CREATURE :: Debug_Extension_Section_Key.Section_4
DEBUG_ENTITY_WIDGET_EFFICIENCY :: u32(0x1001)
DEBUG_ENTITY_WIDGET_RICHNESS :: u32(0x2001)

debug_entity_extension_bounds :: proc(value: ^Client_State, entity: ecs.Entity) -> (Bounds_3D, bool) {
	return fauna_world_bounds(value, entity)
}

debug_entity_outline_scale :: proc(pulse: f32) -> f32 {
	return 1.025 + clamp(pulse, f32(0), f32(1)) * 0.015
}

debug_entity_extension_outline_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	entity: ecs.Entity,
	pulse: f32,
) {
	scale := debug_entity_outline_scale(pulse)
	if building_mesh_outline_draw(value, pass, entity, scale, UI_AMBER) do return
	if node_mesh_outline_draw(value, pass, entity, scale, UI_AMBER) do return
	if vent_mesh_outline_draw(value, pass, entity, scale, UI_AMBER) do return
	_ = fauna_mesh_outline_draw(value, pass, entity, scale, UI_AMBER)
}

debug_present_building :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	building, ok := ecs.get(&value.world.buildings, entity)
	if !ok do return
	if !debug_panel_extension_category(panel, .Entities) do return
	_ = debug_panel_extension_group(panel, "CURRENT BUILDING", .Simple)
	names := BUILDING_NAMES
	debug_panel_extension_readout(panel, "kind", fmt.tprintf("%s", names[building.kind]))
	debug_panel_extension_readout(panel, "level", fmt.tprintf("%d", building.level))
	debug_panel_extension_readout(
		panel,
		"efficiency",
		fmt.tprintf("%d%%", building.efficiency_percent),
	)
	if construction, constructing := ecs.get(&value.world.constructions, entity); constructing {
		debug_panel_extension_readout(
			panel,
			"construction",
			fmt.tprintf("%d ticks left", construction.ticks_remaining),
		)
	}
}

debug_present_resource_node :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	node, ok := ecs.get(&value.world.nodes, entity)
	if !ok do return
	if !debug_panel_extension_category(panel, .Entities) do return
	_ = debug_panel_extension_group(panel, "CURRENT RESOURCE NODE", .Simple)
	resource_names := RESOURCE_NAMES
	debug_panel_extension_readout(panel, "kind", fmt.tprintf("%s", resource_names[node.kind]))
	debug_panel_extension_readout(panel, "richness", fmt.tprintf("%d%%", node.richness_percent))
}

debug_present_hydrothermal_vent :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	vent, ok := ecs.get(&value.world.hydrothermal_vents, entity)
	if !ok do return
	if !debug_panel_extension_category(panel, .Entities) do return
	_ = debug_panel_extension_group(panel, "CURRENT HYDROTHERMAL VENT", .Simple)
	debug_panel_extension_readout(panel, "cell", fmt.tprintf("%d", vent.cell))
	debug_panel_extension_readout(
		panel,
		"temperature",
		fmt.tprintf("%.2f K", f32(vent.temperature_mk) / 1_000),
	)
	debug_panel_extension_readout(panel, "mass flux", fmt.tprintf("%d g/s", vent.mass_flux_g_s))
	debug_panel_extension_readout(panel, "state", fmt.tprintf("%v", vent.state))
	_ = debug_panel_extension_group(panel, "VENT DIAGNOSTICS", .Advanced)
	debug_panel_extension_readout(panel, "buoyancy", fmt.tprintf("%d", vent.buoyancy_flux))
	debug_panel_extension_readout(panel, "age", fmt.tprintf("%d", vent.age_steps))
	debug_panel_extension_readout(panel, "stability / capacity", fmt.tprintf("%d / %d", vent.stability, vent.capacity))
	debug_panel_extension_readout(panel, "pH / redox", fmt.tprintf("%.2f / %d mV", f32(vent.ph_milli) / 1_000, vent.redox_millivolts))
	debug_panel_extension_readout(panel, "sulfide / hydrogen / methane", fmt.tprintf("%d / %d / %d", vent.sulfide_flux, vent.hydrogen_flux, vent.methane_flux))
	debug_panel_extension_readout(panel, "iron / ammonium / phosphate", fmt.tprintf("%d / %d / %d", vent.iron_flux, vent.ammonium_flux, vent.phosphate_flux))
	debug_panel_extension_readout(panel, "carbon / turbidity / output", fmt.tprintf("%d / %d / %d", vent.carbon_flux, vent.turbidity_flux, vent.cumulative_output))
	debug_panel_extension_readout(panel, "chimney", fmt.tprintf("%d mm", vent.chimney_mm))
	debug_panel_extension_readout(panel, "plume", fmt.tprintf("%d mm", vent.plume_height_mm))
	index := int(vent.cell)
	if index >= 0 && index < shared.PLANET_SIM_CELL_COUNT {
		debug_panel_extension_readout(
			panel,
			"ocean local",
			fmt.tprintf(
				"%.2f K / sulfide %d / O2 %d",
				f32(value.world.planetary.biogeochemistry.bottom_temperature_mk[index]) / 1_000,
				value.world.planetary.biogeochemistry.hydrogen_sulfide[index],
				value.world.planetary.biogeochemistry.dissolved_oxygen[index],
			),
		)
	}
}

debug_present_creature :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	creature, ok := ecs.get(&value.world.creatures, entity)
	if !ok do return
	if !debug_panel_extension_category(panel, .Entities) do return
	_ = debug_panel_extension_group(panel, "CURRENT CREATURE", .Simple)
	organism, has_organism := ecs.get(&value.world.organisms, entity)
	movement, has_movement := ecs.get(&value.world.movements, entity)
	if !has_organism || !has_movement do return
	genome, has_genome := ecs.get(&value.world.genomes, entity)
	debug_panel_extension_readout(panel, "kind / stage", fmt.tprintf("%v / %v", creature.kind, organism.stage))
	debug_panel_extension_readout(
		panel,
		"health / energy",
		fmt.tprintf("%d / %d", organism.health, organism.energy),
	)
	debug_panel_extension_readout(panel, "age", fmt.tprintf("%d ticks", organism.age_ticks))
	debug_panel_extension_readout(
		panel,
		"species / lineage",
		fmt.tprintf("#%d / #%d", u64(organism.species), u64(organism.lineage)),
	)
	debug_panel_extension_readout(panel, "genome", fmt.tprintf("#%d", u64(organism.genome)))
	debug_panel_extension_readout(panel, "behavior", fmt.tprintf("%v", movement.behavior))
	_ = debug_panel_extension_group(panel, "CREATURE AI", .Advanced)
	debug_panel_extension_readout(
		panel,
		"speed / sensory",
		fmt.tprintf("%d / %d mm", movement.speed_mm_step, creature.sensory_range_mm),
	)
	debug_panel_extension_readout(
		panel,
		"heading u,v",
		fmt.tprintf("%.3f, %.3f", f32(movement.heading_east) / f32(shared.PLANET_VECTOR_SCALE), f32(movement.heading_north) / f32(shared.PLANET_VECTOR_SCALE)),
	)
	debug_panel_extension_readout(
		panel,
		"prior / destination",
		fmt.tprintf("%v:%d,%d / %v:%d,%d", movement.prior.face, movement.prior.u, movement.prior.v, movement.destination.face, movement.destination.u, movement.destination.v),
	)
	debug_panel_extension_readout(
		panel,
		"next move / decision",
		fmt.tprintf("%d / %d", movement.next_move_tick, movement.decision_serial),
	)
	if has_genome {
		debug_panel_extension_readout(
			panel,
			"genome metabolism / growth / mobility",
			fmt.tprintf("%d / %d / %d", genome.metabolism, genome.growth, genome.mobility),
		)
		debug_panel_extension_readout(
			panel,
			"thermal / chemical preference",
			fmt.tprintf("%.2f K / %d", f32(genome.thermal_preference_mk) / 1_000, genome.chemical_preference),
		)
	}
}

debug_present_relationships :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	link, ok := ecs.get(&value.world.harvest_links, entity)
	if !ok do return
	if !debug_panel_extension_category(panel, .Entities) do return
	_ = debug_panel_extension_group(panel, "RELATIONSHIPS", .Advanced)
	debug_panel_extension_readout(panel, "harvest node", fmt.tprintf("#%d", u64(link.node)))
	if debug_panel_extension_button(panel, 0x3001, "Inspect harvest node") {
		if target, found := shared.world_entity_by_net_id(&value.world, link.node); found {
			value.debug.target = debug_target_entity(link.node, target)
			value.debug.scroll = 0
			value.debug.scope_flash_elapsed = 0
		}
	}
}

debug_panel_entity_extension :: proc(
	value: ^Client_State,
	panel: ^Debug_Panel_Extension_Context,
	entity: ecs.Entity,
) {
	assert(value != nil && panel != nil, "debug entity extension: nil input")
	if debug_panel_extension_category(panel, .Entities) {
		_ = debug_panel_extension_group(panel, "ENTITY IDENTITY", .Advanced)
		if net_id, ok := shared.world_net_id_for_entity(&value.world, entity); ok {
			debug_panel_extension_readout(panel, "stable id", fmt.tprintf("#%d", u64(net_id)))
		}
	}
	debug_present_building(value, panel, entity)
	debug_present_resource_node(value, panel, entity)
	debug_present_hydrothermal_vent(value, panel, entity)
	debug_present_creature(value, panel, entity)
	debug_present_relationships(value, panel, entity)
}
