// inspect_panel.odin renders the selected-building panel docked just above
// the bottom toolbar: a live 3D portrait of the building (rendered from its
// part model into a small offscreen target), the name and level, key stats,
// and the building's options (Upgrade / Tune). The panel joins the toolbar's
// pointer-capture union so clicks on it never leak into world systems.
//
// Layout constants are authored at UI scale 1.0 and converted with ui_px;
// line advances come from fit's text roles rather than being re-declared
// here, because those roles grow with the monitor DPI on Windows.
package main

import shared "../shared"
import "core:fmt"
import "core:math"
import ecs "ingot:ecs"
import fit "ingot:fit"
import rl "ingot:gfx"

PANEL_WIDTH :: i32(380)
PANEL_HEIGHT :: i32(120)
PANEL_PADDING :: i32(10)
// Vertical gap between the panel and the toolbar when the panel must lift
// above it on narrow windows.
PANEL_TOOLBAR_GAP :: i32(8)
PANEL_LINE_GAP :: i32(4)
PANEL_BUTTON_HEIGHT :: i32(30)
PANEL_BUTTON_GAP :: i32(6)
// Slow idle spin of the portrait camera around the model.
PANEL_PORTRAIT_SPIN :: f32(0.5)
// Portrait camera elevation above the model's mid-height.
PANEL_PORTRAIT_ELEVATION :: f32(35.0 * math.PI / 180.0)

// inspect_panel_visible reports whether the panel should draw: a selected
// building exists and terraform mode (which hides selection feedback) is off.
inspect_panel_visible :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "inspect_panel_visible: nil state")
	if value.mode == .Terraform do return false
	if value.selected == ecs.ENTITY_NIL do return false
	return ecs.has(&value.world.buildings, value.selected)
}

// inspect_panel_rect anchors the panel in the bottom-left corner, the
// standard RTS spot for selection info. When the centered toolbar is wide
// enough to reach the corner slot, the panel lifts above the toolbar so the
// two never overlap.
inspect_panel_rect :: proc(value: ^Client_State) -> fit.Rect {
	assert(value != nil, "inspect_panel_rect: nil state")
	toolbar := toolbar_rect(value)
	margin := ui_px(value.ui_scale, TOOLBAR_MARGIN)
	width := ui_px(value.ui_scale, PANEL_WIDTH)
	height := ui_px(value.ui_scale, PANEL_HEIGHT)
	y := rl.GetScreenHeight() - height - margin
	if toolbar.x < margin + width {
		y = toolbar.y - height - ui_px(value.ui_scale, PANEL_TOOLBAR_GAP)
	}
	return fit.Rect{margin, y, width, height}
}

// inspect_panel_contains is the pointer-capture test; always false while the
// panel is hidden so it never swallows input it does not render for.
inspect_panel_contains :: proc(value: ^Client_State, point: rl.Vector2) -> bool {
	assert(value != nil, "inspect_panel_contains: nil state")
	if !inspect_panel_visible(value) do return false
	rect := inspect_panel_rect(value)
	x := i32(point.x)
	y := i32(point.y)
	return x >= rect.x && x < rect.x + rect.w && y >= rect.y && y < rect.y + rect.h
}

// inspect_panel_portrait_render draws the selected building's part model at
// the origin into the portrait target with its own 3D pass; the camera orbits
// slowly for an idle-spin presentation. Must run outside any other 3D pass.
inspect_panel_portrait_render :: proc(value: ^Client_State) {
	assert(value != nil, "inspect_panel_portrait_render: nil state")
	assert(value.graphics_ready, "inspect_panel_portrait_render: graphics not ready")
	building, ok := ecs.get(&value.world.buildings, value.selected)
	if !ok do return

	bounds := building_local_bounds(value, building.kind, building.level)
	size := bounds_size(bounds)
	center := bounds_center(bounds)
	extent := max(size.x, max(size.y, size.z))
	distance := extent * 2.1 + 1.0
	angle := value.cursor.time * PANEL_PORTRAIT_SPIN
	planar := distance * math.cos(PANEL_PORTRAIT_ELEVATION)
	camera := rl.Camera3D {
		position   = {
			math.cos(angle) * planar,
			math.sin(angle) * planar,
			center.z + distance * math.sin(PANEL_PORTRAIT_ELEVATION),
		},
		target     = center,
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 35,
		projection = .PERSPECTIVE,
		near_plane = 0.1,
		far_plane  = 100,
	}
	pass, pass_ok := rl.begin_gpu_3d(&value.portrait_target, camera)
	if !pass_ok do return
	rl.set_gpu_3d_light(&pass, WORLD_LIGHT)
	if building.level == 0 {
		// Mirror the in-world scaffold slab so the portrait matches what the
		// player sees on the terrain.
		footprint := shared.GRID_CELL_SIZE * 0.8
		slab :=
			rl.MatrixTranslate(0, 0, MODEL_SCAFFOLD_HEIGHT / 2) *
			rl.MatrixScale(footprint, footprint, MODEL_SCAFFOLD_HEIGHT)
		rl.draw_gpu_mesh(&pass, value.cylinder, slab, {color = BUILDING_COLORS[building.kind], style = .Opaque})
		rl.draw_gpu_mesh(&pass, value.cube_edges, slab, {color = EDGE_DARK, style = .Opaque_Outline})
	} else {
		model := &BUILDING_MODELS[building.kind]
		transform := _model_transform({}, rl.Matrix(1), model_level_scale(building.level))
		for component_index in 0 ..< model.component_count {
			component := model.components[component_index]
			rl.draw_gpu_mesh(
				&pass,
				structure_mesh(value, component.mesh),
				transform,
				{color = component.color, style = .Opaque},
			)
		}
	}
	rl.end_gpu_3d(&pass)
}

