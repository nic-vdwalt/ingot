package main

import "core:math"
import "core:math/linalg"
import shared "../shared"
import rl "ingot:gfx"

MARINE_REPRESENTATIVE_LIMIT :: 256
MARINE_LOCAL_CELL_LIMIT :: 256
MARINE_LOCAL_RINGS :: 4

Marine_Representative :: struct {
	cell, slot, family, clip, phase: int,
	lineage: u32,
	distance: f32,
	position, direction: [3]f32,
	heading, scale, elongation: f32,
}
Marine_Draw_Counts :: struct {
	candidates, submitted, truncated, failures: int,
}
Marine_Render_State :: struct {
	representatives: [MARINE_REPRESENTATIVE_LIMIT]Marine_Representative,
	count: int,
	counts: Marine_Draw_Counts,
}
marine_render_reset :: proc(state: ^Marine_Render_State) { state^ = {} }
marine_local_cells :: proc(neighbours: [][4]u32, start: int) -> (cells: [256]int, count: int) {
	if start < 0 || start >= len(neighbours) do return
	depths: [256]int
	cells[0], count = start, 1
	cursor := 0
	for cursor < count {
		cell, depth := cells[cursor], depths[cursor]
		cursor += 1
		if depth >= MARINE_LOCAL_RINGS do continue
		for target in neighbours[cell] {
			if int(target) >= len(neighbours) do continue
			seen := false
			for existing in cells[:count] do if existing == int(target) do seen = true
			if seen || count == len(cells) do continue
			cells[count], depths[count] = int(target), depth + 1
			count += 1
		}
	}
	return
}
marine_representative_before :: proc(left, right: Marine_Representative) -> bool {
	if left.distance != right.distance do return left.distance < right.distance
	if left.cell != right.cell do return left.cell < right.cell
	if left.lineage != right.lineage do return left.lineage < right.lineage
	return left.slot < right.slot
}
marine_representative_insert :: proc(state: ^Marine_Render_State, candidate: Marine_Representative) {
	state.counts.candidates += 1
	position := state.count
	if position == len(state.representatives) {
		if !marine_representative_before(candidate, state.representatives[position-1]) do return
		position -= 1
	} else do state.count += 1
	for position > 0 && marine_representative_before(candidate, state.representatives[position-1]) {
		state.representatives[position] = state.representatives[position-1]
		position -= 1
	}
	state.representatives[position] = candidate
}
marine_representative_collect :: proc(state: ^Marine_Render_State, world: ^shared.World, focus: [3]f32, visible: bool) {
	marine_render_reset(state)
	if !visible || world == nil || len(world.marine_ecology.cells) != shared.PLANET_SIM_CELL_COUNT do return
	length := linalg.length(focus)
	if length < 0.001 do return
	direction := focus / length
	cells, count := marine_local_cells(world.planetary.grid.neighbours, shared.planetary_sample_index(direction))
	ecology := &world.marine_ecology
	for cell in cells[:count] {
		if !shared.marine_shallow_habitat(shared.ecology_environment_at_cell(world, cell)) do continue
		coord := shared.planet_sim_terrain_coord(shared.planet_sim_coord_for_index(cell))
		for cohort, slot in ecology.cells[cell].cohorts {
			if cohort.mass == 0 || cohort.lineage == 0 || cohort.lineage > ecology.lineage_count || int(cohort.lineage) > len(ecology.lineages) do continue
			traits := ecology.lineages[cohort.lineage-1].traits
			family := int(shared.marine_morphology_family(traits))
			if family < 0 || family >= 4 do continue
			hash := shared.ecology_hash_mix(ecology.seed ~ u64(cell))
			hash = shared.ecology_hash_mix(hash ~ u64(cohort.lineage) << 8 ~ u64(slot))
			offset_x := (f32(hash & 65535)/65535 - 0.5) * f32(shared.PLANET_SIM_TERRAIN_STRIDE)
			offset_y := (f32((hash >> 16) & 65535)/65535 - 0.5) * f32(shared.PLANET_SIM_TERRAIN_STRIDE)
			placed := shared.planet_neighbour_direction(coord, offset_x, offset_y)
			height := shared.terrain_height_at_coord(world, shared.planet_coord_from_direction(placed))
			candidate := Marine_Representative{
				cell = cell, slot = slot, lineage = cohort.lineage, family = family,
				clip = int((hash >> 32) & 1), phase = int((hash >> 33) & 1),
				distance = 1 - linalg.dot(direction, placed), direction = placed,
				position = shared.planet_position(placed, height + 0.015),
				heading = f32((hash >> 40) & 65535)/65535 * 2 * math.PI,
				scale = clamp(f32(traits.adult_mass)/100, 0.35, 2.0),
				elongation = clamp(f32(traits.elongation)/500, 0.5, 2.0),
			}
			marine_representative_insert(state, candidate)
		}
	}
	state.counts.truncated = state.counts.candidates - state.count
}
marine_draw :: proc(value: ^Client_State, pass: ^rl.Gpu_3D_Pass) {
	marine_representative_collect(&value.marine_render, &value.world, value.orbit.target, value.world_ready && planet_stream_visible(value.orbit.distance))
	if !value.marine_assets.ready do return
	state := &value.marine_render
	material := rl.Gpu_Material{color = UI_GLOW, style = .Opaque, shader = value.atmosphere.object_shader}
	for family in 0 ..< 4 do for clip in 0 ..< 2 do for phase in 0 ..< 2 {
		count := 0
		for candidate in state.representatives[:state.count] {
			if candidate.family != family || candidate.clip != clip || candidate.phase != phase do continue
			to_candidate := candidate.position - value.camera.position
			forward := value.camera.target - value.camera.position
			length := linalg.length(forward)
			if length <= 0.001 do continue
			depth := linalg.dot(to_candidate, forward/length)
			radius := candidate.scale * max(candidate.elongation, 1) * 2
			if depth + radius < value.camera.near_plane || depth - radius > value.camera.far_plane do continue
			lateral := max(0, linalg.dot(to_candidate, to_candidate)-depth*depth)
			limit := max(depth, 0)*_view_tan_limit(value.camera.fovy, _view_aspect(&value.target)) + radius
			if lateral > limit*limit do continue
			value.draw_transforms[count] = marine_representative_transform(candidate)
			count += 1
		}
		if count == 0 do continue
		if !marine_clip_sample(&value.marine_assets, family, clip, phase, value.cursor.time) {
			state.counts.failures += 1
			continue
		}
		rl.draw_gpu_mesh_instanced(pass, value.marine_assets.phases[family][clip][phase].mesh, value.draw_transforms[:count], material)
		state.counts.submitted += count
	}
}
marine_representative_transform :: proc(candidate: Marine_Representative) -> rl.Matrix {
	up, east, north := shared.planet_basis(candidate.direction)
	forward := east * math.cos(candidate.heading) + north * math.sin(candidate.heading)
	left := _camera_cross(up, forward)
	return rl.MatrixTranslate(candidate.position.x, candidate.position.y, candidate.position.z) * _frame_matrix(forward, left, up) * rl.MatrixScale(candidate.scale*candidate.elongation, candidate.scale, candidate.scale)
}
