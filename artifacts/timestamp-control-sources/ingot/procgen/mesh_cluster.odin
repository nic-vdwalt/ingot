package procgen

import asset "../asset"

// Cluster LOD DAG construction.
//
// The shape is Nanite's, reduced to what a WebGPU/Tiger-Style engine can carry:
//
//   1. Partition the source triangles into clusters of at most
//      `CLUSTER_MAX_TRIANGLES` by spatial locality.
//   2. Take adjacent clusters in groups, lock every vertex the group shares
//      with the outside, and simplify the group's interior by half.
//   3. Re-partition each simplified group into clusters. Those are the parents.
//   4. Repeat until one cluster remains.
//
// Locking the shared boundary is the entire crack-free guarantee: a locked
// vertex is never a collapse source and collapses only ever move a vertex onto
// an existing one, so a boundary position is bit-identical at every level.
// Two neighbouring clusters resolved at different levels therefore still meet.
//
// Locality comes from a Morton order over triangle centroids. It is weaker than
// a graph partitioner but has no dependency, no tuning, and is deterministic -
// the same mesh always produces the same DAG, which the cook step relies on.

CLUSTER_BUILD_GROUP_SIZE :: 4
CLUSTER_BUILD_MAX_GROUP_TRIANGLES :: asset.CLUSTER_MAX_TRIANGLES * asset.CLUSTER_MAX_GROUP_CHILDREN
CLUSTER_BUILD_MAX_GROUP_INDICES :: CLUSTER_BUILD_MAX_GROUP_TRIANGLES * 3
CLUSTER_BUILD_MORTON_BITS :: 10
CLUSTER_BUILD_MORTON_SCALE :: f32((1 << CLUSTER_BUILD_MORTON_BITS) - 1)
// A parent must be strictly coarser than its children or the selection rule
// admits two levels at once. When a simplification happens to cost nothing
// measurable, this relative step separates them anyway.
CLUSTER_BUILD_ERROR_STEP :: f32(1.0e-6)

Cluster_Build_Options :: struct {
	// Triangles per cluster. Zero selects `asset.CLUSTER_MAX_TRIANGLES`.
	cluster_triangles: int,
	// Clusters merged before each simplification. Zero selects
	// `CLUSTER_BUILD_GROUP_SIZE`.
	group_size:        int,
	// Fraction of a group's indices to keep. Zero selects one half.
	simplify_ratio:    f32,
}

Cluster_Level :: struct {
	first_vertex: u32,
	vertex_count: u32,
	first_index:  u32,
	index_count:  u32,
	// Worst-case geometric error of any cluster at this level, in mesh units.
	// This is what a V2 LOD record stores.
	error:        f32,
}

Cluster_Build_Result :: struct {
	cluster_count: int,
	group_count:   int,
	vertex_count:  int,
	index_count:   int,
	level_count:   int,
	levels:        [asset.CLUSTER_MAX_LEVELS]Cluster_Level,
}

Cluster_Build_Storage :: struct {
	// Outputs. `vertices` and `indices` hold every level back to back, in the
	// order a V2 bundle stores them.
	clusters:        []asset.Cluster,
	groups:          []asset.Cluster_Group,
	vertices:        []asset.Vertex,
	indices:         []u32,
	// Per-group working set, sized for `CLUSTER_BUILD_MAX_GROUP_INDICES`.
	work_vertices:   []asset.Vertex,
	work_indices:    []u32,
	out_vertices:    []asset.Vertex,
	out_indices:     []u32,
	locked:          []bool,
	// Per output-vertex bookkeeping, sized for twice the source vertex count.
	remap:           []u32,
	stamp:           []u32,
	owner:           []u32,
	shared:          []bool,
	// Triangle reordering scratch, sized for the source index count.
	keys:            []Cluster_Key,
	scratch_indices: []u32,
	simplify:        Simplify_Scratch,
}

@(private)
Cluster_Key :: struct {
	code:     u64,
	triangle: u32,
	_pad:     u32,
}

@(private)
Cluster_Build_State :: struct {
	cluster_count: int,
	group_count:   int,
	vertex_count:  int,
	index_count:   int,
	level:         int,
	// First cluster, index, and vertex of the level currently being consumed.
	level_first:   int,
	level_index:   int,
	level_vertex:  int,
	level_count:   int,
}

// cluster_build produces the DAG plus the per-level geometry a V2 bundle needs.
// It never fails silently: a false return means the storage was too small or
// the source mesh was rejected, and nothing in `storage` should be trusted.
cluster_build :: proc(
	source: asset.Mesh_View,
	options: Cluster_Build_Options,
	storage: Cluster_Build_Storage,
) -> (
	Cluster_Build_Result,
	bool,
) {
	assert(options.cluster_triangles >= 0, "cluster_build: negative cluster size")
	assert(options.group_size >= 0, "cluster_build: negative group size")
	settings, settings_ok := _cluster_settings(options)
	if !settings_ok do return {}, false
	if !_cluster_storage_ok(source, storage, settings) do return {}, false
	result: Cluster_Build_Result
	state := Cluster_Build_State{}
	copy(storage.vertices[:len(source.vertices)], source.vertices)
	copy(storage.indices[:len(source.indices)], source.indices)
	state.vertex_count = len(source.vertices)
	state.index_count = len(source.indices)
	result.levels[0] = {
		vertex_count = u32(state.vertex_count),
		index_count  = u32(state.index_count),
	}
	state.level_count = 1
	if !_cluster_partition_base(source.bounds, storage, &state, settings) do return {}, false
	if !_cluster_levels(storage, &state, settings, &result) do return {}, false
	_cluster_finish(storage, &state)
	result.cluster_count = state.cluster_count
	result.group_count = state.group_count
	result.vertex_count = state.vertex_count
	result.index_count = state.index_count
	result.level_count = state.level_count
	return result, _cluster_result_ok(result, storage)
}

