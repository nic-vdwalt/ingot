package main

import "core:testing"
import fit "ingot:fit"
import rl "ingot:gfx"

@(test)
debug_filter_matches_smart_grep_tokens :: proc(t: ^testing.T) {
	testing.expect(t, debug_filter_matches("", "anything"))
	testing.expect(t, debug_filter_matches("FoG", "fog density", "0.125"))
	testing.expect(t, !debug_filter_matches("atmosphere", "density", "0.125"))
	testing.expect(t, debug_filter_matches("ocean foam", "crest foam", "ocean enabled"))
	testing.expect(t, debug_filter_matches("radius ring", "ring 2 radius", "128"))
	testing.expect(t, !debug_filter_matches("camera foam", "rotate speed", "1.0"))
}

@(test)
debug_row_filter_excludes_section_titles :: proc(t: ^testing.T) {
	testing.expect(t, !debug_row_matches("atmosphere", "density", "0.125"))
	testing.expect(t, debug_row_matches("density", "density", "0.125"))
	testing.expect(t, debug_row_matches("0.125", "density", "0.125"))
}

@(test)
debug_filter_editing_is_bounded_and_cursor_aware :: proc(t: ^testing.T) {
	filter: Debug_Filter
	testing.expect(t, debug_filter_insert(&filter, "fog"))
	filter.cursor = 1
	testing.expect(t, debug_filter_insert(&filter, "i"))
	testing.expect_value(t, debug_filter_text(&filter), "fiog")
	testing.expect(t, debug_filter_backspace(&filter))
	testing.expect_value(t, debug_filter_text(&filter), "fog")
	testing.expect(t, debug_filter_delete(&filter))
	testing.expect_value(t, debug_filter_text(&filter), "fg")
	debug_filter_clear(&filter)
	testing.expect_value(t, debug_filter_text(&filter), "")
	full: Debug_Filter
	for _ in 0 ..< DEBUG_FILTER_MAX do testing.expect(t, debug_filter_insert_rune(&full, 'x'))
	testing.expect(t, !debug_filter_insert_rune(&full, 'y'))
	testing.expect_value(t, full.length, DEBUG_FILTER_MAX)
}

@(test)
debug_tuning_default_is_identity :: proc(t: ^testing.T) {
	tuning := debug_tuning_default()
	testing.expect_value(t, tuning.flora_density_scale, f32(1))
	// The package global must start at the same identity, or a build that
	// never opens the panel would scatter differently than before.
	testing.expect_value(t, debug_tuning.flora_density_scale, f32(1))
}

@(test)
debug_flora_config_identity_at_default_scale :: proc(t: ^testing.T) {
	saved := debug_tuning
	defer debug_tuning = saved
	debug_tuning.flora_density_scale = 1
	config := flora_default_config()
	testing.expect_value(t, config.tree_chance_scale, f32(1.1))
	testing.expect_value(t, config.tree_chance_max, f32(0.42))
	testing.expect_value(t, config.grass_chance, f32(0.42))
	testing.expect_value(t, config.boulder_chance, f32(0.05))
	testing.expect_value(t, config.scree_chance, f32(0.07))
}

@(test)
debug_flora_config_scales_and_clamps :: proc(t: ^testing.T) {
	saved := debug_tuning
	defer debug_tuning = saved
	debug_tuning.flora_density_scale = 2
	doubled := flora_default_config()
	testing.expect_value(t, doubled.grass_chance, f32(0.84))
	testing.expect_value(t, doubled.boulder_chance, f32(0.05))
	// A huge multiplier saturates at probability 1 instead of overflowing
	// the per-tile instance pools.
	debug_tuning.flora_density_scale = 100
	saturated := flora_default_config()
	testing.expect_value(t, saturated.grass_chance, f32(1))
	testing.expect_value(t, saturated.tree_chance_max, f32(0.42))
	// Zero clears every chance rather than going negative.
	debug_tuning.flora_density_scale = 0
	empty := flora_default_config()
	testing.expect_value(t, empty.grass_chance, f32(0))
	testing.expect_value(t, empty.scree_chance, f32(0))
}

