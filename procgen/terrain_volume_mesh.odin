package procgen

import "core:math"
import "ingot:asset"

TERRAIN_VOLUME_VERTICES_PER_CELL_V3 :: 36
TERRAIN_VOLUME_INDICES_PER_CELL_V3 :: 36
// One cell contributes 19 distinct lattice edges under the six-tetrahedron
// decomposition: six from corner 0, six into corner 6, the main diagonal, and
// the six ring edges. Welding keys on the edge, so this -- not three per
// emitted triangle -- is the real vertex ceiling.
TERRAIN_VOLUME_EDGES_PER_CELL_V3 :: 19
// A crossing that lands exactly on a lattice corner coincides with the next
// tetrahedron edge's crossing, so the triangle they span has no area. The
// bound is squared because the test compares squared cross-product length.
TERRAIN_VOLUME_MIN_AREA_V3 :: f32(1.0e-12)
// An empty weld slot. A key is `low << 32 | high` with `low < high`, so zero
// cannot name a real edge and needs no separate occupancy array.
TERRAIN_VOLUME_WELD_EMPTY_V3 :: u64(0)

Terrain_Volume_Request_V3 :: struct {
	origin: [3]f32,
	cells:  [3]int,
	step:   f32,
}

Terrain_Volume_Occupancy_V3 :: enum u8 {
	Empty,
	Solid,
	Mixed,
}

// Terrain_Volume_Result_V3 reports what a chunk turned out to be. An all-air
// or all-solid chunk is the common case in a streaming world, not an error, so
// it must be distinguishable from a rejected recipe or short capacity.
Terrain_Volume_Result_V3 :: struct {
	occupancy:    Terrain_Volume_Occupancy_V3,
	vertex_count: u32,
	index_count:  u32,
}

Terrain_Volume_Buffer_V3 :: struct {
	density_halo: []f32,
	normal_halo:  []asset.Vec3,
	weld_keys:    []u64,
	weld_values:  []u32,
	mesh:         asset.Mesh_Buffer,
}

terrain_volume_requirements_v3 :: proc(
	cells: [3]int,
) -> (
	density_count, vertex_max, index_max, weld_slots: int,
	ok: bool,
) {
	for count in cells {
		if count < 1 || count > TERRAIN_VOLUME_MAX_EDGE_V3 do return 0, 0, 0, 0, false
	}
	density_count = (cells.x + 2) * (cells.y + 2) * (cells.z + 2)
	if density_count > TERRAIN_VOLUME_MAX_SAMPLES_V3 do return 0, 0, 0, 0, false
	cell_count := cells.x * cells.y * cells.z
	vertex_max = cell_count * TERRAIN_VOLUME_EDGES_PER_CELL_V3
	index_max = cell_count * TERRAIN_VOLUME_INDICES_PER_CELL_V3
	weld_slots = _terrain_volume_weld_slots_v3(vertex_max)
	return density_count, vertex_max, index_max, weld_slots, true
}

// terrain_volume_count_v3 samples the field and runs the classification pass
// alone. Callers that stream chunks use it to size the buffers they actually
// need instead of the per-cell worst case, which a typical chunk uses a small
// fraction of. The sampled density is left in `density` for reuse.
terrain_volume_count_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	density: []f32,
) -> (
	vertices, indices: int,
	ok: bool,
) {
	if !terrain_recipe_validate_v3(recipe) do return 0, 0, false
	if !_terrain_volume_request_valid_v3(request) do return 0, 0, false
	density_count, _, _, _, valid := terrain_volume_requirements_v3(request.cells)
	if !valid || len(density) < density_count do return 0, 0, false
	if !_terrain_volume_sample_v3(recipe, request, density[:density_count]) do return 0, 0, false
	vertices, indices = _terrain_volume_count_pass_v3(request, density[:density_count])
	return vertices, indices, true
}

