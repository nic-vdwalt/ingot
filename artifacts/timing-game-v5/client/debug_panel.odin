// debug_panel.odin renders the developer debug panel: a right-docked,
// scrollable column of live-editable config. The world scope shows preset
// sections (world, atmosphere/fog, terrain, flora, water, camera, HUD); in
// debug mode a world click scopes the panel to the picked object — building,
// resource node, flora instance, or terrain chunk — whose live data becomes
// editable in place. Edits write directly into client/sim state and trigger
// the minimal invalidation through debug_apply.
//
// Toggled with F10 or the console's `debug on|off`. The panel joins the
// pointer-capture union like the toolbar and inspect panel, so slider drags
// never sculpt, select, or pan the world underneath.
//
// Layout constants are authored at UI scale 1.0 and converted with ui_px.
package main

import shared "../shared"
import "core:fmt"
import "core:math"
import "core:math/rand"
import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"

DEBUG_PANEL_WIDTH :: i32(380)
DEBUG_PANEL_MARGIN :: i32(14)
DEBUG_PANEL_PADDING :: i32(10)
DEBUG_PANEL_TITLE_HEIGHT :: i32(30)
DEBUG_PANEL_MIN_WIDTH :: i32(280)
DEBUG_PANEL_MIN_HEIGHT :: i32(240)
DEBUG_PANEL_RESIZE_HANDLE :: i32(18)
DEBUG_PANEL_VISIBLE_EDGE :: i32(48)
DEBUG_ROW_HEIGHT :: i32(24)
DEBUG_ROW_GAP :: i32(4)
DEBUG_SECTION_GAP :: i32(10)
DEBUG_HEADER_HEIGHT :: i32(26)
DEBUG_TAB_HEIGHT :: i32(28)
DEBUG_TAB_MIN_WIDTH :: i32(58)
DEBUG_TAB_HORIZONTAL_PADDING :: i32(12)
DEBUG_BUTTON_HEIGHT :: i32(26)
// Right-side widget column inside a row; the label owns the rest.
DEBUG_CONTROL_WIDTH :: i32(170)
// Numeric readout between label and slider.
DEBUG_VALUE_WIDTH :: i32(58)
// Wheel scroll distance per notch.
DEBUG_SCROLL_STEP :: i32(48)
DEBUG_RENDER_STATS_ENABLED :: #config(INGOT_RENDER_STATS, false)

// Base of the panel's numeric widget-id range. Toolbar uses 1..399 and the
// named panels use string ids, so a high offset can never collide.
DEBUG_WIDGET_BASE :: u64(0xDEB0_0000)

debug_pinned_context: bool

Debug_Panel_Section :: Debug_Category
DEBUG_SECTION_TITLES :: [Debug_Panel_Section]string {
	.World    = "WORLD",
	.Water    = "WATER / OCEAN",
	.Terrain  = "TERRAIN",
	.Weather  = "WEATHER & ATMOSPHERE",
	.Entities = "FLORA / FAUNA / STATIC ENTITIES",
	.Hud      = "HUD / PERF",
	.Camera   = "CAMERA",
}

Debug_Panel_Interaction :: enum u8 {
	None,
	Move,
	Resize,
}

Debug_Panel :: struct {
	open:                 bool,
	target:               Debug_Target,
	scroll:               i32,
	selected_tab:         Debug_Tab_Id,
	detail_mode:          Debug_Detail_Mode,
	pill_rows:            int,
	preset_dropdown:      fit.Dropdown_State,
	// Measured content height from the last drawn frame; clamps scroll.
	content_height:       i32,
	filter:               Debug_Filter,
	filter_focused:       bool,
	keyboard_captured:    bool,
	rect:                 fit.Rect,
	geometry_initialized: bool,
	interaction:          Debug_Panel_Interaction,
	interaction_anchor:   rl.Vector2,
	interaction_rect:     fit.Rect,
	pin_armed:            bool,
	marker_mesh:          rl.Gpu_Mesh,
	was_open:             bool,
	animation_elapsed:    f32,
	scope_flash_elapsed:  f32,
	caret_elapsed:        f32,
}

// _Debug_Layout carries the per-frame row cursor. y is virtual (0 at the top
// of the content, unaffected by scroll); rows convert through _debug_row_rect
// and skip drawing when scrolled out of the panel.
@(private = "file")
_Debug_Layout_Phase :: enum u8 {
	Discover,
	Render,
}

@(private = "file")
_Debug_Layout :: struct {
	value:       ^Client_State,
	surface:     ^fit.Surface,
	panel:       fit.Rect,
	x:           i32,
	width:       i32,
	y:           i32,
	widget:      u64,
	phase:       _Debug_Layout_Phase,
	registry:     ^Debug_Tab_Registry,
	current_tab:  Debug_Tab_Id,
	current_tier: Debug_Detail_Tier,
}

Debug_Panel_Extension_Context :: struct {
	layout: rawptr,
}

debug_panel_geometry_default :: proc(screen_width, screen_height: i32, scale: f32) -> fit.Rect {
	margin := ui_px(scale, DEBUG_PANEL_MARGIN)
	available_width := max(screen_width - margin * 2, 0)
	available_height := max(screen_height - margin * 2, 0)
	width := min(ui_px(scale, DEBUG_PANEL_WIDTH), min(screen_width * 2 / 3, available_width))
	return {screen_width - width - margin, margin, width, available_height}
}

debug_panel_geometry_clamp :: proc(
	rect: fit.Rect,
	screen_width, screen_height: i32,
	scale: f32,
) -> fit.Rect {
	margin := ui_px(scale, DEBUG_PANEL_MARGIN)
	available_width := max(screen_width - margin * 2, 0)
	available_height := max(screen_height - margin * 2, 0)
	minimum_visible := ui_px(scale, DEBUG_PANEL_VISIBLE_EDGE)
	minimum_width := min(
		max(ui_px(scale, DEBUG_PANEL_MIN_WIDTH), minimum_visible),
		available_width,
	)
	minimum_height := min(
		max(ui_px(scale, DEBUG_PANEL_MIN_HEIGHT), minimum_visible),
		available_height,
	)
	clamped := rect
	clamped.w = clamp(clamped.w, minimum_width, available_width)
	clamped.h = clamp(clamped.h, minimum_height, available_height)
	clamped.x = clamp(clamped.x, margin, max(screen_width - margin - clamped.w, margin))
	clamped.y = clamp(clamped.y, margin, max(screen_height - margin - clamped.h, margin))
	return clamped
}

debug_panel_geometry_move :: proc(
	rect: fit.Rect,
	delta_x, delta_y, screen_width, screen_height: i32,
	scale: f32,
) -> fit.Rect {
	moved := rect
	moved.x += delta_x
	moved.y += delta_y
	return debug_panel_geometry_clamp(moved, screen_width, screen_height, scale)
}

debug_panel_geometry_resize :: proc(
	rect: fit.Rect,
	delta_x, delta_y, screen_width, screen_height: i32,
	scale: f32,
) -> fit.Rect {
	resized := rect
	resized.w += delta_x
	resized.h += delta_y
	return debug_panel_geometry_clamp(resized, screen_width, screen_height, scale)
}

debug_panel_rect :: proc(value: ^Client_State) -> fit.Rect {
	assert(value != nil, "debug_panel_rect: nil state")
	screen_width := rl.GetScreenWidth()
	screen_height := rl.GetScreenHeight()
	if !value.debug.geometry_initialized {
		value.debug.rect = debug_panel_geometry_default(
			screen_width,
			screen_height,
			value.ui_scale,
		)
		if debug_pinned_context {
			value.debug.rect.x = max(value.debug.rect.x - value.debug.rect.w - ui_px(value.ui_scale, DEBUG_PANEL_MARGIN), ui_px(value.ui_scale, DEBUG_PANEL_MARGIN))
		}
		value.debug.geometry_initialized = true
	}
	value.debug.rect = debug_panel_geometry_clamp(
		value.debug.rect,
		screen_width,
		screen_height,
		value.ui_scale,
	)
	return value.debug.rect
}

debug_panel_visible :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "debug panel visible: nil state")
	return value.debug.open && !value.pause.open && value.world_ready
}

debug_pinned_panel_open :: proc(value: ^Client_State, target: Debug_Target) {
	assert(value != nil, "debug pinned open: nil state")
	if target.kind != .Surface || !target.surface.terrain.valid do return
	panel := &value.debug_pinned
	panel.open = true
	panel.target = target
	panel.selected_tab = value.debug.selected_tab
	panel.detail_mode = value.debug.detail_mode
	panel.scroll = 0
	panel.scope_flash_elapsed = 0
	panel.animation_elapsed = 0
	panel.was_open = false
}

debug_pinned_panel_contains :: proc(value: ^Client_State, point: rl.Vector2) -> bool {
	assert(value != nil, "debug pinned contains: nil state")
	debug_pinned_context = true
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	result := debug_panel_contains(value, point)
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_pinned_context = false
	return result
}

debug_panel_content_visible :: proc(interaction: Debug_Panel_Interaction) -> bool {
	return interaction != .Move
}

debug_panel_visible_rect :: proc(rect: fit.Rect, open_progress: f32) -> fit.Rect {
	progress := clamp(open_progress, 0, 1)
	reveal_width := clamp(i32(math.ceil(f32(rect.w) * progress)), 0, rect.w)
	return {rect.x + rect.w - reveal_width, rect.y, reveal_width, rect.h}
}

