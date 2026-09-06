package main

import shared "../shared"
import "core:fmt"
import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"

// Hover tooltip: a floating info card anchored above the building or resource
// node under the cursor, shown after a short dwell so it never strobes while
// sweeping the pointer across the base. Screen-space, drawn last in the HUD.
//
// Spacing constants are authored at UI scale 1.0 and converted with ui_px;
// row heights come from fit's text roles, which already track the monitor
// DPI on Windows.

TOOLTIP_DELAY :: f32(0.35)
TOOLTIP_PADDING :: i32(10)
TOOLTIP_LINE_GAP :: i32(4)
// Screen-space gap between the anchor point and the card's bottom edge.
TOOLTIP_ANCHOR_GAP :: i32(8)
TOOLTIP_MAX_LINES :: 4

BUILDING_NAMES :: [shared.Building_Kind]cstring {
	.Headquarters = "Headquarters",
	.Mine         = "Mine",
	.Solar_Array  = "Solar Array",
	.Habitat      = "Habitat",
}

RESOURCE_NAMES :: [shared.Resource_Kind]cstring {
	.Ore    = "ore",
	.Energy = "energy",
}

NODE_TITLES :: [shared.Resource_Kind]cstring {
	.Ore    = "Ore Deposit",
	.Energy = "Energy Vent",
}

// tooltip_draw renders the hover card for the cached hover entity once the
// dwell delay has elapsed. Skipped during terraform mode and while the left
// button is dragging the camera, when a floating card would just be noise.
// Cards stay visible in build mode: node richness is exactly what placement
// decisions need.
tooltip_draw :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "tooltip_draw: nil state")
	assert(surface != nil, "tooltip_draw: nil surface")
	assert(value.world_ready, "tooltip_draw: world not ready")
	entity := value.hover_entity
	if entity == ecs.ENTITY_NIL do return
	if value.hover_entity_seconds < TOOLTIP_DELAY do return
	if value.mode == .Terraform do return
	if value.ui_pointer_captured do return
	if value.press_active && value.press_drag >= CLICK_SELECT_MAX_DRAG do return
	if ecs.has(&value.world.buildings, entity) {
		_tooltip_building(value, surface, entity)
		return
	}
	if ecs.has(&value.world.nodes, entity) do _tooltip_node(value, surface, entity)
}

_tooltip_building :: proc(value: ^Client_State, surface: ^fit.Surface, entity: ecs.Entity) {
	assert(value != nil, "_tooltip_building: nil state")
	building, has_building := ecs.get(&value.world.buildings, entity)
	if !has_building do return
	if !ecs.has(&value.world.transforms, entity) do return

	names := BUILDING_NAMES
	construction, constructing := ecs.get(&value.world.constructions, entity)
	title: cstring
	if constructing {
		title = fmt.ctprintf(
			"%s  level %d -> %d",
			names[building.kind],
			building.level,
			construction.target_level,
		)
	} else {
		title = fmt.ctprintf("%s  level %d", names[building.kind], building.level)
	}

	lines: [TOOLTIP_MAX_LINES]cstring
	// Rows carry an ink, not a colour. They always did in effect - the old
	// rl.Color array was mapped back to an Ink at the draw call and the
	// colour itself discarded - so naming the ink directly is what lets the
	// palette govern the card instead of two constants nothing painted with.
	inks: [TOOLTIP_MAX_LINES]fit.Ink
	count := 0
	if constructing {
		lines[count] = fmt.ctprintf("building  %d ticks left", construction.ticks_remaining)
		inks[count] = .Tool
		count += 1
	}
	// Mirror system_production: buildings produce at their completed level,
	// scaled by efficiency and (for matching nodes) richness; level 0 idles.
	if building.level > 0 {
		kind, base_yield := shared.building_yield_per_tick(building.kind, building.level)
		if base_yield > 0 {
			amount := base_yield * u64(building.efficiency_percent) / 100
			if node, has_node := ecs.get(&value.world.nodes, entity);
			   has_node && node.kind == kind {
				amount = amount * u64(node.richness_percent) / 100
			}
			resource_names := RESOURCE_NAMES
			lines[count] = fmt.ctprintf("+%d %s / tick", amount, resource_names[kind])
			inks[count] = .Secondary
			count += 1
		}
	}
	lines[count] = fmt.ctprintf("efficiency %d%%", building.efficiency_percent)
	inks[count] = .Secondary
	count += 1
	if !constructing && building.level < shared.MAX_BUILDING_LEVEL {
		cost := shared.building_cost(building.kind, building.level + 1)
		lines[count] = fmt.ctprintf("upgrade: %d ore  %d energy", cost[.Ore], cost[.Energy])
		// Upgrade cost is a number the player has to weigh, so it takes the
		// amber cost channel rather than the neutral body ink.
		inks[count] = .Tool
		count += 1
	}
	assert(count <= TOOLTIP_MAX_LINES, "_tooltip_building: line overflow")

	bounds, has_bounds := building_world_bounds(value, entity)
	if !has_bounds do return
	anchor, has_anchor := entity_tooltip_anchor(value, entity, bounds)
	if !has_anchor do return
	_tooltip_card(value, surface, anchor, title, lines[:count], inks[:count])
}

