package main

import shared "../shared"
import "core:testing"

@(test)
lithosphere_debug_uses_crust_palette_and_boundary_accent :: proc(t: ^testing.T) {
	oceanic := lithosphere_debug_color(.Oceanic, .Intraplate, 0)
	continental := lithosphere_debug_color(.Continental, .Intraplate, 0)
	testing.expect_value(t, oceanic, UI_LITHOSPHERE_OCEANIC)
	testing.expect_value(t, continental, UI_LITHOSPHERE_CONTINENTAL)
	boundary := lithosphere_debug_color(.Continental, .Subduction, 255)
	testing.expect(t, boundary != continental)
}

@(test)
lithosphere_debug_revision_is_render_only :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init(world))
	defer shared.world_deinit(world)
	before := shared.terrain_height_at_coord(world, {.Pos_X, 20, 20})
	revision := terrain_material_revision(world)
	debug_revision := terrain_material_revision(world, 1)
	testing.expect(t, revision != debug_revision)
	testing.expect_value(t, shared.terrain_height_at_coord(world, {.Pos_X, 20, 20}), before)
}