// debug_panel_contains follows the panel's visible opening edge. An established
// move, resize, or pin drag retains ownership across the whole viewport.
debug_panel_contains :: proc(value: ^Client_State, point: rl.Vector2) -> bool {
	assert(value != nil, "debug_panel_contains: nil state")
	if value.debug.interaction != .None do return true
	if !debug_panel_visible(value) do return false
	rect := debug_panel_rect(value)
	animation := debug_animation_sample(
		value.debug.animation_elapsed,
		value.debug.scope_flash_elapsed,
		value.debug.caret_elapsed,
	)
	visible := debug_panel_visible_rect(rect, animation.open_progress)
	x := i32(point.x)
	y := i32(point.y)
	contains :=
		x >= visible.x && x < visible.x + visible.w &&
		y >= visible.y && y < visible.y + visible.h
	return contains
}

@(private = "file")
_debug_title_rect :: proc(value: ^Client_State) -> fit.Rect {
	rect := debug_panel_rect(value)
	height := ui_px(value.ui_scale, DEBUG_PANEL_TITLE_HEIGHT)
	return {rect.x, rect.y, rect.w, min(height, rect.h)}
}

@(private = "file")
_debug_close_rect :: proc(value: ^Client_State) -> fit.Rect {
	title := _debug_title_rect(value)
	size := min(title.h, ui_px(value.ui_scale, DEBUG_ROW_HEIGHT))
	return {title.x + title.w - size, title.y, size, size}
}

@(private = "file")
_debug_pin_action_rect :: proc(value: ^Client_State) -> fit.Rect {
	close := _debug_close_rect(value)
	width := ui_px(value.ui_scale, 72)
	return {close.x - width, close.y, width, close.h}
}

@(private = "file")
_debug_detail_action_rect :: proc(value: ^Client_State) -> fit.Rect {
	pin := _debug_pin_action_rect(value)
	width := ui_px(value.ui_scale, 82)
	return {pin.x - width, pin.y, width, pin.h}
}

@(private = "file")
_debug_resize_rect :: proc(value: ^Client_State) -> fit.Rect {
	rect := debug_panel_rect(value)
	size := min(ui_px(value.ui_scale, DEBUG_PANEL_RESIZE_HANDLE), min(rect.w, rect.h))
	return {rect.x + rect.w - size, rect.y + rect.h - size, size, size}
}

@(private = "file")
_debug_filter_rect :: proc(value: ^Client_State) -> fit.Rect {
	rect := debug_panel_rect(value)
	padding := ui_px(value.ui_scale, DEBUG_PANEL_PADDING)
	title_height := ui_px(value.ui_scale, DEBUG_PANEL_TITLE_HEIGHT)
	height := ui_px(value.ui_scale, DEBUG_ROW_HEIGHT)
	return {rect.x + padding, rect.y + title_height + padding, rect.w - padding * 2, height}
}

debug_panel_fixed_inset :: proc(scale: f32, pill_rows: int) -> i32 {
	assert(pill_rows > 0, "debug panel inset: no pill rows")
	return ui_px(
		scale,
		DEBUG_PANEL_TITLE_HEIGHT + DEBUG_ROW_HEIGHT +
			DEBUG_TAB_HEIGHT * i32(pill_rows) + DEBUG_ROW_GAP * i32(pill_rows + 1),
	)
}

@(private = "file")
_debug_tabs_rect :: proc(value: ^Client_State) -> fit.Rect {
	rect := debug_panel_rect(value)
	padding := ui_px(value.ui_scale, DEBUG_PANEL_PADDING)
	filter := _debug_filter_rect(value)
	gap := ui_px(value.ui_scale, DEBUG_ROW_GAP)
	rows := max(value.debug.pill_rows, 1)
	return {
		rect.x + padding,
		filter.y + filter.h + gap,
		rect.w - padding * 2,
		ui_px(value.ui_scale, DEBUG_TAB_HEIGHT) * i32(rows) + gap * i32(rows - 1),
	}
}

@(private = "file")
_debug_rect_contains :: proc(rect: fit.Rect, point: rl.Vector2) -> bool {
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

debug_panel_keyboard_captured :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "debug keyboard capture: nil state")
	main := debug_panel_visible(value) && value.debug.keyboard_captured
	pinned := value.debug_pinned.open && !value.pause.open && value.world_ready && value.debug_pinned.keyboard_captured
	return main || pinned
}

debug_panel_tab_focus_allowed :: proc(open, visible, console_open, pause_open: bool) -> bool {
	return open && visible && !console_open && !pause_open
}

@(private = "file")
_debug_filter_input :: proc(value: ^Client_State, surface: ^fit.Surface) {
	filter := &value.debug.filter
	changed := false
	before_cursor := filter.cursor
	defer {
		if changed do value.debug.scroll = 0
		if changed || filter.cursor != before_cursor do value.debug.caret_elapsed = 0
	}
	ctrl :=
		fit.Surface_Key_Down(surface, .Left_Control) ||
		fit.Surface_Key_Down(surface, .Right_Control)
	super :=
		fit.Surface_Key_Down(surface, .Left_Super) || fit.Surface_Key_Down(surface, .Right_Super)
	if fit.Key_Pressed(surface, .V) && (super || ctrl) {
		changed = debug_filter_insert(filter, fit.Surface_Clipboard(surface))
	} else if !ctrl && !super {
		for codepoint in fit.Surface_Characters(surface) {
			if debug_filter_insert_rune(filter, codepoint) do changed = true
		}
	}
	fit.Surface_Characters_Consume(surface)
	if fit.Surface_Key_Pressed_Or_Repeat(surface, .Backspace) && debug_filter_backspace(filter) {
		changed = true
	}
	if fit.Surface_Key_Pressed_Or_Repeat(surface, .Delete) && debug_filter_delete(filter) {
		changed = true
	}
	if fit.Surface_Key_Pressed_Or_Repeat(surface, .Left) && filter.cursor > 0 do filter.cursor -= 1
	if fit.Surface_Key_Pressed_Or_Repeat(surface, .Right) && filter.cursor < filter.length do filter.cursor += 1
	if fit.Key_Pressed(surface, .Home) do filter.cursor = 0
	if fit.Key_Pressed(surface, .End) do filter.cursor = filter.length
	if fit.Key_Pressed(surface, .Escape) {
		changed |= filter.length > 0
		debug_filter_clear(filter)
		value.debug.filter_focused = false
	}
	if changed do value.debug.scroll = 0
}

// debug_panel_update handles the F10 toggle and wheel scrolling. The console
// and pause menu own the keyboard while open, so the toggle defers to them.
debug_panel_update :: proc(value: ^Client_State, surface: ^fit.Surface, frame_dt: f32) {
	assert(value != nil, "debug_panel_update: nil state")
	assert(surface != nil, "debug_panel_update: nil surface")
	assert(frame_dt >= 0, "debug_panel_update: negative delta time")
	value.debug.keyboard_captured = false
	if !debug_pinned_context && !value.console.open && !value.pause.open && fit.Key_Pressed(surface, .F10) {
		value.debug.open = !value.debug.open
		value.debug.filter_focused = false
		value.debug.interaction = .None
		value.debug.pin_armed = false
		settings_save(value)
	}
	if value.debug.open && !value.debug.was_open {
		value.debug.animation_elapsed = 0
		value.debug.scope_flash_elapsed = DEBUG_SCOPE_FLASH_DURATION
		value.debug.caret_elapsed = 0
	}
	value.debug.was_open = value.debug.open
	if !value.debug.open do return
	if !debug_panel_visible(value) {
		value.debug.filter_focused = false
		value.debug.keyboard_captured = false
		value.debug.interaction = .None
		value.debug.pin_armed = false
		return
	}
	value.debug.animation_elapsed += frame_dt
	value.debug.scope_flash_elapsed += frame_dt
	value.debug.caret_elapsed += frame_dt
	if value.debug.pin_armed && fit.Key_Pressed(surface, .Escape) {
		value.debug.pin_armed = false
		value.debug.keyboard_captured = true
	}
	if debug_panel_tab_focus_allowed(
		value.debug.open,
		debug_panel_visible(value),
		value.console.open,
		value.pause.open,
	) && !debug_pinned_context && fit.Key_Pressed(surface, .Tab) {
		value.debug.filter_focused = true
		value.debug.keyboard_captured = true
		value.debug.caret_elapsed = 0
	}
	mouse := rl.GetMousePosition()
	rect := debug_panel_rect(value)
	if value.debug.interaction != .None {
		if !rl.IsMouseButtonDown(.LEFT) {
			value.debug.interaction = .None
		} else {
			delta_x := i32(mouse.x - value.debug.interaction_anchor.x)
			delta_y := i32(mouse.y - value.debug.interaction_anchor.y)
			switch value.debug.interaction {
			case .None:
			case .Move:
				value.debug.rect = debug_panel_geometry_move(
					value.debug.interaction_rect,
					delta_x,
					delta_y,
					rl.GetScreenWidth(),
					rl.GetScreenHeight(),
					value.ui_scale,
				)
			case .Resize:
				value.debug.rect = debug_panel_geometry_resize(
					value.debug.interaction_rect,
					delta_x,
					delta_y,
					rl.GetScreenWidth(),
					rl.GetScreenHeight(),
					value.ui_scale,
				)
			}
		}
	} else if !value.console.open &&
	   !value.pause.open &&
	   fit.Surface_Mouse_Pressed(surface, .Left) {
		if _debug_rect_contains(_debug_close_rect(value), mouse) {
			value.debug.open = false
			value.debug.filter_focused = false
			value.debug.keyboard_captured = false
			value.debug.interaction = .None
			value.debug.pin_armed = false
			settings_save(value)
			return
		} else if _debug_rect_contains(_debug_detail_action_rect(value), mouse) {
			value.debug.detail_mode = .Simple if value.debug.detail_mode == .Advanced else .Advanced
			value.debug.scroll = 0
			value.debug.preset_dropdown = {}
			value.debug.filter_focused = false
			value.debug.keyboard_captured = true
			if !debug_pinned_context do settings_save(value)
		} else if !debug_pinned_context && _debug_rect_contains(_debug_pin_action_rect(value), mouse) {
			value.debug.pin_armed = !value.debug.pin_armed
			value.debug.filter_focused = false
			value.debug.keyboard_captured = true
		} else if _debug_rect_contains(_debug_resize_rect(value), mouse) {
			value.debug.interaction = .Resize
			value.debug.interaction_anchor = mouse
			value.debug.interaction_rect = rect
			value.debug.filter_focused = false
		} else if _debug_rect_contains(_debug_title_rect(value), mouse) {
			value.debug.interaction = .Move
			value.debug.interaction_anchor = mouse
			value.debug.interaction_rect = rect
			value.debug.filter_focused = false
		} else {
			value.debug.filter_focused = _debug_rect_contains(_debug_filter_rect(value), mouse)
		}
	}
	if value.debug.filter_focused && !value.console.open && !value.pause.open {
		value.debug.keyboard_captured = true
		_debug_filter_input(value, surface)
	}
	if value.debug.interaction == .None && debug_panel_contains(value, mouse) {
		wheel := rl.GetMouseWheelMove()
		if wheel != 0 {
			value.debug.scroll -= i32(wheel * f32(ui_px(value.ui_scale, DEBUG_SCROLL_STEP)))
		}
	}
	rect = debug_panel_rect(value)
	padding := ui_px(value.ui_scale, DEBUG_PANEL_PADDING)
	reserved := debug_panel_fixed_inset(value.ui_scale, max(value.debug.pill_rows, 1))
	limit := max(value.debug.content_height - (rect.h - padding * 2 - reserved), 0)
	value.debug.scroll = clamp(value.debug.scroll, 0, limit)
}

