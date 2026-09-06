// highlight.odin renders the placement grid: a 3x3 neighbourhood of
// terrain-conforming tiles centred on the hovered cell, green where a
// building may be placed and red where placement would be refused. Validity
// rides the per-vertex scalar so the whole grid is one mesh and one draw.
// In terraform mode the same mesh shows the 5x5 mound footprint tinted by
// sculpt direction; the mesh is sized for 5x5 and build mode collapses the
// outer ring to degenerate vertices.
package main

import shared "../shared"
import "core:math"
import ecs "ingot:ecs"
import rl "ingot:gfx"

// Cells each side of the hover cell; 4 gives a 9x9 grid, which matches the
// largest selectable terraform brush (TERRAFORM_RADIUS_MAX) and is the mesh
// capacity. Smaller brushes and build mode collapse the cells outside their
// own footprint to degenerate vertices, so the mesh, the index buffer, and
// the draw count never change with the brush.
HIGHLIGHT_EXTENT :: i32(4)
#assert(HIGHLIGHT_EXTENT >= shared.TERRAFORM_RADIUS_MAX)
HIGHLIGHT_SPAN :: int(2 * HIGHLIGHT_EXTENT + 1)
// Quads per cell edge; 4x4 sub-quads let each tile hug the bilinear terrain.
HIGHLIGHT_SUBDIV :: 4
HIGHLIGHT_CELL_VERTS :: (HIGHLIGHT_SUBDIV + 1) * (HIGHLIGHT_SUBDIV + 1)
HIGHLIGHT_CELL_INDICES :: HIGHLIGHT_SUBDIV * HIGHLIGHT_SUBDIV * 6
HIGHLIGHT_VERTS :: HIGHLIGHT_SPAN * HIGHLIGHT_SPAN * HIGHLIGHT_CELL_VERTS
HIGHLIGHT_INDICES :: HIGHLIGHT_SPAN * HIGHLIGHT_SPAN * HIGHLIGHT_CELL_INDICES
// Tile fill fraction; the uncovered margin reads as grid lines.
HIGHLIGHT_INSET :: f32(0.88)
// Lift above the sampled surface so tiles never z-fight the terrain.
HIGHLIGHT_LIFT :: f32(0.06)

Highlight_Key :: struct {
	mode:              Mode,
	kind:              shared.Building_Kind,
	// radius is part of the key because the lit footprint changes with the
	// brush; without it, resizing the brush would leave the previous
	// footprint on screen until the pointer moved.
	radius:            i32,
	center_x:          i32,
	center_y:          i32,
	place_x:           i32,
	place_y:           i32,
	heights_revision:  u64,
	water_revision:    u64,
	world_fingerprint: u64,
}

Highlight :: struct {
	mesh:    rl.Gpu_Mesh,
	scratch: [HIGHLIGHT_VERTS]rl.Gpu_3D_Vertex,
	// Cache key of the last uploaded grid; matching frames skip both the
	// 625-sample height rebuild and the GPU vertex upload.
	key:     Highlight_Key,
	cached:  bool,
	visible: bool,
}

// highlight_init creates the mesh once with a static index buffer; vertices
// are re-uploaded every frame from the scratch buffer.
highlight_init :: proc(value: ^Client_State) -> bool {
	assert(value != nil, "highlight_init: nil state")
	// graphics_create retries every loading frame; the fixed-topology mesh
	// only needs to exist once.
	if value.highlight.mesh.id != 0 do return true
	indices: [HIGHLIGHT_INDICES]u32
	cursor := 0
	for cell in 0 ..< HIGHLIGHT_SPAN * HIGHLIGHT_SPAN {
		base := u32(cell * HIGHLIGHT_CELL_VERTS)
		for row in 0 ..< HIGHLIGHT_SUBDIV {
			for column in 0 ..< HIGHLIGHT_SUBDIV {
				corner := base + u32(row * (HIGHLIGHT_SUBDIV + 1) + column)
				stride := u32(HIGHLIGHT_SUBDIV + 1)
				indices[cursor + 0] = corner
				indices[cursor + 1] = corner + 1
				indices[cursor + 2] = corner + stride + 1
				indices[cursor + 3] = corner
				indices[cursor + 4] = corner + stride + 1
				indices[cursor + 5] = corner + stride
				cursor += 6
			}
		}
	}
	assert(cursor == HIGHLIGHT_INDICES, "highlight_init: index count mismatch")
	mesh, ok := rl.create_gpu_mesh(value.highlight.scratch[:], indices[:], .Triangles)
	if !ok do return false
	if value.highlight.mesh.id != 0 do rl.destroy_gpu_mesh(&value.highlight.mesh)
	value.highlight.mesh = mesh
	return true
}

