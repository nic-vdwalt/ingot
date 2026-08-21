package procgen

import "ingot:asset"

// The geometry half of the runtime cooking path. `asset` owns the INGMESH2
// byte layout; this turns a generated mesh into the `Cooked_Mesh_Chain` that
// layout describes, using the simplifier and cluster builder already in this
// package.
//
// The policies mirror `tools/mesh_cook.py` so an asset cooked here and the same
// asset cooked offline select the same level at the same distance. A runtime
// that disagreed with the bake tool about LOD thresholds would pop where the
// bake did not.
//
// That agreement extends to index order: every level runs through
// `mesh_optimize.odin` on the way out, the same three passes in the same order
// the offline tool applies. Skipping it here would leave the runtime cook
// shipping unoptimised geometry - which is exactly what terrain built at load
// time used to get, while the same project's Blender-cooked props did not.
//
// This is initialization or worker-residency work, the same contract
// `mesh_deform_variant` and `creature_mesh_evolve` carry. It must not run per
// frame.

// Projected height in pixels below which a level is preferred. Strictly
// decreasing across a chain, because two levels that qualify at once would make
// the runtime's choice depend on iteration order.
COOK_LOD_SCREEN_BASE :: f32(1024)
COOK_LOD_SCREEN_FALLOFF :: f32(4)
COOK_LOD_MAX_LEVELS :: asset.COOKED_MESH_V2_MAX_MESH_LODS

Cook_Lod_Policy :: enum u8 {
	None,
	Grass_2,
	Structure_3,
	Tree_4,
}

Mesh_Workspace :: struct {
	block:           []u8,
	vertex_capacity: int,
	index_capacity:  int,
}

mesh_workspace_size :: proc(vertex_capacity, index_capacity: int) -> int {
	assert(vertex_capacity > 0, "mesh_workspace_size: empty vertices")
	assert(index_capacity >= 3, "mesh_workspace_size: empty indices")
	assert(index_capacity % 3 == 0, "mesh_workspace_size: incomplete triangle")
	assert(vertex_capacity <= OPTIMIZE_MAX_VERTICES, "mesh_workspace_size: vertex overflow")
	assert(index_capacity <= OPTIMIZE_MAX_INDICES, "mesh_workspace_size: index overflow")
	required := optimize_scratch_size(vertex_capacity, index_capacity)
	if index_capacity <= SIMPLIFY_MAX_INDICES {
		required = max(required, simplify_scratch_size(vertex_capacity, index_capacity))
	}
	return required + max(SIMPLIFY_SCRATCH_PADDING, OPTIMIZE_SCRATCH_PADDING)
}

mesh_workspace_make :: proc(
	block: []u8,
	vertex_capacity, index_capacity: int,
) -> (Mesh_Workspace, bool) {
	required := mesh_workspace_size(vertex_capacity, index_capacity)
	if len(block) < required do return {}, false
	return {
		block           = block,
		vertex_capacity = vertex_capacity,
		index_capacity  = index_capacity,
	}, true
}

mesh_workspace_simplify :: proc(
	workspace: Mesh_Workspace,
	vertex_count, index_count: int,
) -> (Simplify_Scratch, bool) {
	if vertex_count > workspace.vertex_capacity do return {}, false
	if index_count > workspace.index_capacity || index_count > SIMPLIFY_MAX_INDICES do return {}, false
	return simplify_scratch_make(workspace.block, vertex_count, index_count)
}

mesh_workspace_optimize :: proc(
	workspace: Mesh_Workspace,
	vertex_count, index_count: int,
) -> (Optimize_Scratch, bool) {
	if vertex_count > workspace.vertex_capacity do return {}, false
	if index_count > workspace.index_capacity do return {}, false
	return optimize_scratch_make(workspace.block, vertex_count, index_count)
}

Cook_Chain_Storage :: struct {
	lods:          []asset.Mesh_Lod,
	vertices:      []asset.Vertex,
	indices:       []u32,
	clusters:      []asset.Cluster,
	groups:        []asset.Cluster_Group,
	cluster:       Cluster_Build_Storage,
	simplify:      Simplify_Scratch,
	// Scratch for the index-order passes, sized for the source mesh. Only the
	// policy path uses it: a cluster DAG's index order belongs to
	// `cluster_build`, which stores each cluster as a span.
	optimize:      Optimize_Scratch,
	// Scratch for one simplification step, sized for the source mesh.
	work_vertices: []asset.Vertex,
	work_indices:  []u32,
}