// terrain_volume_occupancy_v3 answers "is this chunk worth meshing" from one
// 2D noise stack per column instead of a full (cells+2)^3 sample pass. Every
// bound it needs is already a recipe field: the overhang term cannot exceed
// overhang_strength times ruggedness, carving cannot exceed
// (1 - cave_threshold) * cave_strength, and floating mass is capped by
// floating_strength * floating_thickness inside its altitude band. The answer
// is conservative -- Mixed never promises a surface, but Empty and Solid are
// certain.
terrain_volume_occupancy_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
) -> (
	Terrain_Volume_Occupancy_V3,
	bool,
) {
	if !terrain_recipe_validate_v3(recipe) do return .Mixed, false
	if !_terrain_volume_request_valid_v3(request) do return .Mixed, false
	_, _, _, _, valid := terrain_volume_requirements_v3(request.cells)
	if !valid do return .Mixed, false
	p := recipe.parameters
	z_low := request.origin.z - request.step
	z_high := request.origin.z + f32(request.cells.z) * request.step
	scale := p.ground_strength / p.surface_softness
	carve_bound := f32(0)
	if p.cave_strength > 0 && p.cave_altitude_min <= z_high && p.cave_altitude_max >= z_low {
		carve_bound = max(1 - p.cave_threshold, 0) * p.cave_strength
	}
	floating_bound := -max(f32)
	float_low := p.floating_altitude_min - p.floating_thickness
	float_high := p.floating_altitude_max + p.floating_thickness
	if p.floating_strength > 0 && float_low <= z_high && float_high >= z_low {
		floating_bound = p.floating_strength * p.floating_thickness
	}
	all_empty, all_solid := true, true
	for y in 0 ..< request.cells.y + 2 {
		world_y := request.origin.y + f32(y - 1) * request.step
		for x in 0 ..< request.cells.x + 2 {
			world_x := request.origin.x + f32(x - 1) * request.step
			ground, ok := _terrain_ground_v3(recipe, world_x, world_y)
			if !ok do return .Mixed, false
			overhang_bound := p.overhang_strength * abs(ground.ruggedness)
			upper := max((ground.height - z_low) * scale + overhang_bound, floating_bound)
			lower := (ground.height - z_high) * scale - overhang_bound - carve_bound
			all_empty = all_empty && upper <= 0
			all_solid = all_solid && lower > 0
			if !all_empty && !all_solid do return .Mixed, true
		}
	}
	if all_empty do return .Empty, true
	if all_solid do return .Solid, true
	return .Mixed, true
}

terrain_generate_volume_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	buffer: ^Terrain_Volume_Buffer_V3,
) -> (
	Terrain_Volume_Result_V3,
	bool,
) {
	if buffer == nil || !terrain_recipe_validate_v3(recipe) do return {}, false
	if !_terrain_volume_request_valid_v3(request) do return {}, false
	density_count, _, _, _, valid := terrain_volume_requirements_v3(request.cells)
	if !valid || len(buffer.density_halo) < density_count do return {}, false
	if len(buffer.normal_halo) < density_count do return {}, false
	density := buffer.density_halo[:density_count]
	if !_terrain_volume_sample_v3(recipe, request, density) do return {}, false
	occupancy := _terrain_volume_uniform_v3(density)
	vertices, indices := _terrain_volume_count_pass_v3(request, density)
	if indices == 0 {
		// No crossing anywhere: the chunk is uniformly air or uniformly rock.
		// Report which and publish zero counts rather than failing, because a
		// streaming world produces far more of these than it does surfaces.
		asset.mesh_reset(&buffer.mesh)
		return {occupancy, 0, 0}, true
	}
	if len(buffer.mesh.vertices) < vertices || len(buffer.mesh.indices) < indices do return {}, false
	slots := _terrain_volume_weld_slots_v3(vertices)
	if len(buffer.weld_keys) < slots || len(buffer.weld_values) < slots do return {}, false
	asset.mesh_reset(&buffer.mesh)
	_terrain_volume_normals_v3(buffer, request, density_count)
	written_vertices, written_indices := _terrain_volume_emit_v3(
		request,
		buffer,
		slots,
		indices,
		recipe.parameters.surface_uv_scale,
	)
	view, ok := asset.mesh_view(&buffer.mesh)
	if !ok || !asset.mesh_validate(view) do return {}, false
	return {occupancy, u32(written_vertices), u32(written_indices)}, true
}

