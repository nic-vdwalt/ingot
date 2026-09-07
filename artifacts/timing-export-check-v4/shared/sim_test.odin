#+build !js
package shared

import "core:testing"
import ecs "ingot:ecs"

// Seeds whose center biome is Ocean, Grassland, Desert and Mountain: one per
// climate corner of the roster. A bake costs ~23 s in the unoptimised test
// build, so tests that only need terrain variety walk this spread instead of
// the whole roster.
_TEST_TERRAIN_SEEDS :: [?]u64{0, 4, 8, 11}

_test_buildable_cell :: proc(world: ^World) -> (x, y: i32, ok: bool) {
	for row in i32(2) ..< i32(PLANET_FACE_RESOLUTION - 2) {
		for column in i32(2) ..< i32(PLANET_FACE_RESOLUTION - 2) {
			if placement_allowed(world, column, row) do return column, row, true
		}
	}
	return 0, 0, false
}

_test_wet_cell :: proc(world: ^World) -> (x, y: i32, ok: bool) {
	for row in i32(1) ..< i32(PLANET_FACE_RESOLUTION - 1) {
		for column in i32(1) ..< i32(PLANET_FACE_RESOLUTION - 1) {
			if waterfield_wet_at_coord(world, {.Pos_X, column, row}) do return column, row, true
		}
	}
	return 0, 0, false
}

// _test_buildable_area finds the min corner of a span x span block of
// buildable, unoccupied cells on the spawn face. Placement tests anchor on
// real ground through this instead of the face corner, which the old flat
// grid only kept dry by way of the sea-level bug.
_test_buildable_area :: proc(world: ^World, span: i32) -> (x, y: i32, ok: bool) {
	assert(span >= 1, "_test_buildable_area: degenerate span")
	limit := i32(PLANET_FACE_RESOLUTION - 2) - span
	for row in i32(2) ..< limit {
		scan: for column in i32(2) ..< limit {
			for offset_y in i32(0) ..< span {
				for offset_x in i32(0) ..< span {
					if !placement_allowed(world, column + offset_x, row + offset_y) {
						continue scan
					}
				}
			}
			return column, row, true
		}
	}
	return 0, 0, false
}

@(test)
place_build_produce_matches_expected_math :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor_x, anchor_y, ok_anchor := _test_buildable_area(&world, 1)
	testing.expect(t, ok_anchor)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = anchor_x,
		grid_y   = anchor_y,
	}
	testing.expect(t, apply_command(&world, place))
	// Placement charged the level-1 mine cost from the starting stockpile.
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	testing.expect_value(t, stockpile.amounts[.Ore], 500 - 10)
	testing.expect_value(t, stockpile.amounts[.Energy], 200 - 5)
	// Same tile is now blocked.
	testing.expect(t, !apply_command(&world, place))
	// Run construction to completion: a level-1 mine takes 4 ticks.
	build_ticks := building_build_ticks(.Mine, 1)
	tick: u64 = 0
	for _ in 0 ..< build_ticks {
		sim_tick(&world, tick)
		tick += 1
	}
	testing.expect_value(t, ecs.set_len(&world.constructions), 0)
	// Production: level-1 mine yields 2 ore/tick at 100% efficiency. The
	// completion tick itself produced at level 1 already (construction system
	// runs before production), so after N more ticks: (N + 1) * 2 ore.
	production_ticks: u64 = 10
	for _ in 0 ..< production_ticks {
		sim_tick(&world, tick)
		tick += 1
	}
	expected_ore := u64(500 - 10) + (production_ticks + 1) * 2
	testing.expect_value(t, stockpile.amounts[.Ore], expected_ore)
}