debug_pinned_panel_update :: proc(value: ^Client_State, surface: ^fit.Surface, frame_dt: f32) {
	assert(value != nil && surface != nil, "debug pinned update: nil input")
	debug_pinned_context = true
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_panel_update(value, surface, frame_dt)
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_pinned_context = false
}

// debug_scope_click resolves a completed world click into a panel scope:
// entity beats flora beats terrain (debug_scope_resolve). Never touches
// value.selected, so gameplay selection keeps working alongside.
debug_scope_click :: proc(value: ^Client_State) {
	debug_scope_click_at(value, rl.GetMousePosition())
}

debug_scope_target_changed :: proc(panel: ^Debug_Panel, target: Debug_Target) -> bool {
	assert(panel != nil, "debug scope identity: nil panel")
	return !debug_target_same_identity(panel.target, target)
}

debug_scope_target_selectable :: proc(kind: Debug_Target_Kind) -> bool {
	return kind != .Surface
}

debug_pin_place_at :: proc(value: ^Client_State, screen_point: rl.Vector2) -> bool {
	assert(value != nil, "debug pin place: nil state")
	if !value.debug.open || !value.debug.pin_armed do return false
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	if width <= 0 || height <= 0 do return false
	ray := rl.screen_to_world_ray(screen_point, value.camera, width, height)
	terrain_point, terrain_hit := terrain_ray_hit(&value.terrain, ray)
	if !debug_pin_placement_ready(value.debug.pin_armed, terrain_hit) do return false
	terrain_ref, located := debug_terrain_locate(value, terrain_point)
	if !located do return false
	value.debug.pin_armed = false
	debug_pinned_panel_open(value, debug_target_surface(.Terrain, terrain_ref))
	return true
}

debug_scope_click_at :: proc(value: ^Client_State, screen_point: rl.Vector2) {
	assert(value != nil, "debug_scope_click: nil state")
	if !value.debug.open do return
	width := rl.GetScreenWidth()
	height := rl.GetScreenHeight()
	if width <= 0 || height <= 0 do return
	ray := rl.screen_to_world_ray(screen_point, value.camera, width, height)
	terrain_point, terrain_hit := terrain_ray_hit(&value.terrain, ray)
	terrain_distance := debug_ray_hit_distance(ray, terrain_point, terrain_hit)
	entity, entity_distance, entity_hit := entity_queries_pick(value, ray)
	entity_hit = entity_hit && entity_hit_visible(entity_distance, terrain_distance, terrain_hit)
	flora_index := -1
	if !entity_hit {
		if found, flora_distance, ok := debug_flora_pick(&value.flora, ray);
		   ok && (!terrain_hit || flora_distance <= terrain_distance) {
			flora_index = found
		}
	}
	kind := debug_target_resolve(entity_hit, flora_index >= 0, terrain_hit)
	if !debug_scope_target_selectable(kind) do return
	target := debug_target_world()
	switch kind {
	case .World:
	case .Entity:
		net_id, _ := shared.world_net_id_for_entity(&value.world, entity)
		target = debug_target_entity(net_id, entity)
	case .Flora_Item:
		target = debug_target_flora(flora_index)
	case .Surface:
		unreachable()
	}
	if debug_scope_target_changed(&value.debug, target) {
		value.debug.scope_flash_elapsed = 0
		value.debug.scroll = 0
	}
	value.debug.target = target
}


debug_ray_hit_distance :: proc(ray: rl.Ray_3D, point: [3]f32, hit: bool) -> f32 {
	if !hit do return TERRAIN_RAY_MAX_DISTANCE
	delta := point - ray.origin
	return math.sqrt(delta.x * delta.x + delta.y * delta.y + delta.z * delta.z)
}

// debug_flora_pick finds the nearest visible flora instance whose pick
// cylinder the ray passes through. Distance along the ray breaks ties so a
// tree in front of another is the one picked.
debug_flora_pick :: proc(value: ^Flora, ray: rl.Ray_3D) -> (int, f32, bool) {
	assert(value != nil, "debug_flora_pick: nil flora")
	if !value.ready do return -1, 0, false
	direction := ray.direction
	length := math.sqrt(
		direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
	)
	if length <= 0 do return -1, 0, false
	direction = direction / length
	best_index := -1
	best_t := TERRAIN_RAY_MAX_DISTANCE
	ranges: [2 * FLORA_STREAM_TILE_COUNT + 1][2]i32
	range_count := _flora_index_ranges(value, &ranges)
	for r in 0 ..< range_count {
		for index in int(ranges[r][0]) ..< int(ranges[r][1]) {
			instance := &value.instances[index]
			if instance.hidden do continue
			to := instance.position - ray.origin
			t := to.x * direction.x + to.y * direction.y + to.z * direction.z
			if t < 0 || t >= best_t do continue
			closest := ray.origin + direction * t
			offset := instance.position - closest
			radius := max(_flora_patch_radius(instance.mesh), 0.6) * instance.scale + 0.4
			distance_sq := offset.x * offset.x + offset.y * offset.y + offset.z * offset.z
			if distance_sq > radius * radius do continue
			best_index = index
			best_t = t
		}
	}
	return best_index, best_t, best_index >= 0
}

debug_scope_brackets_draw :: proc(
	value: ^Client_State,
	pass: ^rl.Gpu_3D_Pass,
	center, size: [3]f32,
	pulse: f32,
) {
	assert(value != nil && pass != nil, "debug brackets: invalid argument")
	if value.debug.marker_mesh.id == 0 do return
	base := rl.MatrixTranslate(center.x, center.y, center.z)
	underlay := base * rl.MatrixScale(size.x * 1.14, size.y * 1.14, size.z * 1.14)
	rl.draw_gpu_mesh(pass, value.debug.marker_mesh, underlay, {color = UI_DEBUG_MARKER_SHADOW})
	scale := 1.08 + pulse * 0.08
	bright := base * rl.MatrixScale(size.x * scale, size.y * scale, size.z * scale)
	rl.draw_gpu_mesh(
		pass,
		value.debug.marker_mesh,
		bright,
		{color = UI_AMBER, style = .Opaque_Outline, depth_nudge = 0.0004},
	)
}

debug_terrain_axes_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass, pulse: f32) {
	assert(value != nil && pass != nil, "debug terrain axes: invalid argument")
	ref := value.debug.target.surface.terrain
	if !ref.valid do return
	geometry := debug_terrain_axes_geometry(ref.point, ref.surface_normal, value.camera.position)
	frame := debug_surface_frame(geometry.z_axis)
	length := geometry.axis_length * (1 + pulse * 0.06)
	thickness := geometry.shaft_thickness
	cap_size := geometry.cap_size * (1 + pulse * 0.12)
	axes := [3][3]f32{geometry.x_axis, geometry.y_axis, geometry.z_axis}
	colors := [3]rl.Color{UI_DEBUG_AXIS_X, UI_DEBUG_AXIS_Y, UI_DEBUG_AXIS_Z}
	shaft_scales := [3][3]f32 {
		{length, thickness, thickness},
		{thickness, length, thickness},
		{thickness, thickness, length},
	}
	for axis, index in axes {
		shaft_center := geometry.origin + axis * (length * 0.5)
		shaft :=
			rl.MatrixTranslate(shaft_center.x, shaft_center.y, shaft_center.z) *
			frame *
			rl.MatrixScale(shaft_scales[index].x, shaft_scales[index].y, shaft_scales[index].z)
		cap_center := geometry.origin + axis * length
		cap :=
			rl.MatrixTranslate(cap_center.x, cap_center.y, cap_center.z) *
			frame *
			rl.MatrixScale(cap_size, cap_size, cap_size)
		transforms := [2]rl.Matrix{shaft, cap}
		for transform in transforms {
			rl.draw_gpu_mesh(
				pass,
				value.cube,
				transform,
				{color = UI_DEBUG_MARKER_SHADOW, style = .Opaque},
			)
			rl.draw_gpu_mesh(
				pass,
				value.cube_edges,
				transform,
				{color = colors[index], style = .Opaque_Outline, depth_nudge = 0.0004},
			)
		}
	}
}