@(test)
debug_target_resolve_priority :: proc(t: ^testing.T) {
	// Entity beats flora beats a surface; nothing hit falls back to world.
	testing.expect_value(t, debug_target_resolve(true, true, true), Debug_Target_Kind.Entity)
	testing.expect_value(t, debug_target_resolve(false, true, true), Debug_Target_Kind.Flora_Item)
	testing.expect_value(t, debug_target_resolve(false, false, true), Debug_Target_Kind.Surface)
	testing.expect_value(t, debug_target_resolve(false, false, false), Debug_Target_Kind.World)
}

@(test)
debug_flora_outline_uses_visible_lod_and_falls_back_to_finest :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	flora.count = 2
	flora.instances[0].mesh = .Conifer_A
	flora.instances[1].mesh = .Baobab
	flora.mesh_lods[.Conifer_A] = 3
	flora.mesh_lods[.Baobab] = 2
	flora.candidate_count = 1
	flora.candidates[0] = 0
	flora.candidate_lods[0] = 2
	testing.expect_value(t, flora_debug_outline_lod(flora, 0), 2)
	testing.expect_value(t, flora_debug_outline_lod(flora, 1), 0)
	flora.candidate_lods[0] = 7
	testing.expect_value(t, flora_debug_outline_lod(flora, 0), 2)
}

@(test)
debug_ray_hit_distance_is_bounded_for_misses_and_measures_hits :: proc(t: ^testing.T) {
	ray := rl.Ray_3D{{1, 2, 3}, {1, 0, 0}}
	testing.expect_value(t, debug_ray_hit_distance(ray, {}, false), TERRAIN_RAY_MAX_DISTANCE)
	testing.expect_value(t, debug_ray_hit_distance(ray, {4, 2, 3}, true), f32(3))
}

@(test)
debug_pin_hit_test_scales_and_rejects_distant_points :: proc(t: ^testing.T) {
	pin := rl.Vector2{100, 80}
	testing.expect(t, debug_pin_hit_test({113, 80}, pin, 1))
	testing.expect(t, !debug_pin_hit_test({115, 80}, pin, 1))
	testing.expect(t, debug_pin_hit_test({127, 80}, pin, 2))
}

@(test)
debug_pin_world_size_is_distance_bounded :: proc(t: ^testing.T) {
	testing.expect_value(t, debug_pin_world_size(0), DEBUG_PIN_WORLD_MIN)
	testing.expect_value(t, debug_pin_world_size(100), f32(1.8))
	testing.expect_value(t, debug_pin_world_size(10_000), DEBUG_PIN_WORLD_MAX)
}

@(test)
debug_pin_geometry_places_hit_target_at_visible_head :: proc(t: ^testing.T) {
	geometry := debug_terrain_pin_geometry({10, 0, 0}, {1, 0, 0}, {110, 0, 0})
	testing.expect_value(t, geometry.size, f32(1.8))
	testing.expect(t, abs(geometry.stem_center.x - 11.17) < 0.00001)
	testing.expect(t, abs(geometry.head_center.x - 12.61) < 0.00001)
	testing.expect_value(t, geometry.stem_center.yz, [2]f32{0, 0})
	testing.expect_value(t, geometry.head_center.yz, [2]f32{0, 0})
}