@(test)
efficiency_command_is_clamped_and_scales_yield :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor_x, anchor_y, ok_anchor := _test_buildable_area(&world, 2)
	testing.expect(t, ok_anchor)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Solar_Array,
		grid_x   = anchor_x,
		grid_y   = anchor_y,
	}
	testing.expect(t, apply_command(&world, place))
	tick: u64 = 0
	for _ in 0 ..< building_build_ticks(.Solar_Array, 1) {
		sim_tick(&world, tick)
		tick += 1
	}
	testing.expect_value(t, ecs.set_len(&world.buildings), 1)
	target := world.buildings.header.entities[0]
	target_id, has_target_id := world_net_id_for_entity(&world, target)
	testing.expect(t, has_target_id)
	// A tampered 255% result must clamp to MAX_EFFICIENCY.
	tune := Command {
		kind               = .Set_Efficiency,
		player             = 0,
		target             = target_id,
		efficiency_percent = 255,
	}
	testing.expect(t, apply_command(&world, tune))
	building, ok_building := ecs.get(&world.buildings, target)
	testing.expect(t, ok_building)
	testing.expect_value(t, building.efficiency_percent, MAX_EFFICIENCY)
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	energy_before := stockpile.amounts[.Energy]
	sim_tick(&world, tick)
	// Level-1 solar array: 3 energy * 150% = 4 (integer division).
	testing.expect_value(t, stockpile.amounts[.Energy], energy_before + 3 * 150 / 100)
	// A foreign player cannot tune someone else's building.
	_, ok_other := spawn_player(&world, 1)
	testing.expect(t, ok_other)
	foreign_tune := Command {
		kind               = .Set_Efficiency,
		player             = 1,
		target             = target_id,
		efficiency_percent = 50,
	}
	testing.expect(t, !apply_command(&world, foreign_tune))
}

@(test)
same_commands_yield_identical_snapshots :: proc(t: ^testing.T) {
	world_a: World
	world_b: World
	testing.expect(t, world_init(&world_a))
	defer world_deinit(&world_a)
	testing.expect(t, world_init(&world_b))
	defer world_deinit(&world_b)
	_run_scripted_session(t, &world_a)
	_run_scripted_session(t, &world_b)
	size_a := world_snapshot_size(&world_a)
	size_b := world_snapshot_size(&world_b)
	testing.expect_value(t, size_a, size_b)
	buffer_a := make([]u8, size_a)
	defer delete(buffer_a)
	buffer_b := make([]u8, size_b)
	defer delete(buffer_b)
	_, ok_a := world_snapshot_write(&world_a, buffer_a)
	_, ok_b := world_snapshot_write(&world_b, buffer_b)
	testing.expect(t, ok_a)
	testing.expect(t, ok_b)
	for byte_index in 0 ..< len(buffer_a) {
		if buffer_a[byte_index] != buffer_b[byte_index] {
			testing.expectf(t, false, "snapshots differ at offset %d", byte_index)
			return
		}
	}
	// Restoring A's snapshot into B and re-running a tick stays identical.
	testing.expect(t, world_snapshot_read(&world_b, buffer_a))
	sim_tick(&world_a, 100)
	sim_tick(&world_b, 100)
	_, ok_a2 := world_snapshot_write(&world_a, buffer_a)
	_, ok_b2 := world_snapshot_write(&world_b, buffer_b)
	testing.expect(t, ok_a2)
	testing.expect(t, ok_b2)
	for byte_index in 0 ..< len(buffer_a) {
		if buffer_a[byte_index] != buffer_b[byte_index] {
			testing.expectf(t, false, "post-restore snapshots differ at offset %d (biome start %d, flora start %d, values %d/%d)", byte_index, len(buffer_a) - flora_ecology_snapshot_size(&world_a.flora_ecology) - BIOME_ENVIRONMENT_SNAPSHOT_BYTES, len(buffer_a) - flora_ecology_snapshot_size(&world_a.flora_ecology), buffer_a[byte_index], buffer_b[byte_index])
			return
		}
	}
}

_run_scripted_session :: proc(t: ^testing.T, world: ^World) {
	assert(world != nil, "_run_scripted_session: nil world")
	_, ok_player := spawn_player(world, 0)
	testing.expect(t, ok_player)
	_, ok_nodes := world_populate_nodes(world)
	testing.expect(t, ok_nodes)
	kinds := [3]Building_Kind{.Mine, .Solar_Array, .Habitat}
	coords: [3][2]i32
	found_all := _find_buildable_coords(world, kinds[:], coords[:])
	testing.expect(
		t,
		found_all,
		"_run_scripted_session: could not find 3 non-overlapping buildable sites",
	)
	if !found_all do return
	tick: u64 = 0
	for i in 0 ..< 3 {
		command := Command {
			kind     = .Place_Building,
			player   = 0,
			building = kinds[i],
			grid_x   = coords[i][0],
			grid_y   = coords[i][1],
		}
		testing.expect(t, apply_command(world, command))
		for _ in 0 ..< 5 {
			sim_tick(world, tick)
			tick += 1
		}
	}
	for _ in 0 ..< 20 {
		sim_tick(world, tick)
		tick += 1
	}
}