debug_terrain_pin_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass, pulse: f32) {
	assert(value != nil && pass != nil, "debug terrain pin: invalid argument")
	ref := value.debug.target.surface.terrain
	if !ref.valid do return
	geometry := debug_terrain_pin_geometry(ref.point, ref.surface_normal, value.camera.position)
	size := geometry.size
	frame := debug_surface_frame(ref.surface_normal)
	stem_center := geometry.stem_center
	stem :=
		rl.MatrixTranslate(stem_center.x, stem_center.y, stem_center.z) *
		frame *
		rl.MatrixScale(size * 0.16, size * 0.16, size * 1.3)
	head_center := geometry.head_center
	active := debug_pinned_context
	head_scale := size * (0.55 + (0.08 if active else 0))
	head :=
		rl.MatrixTranslate(head_center.x, head_center.y, head_center.z) *
		frame *
		rl.MatrixScale(head_scale, head_scale, size * 0.42)
	transforms := [2]rl.Matrix{stem, head}
	marker_color := UI_AMBER if active || pulse > 0 else UI_DEBUG_SCOPE
	for transform in transforms {
		rl.draw_gpu_mesh(
			pass,
			value.cube,
			transform,
			{color = UI_DEBUG_MARKER_SHADOW, style = .Opaque},
		)
		rl.draw_gpu_mesh(
			pass,
			value.cube_edges,
			transform,
			{color = marker_color, style = .Opaque_Outline, depth_nudge = 0.0004},
		)
	}
}

// debug_scope_draw keeps the panel and world selection in agreement.
debug_pinned_scope_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil && pass != nil, "debug pinned scope: nil input")
	debug_pinned_context = true
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_scope_draw(value, pass)
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_pinned_context = false
}

debug_scope_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "debug_scope_draw: nil state")
	assert(pass != nil, "debug_scope_draw: nil pass")
	if !value.debug.open do return
	animation := debug_animation_sample(
		value.debug.animation_elapsed,
		value.debug.scope_flash_elapsed,
		value.debug.caret_elapsed,
	)
	switch value.debug.target.kind {
	case .World:
		return
	case .Surface:
		ref := value.debug.target.surface.terrain
		debug_terrain_pin_draw(value, pass, animation.scope_flash)
		if !ref.valid do return
		debug_terrain_axes_draw(value, pass, animation.scope_flash)
		return
	case .Entity:
		entity := value.debug.target.entity.entity
		if resolved, ok := shared.world_entity_by_net_id(&value.world, value.debug.target.entity.net_id); ok {
			entity = resolved
		}
		if !ecs.is_alive(&value.world.pool, entity) do return
		debug_entity_extension_outline_draw(value, pass, entity, animation.scope_flash)
		return
	case .Flora_Item:
		scale := 1.025 + animation.scope_flash * 0.015
		_ = flora_debug_outline_draw(&value.flora, pass, value.debug.target.flora_index, scale, UI_AMBER)
		return
	}
}

// debug_panel_frame draws the panel and every widget. Runs in screen space
// inside the session frame, after the inspect panel and before the pause
// menu, so the menu scrim still covers it.
debug_panel_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "debug_panel_frame: nil state")
	assert(surface != nil, "debug_panel_frame: nil surface")
	if !debug_panel_visible(value) do return
	rect := debug_panel_rect(value)
	animation := debug_animation_sample(
		value.debug.animation_elapsed,
		value.debug.scope_flash_elapsed,
		value.debug.caret_elapsed,
	)
	visible_rect := debug_panel_visible_rect(rect, animation.open_progress)
	fit.Surface_Clip_Begin(surface, visible_rect)
	defer fit.Surface_Clip_End(surface)
	panel := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	ui_panel_draw(value, surface, panel, .Card)
	_debug_title_frame(value, surface)
	if !debug_panel_content_visible(value.debug.interaction) {
		fit.Request_Redraw(surface)
		return
	}
	_debug_acquisition_frame(value, surface, rect, animation)
	padding := ui_px(value.ui_scale, DEBUG_PANEL_PADDING)
	_debug_filter_frame(value, surface)
	_debug_resize_frame(value, surface)
	registry: Debug_Tab_Registry
	layout := _Debug_Layout {
		value    = value,
		surface  = surface,
		panel    = rect,
		x        = rect.x + padding,
		width    = rect.w - padding * 2,
		y        = 0,
		widget   = DEBUG_WIDGET_BASE + u64(value.debug.target.kind) << 20,
		phase    = .Discover,
		registry = &registry,
	}
	category_titles := DEBUG_CATEGORY_TITLES
	for category in DEBUG_CATEGORY_ORDER {
		debug_tab_registry_add(&registry, debug_tab_category(category), category_titles[category])
	}
	_debug_scope(&layout)
	value.debug.selected_tab = debug_tab_select_valid(&registry, value.debug.selected_tab)
	_debug_tabs_frame(value, surface, &registry)
	layout.phase = .Render
	layout.y = 0
	layout.widget = DEBUG_WIDGET_BASE + u64(value.debug.target.kind) << 20
	_debug_breadcrumb(&layout)
	_debug_scope(&layout)
	value.debug.content_height = layout.y
	fit.Request_Redraw(surface)
}

@(private = "file")
_debug_scope :: proc(layout: ^_Debug_Layout) {
	_debug_world_scope(layout)
	switch layout.value.debug.target.kind {
	case .World:
	case .Entity:
		_debug_entity_scope(layout, layout.value.debug.target.entity)
	case .Flora_Item:
		_debug_flora_scope(layout, layout.value.debug.target.flora_index)
	case .Surface:
		_debug_terrain_scope(layout, layout.value.debug.target.surface)
	}
}

@(private = "file")
_debug_acquisition_frame :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	rect: fit.Rect,
	animation: Debug_Animation_Sample,
) {
	assert(value != nil && surface != nil, "debug acquisition: invalid argument")
	if animation.scan_visible {
		title_height := ui_px(value.ui_scale, DEBUG_PANEL_TITLE_HEIGHT)
		span := max(rect.h - title_height, 1)
		y := rect.y + title_height + i32(f32(span) * animation.scan_progress)
		trail := max(ui_px(value.ui_scale, 10), 2)
		fit.Fill_Rect(
			surface,
			fit.Rect{rect.x + 1, y - trail, max(rect.w - 2, 0), trail},
			fit.Color(UI_DEBUG_SCAN_TRAIL),
		)
		fit.Line(
			surface,
			{f32(rect.x + 1), f32(y)},
			{f32(rect.x + rect.w - 1), f32(y)},
			f32(max(ui_px(value.ui_scale, 1), 1)),
			fit.Color(UI_DEBUG_SCAN),
		)
	}
	color := UI_DEBUG_CHROME
	color.a = u8(55 + 75 * animation.chrome_pulse)
	length := max(ui_px(value.ui_scale, 14), 4)
	inset := max(ui_px(value.ui_scale, 4), 1)
	thickness := f32(max(ui_px(value.ui_scale, 1), 1))
	left := f32(rect.x + inset)
	right := f32(rect.x + rect.w - inset)
	top := f32(rect.y + inset)
	bottom := f32(rect.y + rect.h - inset)
	fit.Line(surface, {left, top}, {left + f32(length), top}, thickness, fit.Color(color))
	fit.Line(surface, {left, top}, {left, top + f32(length)}, thickness, fit.Color(color))
	fit.Line(surface, {right, top}, {right - f32(length), top}, thickness, fit.Color(color))
	fit.Line(surface, {right, top}, {right, top + f32(length)}, thickness, fit.Color(color))
	fit.Line(surface, {left, bottom}, {left + f32(length), bottom}, thickness, fit.Color(color))
	fit.Line(surface, {left, bottom}, {left, bottom - f32(length)}, thickness, fit.Color(color))
	fit.Line(surface, {right, bottom}, {right - f32(length), bottom}, thickness, fit.Color(color))
	fit.Line(surface, {right, bottom}, {right, bottom - f32(length)}, thickness, fit.Color(color))
}

debug_pinned_panel_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil && surface != nil, "debug pinned frame: nil input")
	debug_pinned_context = true
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_panel_frame(value, surface)
	value.debug, value.debug_pinned = value.debug_pinned, value.debug
	debug_pinned_context = false
}

// --- layout helpers --------------------------------------------------------