@(private)
_terrain_volume_request_valid_v3 :: proc(request: Terrain_Volume_Request_V3) -> bool {
	if request.step <= 0 || math.is_nan(request.step) do return false
	if math.is_inf(request.step, 0) do return false
	for value in request.origin do if math.is_nan(value) || math.is_inf(value, 0) do return false
	return true
}

// _terrain_volume_weld_slots_v3 rounds to a power of two at roughly twice the
// vertex ceiling, so the open-addressing mask is a single `and` and the table
// never exceeds half load -- which bounds the probe walk.
@(private)
_terrain_volume_weld_slots_v3 :: proc(vertex_max: int) -> int {
	assert(vertex_max >= 0, "_terrain_volume_weld_slots_v3: negative ceiling")
	slots := 16
	for slots < vertex_max * 2 do slots *= 2
	return slots
}

@(private)
_terrain_volume_sample_v3 :: proc(
	recipe: ^Terrain_Recipe_V3,
	request: Terrain_Volume_Request_V3,
	density: []f32,
) -> bool {
	assert(recipe != nil, "_terrain_volume_sample_v3: nil recipe")
	stride_x := request.cells.x + 2
	stride_y := request.cells.y + 2
	// Column-major order so the expensive 2D surface stack runs once per
	// (x, y) column instead of once per 3D sample.
	for y in 0 ..< request.cells.y + 2 {
		world_y := request.origin.y + f32(y - 1) * request.step
		for x in 0 ..< request.cells.x + 2 {
			world_x := request.origin.x + f32(x - 1) * request.step
			ground, ok := _terrain_ground_v3(recipe, world_x, world_y)
			if !ok do return false
			for z in 0 ..< request.cells.z + 2 {
				world_z := request.origin.z + f32(z - 1) * request.step
				value := _terrain_density_from_ground_v3(recipe, ground, world_x, world_y, world_z)
				density[(z * stride_y + y) * stride_x + x] = value
			}
		}
	}
	return true
}

@(private)
_terrain_volume_uniform_v3 :: proc(density: []f32) -> Terrain_Volume_Occupancy_V3 {
	assert(len(density) > 0, "_terrain_volume_uniform_v3: empty field")
	solid, empty := true, true
	for value in density {
		solid = solid && value > 0
		empty = empty && value <= 0
		if !solid && !empty do return .Mixed
	}
	return .Solid if solid else .Empty
}

// _terrain_volume_normals_v3 derives one normal per halo lattice point. Each
// point is shared by eight cells, so caching here replaces eight identical
// gradient evaluations per point with one.
@(private)
_terrain_volume_normals_v3 :: proc(
	buffer: ^Terrain_Volume_Buffer_V3,
	request: Terrain_Volume_Request_V3,
	density_count: int,
) {
	assert(buffer != nil, "_terrain_volume_normals_v3: nil buffer")
	assert(len(buffer.normal_halo) >= density_count, "_terrain_volume_normals_v3: capacity")
	counts := [3]int{request.cells.x + 2, request.cells.y + 2, request.cells.z + 2}
	for z in 0 ..< counts.z {
		for y in 0 ..< counts.y {
			for x in 0 ..< counts.x {
				index := (z * counts.y + y) * counts.x + x
				buffer.normal_halo[index] = _terrain_volume_lattice_normal_v3(
					buffer.density_halo,
					request.cells,
					{x, y, z},
					request.step,
				)
			}
		}
	}
}

// _Terrain_Volume_Crossing_V3 is one isosurface crossing on a tetrahedron
// edge. Keeping the interpolation factor and the two corner indices -- rather
// than only the position -- lets the counting pass skip normal work entirely
// while the emit pass rebuilds the normal without recomputing the factor, so
// both passes classify exactly the same triangles.
@(private)
_Terrain_Volume_Crossing_V3 :: struct {
	position: asset.Vec3,
	factor:   f32,
	inside:   int,
	outside:  int,
}

