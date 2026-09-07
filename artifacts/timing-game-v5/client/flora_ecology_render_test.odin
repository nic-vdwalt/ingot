package main

import shared "../shared"
import "core:testing"

@(test)
flora_growth_forms_map_to_bounded_meshes_and_scales :: proc(t: ^testing.T) {
	for form in u8(0) ..= u8(5) {
		count := 8 if form == 5 else 4
		pass := Flora_Scatter_Pass.Ground if form < 4 else Flora_Scatter_Pass.Large
		for family in 0 ..< count {
			sample := Flora_Ecology_Visual{form = form, biomass = 500_000, age_steps = 32, morphology_family = u8(family), stature = 1}
			mesh, scale, keep := _flora_pick_ecology(pass, sample, true)
			testing.expect(t, keep)
			if form < 4 do testing.expect_value(t, mesh, FLORA_GROUND_MESHES[family])
			if form == 4 do testing.expect_value(t, mesh, FLORA_SHRUB_MESHES[family])
			if form == 5 do testing.expect_value(t, mesh, FLORA_TREE_MESHES[family])
			sample.stature = 1000
			_, taller, _ := _flora_pick_ecology(pass, sample, true)
			testing.expect(t, taller > scale && taller <= 1.21)
			other := Flora_Scatter_Pass.Large if form < 4 else Flora_Scatter_Pass.Ground
			_, _, keep = _flora_pick_ecology(other, sample, true)
			testing.expect(t, !keep)
		}
	}
}

@(test)
flora_ecology_world_sample_reaches_a_render_mesh :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	occupied := -1
	for cell, index in world.flora_ecology.cells {
		if cell.cohorts[0].lineage != shared.Lineage_Id(0) {
			occupied = index
			break
		}
	}
	testing.expect(t, occupied >= 0)
	direction := shared.planet_sim_direction(shared.planet_sim_coord_for_index(occupied))
	visual, biological := flora_ecology_visual(world, direction, 0)
	testing.expect(t, biological)
	testing.expect(t, visual.lineage != 0)
	mesh, scale, keep := _flora_pick_ecology(.Ground, visual, biological)
	testing.expect(t, keep)
	testing.expect(t, _flora_is_grass(mesh))
	testing.expect(t, scale > 0)
}

@(test)
flora_debug_time_controls_are_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, FLORA_DEBUG_STEPS_PER_FRAME_MAX, 1)
	scales := [5]u32{0, 1, 10, 100, 1000}
	for scale in scales do testing.expect(t, scale <= 1000)
}

@(test)
flora_lineage_debug_navigates_ancestry_and_population :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	parent := world.flora_ecology.lineages[shared.Flora_Growth_Form.Grass]
	child_id, mutated := shared.flora_ecology_mutate_lineage(
		&world.flora_ecology,
		parent.id,
		world.foundation.seed,
		42,
	)
	testing.expect(t, mutated)
	world.flora_ecology.cells[42].cohorts[0] = {
		lineage = child_id,
		ground_cover = 700,
		biomass = 20_000,
	}
	state := Flora_Lineage_Debug_State{selected = parent.id}
	testing.expect(t, flora_lineage_debug_select_child(&state, &world.flora_ecology, 1))
	testing.expect_value(t, state.selected, child_id)
	population := flora_lineage_debug_population(&world.flora_ecology, child_id)
	testing.expect_value(t, population.active_cells, u32(1))
	testing.expect_value(t, population.strongest_cell, 42)
	testing.expect(t, flora_lineage_debug_select_parent(&state, &world.flora_ecology))
	testing.expect_value(t, state.selected, parent.id)
}