@(private = "file")
_debug_title_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	rect := _debug_title_rect(value)
	tokens := fit.Get_Theme_Tokens(surface)
	fit.Fill_Rect(surface, rect, tokens.background_active)
	padding := ui_px(value.ui_scale, DEBUG_PANEL_PADDING)
	text_y := rect.y + (rect.h - fit.Text_Size(surface, .Note)) / 2
	close := _debug_close_rect(value)
	pin := _debug_pin_action_rect(value)
	detail := _debug_detail_action_rect(value)
	title := "PINNED FOCUS" if debug_pinned_context else "DEBUG PANEL"
	text_right := detail.x
	fit.Text_Truncated(
		surface,
		title,
		rect.x + padding,
		text_y,
		max(text_right - rect.x - padding * 2, 0),
		.Note,
		.Heading,
	)
	cursor_target_register(value, surface, detail)
	detail_label := "Advanced" if value.debug.detail_mode == .Simple else "Simple"
	detail_style: fit.Button_Style = .Primary if value.debug.detail_mode == .Advanced else .Ghost
	_ = fit.Surface_Button(surface, fit.Widget_Id_From_String("debug.detail"), detail_label, detail, detail_style)
	if !debug_pinned_context {
		cursor_target_register(value, surface, pin)
		pin_style: fit.Button_Style = .Primary if value.debug.pin_armed else .Ghost
		_ = fit.Surface_Button(surface, fit.Widget_Id_From_String("debug.pin.arm"), "Drop pin", pin, pin_style)
	}
	cursor_target_register(value, surface, close)
	_ = fit.Surface_Button(surface, fit.Widget_Id_From_String("debug.close"), "X", close, .Ghost)
}

@(private = "file")
_debug_resize_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	rect := _debug_resize_rect(value)
	tokens := fit.Get_Theme_Tokens(surface)
	inset := max(ui_px(value.ui_scale, 4), 1)
	step := max(ui_px(value.ui_scale, 4), 1)
	thickness := f32(max(ui_px(value.ui_scale, 1), 1))
	for index in 0 ..< 3 {
		offset := inset + i32(index) * step
		fit.Line(
			surface,
			{f32(rect.x + rect.w - offset), f32(rect.y + rect.h - inset)},
			{f32(rect.x + rect.w - inset), f32(rect.y + rect.h - offset)},
			thickness,
			tokens.foreground_secondary,
		)
	}
}

@(private = "file")
_debug_tabs_frame :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	registry: ^Debug_Tab_Registry,
) {
	assert(value != nil && surface != nil && registry != nil, "debug pills: invalid input")
	if registry.count == 0 do return
	gap := ui_px(value.ui_scale, DEBUG_ROW_GAP)
	minimum_width := ui_px(value.ui_scale, DEBUG_TAB_MIN_WIDTH)
	padding := ui_px(value.ui_scale, DEBUG_TAB_HORIZONTAL_PADDING)
	available_width := debug_panel_rect(value).w - ui_px(value.ui_scale, DEBUG_PANEL_PADDING) * 2
	widths: [DEBUG_TAB_MAX]i32
	for index in 0 ..< registry.count {
		widths[index] = max(fit.Text_Width(surface, registry.entries[index].title, .Note) + padding, minimum_width)
	}
	value.debug.pill_rows = debug_pill_row_count(widths[:registry.count], available_width, gap)
	rect := _debug_tabs_rect(value)
	pill_height := ui_px(value.ui_scale, DEBUG_TAB_HEIGHT)
	x := rect.x
	y := rect.y
	for index in 0 ..< registry.count {
		entry := registry.entries[index]
		pill_width := min(widths[index], rect.w)
		if x > rect.x && x + pill_width > rect.x + rect.w {
			x = rect.x
			y += pill_height + gap
		}
		pill := fit.Rect{x, y, pill_width, pill_height}
		style: fit.Button_Style = .Primary if entry.id == value.debug.selected_tab else .Ghost
		cursor_target_register(value, surface, pill)
		if fit.Surface_Button(surface, debug_tab_widget_id(entry.id, 1), entry.title, pill, style) {
			value.debug.selected_tab = entry.id
			value.debug.scroll = 0
			value.debug.filter_focused = false
		}
		x += pill_width + gap
	}
}

@(private = "file")
_debug_filter_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	rect := _debug_filter_rect(value)
	tokens := fit.Get_Theme_Tokens(surface)
	background :=
		tokens.background_active if value.debug.filter_focused else tokens.background_input
	fit.Fill_Rect(surface, rect, background)
	text := debug_filter_text(&value.debug.filter)
	button_width := i32(0)
	if text != "" do button_width = ui_px(value.ui_scale, 52)
	text_x := rect.x + ui_px(value.ui_scale, 8)
	text_width := rect.w - button_width - ui_px(value.ui_scale, 12)
	shown := text if text != "" else "Filter settings..."
	ink: fit.Ink = .Primary if text != "" else .Secondary
	text_y := rect.y + (rect.h - fit.Text_Size(surface, .Note)) / 2
	fit.Text_Truncated(surface, shown, text_x, text_y, text_width, .Note, ink)
	animation := debug_animation_sample(
		value.debug.animation_elapsed,
		value.debug.scope_flash_elapsed,
		value.debug.caret_elapsed,
	)
	if value.debug.filter_focused && animation.caret_visible {
		prefix := text[:value.debug.filter.cursor]
		caret_x := min(text_x + fit.Text_Width(surface, prefix, .Note), text_x + text_width)
		inset := max(ui_px(value.ui_scale, 4), 1)
		fit.Line(
			surface,
			{f32(caret_x), f32(rect.y + inset)},
			{f32(caret_x), f32(rect.y + rect.h - inset)},
			f32(max(ui_px(value.ui_scale, 1), 1)),
			tokens.foreground_secondary,
		)
	}
	if text != "" {
		clear_rect := fit.Rect{rect.x + rect.w - button_width, rect.y, button_width, rect.h}
		cursor_target_register(value, surface, clear_rect)
		if fit.Surface_Button(
			surface,
			fit.Widget_Id_From_String("debug.filter.clear"),
			"Clear",
			clear_rect,
			.Ghost,
		) {
			debug_filter_clear(&value.debug.filter)
			value.debug.scroll = 0
			value.debug.caret_elapsed = 0
			value.debug.filter_focused = true
		}
	}
}

// _debug_row_rect converts the virtual row cursor into a screen rect, or
// reports the row invisible when scrolled outside the panel.
@(private = "file")
_debug_row_rect :: proc(layout: ^_Debug_Layout, height: i32) -> (fit.Rect, bool) {
	padding := ui_px(layout.value.ui_scale, DEBUG_PANEL_PADDING)
	reserved := debug_panel_fixed_inset(layout.value.ui_scale, max(layout.value.debug.pill_rows, 1))
	top := layout.panel.y + padding + reserved
	y := top + layout.y - layout.value.debug.scroll
	resize_handle := ui_px(layout.value.ui_scale, DEBUG_PANEL_RESIZE_HANDLE)
	visible :=
		y + height > top && y < layout.panel.y + layout.panel.h - max(padding, resize_handle)
	return fit.Rect{layout.x, y, layout.width, height}, visible
}

@(private = "file")
_debug_advance :: proc(layout: ^_Debug_Layout, height: i32) {
	layout.y += height + ui_px(layout.value.ui_scale, DEBUG_ROW_GAP)
}

@(private = "file")
_debug_widget_next :: proc(layout: ^_Debug_Layout) -> fit.Widget_Id {
	layout.widget += 1
	return fit.Widget_Id_From_U64(layout.widget)
}

debug_row_matches :: proc(query, label: string, value := "") -> bool {
	return debug_filter_matches(query, label, value)
}

@(private = "file")
_debug_matches :: proc(layout: ^_Debug_Layout, label: string, value := "") -> bool {
	query := debug_filter_text(&layout.value.debug.filter)
	return debug_row_matches(query, label, value)
}

debug_extension_widget_id :: proc(key: u32) -> fit.Widget_Id {
	assert(key > 0, "debug extension: invalid widget key")
	return fit.Widget_Id_From_U64(DEBUG_WIDGET_BASE + 0x10000 + u64(key))
}

debug_tab_widget_value :: proc(id: Debug_Tab_Id, key: u32) -> u64 {
	assert(key > 0, "debug tab widget: invalid key")
	return DEBUG_WIDGET_BASE + u64(id.category) << 12 + u64(key)
}

debug_tab_widget_id :: proc(id: Debug_Tab_Id, key: u32) -> fit.Widget_Id {
	return fit.Widget_Id_From_U64(debug_tab_widget_value(id, key))
}

@(private = "file")
_debug_tab_enter :: proc(layout: ^_Debug_Layout, id: Debug_Tab_Id) {
	layout.current_tab = id
	layout.widget = DEBUG_WIDGET_BASE + u64(id.category) << 12
}

@(private = "file")
_debug_extension_layout :: proc(extension: ^Debug_Panel_Extension_Context) -> ^_Debug_Layout {
	assert(extension != nil && extension.layout != nil, "debug extension: nil extension")
	return cast(^_Debug_Layout)extension.layout
}

debug_readout_columns :: proc(rect: fit.Rect, scale: f32) -> (label, value: fit.Rect) {
	assert(scale > 0, "debug readout columns: invalid scale")
	gap := ui_px(scale, DEBUG_ROW_GAP)
	preferred_value := ui_px(scale, DEBUG_VALUE_WIDTH + DEBUG_CONTROL_WIDTH / 2)
	value_width := min(preferred_value, max((rect.w - gap) * 3 / 5, 0))
	label_width := max(rect.w - gap - value_width, 0)
	label = {rect.x, rect.y, label_width, rect.h}
	value = {rect.x + label_width + gap, rect.y, value_width, rect.h}
	return
}