_find_buildable_coords :: proc(world: ^World, kinds: []Building_Kind, out: [][2]i32) -> bool {
	assert(len(kinds) == len(out))
	placed: int = 0
	for row in i32(10) ..< i32(PLANET_FACE_RESOLUTION - 10) {
		for col in i32(10) ..< i32(PLANET_FACE_RESOLUTION - 10) {
			w, h := building_footprint(kinds[placed])
			ok := true
			for ov in i32(0) ..< h {
				for ou in i32(0) ..< w {
					if !placement_allowed(world, col + ou, row + ov) {
						ok = false
						break
					}
					if _tile_occupied(world, col + ou, row + ov) {
						ok = false
						break
					}
				}
				if !ok do break
			}
			if !ok do continue
			overlap := false
			for p in 0 ..< placed {
				pw, ph := building_footprint(kinds[p])
				if col < out[p][0] + pw &&
				   col + w > out[p][0] &&
				   row < out[p][1] + ph &&
				   row + h > out[p][1] {
					overlap = true
					break
				}
			}
			if overlap do continue
			out[placed] = {col, row}
			placed += 1
			if placed == len(kinds) do return true
		}
	}
	return false
}

@(test)
placement_rejects_water_and_out_of_bounds_tiles :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	wet_x, wet_y, wet_found := _test_wet_cell(&world)
	testing.expect(t, wet_found)
	if !wet_found do return
	testing.expect(t, !placement_allowed(&world, wet_x, wet_y))
	water := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = wet_x,
		grid_y   = wet_y,
	}
	testing.expect(t, !apply_command(&world, water))
	// Outside the world bounds is never buildable.
	outside := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = 10_000,
		grid_y   = 0,
	}
	testing.expect(t, !apply_command(&world, outside))
	// A rejected command must not have charged the stockpile.
	player_entity := world.players[0]
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	testing.expect_value(t, stockpile.amounts[.Ore], 500)
	testing.expect_value(t, stockpile.amounts[.Energy], 200)
	grid_x, grid_y, found := _test_buildable_cell(&world)
	testing.expect(t, found)
	if !found do return
	valid := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = grid_x,
		grid_y   = grid_y,
	}
	testing.expect(t, apply_command(&world, valid))
}

@(test)
building_transforms_sit_on_terrain :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	transform := transform_make(&world, 3, 4)
	testing.expect_value(t, transform.position.x, 6)
	testing.expect_value(t, transform.position.y, 8)
	testing.expect_value(t, transform.position.z, terrain_height(&world, 6, 8))
	testing.expect(t, transform.position.z != 0)
}

@(test)
terraform_raises_height_and_charges_cost :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	before := terrain_height(&world, 2, 2)
	raise := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = 1,
		grid_y           = 1,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	testing.expect(t, apply_command(&world, raise))
	// Center vertex moves by the mound's peak, which is held constant
	// across brush sizes.
	expected_rise := f32(TERRAFORM_PEAK) / f32(HEIGHT_DELTA_SCALE)
	testing.expect_value(t, terrain_height(&world, 2, 2), before + expected_rise)
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	testing.expect_value(t, stockpile.amounts[.Ore], 500 - TERRAFORM_COST_ORE)
	// Lowering undoes the raise exactly (integer deltas).
	lower := raise
	lower.direction = -1
	testing.expect(t, apply_command(&world, lower))
	testing.expect_value(t, terrain_height(&world, 2, 2), before)
}