@(private)
_terrain_volume_crossings_v3 :: proc(
	positions: [4]asset.Vec3,
	densities: [4]f32,
) -> (
	crossings: [4]_Terrain_Volume_Crossing_V3,
	count: int,
) {
	inside_indices, outside_indices: [4]int
	inside_count, outside_count := 0, 0
	for density, index in densities {
		if density > 0 {
			inside_indices[inside_count] = index
			inside_count += 1
		} else {
			outside_indices[outside_count] = index
			outside_count += 1
		}
	}
	if inside_count == 0 || inside_count == 4 do return {}, 0
	for inside in inside_indices[:inside_count] {
		for outside in outside_indices[:outside_count] {
			position, factor := _terrain_volume_intersection_v3(
				positions[inside],
				positions[outside],
				densities[inside],
				densities[outside],
			)
			crossings[count] = {position, factor, inside, outside}
			count += 1
		}
	}
	assert(count == 3 || count == 4, "_terrain_volume_crossings_v3: crossing count")
	return crossings, count
}

// _terrain_volume_triangles_v3 names the crossing triples each case spans. One
// inside or one outside corner cuts a triangle; two of each cuts a quad, which
// is split along the 0-3 diagonal.
@(private)
_terrain_volume_triangles_v3 :: proc(count: int) -> (triangles: [2][3]int, triangle_count: int) {
	assert(count == 3 || count == 4, "_terrain_volume_triangles_v3: crossing count")
	if count == 3 do return {{0, 1, 2}, {}}, 1
	return {{0, 1, 3}, {0, 3, 2}}, 2
}

@(private)
_terrain_volume_cross_v3 :: proc(triangle: [3]asset.Vec3) -> asset.Vec3 {
	edge_a := triangle[1] - triangle[0]
	edge_b := triangle[2] - triangle[0]
	return {
		edge_a.y * edge_b.z - edge_a.z * edge_b.y,
		edge_a.z * edge_b.x - edge_a.x * edge_b.z,
		edge_a.x * edge_b.y - edge_a.y * edge_b.x,
	}
}

@(private)
_terrain_volume_area_squared_v3 :: proc(triangle: [3]asset.Vec3) -> f32 {
	cross := _terrain_volume_cross_v3(triangle)
	return cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
}

@(private)
_terrain_volume_cell_corners_v3 :: proc(
	request: Terrain_Volume_Request_V3,
	cell: [3]int,
) -> [8]asset.Vec3 {
	cell_min := request.origin + [3]f32{f32(cell.x), f32(cell.y), f32(cell.z)} * request.step
	positions: [8]asset.Vec3
	for unit, corner in _terrain_volume_corner_units_v3() {
		positions[corner] = cell_min + asset.Vec3(unit) * request.step
	}
	return positions
}

// _terrain_volume_count_pass_v3 classifies every tetrahedron exactly as the
// emit pass does, degenerate rejection included, so the two agree on the
// totals the emit pass asserts against.
@(private)
_terrain_volume_count_pass_v3 :: proc(
	request: Terrain_Volume_Request_V3,
	density: []f32,
) -> (
	vertices, indices: int,
) {
	stride_x := request.cells.x + 2
	stride_y := request.cells.y + 2
	corner_offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	for z in 0 ..< request.cells.z {
		for y in 0 ..< request.cells.y {
			for x in 0 ..< request.cells.x {
				origin := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				positions := _terrain_volume_cell_corners_v3(request, {x, y, z})
				triangles := _terrain_volume_count_cell_v3(
					positions,
					density,
					corner_offsets,
					origin,
				)
				vertices += triangles * 3
				indices += triangles * 3
			}
		}
	}
	return
}

@(private)
_terrain_volume_count_cell_v3 :: proc(
	positions: [8]asset.Vec3,
	density: []f32,
	corner_offsets: [8]int,
	origin: int,
) -> (
	triangles: int,
) {
	for tetrahedron in _terrain_volume_tetrahedra_v3() {
		tetra_positions: [4]asset.Vec3
		tetra_densities: [4]f32
		for corner, index in tetrahedron {
			tetra_positions[index] = positions[corner]
			tetra_densities[index] = density[origin + corner_offsets[corner]]
		}
		crossings, count := _terrain_volume_crossings_v3(tetra_positions, tetra_densities)
		if count == 0 do continue
		corner_triples, triple_count := _terrain_volume_triangles_v3(count)
		for triple in corner_triples[:triple_count] {
			corners := [3]asset.Vec3 {
				crossings[triple[0]].position,
				crossings[triple[1]].position,
				crossings[triple[2]].position,
			}
			if _terrain_volume_area_squared_v3(corners) <= TERRAIN_VOLUME_MIN_AREA_V3 do continue
			triangles += 1
		}
	}
	return
}