// _debug_readout draws one label/value row in separate bounded columns.
@(private = "file")
_debug_readout :: proc(layout: ^_Debug_Layout, label, text: string) {
	if layout.phase == .Discover do return
	if !debug_detail_visible(layout.value.debug.detail_mode, layout.current_tier) do return
	if !debug_tab_body_visible(
		debug_filter_text(&layout.value.debug.filter) != "",
		layout.value.debug.selected_tab,
		layout.current_tab,
	) {
		return
	}
	if !_debug_matches(layout, label, text) do return
	height := ui_px(layout.value.ui_scale, DEBUG_ROW_HEIGHT)
	rect, visible := _debug_row_rect(layout, height)
	defer _debug_advance(layout, height)
	if !visible do return
	text_y := rect.y + (height - fit.Text_Size(layout.surface, .Note)) / 2
	label_rect, value_rect := debug_readout_columns(rect, layout.value.ui_scale)
	fit.Text_Truncated(
		layout.surface,
		label,
		label_rect.x,
		text_y,
		label_rect.w,
		.Note,
		.Label,
	)
	fit.Text_Truncated(
		layout.surface,
		text,
		value_rect.x,
		text_y,
		value_rect.w,
		.Note,
		.Secondary,
	)
}

// _debug_slider draws a labelled slider with a numeric readout and reports
// whether the value changed this frame.
@(private = "file")
_debug_slider :: proc(
	layout: ^_Debug_Layout,
	label: string,
	target: ^f32,
	minimum, maximum, step: f32,
) -> bool {
	assert(target != nil, "_debug_slider: nil target")
	if layout.phase == .Discover do return false
	if !debug_tab_body_visible(
		debug_filter_text(&layout.value.debug.filter) != "",
		layout.value.debug.selected_tab,
		layout.current_tab,
	) {
		return false
	}
	widget := _debug_widget_next(layout)
	if !_debug_matches(layout, label) do return false
	height := ui_px(layout.value.ui_scale, DEBUG_ROW_HEIGHT)
	rect, visible := _debug_row_rect(layout, height)
	defer _debug_advance(layout, height)
	if !visible do return false
	control_width := ui_px(layout.value.ui_scale, DEBUG_CONTROL_WIDTH)
	value_width := ui_px(layout.value.ui_scale, DEBUG_VALUE_WIDTH)
	text_y := rect.y + (height - fit.Text_Size(layout.surface, .Note)) / 2
	label_width := max(rect.w - control_width - value_width, 0)
	fit.Text_Truncated(layout.surface, label, rect.x, text_y, label_width, .Note, .Label)
	readout := fmt.tprintf("%.3f", target^)
	fit.Text_Truncated(
		layout.surface,
		readout,
		rect.x + label_width,
		text_y,
		value_width,
		.Note,
		.Secondary,
	)
	slider := fit.Rect{rect.x + rect.w - control_width, rect.y, control_width, height}
	return fit.Surface_Slider(layout.surface, widget, target, minimum, maximum, step, slider)
}

@(private = "file")
_debug_checkbox :: proc(layout: ^_Debug_Layout, label: string, target: ^bool) -> bool {
	assert(target != nil, "_debug_checkbox: nil target")
	if layout.phase == .Discover do return false
	if !debug_tab_body_visible(
		debug_filter_text(&layout.value.debug.filter) != "",
		layout.value.debug.selected_tab,
		layout.current_tab,
	) {
		return false
	}
	widget := _debug_widget_next(layout)
	if !_debug_matches(layout, label) do return false
	height := ui_px(layout.value.ui_scale, DEBUG_ROW_HEIGHT)
	rect, visible := _debug_row_rect(layout, height)
	defer _debug_advance(layout, height)
	if !visible do return false
	return fit.Surface_Checkbox(layout.surface, widget, label, target, rect)
}

@(private = "file")
_debug_button :: proc(layout: ^_Debug_Layout, label: string) -> bool {
	if layout.phase == .Discover do return false
	if !debug_tab_body_visible(
		debug_filter_text(&layout.value.debug.filter) != "",
		layout.value.debug.selected_tab,
		layout.current_tab,
	) {
		return false
	}
	widget := _debug_widget_next(layout)
	if !_debug_matches(layout, label) do return false
	height := ui_px(layout.value.ui_scale, DEBUG_BUTTON_HEIGHT)
	rect, visible := _debug_row_rect(layout, height)
	defer _debug_advance(layout, height)
	if !visible do return false
	cursor_target_register(layout.value, layout.surface, rect)
	return fit.Surface_Button(layout.surface, widget, label, rect, .Secondary)
}

@(private = "file")
_debug_section :: proc(layout: ^_Debug_Layout, section: Debug_Panel_Section) -> bool {
	layout.current_tier = .Simple
	id := debug_tab_category(section)
	if layout.phase == .Discover {
		titles := DEBUG_CATEGORY_TITLES
		debug_tab_registry_add(layout.registry, id, titles[section])
		return false
	}
	_debug_tab_enter(layout, id)
	filtering := debug_filter_text(&layout.value.debug.filter) != ""
	return debug_tab_body_visible(filtering, layout.value.debug.selected_tab, id)
}

@(private = "file")
_debug_tier :: proc(layout: ^_Debug_Layout, tier: Debug_Detail_Tier) -> bool {
	layout.current_tier = tier
	return debug_detail_visible(layout.value.debug.detail_mode, tier)
}

@(private = "file")
_debug_extension_section :: proc(
	layout: ^_Debug_Layout,
	key: Debug_Extension_Section_Key,
	title: string,
) -> bool {
	category := Debug_Category(clamp(int(key), 0, DEBUG_CATEGORY_COUNT - 1))
	_ = title
	return _debug_section(layout, category)
}

debug_panel_extension_readout :: proc(
	extension: ^Debug_Panel_Extension_Context,
	label, text: string,
) {
	layout := _debug_extension_layout(extension)
	_debug_readout(layout, label, text)
}

debug_panel_extension_category :: proc(
	extension: ^Debug_Panel_Extension_Context,
	category: Debug_Category,
) -> bool {
	return _debug_section(_debug_extension_layout(extension), category)
}

debug_panel_extension_group :: proc(
	extension: ^Debug_Panel_Extension_Context,
	title: string,
	tier := Debug_Detail_Tier.Simple,
) -> bool {
	layout := _debug_extension_layout(extension)
	layout.current_tier = tier
	_ = title
	return debug_detail_visible(layout.value.debug.detail_mode, tier)
}

debug_panel_extension_section :: proc(
	extension: ^Debug_Panel_Extension_Context,
	key: Debug_Extension_Section_Key,
	title: string,
) -> bool {
	assert(debug_extension_section_key_valid(key), "debug extension: invalid section key")
	assert(title != "", "debug extension: empty section title")
	return _debug_extension_section(_debug_extension_layout(extension), key, title)
}

debug_panel_extension_slider :: proc(
	extension: ^Debug_Panel_Extension_Context,
	key: u32,
	label: string,
	target: ^f32,
	minimum, maximum, step: f32,
) -> bool {
	layout := _debug_extension_layout(extension)
	assert(key > 0 && target != nil, "debug extension slider: invalid input")
	previous := layout.widget
	layout.widget = debug_tab_widget_value(layout.current_tab, key) - 1
	changed := _debug_slider(layout, label, target, minimum, maximum, step)
	layout.widget = previous
	return changed
}

debug_panel_extension_checkbox :: proc(
	extension: ^Debug_Panel_Extension_Context,
	key: u32,
	label: string,
	target: ^bool,
) -> bool {
	layout := _debug_extension_layout(extension)
	assert(key > 0 && target != nil, "debug extension checkbox: invalid input")
	previous := layout.widget
	layout.widget = debug_tab_widget_value(layout.current_tab, key) - 1
	changed := _debug_checkbox(layout, label, target)
	layout.widget = previous
	return changed
}

debug_panel_extension_button :: proc(
	extension: ^Debug_Panel_Extension_Context,
	key: u32,
	label: string,
) -> bool {
	layout := _debug_extension_layout(extension)
	assert(key > 0 && label != "", "debug extension button: invalid input")
	previous := layout.widget
	layout.widget = debug_tab_widget_value(layout.current_tab, key) - 1
	pressed := _debug_button(layout, label)
	layout.widget = previous
	return pressed
}

// _debug_breadcrumb draws the scope title row plus a Back button when scoped.
@(private = "file")
_debug_breadcrumb :: proc(layout: ^_Debug_Layout) {
	value := layout.value
	height := ui_px(value.ui_scale, DEBUG_HEADER_HEIGHT)
	rect, visible := _debug_row_rect(layout, height)
	defer {
		_debug_advance(layout, height)
	}
	title: string
	switch value.debug.target.kind {
	case .World:
		title = "DEBUG  world"
	case .Entity:
		title = fmt.tprintf("DEBUG  world > entity #%d", value.debug.target.entity.entity.index)
	case .Flora_Item:
		title = fmt.tprintf("DEBUG  world > flora #%d", value.debug.target.flora_index)
	case .Surface:
		ref := value.debug.target.surface.terrain
		title = fmt.tprintf("DEBUG  world > %v %d,%d", value.debug.target.surface.kind, ref.chunk_x, ref.chunk_y)
	}
	if !visible do return
	text_y := rect.y + (height - fit.Text_Size(layout.surface, .Note)) / 2
	back_width := i32(0)
	if value.debug.target.kind != .World {
		back_width = ui_px(value.ui_scale, 64)
		back := fit.Rect{rect.x + rect.w - back_width, rect.y, back_width, height}
		cursor_target_register(value, layout.surface, back)
		if fit.Surface_Button(
			layout.surface,
			fit.Widget_Id_From_String("debug.back"),
			"Back",
			back,
			.Secondary,
		) {
			if debug_pinned_context {
				value.debug.open = false
			} else {
				value.debug.target = debug_target_world()
				value.debug.scope_flash_elapsed = 0
				value.debug.scroll = 0
			}
		}
	}
	fit.Text_Truncated(layout.surface, title, rect.x, text_y, rect.w - back_width, .Note, .Tool)
	animation := debug_animation_sample(
		value.debug.animation_elapsed,
		value.debug.scope_flash_elapsed,
		value.debug.caret_elapsed,
	)
	if animation.scope_flash > 0 {
		color := UI_AMBER
		color.a = u8(255 * animation.scope_flash)
		underline_y := f32(rect.y + rect.h - 1)
		underline_width := f32(max((rect.w - back_width) / 3, 1))
		fit.Line(
			layout.surface,
			{f32(rect.x), underline_y},
			{f32(rect.x) + underline_width, underline_y},
			f32(max(ui_px(value.ui_scale, 2), 1)),
			fit.Color(color),
		)
	}
}