@(test)
terraform_levels_brush_and_validates_command :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	raise := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = 3,
		grid_y           = 3,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	testing.expect(t, apply_command(&world, raise))
	level := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = 1,
		grid_y           = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	target := f32(height_to_fixed(terrain_height(&world, 2, 2))) / f32(HEIGHT_DELTA_SCALE)
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	ore_before := stockpile.amounts[.Ore]
	testing.expect(t, apply_command(&world, level))
	testing.expect_value(t, stockpile.amounts[.Ore], ore_before - TERRAFORM_COST_ORE)
	for offset_y in -TERRAFORM_RADIUS ..= TERRAFORM_RADIUS {
		for offset_x in -TERRAFORM_RADIUS ..= TERRAFORM_RADIUS {
			cell_x := level.grid_x + offset_x
			cell_y := level.grid_y + offset_y
			if !grid_in_world(cell_x, cell_y) do continue
			height := terrain_height(
				&world,
				f32(cell_x) * GRID_CELL_SIZE,
				f32(cell_y) * GRID_CELL_SIZE,
			)
			testing.expect(t, abs(height - target) <= 0.5 / f32(HEIGHT_DELTA_SCALE) + 0.001)
		}
	}
	invalid := level
	invalid.direction = 2
	testing.expect(t, !apply_command(&world, invalid))
	testing.expect_value(t, stockpile.amounts[.Ore], ore_before - TERRAFORM_COST_ORE)
	occupied_world: World
	testing.expect(t, world_init(&occupied_world))
	defer world_deinit(&occupied_world)
	occupied_player, occupied_player_ok := spawn_player(&occupied_world, 0)
	testing.expect(t, occupied_player_ok)
	mine_x, mine_y, ok_mine := _test_buildable_area(&occupied_world, 1)
	testing.expect(t, ok_mine)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = mine_x,
		grid_y   = mine_y,
	}
	testing.expect(t, apply_command(&occupied_world, place))
	blocked := level
	blocked.grid_x = mine_x + TERRAFORM_RADIUS
	blocked.grid_y = mine_y
	occupied_stockpile, occupied_stockpile_ok := ecs.get(
		&occupied_world.stockpiles,
		occupied_player,
	)
	testing.expect(t, occupied_stockpile_ok)
	ore_before_blocked := occupied_stockpile.amounts[.Ore]
	testing.expect(t, !apply_command(&occupied_world, blocked))
	testing.expect_value(t, occupied_stockpile.amounts[.Ore], ore_before_blocked)
}

@(test)
terraform_clamps_at_max_delta_and_rejects_occupied :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	raise := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = 1,
		grid_y           = 1,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	// Saturate the center vertex; each apply adds the mound peak.
	applies := int(TERRAFORM_MAX_DELTA / TERRAFORM_PEAK)
	for _ in 0 ..< applies {
		testing.expect(t, apply_command(&world, raise))
	}
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	ore_at_clamp := stockpile.amounts[.Ore]
	// At the clamp further raising is rejected and not charged.
	testing.expect(t, !apply_command(&world, raise))
	testing.expect_value(t, stockpile.amounts[.Ore], ore_at_clamp)
	// A building blocks terraforming of every cell its mound would touch.
	mine_x, mine_y, ok_mine := _test_buildable_area(&world, 1)
	testing.expect(t, ok_mine)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = mine_x,
		grid_y   = mine_y,
	}
	testing.expect(t, apply_command(&world, place))
	ore_after_place := stockpile.amounts[.Ore]
	near_building := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = mine_x + TERRAFORM_RADIUS,
		grid_y           = mine_y,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	testing.expect(t, !apply_command(&world, near_building))
	testing.expect_value(t, stockpile.amounts[.Ore], ore_after_place)
}

@(test)
footprint_placement_rejects_overlap :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor_x, anchor_y, ok_anchor := _test_buildable_area(&world, 3)
	testing.expect(t, ok_anchor)
	// A 3x3 headquarters covers cells (anchor..anchor+2) on both axes.
	headquarters := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Headquarters,
		grid_x   = anchor_x,
		grid_y   = anchor_y,
	}
	testing.expect(t, apply_command(&world, headquarters))
	// A mine on a covered non-anchor cell must be rejected.
	inside := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = anchor_x + 2,
		grid_y   = anchor_y + 2,
	}
	testing.expect(t, !apply_command(&world, inside))
	// Terraform whose mound touches a covered non-anchor cell is rejected.
	near_footprint := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = anchor_x + 2 + TERRAFORM_RADIUS,
		grid_y           = anchor_y + 2,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	testing.expect(t, !apply_command(&world, near_footprint))
	// Selection helper agrees: every footprint cell resolves to the building.
	anchor_entity, anchor_found := building_at_cell(&world, anchor_x, anchor_y)
	testing.expect(t, anchor_found)
	corner_entity, corner_found := building_at_cell(&world, anchor_x + 2, anchor_y + 2)
	testing.expect(t, corner_found)
	testing.expect_value(t, corner_entity, anchor_entity)
	_, outside_found := building_at_cell(&world, anchor_x + 3, anchor_y)
	testing.expect(t, !outside_found)
}