// _Terrain_Volume_Emit_V3 carries the cursors, bounds and weld table through
// the cell walk. Passing one pointer keeps the emit procedures inside Tiger
// Style's parameter and length budgets.
@(private)
_Terrain_Volume_Emit_V3 :: struct {
	buffer:    ^Terrain_Volume_Buffer_V3,
	uv_scale:  f32,
	slot_mask: u64,
	vertices:  int,
	indices:   int,
	minimum:   asset.Vec3,
	maximum:   asset.Vec3,
}

@(private)
_terrain_volume_emit_v3 :: proc(
	request: Terrain_Volume_Request_V3,
	buffer: ^Terrain_Volume_Buffer_V3,
	slots, index_count: int,
	uv_scale: f32,
) -> (
	written_vertices, written_indices: int,
) {
	assert(buffer != nil, "_terrain_volume_emit_v3: nil buffer")
	assert(index_count > 0, "_terrain_volume_emit_v3: empty mesh")
	assert(slots > 0 && slots & (slots - 1) == 0, "_terrain_volume_emit_v3: slot count")
	for slot in 0 ..< slots do buffer.weld_keys[slot] = TERRAIN_VOLUME_WELD_EMPTY_V3
	state := _Terrain_Volume_Emit_V3 {
		buffer    = buffer,
		uv_scale  = uv_scale,
		slot_mask = u64(slots - 1),
		minimum   = {max(f32), max(f32), max(f32)},
		maximum   = {-max(f32), -max(f32), -max(f32)},
	}
	stride_x := request.cells.x + 2
	stride_y := request.cells.y + 2
	corner_offsets := _terrain_volume_corner_offsets_v3(stride_x, stride_y)
	for z in 0 ..< request.cells.z {
		for y in 0 ..< request.cells.y {
			for x in 0 ..< request.cells.x {
				origin := ((z + 1) * stride_y + y + 1) * stride_x + x + 1
				positions := _terrain_volume_cell_corners_v3(request, {x, y, z})
				corner_halo: [8]int
				for corner in 0 ..< 8 do corner_halo[corner] = origin + corner_offsets[corner]
				_terrain_volume_emit_cell_v3(&state, positions, corner_halo)
			}
		}
	}
	assert(state.indices == index_count, "_terrain_volume_emit_v3: index count mismatch")
	buffer.mesh.vertex_count = u32(state.vertices)
	buffer.mesh.index_count = u32(state.indices)
	buffer.mesh.primitive = .Triangles
	buffer.mesh.bounds = {state.minimum, state.maximum}
	return state.vertices, state.indices
}

@(private)
_terrain_volume_emit_cell_v3 :: proc(
	state: ^_Terrain_Volume_Emit_V3,
	positions: [8]asset.Vec3,
	corner_halo: [8]int,
) {
	assert(state != nil, "_terrain_volume_emit_cell_v3: nil state")
	for tetrahedron in _terrain_volume_tetrahedra_v3() {
		tetra_positions: [4]asset.Vec3
		tetra_densities: [4]f32
		tetra_halo: [4]int
		for corner, index in tetrahedron {
			tetra_positions[index] = positions[corner]
			tetra_densities[index] = state.buffer.density_halo[corner_halo[corner]]
			tetra_halo[index] = corner_halo[corner]
		}
		_terrain_volume_emit_tetrahedron_v3(state, tetra_positions, tetra_densities, tetra_halo)
	}
}