// highlight_update rebuilds the conforming tiles around the hover (or sculpt
// anchor) cell. Scalar 0 marks a placeable cell, 1 a refused one; terraform
// mode zeroes every scalar and lets the material tint carry the meaning. In
// build mode the window centers on the armed footprint and only its cells
// are live, so the preview always shows the exact area the building covers.
highlight_update :: proc(value: ^Client_State) {
	assert(value != nil, "highlight_update: nil state")
	value.highlight.visible = false
	if !value.terrain.ready do return
	// Inspect mode shows no grid at all.
	if value.mode == .Inspect do return
	if !value.hover_valid && !value.sculpt_active do return
	foot_w, foot_h := shared.building_footprint(value.selected_kind)
	center_x := value.hover_x
	center_y := value.hover_y
	if value.mode == .Build {
		center_x = value.place_x + (foot_w - 1) / 2
		center_y = value.place_y + (foot_h - 1) / 2
	}
	if value.mode == .Terraform && value.sculpt_active {
		center_x = value.sculpt_x
		center_y = value.sculpt_y
	}
	cell := shared.GRID_CELL_SIZE
	half := cell * HIGHLIGHT_INSET / 2
	step := cell * HIGHLIGHT_INSET / f32(HIGHLIGHT_SUBDIV)
	key := Highlight_Key {
		mode              = value.mode,
		kind              = value.selected_kind,
		radius            = value.terraform_radius,
		center_x          = center_x,
		center_y          = center_y,
		place_x           = value.place_x,
		place_y           = value.place_y,
		heights_revision  = value.terrain.heights_revision,
		water_revision    = value.world.waterfield.revision,
		world_fingerprint = value.queries.fingerprint,
	}
	if value.highlight.cached && key == value.highlight.key {
		value.highlight.visible = true
		return
	}
	harvest_kind, harvests := shared.building_harvests(value.selected_kind)
	write := 0
	for offset_y in -HIGHLIGHT_EXTENT ..= HIGHLIGHT_EXTENT {
		for offset_x in -HIGHLIGHT_EXTENT ..= HIGHLIGHT_EXTENT {
			grid_x := center_x + offset_x
			grid_y := center_y + offset_y
			// Terraform lights exactly the selected brush's extent; build
			// mode lights exactly the footprint rect. Cells outside collapse
			// to a single point far below the world; zero-area triangles
			// rasterise nothing, so the fixed-size mesh and index buffer stay
			// untouched whatever the brush.
			live := true
			if value.mode == .Build {
				live =
					grid_x >= value.place_x &&
					grid_x < value.place_x + foot_w &&
					grid_y >= value.place_y &&
					grid_y < value.place_y + foot_h
			} else if value.mode == .Terraform {
				radius := value.terraform_radius
				live = abs(offset_x) <= radius && abs(offset_y) <= radius
			}
			if !live {
				for _ in 0 ..< HIGHLIGHT_CELL_VERTS {
					value.highlight.scratch[write] = {
						position = {0, 0, -1000},
						normal   = {0, 0, 1},
					}
					write += 1
				}
				continue
			}
			scalar := f32(0)
			if value.mode != .Terraform {
				allowed := shared.placement_allowed(&value.world, grid_x, grid_y, value.hover_face)
				_, occupied := building_at(value, grid_x, grid_y)
				if !allowed || occupied do scalar = 1
				// Node cells refuse everything but the matching harvester.
				if node_entity, node_found := shared.node_at_cell(&value.world, grid_x, grid_y, value.hover_face);
				   node_found {
					node, has_node := ecs.get(&value.world.nodes, node_entity)
					if !has_node || !harvests || node.kind != harvest_kind do scalar = 1
				}
			}
			origin_x := f32(grid_x) * cell - half
			origin_y := f32(grid_y) * cell - half
			for row in 0 ..= HIGHLIGHT_SUBDIV {
				for column in 0 ..= HIGHLIGHT_SUBDIV {
					world_x := origin_x + f32(column) * step
					world_y := origin_y + f32(row) * step
					ground := terrain_height_cached(&value.terrain, world_x, world_y)
					value.highlight.scratch[write] = {
						position = {world_x, world_y, ground + HIGHLIGHT_LIFT},
						normal   = {0, 0, 1},
						scalar   = scalar,
					}
					write += 1
				}
			}
		}
	}
	assert(write == HIGHLIGHT_VERTS, "highlight_update: vertex count mismatch")
	if !rl.update_gpu_mesh_vertices(value.highlight.mesh, value.highlight.scratch[:]) do return
	value.highlight.key = key
	value.highlight.cached = true
	value.highlight.visible = true
}