// inspect_panel_frame draws the panel card, the portrait, the title/stat
// lines, and the Upgrade/Tune buttons. Runs in screen space inside the
// session frame, after the world target has been composited.
inspect_panel_frame :: proc(value: ^Client_State, surface: ^fit.Surface) {
	assert(value != nil, "inspect_panel_frame: nil state")
	assert(surface != nil, "inspect_panel_frame: nil surface")
	if !inspect_panel_visible(value) do return
	building, ok := ecs.get(&value.world.buildings, value.selected)
	if !ok do return

	rect := inspect_panel_rect(value)
	panel := fit.Float_Rect{f32(rect.x), f32(rect.y), f32(rect.w), f32(rect.h)}
	ui_panel_draw(value, surface, panel, .Card)
	padding := ui_px(value.ui_scale, PANEL_PADDING)
	line_gap := ui_px(value.ui_scale, PANEL_LINE_GAP)

	// Portrait square on the left, framed with the building's accent color
	// so the panel reads as "this kind is selected" at a glance.
	portrait_size := rect.h - padding * 2
	portrait := rl.Rectangle {
		f32(rect.x + padding),
		f32(rect.y + padding),
		f32(portrait_size),
		f32(portrait_size),
	}
	rl.draw_gpu_3d_target(&value.portrait_target, portrait, rl.WHITE)
	// Near-square frame in the building's accent, matching the panel chrome
	// rather than the rounded card the portrait used to sit in.
	rl.DrawRectangleRoundedLinesEx(portrait, 0.04, 4, 1, BUILDING_COLORS[building.kind])
	portrait_interaction := fit.Interact(
		surface,
		{portrait.x, portrait.y, portrait.width, portrait.height},
	)
	if portrait_interaction.clicked {
		focus_selected_building(value)
	}

	names := BUILDING_NAMES
	construction, constructing := ecs.get(&value.world.constructions, value.selected)
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
	text_x := rect.x + padding + portrait_size + padding
	text_y := rect.y + padding
	// The text column stops at the card's right padding: every line below is
	// truncated to it rather than painting onto the game canvas.
	text_width := max(rect.x + rect.w - padding - text_x, 0)
	fit.Text_Truncated(surface, string(title), text_x, text_y, text_width, .Title, .Heading)
	text_y += fit.Text_Line_Height(surface, .Title) + line_gap

	if constructing {
		progress := fmt.ctprintf("building  %d ticks left", construction.ticks_remaining)
		fit.Text_Truncated(
			surface,
			string(progress),
			text_x,
			text_y,
			text_width,
			.Body,
			.Accent,
		)
		text_y += fit.Text_Line_Height(surface, .Body) + line_gap
	} else if building.level > 0 {
		// Mirror system_production, matching the hover tooltip's yield math.
		kind, base_yield := shared.building_yield_per_tick(building.kind, building.level)
		if base_yield > 0 {
			amount := base_yield * u64(building.efficiency_percent) / 100
			if node, has_node := ecs.get(&value.world.nodes, value.selected);
			   has_node && node.kind == kind {
				amount = amount * u64(node.richness_percent) / 100
			}
			resource_names := RESOURCE_NAMES
			yield_line := fmt.ctprintf("+%d %s / tick", amount, resource_names[kind])
			fit.Text_Truncated(
				surface,
				string(yield_line),
				text_x,
				text_y,
				text_width,
				.Body,
				.Secondary,
			)
			text_y += fit.Text_Line_Height(surface, .Body) + line_gap
		}
	}
	efficiency := fmt.ctprintf("efficiency %d%%", building.efficiency_percent)
	fit.Text_Truncated(surface, string(efficiency), text_x, text_y, text_width, .Body, .Secondary)

	// Options: Upgrade with its cost, and Tune. Both stay clickable in the
	// Ghost style (the sim validates again), matching the build toolbar.
	button_gap := ui_px(value.ui_scale, PANEL_BUTTON_GAP)
	button_height := ui_px(value.ui_scale, PANEL_BUTTON_HEIGHT)
	button_width := (text_width - button_gap) / 2
	button_y := rect.y + rect.h - padding - button_height
	upgrade_label: string = "Upgrade (U)  max"
	upgrade_style: fit.Button_Style = .Ghost
	if !constructing && building.level < shared.MAX_BUILDING_LEVEL {
		cost := shared.building_cost(building.kind, building.level + 1)
		if cost[.Energy] > 0 {
			upgrade_label = fmt.tprintf(
				"Upgrade (U)  %do %de",
				cost[.Ore],
				cost[.Energy],
			)
		} else {
			upgrade_label = fmt.tprintf("Upgrade (U)  %do", cost[.Ore])
		}
		ore, energy := stockpile_amounts(value)
		if cost[.Ore] <= ore && cost[.Energy] <= energy do upgrade_style = .Secondary
	}
	upgrade := fit.Rect{text_x, button_y, button_width, button_height}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("inspect.upgrade"),
		upgrade_label,
		upgrade,
		upgrade_style,
	) {
		upgrade_selected(value)
	}
	tune := fit.Rect {
		text_x + button_width + button_gap,
		button_y,
		button_width,
		button_height,
	}
	if fit.Surface_Button(
		surface,
		fit.Widget_Id_From_String("inspect.tune"),
		"Tune (F)",
		tune,
		.Secondary,
	) {
		tune_selected(value)
	}
}