// cook_lod_ratios is the fraction of level 0's indices each level keeps.
cook_lod_ratios :: proc(policy: Cook_Lod_Policy) -> []f32 {
	@(static) none := [?]f32{1}
	@(static) grass := [?]f32{1, 0.25}
	@(static) structure := [?]f32{1, 0.5, 0.2}
	@(static) tree := [?]f32{1, 0.5, 0.25, 0.08}
	switch policy {
	case .None:
		return none[:]
	case .Grass_2:
		return grass[:]
	case .Structure_3:
		return structure[:]
	case .Tree_4:
		return tree[:]
	}
	return none[:]
}

cook_lod_threshold :: proc(level: int) -> f32 {
	assert(level >= 0, "cook_lod_threshold: negative level")
	assert(level < COOK_LOD_MAX_LEVELS, "cook_lod_threshold: level past the format bound")
	threshold := COOK_LOD_SCREEN_BASE
	for _ in 0 ..< level do threshold /= COOK_LOD_SCREEN_FALLOFF
	return threshold
}

// cook_chain_requirements reports the caller-owned capacity a policy needs.
// Every level is a subset of level 0, so the source counts bound the whole
// chain once multiplied by its depth.
cook_chain_requirements :: proc(
	vertex_count, index_count: int,
	policy: Cook_Lod_Policy,
) -> (
	lod_max, vertex_max, index_max: int,
	ok: bool,
) {
	if vertex_count <= 0 || index_count <= 0 || index_count % 3 != 0 do return 0, 0, 0, false
	if vertex_count > SIMPLIFY_MAX_VERTICES || index_count > SIMPLIFY_MAX_INDICES {
		return 0, 0, 0, false
	}
	lod_max = len(cook_lod_ratios(policy))
	if lod_max > COOK_LOD_MAX_LEVELS do return 0, 0, 0, false
	return lod_max, vertex_count * lod_max, index_count * lod_max, true
}

// cook_chain_from_policy builds a discrete LOD chain by repeated
// simplification. A ratio that removes nothing ends the chain early: a shorter
// chain is valid and honest, where a duplicated level is neither.
cook_chain_from_policy :: proc(
	source: asset.Mesh_View,
	policy: Cook_Lod_Policy,
	storage: Cook_Chain_Storage,
) -> (
	asset.Cooked_Mesh_Chain,
	bool,
) {
	if source.id == 0 || !asset.mesh_validate(source) do return {}, false
	if source.primitive != .Triangles do return {}, false
	ratios := cook_lod_ratios(policy)
	lod_max, vertex_max, index_max, ok := cook_chain_requirements(
		len(source.vertices),
		len(source.indices),
		policy,
	)
	if !ok do return {}, false
	if len(storage.lods) < lod_max do return {}, false
	if len(storage.vertices) < vertex_max || len(storage.indices) < index_max do return {}, false
	written_vertices, written_indices := 0, 0
	level_count := 0
	previous_error := f32(0)
	for ratio, level in ratios {
		if level >= COOK_LOD_MAX_LEVELS do break
		vertices, indices, error, step_ok := _cook_level_geometry(
			source,
			storage,
			ratio,
			level,
			written_vertices,
			written_indices,
		)
		if !step_ok do break
		if level > 0 && indices >= len(storage.lods[level - 1].view.indices) do break
		if level > 0 && error <= previous_error do error = previous_error + CLUSTER_BUILD_ERROR_STEP
		storage.lods[level] = {
			view = {
				id = source.id,
				vertices = storage.vertices[written_vertices:written_vertices + vertices],
				indices = storage.indices[written_indices:written_indices + indices],
				primitive = .Triangles,
				bounds = source.bounds,
			},
			error = error,
			screen_height_threshold = cook_lod_threshold(level),
		}
		written_vertices += vertices
		written_indices += indices
		previous_error = error
		level_count += 1
	}
	if level_count == 0 do return {}, false
	return _cook_chain_finish(source, storage.lods[:level_count])
}