// --- world scope ------------------------------------------------------------

@(private = "file")
_debug_world_scope :: proc(layout: ^_Debug_Layout) {
	value := layout.value
	if _debug_section(layout, .World) {
		_debug_readout(layout, "seed", fmt.tprintf("%d", value.world.foundation.seed))
		_debug_readout(layout, "tick", fmt.tprintf("%d", value.tick))
		_debug_readout(layout, "world / regeneration", fmt.tprintf("%v / %v", value.world_ready, value.regenerate_pending))
		_debug_readout(
			layout,
			"entities / buildings / nodes",
			fmt.tprintf("%d / %d / %d", len(value.world.entities_by_net_id), ecs.set_len(&value.world.buildings), ecs.set_len(&value.world.nodes)),
		)
		if _debug_button(layout, "Regenerate (same seed)") {
			debug_apply(value, .World_Regenerate)
		}
		if _debug_button(layout, "Regenerate (random seed)") {
			value.regenerate_seed = rand.uint64()
			value.regenerate_pending = true
		}
		if _debug_tier(layout, .Advanced) {
			_debug_readout(layout, "foundation profile", fmt.tprintf("%d", shared.TERRAIN_PROFILE_ID))
			_debug_readout(layout, "regeneration seed", fmt.tprintf("%d", value.regenerate_seed))
			_debug_readout(layout, "grid cell size", fmt.tprintf("%.1f", shared.GRID_CELL_SIZE))
			_debug_readout(layout, "world half size", fmt.tprintf("%.0f", shared.WORLD_HALF_SIZE))
		}
	}
	if _debug_section(layout, .Weather) {
		_debug_atmosphere_rows(layout)
		summary := shared.world_planetary_summary(&value.world)
		_debug_readout(
			layout,
			"temperature",
			fmt.tprintf("%.2f K", f32(summary.temperature_mk) / 1000),
		)
		_debug_readout(layout, "pressure", fmt.tprintf("%d Pa", summary.pressure_pa))
		_debug_readout(
			layout,
			"humidity / rain",
			fmt.tprintf("%d / %d", summary.humidity, summary.precipitation),
		)
		_debug_readout(layout, "mean wind", fmt.tprintf("%d", summary.wind_speed))
		if _debug_tier(layout, .Advanced) {
			_debug_readout(layout, "surface / benthic PAR", fmt.tprintf("%d / %d", summary.surface_par, summary.benthic_par))
			_debug_readout(layout, "oxygenated / anoxic", fmt.tprintf("%d / %d", summary.oxygenated, summary.anoxic))
			_debug_readout(layout, "diagnostic steps", fmt.tprintf("%d", summary.diagnostic_steps))
		}
	}
	if _debug_section(layout, .Terrain) {
		terrain := &value.terrain
		_debug_readout(layout, "ready / modified", fmt.tprintf("%v / %v", terrain.ready, value.world.heightfield.modified))
		_debug_readout(layout, "sea / snow level", fmt.tprintf("%.2f / %.2f", terrain.sea_level, terrain.snow_level))
		summary := shared.world_planetary_summary(&value.world)
		_debug_readout(layout, "crust / heat", fmt.tprintf("%d ka / %d mWm2", summary.crust_age_ka, summary.heat_flux_mw_m2))
		_debug_readout(layout, "volcanoes / active vents", fmt.tprintf("%d / %d", summary.volcanoes, summary.vents))
		if _debug_tier(layout, .Advanced) {
			_debug_readout(layout, "dormant / extinct vents", fmt.tprintf("%d / %d", summary.dormant_vents, summary.extinct_vents))
		}
		if _debug_tier(layout, .Advanced) {
			when ODIN_OS != .JS {
				_debug_readout(layout, "bake workers", fmt.tprintf("%d", terrain_bake_worker_count()))
			}
			_debug_readout(layout, "lod levels", fmt.tprintf("%d", TERRAIN_LOD_COUNT))
		}
	}
	if _debug_section(layout, .Entities) {
		if _debug_slider(
			layout,
			"density scale",
			&debug_tuning.flora_density_scale,
			0,
			DEBUG_FLORA_DENSITY_MAX,
			0.05,
		) {
			debug_apply(value, .Flora_Regenerate)
			settings_save(value)
		}
		counts := flora_counts(&value.flora)
		_debug_readout(
			layout,
			"trees",
			fmt.tprintf("%d conifer  %d broadleaf", counts.conifers, counts.broadleaf),
		)
		_debug_readout(
			layout,
			"ground",
			fmt.tprintf(
				"%d grass  %d boulder  %d scree",
				counts.grass,
				counts.boulders,
				counts.scree,
			),
		)
		_debug_readout(layout, "hidden", fmt.tprintf("%d", counts.hidden))
		if _debug_button(layout, "Regenerate flora") {
			debug_apply(value, .Flora_Regenerate)
		}
		if _debug_button(layout, "Clear trees") {
			_ = flora_clear_trees(&value.flora)
		}
	}
	if _debug_section(layout, .Water) {
		summary := shared.world_planetary_summary(&value.world)
		_debug_readout(layout, "settled / revision", fmt.tprintf("%v / %d", value.world.waterfield.settled, value.world.waterfield.revision))
		_debug_readout(layout, "rebuild pending", fmt.tprintf("%v", value.terrain.water_dirty))
		_debug_readout(layout, "mean current / tide / waves", fmt.tprintf("%d / %d / %d mm", summary.current_speed, summary.tide_mm, summary.wave_height_mm))
		if _debug_button(layout, "Rebuild water mesh") {
			debug_apply(value, .Water_Rebuild)
		}
	}
	extension := Debug_Panel_Extension_Context {
		layout = rawptr(layout),
	}
	debug_panel_world_extension(value, &extension)
	if _debug_section(layout, .Camera) {
		_debug_readout(layout, "distance", fmt.tprintf("%.1f", value.orbit.distance))
		_debug_readout(layout, "surface altitude", fmt.tprintf("%.1f", value.camera_visual.surface_altitude))
		_ = _debug_slider(layout, "fov", &value.camera.fovy, 20, 100, 1)
		_debug_readout(layout, "pitch / yaw", fmt.tprintf("%.2f / %.2f", value.orbit.pitch, value.orbit.yaw))
		if _debug_tier(layout, .Advanced) {
			_ = _debug_slider(layout, "far plane", &value.camera.far_plane, 200, 20000, 100)
			_ = _debug_slider(layout, "min distance", &value.orbit_config.min_distance, 1, 100, 1)
			_ = _debug_slider(layout, "max distance", &value.orbit_config.max_distance, 50, 10000, 10)
			_ = _debug_slider(layout, "pan speed", &value.orbit_config.pan_speed, 0.1, 5, 0.1)
			_ = _debug_slider(layout, "rotate speed", &value.orbit_config.rotate_speed, 0.1, 5, 0.1)
		_debug_readout(
			layout,
			"altitude / coverage",
			fmt.tprintf(
				"%.1f / %.3f",
				value.camera_visual.surface_altitude,
				value.camera_visual.coverage,
			),
		)
		_debug_readout(
			layout,
			"projection scale",
			fmt.tprintf("%.1f", value.camera_visual.projection_scale),
		)
		_debug_readout(
			layout,
			"close / regional / overview",
			fmt.tprintf(
				"%.3f / %.3f / %.3f",
				value.camera_visual.close_weight,
				value.camera_visual.regional_weight,
				value.camera_visual.overview_weight,
			),
		)
		}
	}
	if _debug_section(layout, .Hud) {
		if _debug_checkbox(layout, "hud text", &value.show_hud_text) do settings_save(value)
		if _debug_checkbox(layout, "fps counter", &value.show_fps) do settings_save(value)
		if _debug_checkbox(layout, "profiler overlay", &value.profiler.visible) {
			settings_save(value)
		}
		_debug_readout(
			layout,
			"profile / renderer stats",
			fmt.tprintf("%v / %v", PROFILE_ENABLED, DEBUG_RENDER_STATS_ENABLED),
		)
		when PROFILE_ENABLED {
			total := profile_summary(
				value.profiler.totals[:],
				value.profiler.filled,
				value.profiler.frame,
			)
			_debug_readout(
				layout,
				"frame last / mean / peak",
				fmt.tprintf("%.2f / %.2f / %.2f ms", total.last, total.mean, total.peak),
			)
		}
		stats := rl.renderer_stats()
		_debug_readout(
			layout,
			"draws / instanced",
			fmt.tprintf("%d / %d", stats.gpu3d_draws, stats.gpu3d_instanced_draws),
		)
		_debug_readout(
			layout,
			"vertices / passes",
			fmt.tprintf("%d / %d", stats.gpu3d_vertices_drawn, stats.render_passes),
		)
	}
}