// _tooltip_node previews what harvesting the deposit would yield: base
// level-1 output of the matching building scaled by richness, mirroring
// system_production at default efficiency.
_tooltip_node :: proc(value: ^Client_State, surface: ^fit.Surface, entity: ecs.Entity) {
	assert(value != nil, "_tooltip_node: nil state")
	node, has_node := ecs.get(&value.world.nodes, entity)
	if !has_node do return
	if !ecs.has(&value.world.transforms, entity) do return

	titles := NODE_TITLES
	title := titles[node.kind]
	harvester: shared.Building_Kind = .Mine if node.kind == .Ore else .Solar_Array
	kind, base_yield := shared.building_yield_per_tick(harvester, 1)
	assert(kind == node.kind, "_tooltip_node: harvester resource mismatch")
	amount := base_yield * u64(node.richness_percent) / 100

	names := BUILDING_NAMES
	resource_names := RESOURCE_NAMES
	lines: [TOOLTIP_MAX_LINES]cstring
	inks: [TOOLTIP_MAX_LINES]fit.Ink
	count := 0
	lines[count] = fmt.ctprintf("richness %d%%", node.richness_percent)
	inks[count] = .Secondary
	count += 1
	lines[count] = fmt.ctprintf(
		"%s here: +%d %s / tick",
		names[harvester],
		amount,
		resource_names[kind],
	)
	inks[count] = .Secondary
	count += 1

	bounds, has_bounds := node_world_bounds(value, entity)
	if !has_bounds do return
	anchor, has_anchor := entity_tooltip_anchor(value, entity, bounds)
	if !has_anchor do return
	_tooltip_card(value, surface, anchor, title, lines[:count], inks[:count])
}

// _tooltip_card measures, clamps, and draws the card above a world anchor.
// Skips when the anchor is behind the camera because GetWorldToScreen has no
// valid projection there.
_tooltip_card :: proc(
	value: ^Client_State,
	surface: ^fit.Surface,
	anchor: [3]f32,
	title: cstring,
	lines: []cstring,
	inks: []fit.Ink,
) {
	assert(value != nil, "_tooltip_card: nil state")
	assert(surface != nil, "_tooltip_card: nil surface")
	assert(len(lines) == len(inks), "_tooltip_card: line/ink mismatch")
	assert(len(lines) <= TOOLTIP_MAX_LINES, "_tooltip_card: line overflow")
	forward := rl.GetCameraForward(value.camera)
	to_anchor := rl.Vector3{anchor.x, anchor.y, anchor.z} - value.camera.position
	if forward.x * to_anchor.x + forward.y * to_anchor.y + forward.z * to_anchor.z <= 0 do return
	screen := rl.GetWorldToScreen({anchor.x, anchor.y, anchor.z}, value.camera)

	width := fit.Text_Width(surface, string(title), .Title)
	for line in lines {
		width = max(width, fit.Text_Width(surface, string(line), .Body))
	}
	padding := ui_px(value.ui_scale, TOOLTIP_PADDING)
	line_gap := ui_px(value.ui_scale, TOOLTIP_LINE_GAP)
	title_advance := fit.Text_Line_Height(surface, .Title) + line_gap
	body_advance := fit.Text_Line_Height(surface, .Body) + line_gap
	card_width := width + padding * 2
	card_height := title_advance + i32(len(lines)) * body_advance - line_gap + padding * 2
	screen_width := rl.GetScreenWidth()
	screen_height := rl.GetScreenHeight()
	x := i32(screen.x) - card_width / 2
	y := i32(screen.y) - card_height - ui_px(value.ui_scale, TOOLTIP_ANCHOR_GAP)
	x = clamp(x, 0, max(screen_width - card_width, 0))
	y = clamp(y, 0, max(screen_height - card_height, 0))

	rect := fit.Float_Rect{f32(x), f32(y), f32(card_width), f32(card_height)}
	ui_panel_draw(value, surface, rect, .Card)
	text_x := x + padding
	text_y := y + padding
	fit.Text(surface, string(title), text_x, text_y, .Title, .Heading)
	text_y += title_advance
	for line, index in lines {
		fit.Text(surface, string(line), text_x, text_y, .Body, inks[index])
		text_y += body_advance
	}
}