@(test)
debug_terrain_axes_are_orthonormal_right_handed_and_outward :: proc(t: ^testing.T) {
	geometry := debug_terrain_axes_geometry({10, 0, 0}, {1, 0, 0}, {110, 0, 0})
	dot_xy := geometry.x_axis.x * geometry.y_axis.x +
		geometry.x_axis.y * geometry.y_axis.y + geometry.x_axis.z * geometry.y_axis.z
	dot_xz := geometry.x_axis.x * geometry.z_axis.x +
		geometry.x_axis.y * geometry.z_axis.y + geometry.x_axis.z * geometry.z_axis.z
	dot_yz := geometry.y_axis.x * geometry.z_axis.x +
		geometry.y_axis.y * geometry.z_axis.y + geometry.y_axis.z * geometry.z_axis.z
	x_length := geometry.x_axis.x * geometry.x_axis.x +
		geometry.x_axis.y * geometry.x_axis.y + geometry.x_axis.z * geometry.x_axis.z
	y_length := geometry.y_axis.x * geometry.y_axis.x +
		geometry.y_axis.y * geometry.y_axis.y + geometry.y_axis.z * geometry.y_axis.z
	z_length := geometry.z_axis.x * geometry.z_axis.x +
		geometry.z_axis.y * geometry.z_axis.y + geometry.z_axis.z * geometry.z_axis.z
	cross_xy := [3]f32 {
		geometry.x_axis.y * geometry.y_axis.z - geometry.x_axis.z * geometry.y_axis.y,
		geometry.x_axis.z * geometry.y_axis.x - geometry.x_axis.x * geometry.y_axis.z,
		geometry.x_axis.x * geometry.y_axis.y - geometry.x_axis.y * geometry.y_axis.x,
	}
	testing.expect(t, abs(dot_xy) < 0.00001)
	testing.expect(t, abs(dot_xz) < 0.00001)
	testing.expect(t, abs(dot_yz) < 0.00001)
	testing.expect(t, abs(x_length - 1) < 0.00001)
	testing.expect(t, abs(y_length - 1) < 0.00001)
	testing.expect(t, abs(z_length - 1) < 0.00001)
	testing.expect(t, cross_xy.x * geometry.z_axis.x + cross_xy.y * geometry.z_axis.y +
		cross_xy.z * geometry.z_axis.z > 0.9999)
	testing.expect(t, geometry.origin.x > 10)
	testing.expect_value(t, geometry.origin.yz, [2]f32{0, 0})
	testing.expect(t, geometry.axis_length > 0)
	testing.expect(t, geometry.shaft_thickness > 0)
	testing.expect(t, geometry.cap_size > geometry.shaft_thickness)
}

@(test)
debug_terrain_axes_are_pole_safe_and_distance_bounded :: proc(t: ^testing.T) {
	near := debug_terrain_axes_geometry({0, 10, 0}, {0, 1, 0}, {0, 10, 0})
	middle := debug_terrain_axes_geometry({0, 10, 0}, {0, 1, 0}, {0, 110, 0})
	far := debug_terrain_axes_geometry({0, 10, 0}, {0, 1, 0}, {0, 10_010, 0})
	testing.expect_value(t, near.axis_length, DEBUG_PIN_WORLD_MIN * 2.4)
	testing.expect_value(t, far.axis_length, DEBUG_PIN_WORLD_MAX * 2.4)
	testing.expect(t, middle.axis_length > near.axis_length)
	testing.expect(t, middle.axis_length < far.axis_length)
	for component in near.origin {
		testing.expect(t, component == component)
	}
	axes := [3][3]f32{near.x_axis, near.y_axis, near.z_axis}
	for axis in axes {
		for component in axis {
			testing.expect(t, component == component)
		}
	}
	testing.expect(t, near.origin.y > 10)
	testing.expect(t, abs(near.x_axis.y) < 0.00001)
	testing.expect(t, abs(near.y_axis.y) < 0.00001)
	testing.expect(t, near.z_axis.y > 0.9999)
}

@(test)
debug_console_commands_parse :: proc(t: ^testing.T) {
	open := console_command_parse("debug")
	testing.expect_value(t, open.kind, Console_Command.Debug_On)
	on := console_command_parse("debug on")
	testing.expect_value(t, on.kind, Console_Command.Debug_On)
	off := console_command_parse("debug off")
	testing.expect_value(t, off.kind, Console_Command.Debug_Off)
	invalid := console_command_parse("debug sideways")
	testing.expect_value(t, invalid.kind, Console_Command.Invalid)
}

@(test)
debug_parse_f32_falls_back_on_garbage :: proc(t: ^testing.T) {
	testing.expect_value(t, debug_parse_f32("1.5", 1), f32(1.5))
	testing.expect_value(t, debug_parse_f32("", 1), f32(1))
	testing.expect_value(t, debug_parse_f32("not a number", 2), f32(2))
	// Non-finite input must fall back: a NaN multiplier fails every clamp.
	testing.expect_value(t, debug_parse_f32("1e40", 3), f32(3))
}

