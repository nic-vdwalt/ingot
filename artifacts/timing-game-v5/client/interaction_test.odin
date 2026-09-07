#+build !js
package main

import "core:testing"
import ecs "ingot:ecs"

@(test)
entity_hits_are_clipped_to_the_visible_surface :: proc(t: ^testing.T) {
	testing.expect(t, entity_hit_visible(9, 10, true), "entity in front of terrain")
	testing.expect(t, entity_hit_visible(10.5, 10, true), "bounds tolerance at terrain")
	testing.expect(t, !entity_hit_visible(12, 10, true), "entity behind terrain")
	testing.expect(t, entity_hit_visible(12, 0, false), "entity without terrain")
	testing.expect(t, !entity_hit_visible(-1, 10, true), "negative entity distance")
}

@(test)
entity_query_bounds_hash_changes_with_bounds :: proc(t: ^testing.T) {
	first := Bounds_3D{min = {-1, -2, -3}, max = {1, 2, 3}}
	second := Bounds_3D{min = {-1, -2, -3}, max = {1, 2, 4}}
	testing.expect_value(t, entity_query_bounds_hash(first), entity_query_bounds_hash(first))
	testing.expect(t, entity_query_bounds_hash(first) != entity_query_bounds_hash(second))
}

@(test)
entity_query_bounds_reject_degenerate_boxes :: proc(t: ^testing.T) {
	testing.expect(t, entity_query_bounds_valid({min = {-1, -2, -3}, max = {1, 2, 3}}))
	testing.expect(t, !entity_query_bounds_valid({min = {0, 0, 0}, max = {0, 1, 1}}))
}

@(test)
spherical_tooltip_anchors_move_outward_on_every_face :: proc(t: ^testing.T) {
	bounds := Bounds_3D {
		min = {-2, -3, -4},
		max = {2, 3, 4},
	}
	ups := [][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for up in ups {
		anchor := entity_tooltip_anchor_from_up(bounds, up)
		testing.expect(t, anchor.x * up.x + anchor.y * up.y + anchor.z * up.z > 0)
	}
}

@(test)
gameplay_selection_and_debug_scope_remain_independent :: proc(t: ^testing.T) {
	selected := ecs.Entity {
		index      = 7,
		generation = 2,
	}
	hovered := ecs.Entity {
		index      = 8,
		generation = 3,
	}
	testing.expect_value(t, gameplay_selection_entity(selected, hovered, true, false), hovered)
	testing.expect_value(t, gameplay_selection_entity(selected, hovered, true, true), hovered)
	testing.expect_value(t, gameplay_selection_entity(selected, hovered, false, true), selected)
	testing.expect_value(
		t,
		gameplay_selection_entity(ecs.ENTITY_NIL, hovered, false, true),
		ecs.ENTITY_NIL,
	)
	testing.expect_value(
		t,
		gameplay_selection_entity(selected, hovered, false, false),
		ecs.ENTITY_NIL,
	)
}

@(test)
debug_target_keeps_resource_nodes_inspectable :: proc(t: ^testing.T) {
	testing.expect_value(t, debug_target_resolve(true, false, true), Debug_Target_Kind.Entity)
	testing.expect_value(t, debug_target_resolve(false, true, true), Debug_Target_Kind.Flora_Item)
	testing.expect_value(t, debug_target_resolve(false, false, true), Debug_Target_Kind.Surface)
	testing.expect_value(t, debug_target_resolve(false, false, false), Debug_Target_Kind.World)
}

@(test)
terrain_click_requires_an_uncaptured_short_release :: proc(t: ^testing.T) {
	threshold := terrain_click_drag_threshold(2)
	testing.expect_value(t, threshold, CLICK_SELECT_MAX_DRAG * 2)
	testing.expect_value(t, pointer_displacement({0, 0}, {3, 4}), f32(5))
	testing.expect(t, terrain_click_completed(false, 0, threshold))
	testing.expect(t, terrain_click_completed(false, threshold - 0.01, threshold))
	testing.expect(t, !terrain_click_completed(false, threshold, threshold))
	testing.expect(t, !terrain_click_completed(true, 0, threshold))
	testing.expect(t, !terrain_click_completed(false, -1, threshold))
}

@(test)
debug_pin_placement_is_opt_in_and_preserves_primary_state :: proc(t: ^testing.T) {
	primary := Debug_Panel {
		open         = true,
		target       = debug_target_world(),
		selected_tab = debug_tab_default(),
		scroll       = 48,
	}
	before := primary
	testing.expect(t, !debug_pin_placement_ready(primary.pin_armed, true))
	primary.pin_armed = true
	testing.expect(t, debug_pin_placement_ready(primary.pin_armed, true))
	primary.pin_armed = false
	testing.expect_value(t, primary.target, before.target)
	testing.expect_value(t, primary.selected_tab, before.selected_tab)
	testing.expect_value(t, primary.scroll, before.scroll)
}