@(test)
placement_rejects_node_coverage :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor_x, anchor_y, ok_anchor := _test_buildable_area(&world, 2)
	testing.expect(t, ok_anchor)
	_, ok_node := spawn_resource_node(
		&world,
		Planet_Coord{.Pos_X, anchor_x + 1, anchor_y + 1},
		.Ore,
		200,
	)
	testing.expect(t, ok_node)
	// A habitat footprint (2x2 from the anchor) covering the node is rejected.
	habitat := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Habitat,
		grid_x   = anchor_x,
		grid_y   = anchor_y,
	}
	testing.expect(t, !apply_command(&world, habitat))
	// A solar array (wrong harvester for ore) is rejected too.
	solar := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Solar_Array,
		grid_x   = anchor_x + 1,
		grid_y   = anchor_y + 1,
	}
	testing.expect(t, !apply_command(&world, solar))
	// The matching harvester is accepted on the same node.
	mine := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = anchor_x + 1,
		grid_y   = anchor_y + 1,
	}
	testing.expect(t, apply_command(&world, mine))
}

@(test)
mine_on_node_scales_yield :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	mine_x, mine_y, ok_anchor := _test_buildable_area(&world, 1)
	testing.expect(t, ok_anchor)
	_, ok_node := spawn_resource_node(&world, Planet_Coord{.Pos_X, mine_x, mine_y}, .Ore, 200)
	testing.expect(t, ok_node)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = mine_x,
		grid_y   = mine_y,
	}
	testing.expect(t, apply_command(&world, place))
	tick: u64 = 0
	for _ in 0 ..< building_build_ticks(.Mine, 1) {
		sim_tick(&world, tick)
		tick += 1
	}
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	ore_before := stockpile.amounts[.Ore]
	sim_tick(&world, tick)
	// Level-1 mine: 2 ore * 200% richness = 4 ore per tick.
	testing.expect_value(t, stockpile.amounts[.Ore], ore_before + 2 * 200 / 100)
}

@(test)
placement_flattens_footprint :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor_x, anchor_y, ok_anchor := _test_buildable_area(&world, 3)
	testing.expect(t, ok_anchor)
	headquarters := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Headquarters,
		grid_x   = anchor_x,
		grid_y   = anchor_y,
	}
	testing.expect(t, apply_command(&world, headquarters))
	target :=
		f32(
			height_to_fixed(
				terrain_height(
					&world,
					f32(anchor_x) * GRID_CELL_SIZE,
					f32(anchor_y) * GRID_CELL_SIZE,
				),
			),
		) /
		f32(HEIGHT_DELTA_SCALE)
	width, height := building_footprint(.Headquarters)
	for offset_y in 0 ..< height {
		for offset_x in 0 ..< width {
			world_x := f32(anchor_x + offset_x) * GRID_CELL_SIZE
			world_y := f32(anchor_y + offset_y) * GRID_CELL_SIZE
			cell_height := terrain_height(&world, world_x, world_y)
			// Each cell keeps its base-height quantisation remainder, so the
			// flattened surface is level to within half a fixed-point unit.
			difference := abs(cell_height - target)
			testing.expectf(
				t,
				difference <= 0.5 / f32(HEIGHT_DELTA_SCALE) + 0.001,
				"cell (%d,%d) off target by %f",
				anchor_x + offset_x,
				anchor_y + offset_y,
				difference,
			)
		}
	}
}

@(test)
footprint_partially_out_of_world_rejected :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	// Anchor is in bounds but the 3x3 footprint spills past the face edge.
	edge := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Headquarters,
		grid_x   = i32(PLANET_FACE_RESOLUTION - 2),
		grid_y   = i32(PLANET_FACE_RESOLUTION - 2),
	}
	testing.expect(t, !apply_command(&world, edge))
}

@(test)
terraform_deltas_survive_snapshot_roundtrip :: proc(t: ^testing.T) {
	world_a: World
	world_b: World
	testing.expect(t, world_init(&world_a))
	defer world_deinit(&world_a)
	testing.expect(t, world_init(&world_b))
	defer world_deinit(&world_b)
	_, ok_player := spawn_player(&world_a, 0)
	testing.expect(t, ok_player)
	raise := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = 100,
		grid_y           = 100,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	testing.expect(t, apply_command(&world_a, raise))
	buffer := make([]u8, world_snapshot_size(&world_a))
	defer delete(buffer)
	written, ok_write := world_snapshot_write(&world_a, buffer)
	testing.expect(t, ok_write)
	testing.expect_value(t, written, len(buffer))
	world_a.planetary.climate.surface_revision = 17
	world_a.planetary.orbit.simulated_seconds = 12345
	world_a.planetary.orbit.rotation_phase = 67890
	_, ok_write = world_snapshot_write(&world_a, buffer)
	testing.expect(t, ok_write)
	testing.expect(t, world_snapshot_read(&world_b, buffer))
	testing.expect_value(t, world_b.foundation.seed, world_a.foundation.seed)
	testing.expect_value(t, world_b.planetary.orbit, world_a.planetary.orbit)
	testing.expect_value(
		t,
		world_b.planetary.climate.surface_revision,
		world_a.planetary.climate.surface_revision,
	)
	_test_expect_slice_equal(t, world_b.heightfield.deltas, world_a.heightfield.deltas)
}