@(test)
debug_extension_section_keys_are_bounded :: proc(t: ^testing.T) {
	testing.expect(t, debug_extension_section_key_valid(.Section_0))
	testing.expect(t, debug_extension_section_key_valid(.Section_15))
}

@(test)
debug_extension_widget_ids_are_stable :: proc(t: ^testing.T) {
	testing.expect_value(t, debug_extension_widget_id(7), debug_extension_widget_id(7))
	testing.expect(t, debug_extension_widget_id(7) != debug_extension_widget_id(8))
}

@(test)
debug_tabs_have_stable_category_identity :: proc(t: ^testing.T) {
	world := debug_tab_category(.World)
	weather := debug_tab_category(.Weather)
	testing.expect_value(t, world, debug_tab_default())
	testing.expect(t, world != weather)
	testing.expect(t, debug_tab_widget_id(weather, 7) != debug_tab_widget_id(world, 7))
}

@(test)
debug_categories_have_required_order :: proc(t: ^testing.T) {
	testing.expect_value(t, DEBUG_CATEGORY_COUNT, 7)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[0], Debug_Category.World)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[1], Debug_Category.Water)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[2], Debug_Category.Terrain)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[3], Debug_Category.Weather)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[4], Debug_Category.Entities)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[5], Debug_Category.Hud)
	testing.expect_value(t, DEBUG_CATEGORY_ORDER[6], Debug_Category.Camera)
}

@(test)
debug_detail_mode_hides_only_advanced_rows :: proc(t: ^testing.T) {
	testing.expect(t, debug_detail_visible(.Simple, .Simple))
	testing.expect(t, !debug_detail_visible(.Simple, .Advanced))
	testing.expect(t, debug_detail_visible(.Advanced, .Simple))
	testing.expect(t, debug_detail_visible(.Advanced, .Advanced))
}

@(test)
debug_tab_registry_preserves_selection_and_falls_back :: proc(t: ^testing.T) {
	registry: Debug_Tab_Registry
	world := debug_tab_default()
	weather := debug_tab_category(.Weather)
	debug_tab_registry_add(&registry, world, "WORLD")
	debug_tab_registry_add(&registry, weather, "WEATHER")
	debug_tab_registry_add(&registry, weather, "WEATHER")
	testing.expect_value(t, registry.count, 2)
	testing.expect_value(t, debug_tab_select_valid(&registry, weather), weather)
	testing.expect_value(t, debug_tab_select_valid(&registry, debug_tab_category(.Camera)), world)
}

@(test)
debug_tab_filtering_shows_all_bodies_without_changing_selection :: proc(t: ^testing.T) {
	world := debug_tab_default()
	weather := debug_tab_category(.Weather)
	testing.expect(t, debug_tab_body_visible(false, world, world))
	testing.expect(t, !debug_tab_body_visible(false, world, weather))
	testing.expect(t, debug_tab_body_visible(true, world, weather))
}

@(test)
debug_filter_pills_wrap_without_overflow :: proc(t: ^testing.T) {
	widths := []i32{80, 90, 70, 120}
	testing.expect_value(t, debug_pill_row_count(widths, 180, 4), 3)
	testing.expect_value(t, debug_pill_row_count(widths, 400, 4), 1)
	testing.expect_value(t, debug_pill_row_count([]i32{}, 180, 4), 0)
}

@(test)
debug_filter_pills_clamp_oversized_items :: proc(t: ^testing.T) {
	widths := []i32{400, 40}
	testing.expect_value(t, debug_pill_row_count(widths, 180, 4), 2)
}

@(test)
debug_category_pills_fit_in_two_rows_at_minimum_width :: proc(t: ^testing.T) {
	widths := [DEBUG_CATEGORY_COUNT]i32{}
	for &width in widths do width = DEBUG_TAB_MIN_WIDTH
	available := DEBUG_PANEL_MIN_WIDTH - DEBUG_PANEL_PADDING * 2
	testing.expect_value(t, debug_pill_row_count(widths[:], available, DEBUG_ROW_GAP), 2)
}

@(test)
debug_panel_fixed_inset_reserves_filter_and_pills :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		debug_panel_fixed_inset(1, 2),
		DEBUG_PANEL_TITLE_HEIGHT + DEBUG_ROW_HEIGHT + DEBUG_TAB_HEIGHT * 2 + DEBUG_ROW_GAP * 3,
	)
}