@(private)
_terrain_volume_emit_tetrahedron_v3 :: proc(
	state: ^_Terrain_Volume_Emit_V3,
	positions: [4]asset.Vec3,
	densities: [4]f32,
	halo: [4]int,
) {
	assert(state != nil, "_terrain_volume_emit_tetrahedron_v3: nil state")
	crossings, count := _terrain_volume_crossings_v3(positions, densities)
	if count == 0 do return
	corner_triples, triple_count := _terrain_volume_triangles_v3(count)
	for triple in corner_triples[:triple_count] {
		corners: [3]asset.Vec3
		for crossing, corner in triple do corners[corner] = crossings[crossing].position
		// The counting pass ran this same test, so skipping here is what keeps
		// the two passes' totals equal.
		if _terrain_volume_area_squared_v3(corners) <= TERRAIN_VOLUME_MIN_AREA_V3 do continue
		indices: [3]u32
		for crossing, corner in triple {
			indices[corner] = _terrain_volume_weld_v3(state, crossings[crossing], halo)
		}
		_terrain_volume_emit_indices_v3(state, corners, indices)
	}
}

// _terrain_volume_weld_v3 resolves a crossing to a vertex index, appending one
// only the first time an edge is seen. The key is the canonical ordered pair
// of halo lattice indices, so it is exact -- no float comparison -- and two
// cells sharing a face necessarily agree on it, which is what turns the index
// buffer into real connectivity instead of three fresh vertices per triangle.
@(private)
_terrain_volume_weld_v3 :: proc(
	state: ^_Terrain_Volume_Emit_V3,
	crossing: _Terrain_Volume_Crossing_V3,
	halo: [4]int,
) -> u32 {
	assert(state != nil, "_terrain_volume_weld_v3: nil state")
	low := u64(min(halo[crossing.inside], halo[crossing.outside]))
	high := u64(max(halo[crossing.inside], halo[crossing.outside]))
	assert(low < high, "_terrain_volume_weld_v3: degenerate edge")
	key := low << 32 | high
	// Multiply-shift so neighbouring edges do not land in one probe cluster.
	// The walk stays deterministic because the table is cleared per call and
	// filled in cell order.
	slot := (key * 0x9E3779B97F4A7C15 >> 32) & state.slot_mask
	for {
		existing := state.buffer.weld_keys[slot]
		if existing == key do return state.buffer.weld_values[slot]
		if existing == TERRAIN_VOLUME_WELD_EMPTY_V3 do break
		slot = (slot + 1) & state.slot_mask
	}
	index := u32(state.vertices)
	state.buffer.weld_keys[slot] = key
	state.buffer.weld_values[slot] = index
	_terrain_volume_append_vertex_v3(state, crossing, halo)
	return index
}

@(private)
_terrain_volume_append_vertex_v3 :: proc(
	state: ^_Terrain_Volume_Emit_V3,
	crossing: _Terrain_Volume_Crossing_V3,
	halo: [4]int,
) {
	assert(state != nil, "_terrain_volume_append_vertex_v3: nil state")
	assert(state.vertices < len(state.buffer.mesh.vertices), "volume vertex capacity")
	normal := _terrain_volume_blend_normal_v3(
		state.buffer.normal_halo[halo[crossing.inside]],
		state.buffer.normal_halo[halo[crossing.outside]],
		crossing.factor,
	)
	position := crossing.position
	state.buffer.mesh.vertices[state.vertices] = {
		position = position,
		normal   = normal,
		scalar   = clamp(normal.z * 0.5 + 0.5, 0, 1),
		uv       = _terrain_volume_projection_uv_v3(normal, position, state.uv_scale),
	}
	for axis in 0 ..< 3 {
		state.minimum[axis] = min(state.minimum[axis], position[axis])
		state.maximum[axis] = max(state.maximum[axis], position[axis])
	}
	state.vertices += 1
}

// _terrain_volume_emit_indices_v3 writes the triangle. Welded vertices are
// shared, so a back-facing triangle is fixed by reversing the index order
// rather than by swapping vertex slots the way the unwelded emitter did.
@(private)
_terrain_volume_emit_indices_v3 :: proc(
	state: ^_Terrain_Volume_Emit_V3,
	corners: [3]asset.Vec3,
	indices: [3]u32,
) {
	assert(state != nil, "_terrain_volume_emit_indices_v3: nil state")
	assert(state.indices + 3 <= len(state.buffer.mesh.indices), "volume index capacity")
	cross := _terrain_volume_cross_v3(corners)
	average :=
		state.buffer.mesh.vertices[indices[0]].normal +
		state.buffer.mesh.vertices[indices[1]].normal +
		state.buffer.mesh.vertices[indices[2]].normal
	order := indices
	if cross.x * average.x + cross.y * average.y + cross.z * average.z < 0 {
		order[1], order[2] = order[2], order[1]
	}
	for index in order {
		state.buffer.mesh.indices[state.indices] = index
		state.indices += 1
	}
}