@(test)
world_snapshot_restores_non_default_terrain_seed :: proc(t: ^testing.T) {
	for seed in _TEST_TERRAIN_SEEDS {
		world_a, world_b: World
		testing.expect(t, world_init_seed(&world_a, seed))
		testing.expect(t, world_init(&world_b))
		buffer := make([]u8, world_snapshot_size(&world_a))
		_, written := world_snapshot_write(&world_a, buffer)
		testing.expect(t, written)
		testing.expect(t, world_snapshot_read(&world_b, buffer))
		_test_expect_planet_foundation_equal(t, &world_b.foundation, &world_a.foundation)
		_test_expect_slice_equal(t, world_b.waterfield.ground, world_a.waterfield.ground)
		delete(buffer)
		world_deinit(&world_b)
		world_deinit(&world_a)
	}
}

@(test)
world_snapshot_rejects_incompatible_terrain_version :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	buffer := make([]u8, world_snapshot_size(&world))
	defer delete(buffer)
	_, written := world_snapshot_write(&world, buffer)
	testing.expect(t, written)
	payload_size :=
		size_of(u32) + size_of(world.foundation.seed) + size_of(world.foundation.lithosphere)
	payload_size += PLANET_HEIGHTFIELD_SNAPSHOT_BYTES + PLANET_TECTONIC_FIELD_SNAPSHOT_BYTES
	payload_size += size_of(world.foundation.tectonic_revision)
	payload_size += PLANET_WATERFIELD_SNAPSHOT_BYTES + size_of(world.waterfield.revision)
	payload_size += planetary_snapshot_size(&world.planetary)
	payload_size += flora_ecology_snapshot_size(&world.flora_ecology)
	payload_size += BIOME_ENVIRONMENT_SNAPSHOT_BYTES
	payload_size += marine_ecology_snapshot_size(&world.marine_ecology)
	version_offset := len(buffer) - payload_size
	buffer[version_offset] = 0
	testing.expect(t, !world_snapshot_read(&world, buffer))
}

@(test)
terraform_digging_below_sea_level_blocks_placement :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	dig_x, dig_y, ok_anchor := _test_buildable_area(&world, 1)
	testing.expect(t, ok_anchor)
	testing.expect(t, placement_allowed(&world, dig_x, dig_y))
	lower := Command {
		kind             = .Terraform,
		player           = 0,
		grid_x           = dig_x,
		grid_y           = dig_y,
		direction        = -1,
		terraform_radius = i8(TERRAFORM_RADIUS),
	}
	// Dig until the delta clamps; the crater walls exceed the buildable
	// slope limit long before that, so the cell must refuse placement.
	max_applies := int(TERRAFORM_MAX_DELTA / TERRAFORM_PEAK)
	for _ in 0 ..< max_applies {
		testing.expect(t, apply_command(&world, lower))
	}
	testing.expect(t, !placement_allowed(&world, dig_x, dig_y))
	flooded := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = dig_x,
		grid_y   = dig_y,
	}
	testing.expect(t, !apply_command(&world, flooded))
}

@(test)
populate_nodes_is_deterministic :: proc(t: ^testing.T) {
	for seed in _TEST_TERRAIN_SEEDS {
		world_a: World
		world_b: World
		testing.expect(t, world_init_seed(&world_a, seed))
		testing.expect(t, world_init_seed(&world_b, seed))
		count_a, ok_a := world_populate_nodes(&world_a)
		count_b, ok_b := world_populate_nodes(&world_b)
		testing.expect(t, ok_a)
		testing.expect(t, ok_b)
		testing.expect_value(t, count_a, count_b)
		size_a := world_snapshot_size(&world_a)
		testing.expect_value(t, size_a, world_snapshot_size(&world_b))
		buffer_a := make([]u8, size_a)
		buffer_b := make([]u8, size_a)
		_, ok_write_a := world_snapshot_write(&world_a, buffer_a)
		_, ok_write_b := world_snapshot_write(&world_b, buffer_b)
		testing.expect(t, ok_write_a)
		testing.expect(t, ok_write_b)
		for byte_index in 0 ..< len(buffer_a) {
			if buffer_a[byte_index] != buffer_b[byte_index] {
				testing.expectf(t, false, "node snapshots differ at offset %d", byte_index)
				break
			}
		}
		delete(buffer_b)
		delete(buffer_a)
		world_deinit(&world_b)
		world_deinit(&world_a)
	}
}