@(private)
Cluster_Settings :: struct {
	cluster_triangles: int,
	group_size:        int,
	simplify_ratio:    f32,
}

@(private)
_cluster_settings :: proc(options: Cluster_Build_Options) -> (Cluster_Settings, bool) {
	assert(options.simplify_ratio >= 0, "_cluster_settings: negative ratio")
	assert(options.group_size <= asset.CLUSTER_MAX_GROUP_CHILDREN, "_cluster_settings: group size")
	result := Cluster_Settings {
		cluster_triangles = options.cluster_triangles,
		group_size        = options.group_size,
		simplify_ratio    = options.simplify_ratio,
	}
	if result.cluster_triangles == 0 do result.cluster_triangles = asset.CLUSTER_MAX_TRIANGLES
	if result.group_size == 0 do result.group_size = CLUSTER_BUILD_GROUP_SIZE
	if result.simplify_ratio == 0 do result.simplify_ratio = 0.5
	if result.cluster_triangles < 1 || result.cluster_triangles > asset.CLUSTER_MAX_TRIANGLES {
		return {}, false
	}
	if result.group_size < 2 || result.group_size > asset.CLUSTER_MAX_GROUP_CHILDREN {
		return {}, false
	}
	// A ratio at or above one would never shrink the mesh, so the level loop
	// would spin until its bound instead of converging.
	if result.simplify_ratio <= 0 || result.simplify_ratio >= 1 do return {}, false
	return result, true
}

// cluster_group_indices is the working-buffer size a caller must provide for a
// given configuration: one group's worth of indices, which is also the upper
// bound on its vertex count.
cluster_group_indices :: proc(options: Cluster_Build_Options) -> int {
	assert(options.cluster_triangles >= 0, "cluster_group_indices: negative cluster size")
	assert(options.group_size >= 0, "cluster_group_indices: negative group size")
	settings, ok := _cluster_settings(options)
	if !ok do return 0
	return settings.cluster_triangles * settings.group_size * 3
}

@(private)
_cluster_storage_ok :: proc(
	source: asset.Mesh_View,
	storage: Cluster_Build_Storage,
	settings: Cluster_Settings,
) -> bool {
	assert(len(storage.vertices) >= 0, "_cluster_storage_ok: negative vertex storage")
	assert(settings.cluster_triangles > 0, "_cluster_storage_ok: zero cluster size")
	if !asset.mesh_validate(source) || source.primitive != .Triangles do return false
	vertex_count := len(source.vertices)
	index_count := len(source.indices)
	if vertex_count > SIMPLIFY_MAX_VERTICES || index_count > SIMPLIFY_MAX_INDICES do return false
	// Every level after the first is at most half the previous, so the whole
	// chain fits in twice the source. The check is against the source rather
	// than a running total because the storage must be sized up front.
	if len(storage.vertices) < vertex_count * 2 || len(storage.indices) < index_count * 2 {
		return false
	}
	group := settings.cluster_triangles * settings.group_size * 3
	if group > CLUSTER_BUILD_MAX_GROUP_INDICES do return false
	if len(storage.work_vertices) < group || len(storage.work_indices) < group do return false
	if len(storage.out_vertices) < group || len(storage.out_indices) < group do return false
	if len(storage.locked) < group do return false
	if len(storage.remap) < vertex_count * 2 || len(storage.owner) < vertex_count * 2 do return false
	if len(storage.stamp) < vertex_count * 2 || len(storage.shared) < vertex_count * 2 do return false
	if len(storage.keys) < index_count / 3 do return false
	if len(storage.scratch_indices) < index_count do return false
	if len(storage.clusters) == 0 || len(storage.groups) == 0 do return false
	return true
}

// The root cluster has no parent, so nothing can replace it. Marking it here
// rather than during the level loop keeps the loop free of a special case.
@(private)
_cluster_finish :: proc(storage: Cluster_Build_Storage, state: ^Cluster_Build_State) {
	assert(state != nil, "_cluster_finish: nil state")
	assert(state.cluster_count > 0, "_cluster_finish: empty graph")
	for index in state.level_first ..< state.cluster_count {
		storage.clusters[index].group = asset.CLUSTER_GROUP_NONE
		storage.clusters[index].parent_error = asset.CLUSTER_ERROR_ROOT
	}
}

@(private)
_cluster_result_ok :: proc(result: Cluster_Build_Result, storage: Cluster_Build_Storage) -> bool {
	assert(result.cluster_count >= 0, "_cluster_result_ok: negative cluster count")
	assert(result.level_count >= 0, "_cluster_result_ok: negative level count")
	if result.cluster_count == 0 || result.level_count == 0 do return false
	if result.level_count > asset.CLUSTER_MAX_LEVELS do return false
	dag := asset.Cluster_Dag {
		clusters    = storage.clusters[:result.cluster_count],
		groups      = storage.groups[:result.group_count],
		level_count = u8(result.level_count),
	}
	_, ok := asset.cluster_dag_validate(dag, u32(result.index_count))
	return ok
}