// cook_cluster_requirements reports the capacity the clustered path needs. A
// caller cannot predict how many levels `cluster_build` will produce, so the
// chain storage is sized for the format's ceiling rather than a guess. The
// index buffer holds every level, which `cluster_build` bounds at twice the
// source, and the vertex slice is unused because the levels are read straight
// out of the cluster builder's own output.
cook_cluster_requirements :: proc(
	vertex_count, index_count: int,
) -> (
	lod_max, index_max: int,
	ok: bool,
) {
	if vertex_count <= 0 || index_count <= 0 || index_count % 3 != 0 do return 0, 0, false
	return COOK_LOD_MAX_LEVELS, index_count * 2, true
}

// cook_chain_from_clusters builds a chain backed by a cluster DAG. A DAG and a
// discrete chain are alternatives rather than companions: the DAG already
// carries every level's geometry, so cooking both would store the same
// triangles twice.
//
// A source detailed enough to need more than `COOK_LOD_MAX_LEVELS` levels is
// rejected rather than truncated, because dropping the coarsest levels would
// silently remove the distances the DAG was built to cover. Raise
// `simplify_ratio` to converge in fewer levels.
cook_chain_from_clusters :: proc(
	source: asset.Mesh_View,
	options: Cluster_Build_Options,
	storage: Cook_Chain_Storage,
) -> (
	asset.Cooked_Mesh_Chain,
	bool,
) {
	if source.id == 0 || !asset.mesh_validate(source) do return {}, false
	if source.primitive != .Triangles do return {}, false
	result, build_ok := cluster_build(source, options, storage.cluster)
	if !build_ok do return {}, false
	if result.level_count == 0 || result.level_count > COOK_LOD_MAX_LEVELS do return {}, false
	if len(storage.lods) < result.level_count do return {}, false
	if len(storage.clusters) < result.cluster_count do return {}, false
	if len(storage.groups) < result.group_count do return {}, false
	previous_error := f32(-1)
	for level in 0 ..< result.level_count {
		span := result.levels[level]
		if !_cook_level_rebase(storage, span) do return {}, false
		// cluster_build reports geometric error only; the screen threshold is
		// the cook step's to choose, and it must match the offline tool's.
		error := span.error
		if level == 0 do error = 0
		if error <= previous_error do error = previous_error + CLUSTER_BUILD_ERROR_STEP
		storage.lods[level] = {
			view = {
				id = source.id,
				vertices = storage.cluster.vertices[span.first_vertex:][:span.vertex_count],
				indices = storage.indices[span.first_index:][:span.index_count],
				primitive = .Triangles,
				bounds = source.bounds,
			},
			error = error,
			screen_height_threshold = cook_lod_threshold(level),
		}
		previous_error = error
	}
	copy(storage.clusters[:result.cluster_count], storage.cluster.clusters[:result.cluster_count])
	copy(storage.groups[:result.group_count], storage.cluster.groups[:result.group_count])
	chain, chain_ok := _cook_chain_finish(source, storage.lods[:result.level_count])
	if !chain_ok do return {}, false
	chain.dag = {
		clusters    = storage.clusters[:result.cluster_count],
		groups      = storage.groups[:result.group_count],
		level_count = u8(result.level_count),
	}
	return chain, true
}

// _cook_level_rebase makes a level's indices local to its own vertex span. The
// DAG keeps them mesh-global so cluster spans can be, but a V2 LOD stores them
// relative to its own vertices, the same way version 1 stored them relative to
// a mesh.
@(private)
_cook_level_rebase :: proc(storage: Cook_Chain_Storage, span: Cluster_Level) -> bool {
	first := int(span.first_index)
	count := int(span.index_count)
	if len(storage.indices) < first + count do return false
	if count == 0 || count % 3 != 0 do return false
	for offset in 0 ..< count {
		index := storage.cluster.indices[first + offset]
		if index < span.first_vertex do return false
		local := index - span.first_vertex
		if local >= span.vertex_count do return false
		storage.indices[first + offset] = local
	}
	return true
}