// highlight_draw draws the grid with a gentle alpha pulse. Build mode blends
// green (scalar 0) to red (scalar 1) per cell; terraform mode tints the whole
// footprint by the armed tool, turns danger-red when the command would be
// refused, and fades toward neutral as the centre delta nears its clamp.
highlight_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	assert(value != nil, "highlight_draw: nil state")
	assert(pass != nil, "highlight_draw: nil pass")
	if !value.highlight.visible do return
	alpha := u8(140 + 35 * math.sin(value.cursor.time * 4))
	material: rl.Gpu_Material
	if value.mode == .Terraform {
		// The tint follows the armed tool so the footprint shows what the
		// brush will do before the press; it matches cursor_color exactly.
		tint := UI_TERRAFORM_NEUTRAL
		switch value.terraform_tool {
		case .Raise:
			tint = UI_TERRAFORM_RAISE
		case .Lower:
			tint = UI_TERRAFORM_LOWER
		case .Level:
			tint = UI_TERRAFORM_LEVEL
		}
		// At the clamp the brush silently stops moving ground. Fading the
		// tint toward neutral as the delta saturates is what turns that
		// from "the game stopped responding" into "this cell is done".
		tint = _highlight_desaturate(tint, terraform_saturation(value))
		// A refusal outranks every other tint: the player needs to know the
		// click will do nothing before spending it.
		if terraform_would_be_refused(value) do tint = UI_DANGER
		tint.a = alpha
		material = {
			color = tint,
		}
	} else {
		valid := UI_PLACE_VALID
		invalid := UI_PLACE_INVALID
		valid.a = alpha
		invalid.a = alpha
		material = {
			color      = valid,
			color_high = invalid,
			use_scalar = true,
		}
	}
	rl.draw_gpu_mesh(&pass^, value.highlight.mesh, rl.Matrix(1), material)
	// Crisp frame spanning the committed footprint (build) or the brush
	// extent (terraform), kept from the old marker.
	cell := shared.GRID_CELL_SIZE
	frame_x := value.hover_x
	frame_y := value.hover_y
	span_w := f32(1)
	span_h := f32(1)
	frame_world_x := f32(frame_x) * cell
	frame_world_y := f32(frame_y) * cell
	if value.mode == .Build {
		foot_w, foot_h := shared.building_footprint(value.selected_kind)
		span_w = f32(foot_w)
		span_h = f32(foot_h)
		frame_world_x = (f32(value.place_x) + f32(foot_w - 1) / 2) * cell
		frame_world_y = (f32(value.place_y) + f32(foot_h - 1) / 2) * cell
	}
	if value.mode == .Terraform {
		// The frame reports the brush, not the cell: without this a 9x9
		// brush looked identical to a 1x1 until the ground moved.
		span := f32(shared.terraform_cell_span(value.terraform_radius))
		span_w = span
		span_h = span
		if value.sculpt_active {
			frame_world_x = f32(value.sculpt_x) * cell
			frame_world_y = f32(value.sculpt_y) * cell
		}
	}
	ground := terrain_height_cached(&value.terrain, frame_world_x, frame_world_y)
	transform :=
		rl.MatrixTranslate(frame_world_x, frame_world_y, ground + HIGHLIGHT_LIFT) *
		rl.MatrixScale(cell * span_w, cell * span_h, 0.1)
	rl.draw_gpu_mesh(&pass^, value.cube_edges, transform, {color = UI_SELECTED_OUTLINE})
}

// _highlight_desaturate blends a tint toward the neutral survey colour.
// Pure, so the saturation feedback can be reasoned about without a GPU.
@(private = "file")
_highlight_desaturate :: proc(color: rl.Color, amount: f32) -> rl.Color {
	assert(amount >= 0 && amount <= 1, "_highlight_desaturate: amount out of range")
	blend :: proc(from, to: u8, amount: f32) -> u8 {
		mixed := f32(from) + (f32(to) - f32(from)) * amount
		return u8(clamp(mixed, 0, 255))
	}
	target := UI_TERRAFORM_NEUTRAL
	return {
		blend(color.r, target.r, amount),
		blend(color.g, target.g, amount),
		blend(color.b, target.b, amount),
		color.a,
	}
}