@(test)
debug_panel_tab_focus_respects_input_owners :: proc(t: ^testing.T) {
	testing.expect(t, debug_panel_tab_focus_allowed(true, true, false, false))
	testing.expect(t, !debug_panel_tab_focus_allowed(false, true, false, false))
	testing.expect(t, !debug_panel_tab_focus_allowed(true, false, false, false))
	testing.expect(t, !debug_panel_tab_focus_allowed(true, true, true, false))
	testing.expect(t, !debug_panel_tab_focus_allowed(true, true, false, true))
}

@(test)
debug_panel_geometry_defaults_to_the_right_margin :: proc(t: ^testing.T) {
	rect := debug_panel_geometry_default(1280, 720, 1)
	testing.expect_value(t, rect, fit.Rect{886, 14, 380, 692})
}

@(test)
debug_panel_visible_rect_tracks_open_reveal :: proc(t: ^testing.T) {
	rect := fit.Rect{100, 20, 380, 500}
	testing.expect_value(t, debug_panel_visible_rect(rect, 0), fit.Rect{480, 20, 0, 500})
	testing.expect_value(t, debug_panel_visible_rect(rect, 0.5), fit.Rect{290, 20, 190, 500})
	testing.expect_value(t, debug_panel_visible_rect(rect, 1), rect)
}

@(test)
debug_panel_move_suspends_expensive_content_rendering :: proc(t: ^testing.T) {
	testing.expect(t, !debug_panel_content_visible(.Move))
	testing.expect(t, debug_panel_content_visible(.None))
	testing.expect(t, debug_panel_content_visible(.Resize))
}

@(test)
debug_readout_columns_do_not_overlap_at_minimum_width :: proc(t: ^testing.T) {
	rect := fit.Rect{0, 0, DEBUG_PANEL_MIN_WIDTH, DEBUG_ROW_HEIGHT}
	label, value := debug_readout_columns(rect, 1)
	testing.expect(t, label.w > 0)
	testing.expect(t, value.w > 0)
	testing.expect(t, label.x + label.w <= value.x)
	testing.expect(t, value.x + value.w <= rect.x + rect.w)
}

@(test)
debug_panel_geometry_move_stays_inside_the_window :: proc(t: ^testing.T) {
	rect := fit.Rect{886, 14, 380, 692}
	left_top := debug_panel_geometry_move(rect, -2000, -2000, 1280, 720, 1)
	testing.expect_value(t, left_top.x, 14)
	testing.expect_value(t, left_top.y, 14)
	right_bottom := debug_panel_geometry_move(rect, 2000, 2000, 1280, 720, 1)
	testing.expect_value(t, right_bottom.x, 886)
	testing.expect_value(t, right_bottom.y, 14)
}

@(test)
debug_panel_geometry_resize_obeys_minimum_and_window_bounds :: proc(t: ^testing.T) {
	rect := fit.Rect{300, 100, 380, 500}
	minimum := debug_panel_geometry_resize(rect, -1000, -1000, 1280, 720, 1)
	testing.expect_value(t, minimum, fit.Rect{300, 100, 280, 240})
	maximum := debug_panel_geometry_resize(rect, 2000, 2000, 1280, 720, 1)
	testing.expect_value(t, maximum, fit.Rect{14, 14, 1252, 692})
}

@(test)
debug_panel_geometry_reclamps_after_window_resize :: proc(t: ^testing.T) {
	rect := fit.Rect{886, 14, 380, 692}
	first := debug_panel_geometry_clamp(rect, 800, 500, 1)
	second := debug_panel_geometry_clamp(first, 800, 500, 1)
	testing.expect_value(t, first, fit.Rect{406, 14, 380, 472})
	testing.expect_value(t, second, first)
}