@(test)
populate_nodes_all_valid :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	count, ok := world_populate_nodes(&world)
	testing.expect(t, ok)
	testing.expectf(t, count > 500 && count < 20000, "suspicious node count %d", count)
	testing.expect_value(t, u32(ecs.set_len(&world.nodes)), count)
	for index in 0 ..< ecs.set_len(&world.nodes) {
		entity := world.nodes.header.entities[index]
		node := world.nodes.items[index]
		testing.expect(t, node.richness_percent >= 100 && node.richness_percent <= 400)
		transform, has_transform := ecs.get(&world.transforms, entity)
		testing.expect(t, has_transform)
		coord := Planet_Coord{transform.face, transform.grid_x, transform.grid_y}
		testing.expect(t, planet_coord_valid(coord))
		testing.expectf(
			t,
			planet_placement_allowed(&world, coord),
			"node at (%d,%d) not buildable",
			transform.grid_x,
			transform.grid_y,
		)
	}
}

@(test)
populate_nodes_yields_both_kinds :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	_, ok := world_populate_nodes(&world)
	testing.expect(t, ok)
	ore_seen := false
	energy_seen := false
	for index in 0 ..< ecs.set_len(&world.nodes) {
		node := world.nodes.items[index]
		if node.kind == .Ore do ore_seen = true
		if node.kind == .Energy do energy_seen = true
	}
	testing.expect(t, ore_seen)
	testing.expect(t, energy_seen)
}

@(test)
clear_resource_nodes_preserves_players_and_linked_buildings :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	mine_x, mine_y, ok_anchor := _test_buildable_area(&world, 1)
	testing.expect(t, ok_anchor)
	covered_node, ok_covered := spawn_resource_node(
		&world,
		Planet_Coord{.Pos_X, mine_x, mine_y},
		.Ore,
		200,
	)
	testing.expect(t, ok_covered)
	bare_coord := planet_neighbour(Planet_Coord{.Pos_X, mine_x, mine_y}, 5, 5)
	bare_node, ok_bare := spawn_resource_node(&world, bare_coord, .Energy, 150)
	testing.expect(t, ok_bare)
	covered_id, has_covered_id := world_net_id_for_entity(&world, covered_node)
	bare_id, has_bare_id := world_net_id_for_entity(&world, bare_node)
	testing.expect(t, has_covered_id && has_bare_id)
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		grid_x   = mine_x,
		grid_y   = mine_y,
	}
	testing.expect(t, apply_command(&world, place))
	building := world.buildings.header.entities[0]
	link, has_link := ecs.get(&world.harvest_links, building)
	testing.expect(t, has_link)
	testing.expect_value(t, link.node, covered_id)
	testing.expect_value(t, world_clear_resource_nodes(&world), u32(2))
	testing.expect(t, !ecs.is_alive(&world.pool, covered_node))
	testing.expect(t, !ecs.is_alive(&world.pool, bare_node))
	_, covered_found := world_entity_by_net_id(&world, covered_id)
	_, bare_found := world_entity_by_net_id(&world, bare_id)
	testing.expect(t, !covered_found && !bare_found)
	testing.expect(t, ecs.is_alive(&world.pool, player))
	testing.expect(t, ecs.is_alive(&world.pool, building))
	testing.expect_value(t, ecs.set_len(&world.buildings), 1)
	testing.expect_value(t, ecs.set_len(&world.nodes), 0)
	testing.expect_value(t, world_clear_resource_nodes(&world), u32(0))
}

// A command carrying a brush size outside the selectable range must be
// refused and must not charge. This is the validation path a tampered
// client reaches, so rejecting rather than asserting is the requirement.
@(test)
terraform_rejects_a_brush_size_outside_the_selectable_range :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	before := stockpile.amounts[.Ore]
	for radius in ([?]i8{i8(TERRAFORM_RADIUS_MIN) - 1, i8(TERRAFORM_RADIUS_MAX) + 1, 127, -128}) {
		bad := Command {
			kind             = .Terraform,
			player           = 0,
			grid_x           = 1,
			grid_y           = 1,
			direction        = 1,
			terraform_radius = radius,
		}
		testing.expect(t, !apply_command(&world, bad))
	}
	testing.expect_value(t, stockpile.amounts[.Ore], before)
}