// Every level leaves here in optimised index order, including level 0, which is
// the source geometry rather than a simplification of it. The offline tool
// optimises level 0 too; a cook that skipped it would ship a different index
// buffer for the same asset depending on which tool ran.
@(private)
_cook_level_geometry :: proc(
	source: asset.Mesh_View,
	storage: Cook_Chain_Storage,
	ratio: f32,
	level: int,
	vertex_cursor, index_cursor: int,
) -> (
	vertices, indices: int,
	error: f32,
	ok: bool,
) {
	if level == 0 {
		count, index_count, level_ok := _cook_level_optimize(
			source,
			storage,
			vertex_cursor,
			index_cursor,
		)
		return count, index_count, 0, level_ok
	}
	target := int(f32(len(source.indices)) * ratio) / 3 * 3
	if target < 3 do return 0, 0, 0, false
	if target >= len(source.indices) do return 0, 0, 0, false
	if len(storage.work_vertices) < len(source.vertices) do return 0, 0, 0, false
	if len(storage.work_indices) < len(source.indices) do return 0, 0, 0, false
	result, simplify_ok := simplify_mesh(
		source,
		{target_index_count = target},
		nil,
		storage.work_vertices,
		storage.work_indices,
		storage.simplify,
	)
	if !simplify_ok || result.index_count == 0 do return 0, 0, 0, false
	// The simplifier never moves a vertex off an existing one, so the source's
	// frame still contains the reduced geometry and `mesh_validate` inside the
	// optimiser accepts this view.
	reduced := asset.Mesh_View {
		id        = source.id,
		vertices  = storage.work_vertices[:result.vertex_count],
		indices   = storage.work_indices[:result.index_count],
		primitive = .Triangles,
		bounds    = source.bounds,
	}
	count, index_count, level_ok := _cook_level_optimize(
		reduced,
		storage,
		vertex_cursor,
		index_cursor,
	)
	return count, index_count, result.error, level_ok
}

// _cook_level_optimize runs the cache, overdraw, and fetch passes straight into
// the chain's storage. The passes are permutations, so the level cannot grow
// and the capacity `cook_chain_requirements` already reports still covers it.
@(private)
_cook_level_optimize :: proc(
	level: asset.Mesh_View,
	storage: Cook_Chain_Storage,
	vertex_cursor, index_cursor: int,
) -> (
	vertices, indices: int,
	ok: bool,
) {
	if len(storage.vertices) < vertex_cursor + len(level.vertices) do return 0, 0, false
	if len(storage.indices) < index_cursor + len(level.indices) do return 0, 0, false
	result, optimize_ok := optimize_mesh(
		level,
		storage.vertices[vertex_cursor:],
		storage.indices[index_cursor:],
		storage.optimize,
	)
	if !optimize_ok do return 0, 0, false
	return result.vertex_count, result.index_count, true
}

// _cook_chain_finish measures the bounds the packed-vertex quantization is
// derived from. They are measured over what was actually written rather than
// inherited from the source, so a simplified chain does not carry a frame
// wider than its own geometry.
@(private)
_cook_chain_finish :: proc(
	source: asset.Mesh_View,
	lods: []asset.Mesh_Lod,
) -> (
	asset.Cooked_Mesh_Chain,
	bool,
) {
	assert(len(lods) > 0, "_cook_chain_finish: empty chain")
	bounds := asset.Bounds_3D {
		minimum = {max(f32), max(f32), max(f32)},
		maximum = {-max(f32), -max(f32), -max(f32)},
	}
	uv_bounds := asset.Bounds_2D {
		minimum = {max(f32), max(f32)},
		maximum = {-max(f32), -max(f32)},
	}
	for lod in lods {
		for vertex in lod.view.vertices {
			for axis in 0 ..< 3 {
				bounds.minimum[axis] = min(bounds.minimum[axis], vertex.position[axis])
				bounds.maximum[axis] = max(bounds.maximum[axis], vertex.position[axis])
			}
			for axis in 0 ..< 2 {
				uv_bounds.minimum[axis] = min(uv_bounds.minimum[axis], vertex.uv[axis])
				uv_bounds.maximum[axis] = max(uv_bounds.maximum[axis], vertex.uv[axis])
			}
		}
	}
	if !asset.bounds_valid(bounds) do return {}, false
	// Every level is validated against the chain's bounds on load, so widen
	// each view to them here rather than leaving per-level frames behind.
	for &lod in lods do lod.view.bounds = bounds
	return {id = source.id, lods = lods, bounds = bounds, uv_bounds = uv_bounds}, true
}