@(test)
debug_animation_is_bounded_and_deterministic :: proc(t: ^testing.T) {
	start := debug_animation_sample(0, 0, 0)
	middle := debug_animation_sample(DEBUG_OPEN_DURATION / 2, DEBUG_SCOPE_FLASH_DURATION / 2, 0)
	settled := debug_animation_sample(DEBUG_OPEN_DURATION + DEBUG_SCAN_DURATION + 1, 10, 0)
	testing.expect_value(t, start.open_progress, f32(0))
	testing.expect(t, middle.open_progress > start.open_progress)
	testing.expect_value(t, settled.open_progress, f32(1))
	testing.expect(t, !settled.scan_visible)
	testing.expect_value(t, settled.scope_flash, f32(0))
	for index in 0 ..= 32 {
		sample := debug_animation_sample(f32(index) * 0.1, f32(index) * 0.1, f32(index) * 0.1)
		testing.expect(t, sample.open_progress >= 0 && sample.open_progress <= 1)
		testing.expect(t, sample.scan_progress >= 0 && sample.scan_progress <= 1)
		testing.expect(t, sample.chrome_pulse >= 0 && sample.chrome_pulse <= 1)
		testing.expect(t, sample.scope_flash >= 0 && sample.scope_flash <= 1)
	}
}

@(test)
debug_pin_placement_requires_arming_and_terrain :: proc(t: ^testing.T) {
	testing.expect(t, debug_pin_placement_ready(true, true))
	testing.expect(t, !debug_pin_placement_ready(false, true))
	testing.expect(t, !debug_pin_placement_ready(true, false))
}

@(test)
debug_scope_rejects_terrain_without_blocking_other_targets :: proc(t: ^testing.T) {
	testing.expect(t, debug_scope_target_selectable(.World))
	testing.expect(t, debug_scope_target_selectable(.Entity))
	testing.expect(t, debug_scope_target_selectable(.Flora_Item))
	testing.expect(t, !debug_scope_target_selectable(.Surface))
}

@(test)
debug_pinned_panel_open_preserves_primary_panel_state :: proc(t: ^testing.T) {
	value := new(Client_State)
	defer free(value)
	value.debug = {
		open         = true,
		target       = debug_target_world(),
		selected_tab = debug_tab_category(.Water),
		detail_mode  = .Advanced,
		scroll       = 48,
	}
	primary := value.debug
	terrain := Debug_Terrain_Ref{face = 2, grid_x = 30, grid_y = 40, valid = true}
	debug_pinned_panel_open(value, debug_target_surface(.Terrain, terrain))
	testing.expect_value(t, value.debug.target, primary.target)
	testing.expect_value(t, value.debug.selected_tab, primary.selected_tab)
	testing.expect_value(t, value.debug.scroll, primary.scroll)
	testing.expect(t, value.debug_pinned.open)
	testing.expect_value(t, value.debug_pinned.target.surface.terrain.face, terrain.face)
	testing.expect_value(t, value.debug_pinned.selected_tab, debug_tab_category(.Water))
	testing.expect_value(t, value.debug_pinned.detail_mode, Debug_Detail_Mode.Advanced)
}

@(test)
debug_target_identity_preserves_same_surface_cell :: proc(t: ^testing.T) {
	current := Debug_Terrain_Ref{face = 2, grid_x = 30, grid_y = 40, valid = true}
	panel := Debug_Panel{target = debug_target_surface(.Terrain, current)}
	same := Debug_Terrain_Ref{face = 2, grid_x = 30, grid_y = 40, valid = true}
	other := Debug_Terrain_Ref{face = 2, grid_x = 31, grid_y = 40, valid = true}
	testing.expect(t, !debug_scope_target_changed(&panel, debug_target_surface(.Terrain, same)))
	testing.expect(t, debug_scope_target_changed(&panel, debug_target_surface(.Terrain, other)))
	testing.expect(t, debug_scope_target_changed(&panel, debug_target_surface(.Seafloor, same)))
}

@(test)
debug_animation_caret_blinks_by_half_period :: proc(t: ^testing.T) {
	testing.expect(t, debug_animation_sample(1, 1, 0).caret_visible)
	testing.expect(t, !debug_animation_sample(1, 1, DEBUG_CARET_HALF_PERIOD).caret_visible)
	testing.expect(t, debug_animation_sample(1, 1, DEBUG_CARET_HALF_PERIOD * 2).caret_visible)
}