// Each brush size charges its own cost and moves exactly its own extent.
// The extent check is what catches a radius wired into the cost but not
// into the mound, which would be invisible until a player used it.
@(test)
terraform_brush_sizes_charge_and_move_their_own_extent :: proc(t: ^testing.T) {
	for radius in TERRAFORM_RADIUS_MIN ..= TERRAFORM_RADIUS_MAX {
		world: World
		testing.expect(t, world_init(&world))
		defer world_deinit(&world)
		player_entity, ok_player := spawn_player(&world, 0)
		testing.expect(t, ok_player)
		stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
		testing.expect(t, ok_stock)
		before := stockpile.amounts[.Ore]
		raise := Command {
			kind             = .Terraform,
			player           = 0,
			grid_x           = 100,
			grid_y           = 100,
			direction        = 1,
			terraform_radius = i8(radius),
		}
		testing.expect(t, apply_command(&world, raise))
		testing.expect_value(t, stockpile.amounts[.Ore], before - terraform_cost_ore(radius))
		center := Planet_Coord{.Pos_X, 100, 100}
		edge_coord := planet_neighbour(center, radius, 0)
		beyond_coord := planet_neighbour(center, radius + 1, 0)
		testing.expectf(
			t,
			world.heightfield.deltas[planet_index(edge_coord)] > 0,
			"radius %d left its own outer ring untouched",
			radius,
		)
		testing.expectf(
			t,
			world.heightfield.deltas[planet_index(beyond_coord)] == 0,
			"radius %d moved ground beyond its own extent",
			radius,
		)
	}
}

// A larger brush must be refused by a building it reaches that a smaller
// brush clears. This is the rule that stops a 9x9 raise from lifting the
// ground out from under a base the player cannot see it touching.
@(test)
terraform_brush_size_widens_the_occupancy_refusal :: proc(t: ^testing.T) {
	world: World
	testing.expect(t, world_init(&world))
	defer world_deinit(&world)
	player_entity, ok_player := spawn_player(&world, 0)
	testing.expect(t, ok_player)
	anchor := Planet_Coord{.Pos_X, 104, 100}
	for radius in 0 ..= 96 {
		candidate := planet_neighbour(anchor, i32(radius), 0)
		if !placement_allowed(&world, candidate.u, candidate.v, candidate.face) do continue
		anchor = planet_neighbour(candidate, -4, 0)
		break
	}
	place := Command {
		kind     = .Place_Building,
		player   = 0,
		building = .Mine,
		face     = anchor.face,
		grid_x   = anchor.u + 4,
		grid_y   = anchor.v,
	}
	testing.expect(t, apply_command(&world, place))
	stockpile, ok_stock := ecs.get(&world.stockpiles, player_entity)
	testing.expect(t, ok_stock)
	// A 1x1 brush four cells away clears the mine; a 9x9 one reaches it.
	near := Command {
		kind             = .Terraform,
		player           = 0,
		face             = anchor.face,
		grid_x           = anchor.u,
		grid_y           = anchor.v,
		direction        = 1,
		terraform_radius = i8(TERRAFORM_RADIUS_MIN),
	}
	testing.expect(t, apply_command(&world, near))
	wide := near
	wide.terraform_radius = i8(TERRAFORM_RADIUS_MAX)
	ore_before := stockpile.amounts[.Ore]
	testing.expect(t, !apply_command(&world, wide))
	testing.expect_value(t, stockpile.amounts[.Ore], ore_before)
}

@(test)
world_test_foundation_cache_keeps_worlds_isolated :: proc(t: ^testing.T) {
	world_a, world_b: World
	testing.expect(t, world_init(&world_a))
	defer world_deinit(&world_a)
	index := planet_index({.Pos_X, PLANET_FACE_CELLS / 2, PLANET_FACE_CELLS / 2})
	expected := world_a.foundation.base_height[index]
	world_a.foundation.base_height[index] += 1
	testing.expect(t, world_init(&world_b))
	defer world_deinit(&world_b)
	testing.expect_value(t, world_b.foundation.base_height[index], expected)
}