// _debug_atmosphere_rows: every field is live state the renderer reads each
// frame, so edits show up on the next frame with no apply step. Presets go
// through atmosphere_apply_preset, which preserves the GPU handles.
@(private = "file")
_debug_atmosphere_rows :: proc(layout: ^_Debug_Layout) {
	value := layout.value
	atmosphere := &value.atmosphere
	effective_bloom := atmosphere.bloom_strength
	when ODIN_OS == .JS {
		effective_bloom = 0
	}
	if !atmosphere.post_ready || atmosphere.quality == .Low do effective_bloom = 0
	_debug_readout(layout, "quality", fmt.tprintf("%v", atmosphere.quality))
	_debug_readout(layout, "ready", fmt.tprintf("%v", atmosphere.ready))
	_debug_readout(
		layout,
		"sky / object / post ready",
		fmt.tprintf(
			"%v / %v / %v",
			atmosphere.sky_ready,
			atmosphere.object_ready,
			atmosphere.post_ready,
		),
	)
	_debug_readout(layout, "effective bloom", fmt.tprintf("%.3f", effective_bloom))
	// Preset dropdown row.
	widget := _debug_widget_next(layout)
	if _debug_matches(layout, "preset", "Clear Dusk Dark Overcast Heavy Fog Orbital Day") {
		height := ui_px(value.ui_scale, DEBUG_ROW_HEIGHT)
		rect, visible := _debug_row_rect(layout, height)
		_debug_advance(layout, height)
		if visible {
			control_width := ui_px(value.ui_scale, DEBUG_CONTROL_WIDTH)
			text_y := rect.y + (height - fit.Text_Size(layout.surface, .Note)) / 2
			fit.Text(layout.surface, "preset", rect.x, text_y, .Note, .Label)
			items := []string{"Clear Dusk", "Dark Overcast", "Heavy Fog", "Orbital Day"}
			selected := i32(atmosphere.preset)
			dropdown := fit.Rect{rect.x + rect.w - control_width, rect.y, control_width, height}
			if fit.Surface_Dropdown(
				layout.surface,
				widget,
				items,
				&selected,
				&value.debug.preset_dropdown,
				dropdown,
				a11y_label = "Atmosphere preset",
			) {
				atmosphere_apply_preset(atmosphere, Atmosphere_Preset(selected))
			}
		}
	}
	_ = _debug_slider(layout, "sun intensity", &atmosphere.sun_intensity, 0, 2, 0.01)
	_ = _debug_slider(layout, "ambient", &atmosphere.ambient_intensity, 0, 1, 0.01)
	_ = _debug_slider(layout, "exposure", &atmosphere.exposure, 0.2, 2.5, 0.01)
	_ = _debug_slider(layout, "vibrance", &atmosphere.vibrance, 0.5, 1.8, 0.01)
	_ = _debug_slider(layout, "contrast", &atmosphere.contrast, 0.7, 1.5, 0.01)
	_ = _debug_slider(layout, "bloom strength", &atmosphere.bloom_strength, 0, 0.4, 0.01)
	_ = _debug_slider(layout, "bloom threshold", &atmosphere.bloom_threshold, 0.5, 1.5, 0.01)
	_debug_readout(layout, "overview", fmt.tprintf("%.3f", atmosphere.overview_weight))
	_ = _debug_slider(layout, "fog density", &atmosphere.fog_density, 0, 0.05, 0.0005)
	_ = _debug_slider(layout, "fog falloff", &atmosphere.fog_height_falloff, 0, 0.3, 0.005)
	_ = _debug_slider(layout, "fog base height", &atmosphere.fog_base_height, -50, 100, 1)
	_ = _debug_slider(layout, "fog color r", &atmosphere.fog_color.x, 0, 1, 0.01)
	_ = _debug_slider(layout, "fog color g", &atmosphere.fog_color.y, 0, 1, 0.01)
	_ = _debug_slider(layout, "fog color b", &atmosphere.fog_color.z, 0, 1, 0.01)
	_ = _debug_slider(layout, "cloud coverage", &atmosphere.cloud_coverage, 0, 1, 0.01)
	_ = _debug_slider(layout, "cloud speed", &atmosphere.cloud_speed, 0, 2, 0.01)
	sun_changed := _debug_slider(layout, "sun dir x", &atmosphere.sun_direction.x, -1, 1, 0.01)
	sun_changed |= _debug_slider(layout, "sun dir y", &atmosphere.sun_direction.y, -1, 1, 0.01)
	sun_changed |= _debug_slider(layout, "sun dir z", &atmosphere.sun_direction.z, -1, 1, 0.01)
	if sun_changed {
		direction := atmosphere.sun_direction
		length := math.sqrt(
			direction.x * direction.x + direction.y * direction.y + direction.z * direction.z,
		)
		// Renormalized only above a floor: the shadow projection expects a
		// unit sun, but a slider passing through zero must not divide by it.
		if length > 0.05 do atmosphere.sun_direction = direction / length
	}
	if _debug_button(layout, "Reset atmosphere to preset") {
		atmosphere_apply_preset(atmosphere, atmosphere.preset)
	}
}

// --- entity scope -----------------------------------------------------------

@(private = "file")
_debug_entity_scope :: proc(layout: ^_Debug_Layout, ref: Debug_Entity_Ref) {
	value := layout.value
	visible := _debug_section(layout, .Entities)
	entity := ref.entity
	if resolved, ok := shared.world_entity_by_net_id(&value.world, ref.net_id); ok {
		entity = resolved
	}
	if !ecs.is_alive(&value.world.pool, entity) {
		if visible do _debug_readout(layout, "entity", "destroyed")
		return
	}
	if visible do _debug_readout(layout, "entity", fmt.tprintf("#%d gen %d", entity.index, entity.generation))
	if transform, ok := ecs.get(&value.world.transforms, entity); ok && visible {
		_debug_readout(
			layout,
			"position",
			fmt.tprintf(
				"%.1f  %.1f  %.1f",
				transform.position.x,
				transform.position.y,
				transform.position.z,
			),
		)
		if _debug_button(layout, "Focus camera") {
			value.orbit.target = transform.position
		}
	}
	extension := Debug_Panel_Extension_Context{layout = rawptr(layout)}
	debug_panel_entity_extension(value, &extension, entity)
}

// --- flora scope ------------------------------------------------------------

@(private = "file")
_debug_flora_scope :: proc(layout: ^_Debug_Layout, index: int) {
	value := layout.value
	if !_debug_section(layout, .Entities) do return
	if index < 0 || index >= FLORA_MAX {
		_debug_readout(layout, "flora", "instance gone")
		return
	}
	instance := &value.flora.instances[index]
	_debug_readout(layout, "instance", fmt.tprintf("#%d", index))
	_debug_readout(layout, "mesh", fmt.tprintf("%v", instance.mesh))
	_debug_readout(
		layout,
		"position",
		fmt.tprintf(
			"%.1f  %.1f  %.1f",
			instance.position.x,
			instance.position.y,
			instance.position.z,
		),
	)
	_debug_slider(layout, "scale", &instance.scale, 0.1, 5, 0.05)
	if _debug_slider(layout, "yaw", &instance.yaw, 0, 2 * math.PI, 0.05) {
		instance.cos_yaw = math.cos(instance.yaw)
		instance.sin_yaw = math.sin(instance.yaw)
	}
	hidden := instance.hidden
	if _debug_checkbox(layout, "hidden", &hidden) do instance.hidden = hidden
}

// --- terrain scope ----------------------------------------------------------

@(private = "file")
_debug_terrain_scope :: proc(layout: ^_Debug_Layout, surface: Debug_Surface_Ref) {
	value := layout.value
	visible := _debug_section(layout, .Terrain)
	ref := surface.terrain
	if !ref.valid {
		if visible do _debug_readout(layout, "terrain", "no chunk located")
		return
	}
	if visible {
		_debug_readout(layout, "location", fmt.tprintf("face %d / cell %d,%d", ref.face, ref.grid_x, ref.grid_y))
		_debug_readout(layout, "elevation / biome", fmt.tprintf("%.2f m / %v", ref.height, ref.biome))
		if _debug_tier(layout, .Advanced) {
			_debug_readout(layout, "patch", fmt.tprintf("%d, %d", ref.chunk_x, ref.chunk_y))
			_debug_readout(layout, "world X", fmt.tprintf("%.2f", ref.point.x))
			_debug_readout(layout, "world Y", fmt.tprintf("%.2f", ref.point.y))
			_debug_readout(layout, "world Z", fmt.tprintf("%.2f", ref.point.z))
		}
	}
	extension := Debug_Panel_Extension_Context {
		layout = rawptr(layout),
	}
	debug_panel_terrain_extension(value, &extension, ref)
	if visible {
		_debug_tab_enter(layout, debug_tab_category(.Terrain))
		if _debug_button(layout, "Remesh chunk") {
			debug_terrain_remesh(value, ref)
		}
		if _debug_tier(layout, .Advanced) && _debug_button(layout, "Re-locate at hit point") {
			if located, ok := debug_terrain_locate(value, ref.point); ok {
				value.debug.target = debug_target_surface(surface.kind, located)
			}
		}
	}
}