@(private)
_terrain_volume_intersection_v3 :: proc(
	inside, outside: asset.Vec3,
	inside_density, outside_density: f32,
) -> (
	point: asset.Vec3,
	factor: f32,
) {
	denominator := inside_density - outside_density
	factor = 0.5
	if abs(denominator) > 0.000001 do factor = clamp(inside_density / denominator, 0, 1)
	return inside + (outside - inside) * factor, factor
}

@(private)
_terrain_volume_blend_normal_v3 :: proc(
	inside_normal, outside_normal: asset.Vec3,
	factor: f32,
) -> asset.Vec3 {
	blended := inside_normal + (outside_normal - inside_normal) * factor
	length := math.sqrt(blended.x * blended.x + blended.y * blended.y + blended.z * blended.z)
	if length <= 0.000001 do return {0, 0, 1}
	return blended / length
}

@(private)
_terrain_volume_projection_uv_v3 :: proc(normal, position: asset.Vec3, scale: f32) -> asset.Vec2 {
	assert(scale > 0, "_terrain_volume_projection_uv_v3: non-positive scale")
	absolute := asset.Vec3{abs(normal.x), abs(normal.y), abs(normal.z)}
	if absolute.x >= absolute.y && absolute.x >= absolute.z {
		return {position.y / scale, position.z / scale}
	}
	if absolute.y >= absolute.z do return {position.x / scale, position.z / scale}
	return {position.x / scale, position.y / scale}
}

@(private)
_terrain_volume_corner_offsets_v3 :: proc(stride_x, stride_y: int) -> [8]int {
	assert(stride_x >= 3 && stride_y >= 3, "_terrain_volume_corner_offsets_v3: strides")
	plane := stride_x * stride_y
	return {0, 1, 1 + stride_x, stride_x, plane, plane + 1, plane + 1 + stride_x, plane + stride_x}
}

@(private)
_terrain_volume_corner_units_v3 :: proc() -> [8][3]f32 {
	return {{0, 0, 0}, {1, 0, 0}, {1, 1, 0}, {0, 1, 0}, {0, 0, 1}, {1, 0, 1}, {1, 1, 1}, {0, 1, 1}}
}

@(private)
_terrain_volume_tetrahedra_v3 :: proc() -> [6][4]int {
	return {{0, 5, 1, 6}, {0, 1, 2, 6}, {0, 2, 3, 6}, {0, 3, 7, 6}, {0, 7, 4, 6}, {0, 4, 5, 6}}
}

// _terrain_volume_lattice_normal_v3 derives the surface normal at a halo
// lattice point from central differences of the sampled density field,
// falling back to one-sided differences at the halo boundary. Reusing the
// halo keeps normal evaluation free of any additional noise-stack work.
@(private)
_terrain_volume_lattice_normal_v3 :: proc(
	density: []f32,
	cells: [3]int,
	lattice: [3]int,
	step: f32,
) -> asset.Vec3 {
	assert(step > 0, "_terrain_volume_lattice_normal_v3: step")
	counts := [3]int{cells.x + 2, cells.y + 2, cells.z + 2}
	for axis in 0 ..< 3 {
		assert(lattice[axis] >= 0 && lattice[axis] < counts[axis], "lattice point out of halo")
	}
	gradient: [3]f32
	for axis in 0 ..< 3 {
		low, high := lattice, lattice
		low[axis] = max(lattice[axis] - 1, 0)
		high[axis] = min(lattice[axis] + 1, counts[axis] - 1)
		low_index := (low.z * counts.y + low.y) * counts.x + low.x
		high_index := (high.z * counts.y + high.y) * counts.x + high.x
		span := f32(high[axis] - low[axis]) * step
		gradient[axis] = (density[high_index] - density[low_index]) / span
	}
	normal := asset.Vec3{-gradient.x, -gradient.y, -gradient.z}
	length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
	if length <= 0.000001 do return {0, 0, 1}
	return normal / length
}
