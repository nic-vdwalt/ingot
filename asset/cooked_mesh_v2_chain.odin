package asset

// Chain assembly and validation for INGMESH2. Split from `cooked_mesh_v2.odin`
// so the byte-layout reader and the semantic checks stay separately reviewable:
// the reader may only be wrong about offsets, this file may only be wrong about
// meaning.

@(private)
_cooked_v2_chains :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	storage: Cooked_Mesh_V2_Storage,
) -> (
	Cooked_Mesh_V2_Bundle,
	Cooked_Mesh_Result,
	bool,
) {
	assert(layout.mesh_count > 0, "_cooked_v2_chains: empty bundle")
	assert(int(layout.mesh_count) <= len(storage.meshes), "_cooked_v2_chains: unchecked capacity")
	cursor := Cooked_V2_Cursor{}
	for index in 0 ..< int(layout.mesh_count) {
		offset := COOKED_MESH_V2_HEADER_SIZE + index * COOKED_MESH_V2_RECORD_SIZE
		record := _cooked_v2_mesh_record(bytes, offset)
		if result, ok := _cooked_v2_record_valid(record, layout, &cursor, offset); !ok {
			return {}, result, false
		}
		chain, chain_result, chain_ok := _cooked_v2_chain(
			bytes,
			layout,
			storage,
			record,
			&cursor,
			offset,
		)
		if !chain_ok do return {}, chain_result, false
		storage.meshes[index] = chain
		cursor.mesh_id = record.id
	}
	if cursor.lod != layout.lod_count ||
	   cursor.cluster != layout.cluster_count ||
	   cursor.group != layout.group_count {
		return {}, {fault = .Invalid_Record, offset = 12}, false
	}
	if cursor.vertex != layout.vertex_count || cursor.index != layout.index_count {
		return {}, {fault = .Invalid_Lod, offset = 12}, false
	}
	bundle := Cooked_Mesh_V2_Bundle {
		meshes       = storage.meshes[:layout.mesh_count],
		vertex_count = layout.vertex_count,
		index_count  = layout.index_count,
		flags        = layout.flags,
	}
	return bundle, {}, true
}

// Every table in the bundle is walked exactly once, in record order, so a
// single running cursor proves the spans are contiguous, non-overlapping, and
// exhaustive. That is the same invariant version 1 enforces for vertices and
// indices, extended to LODs, clusters, and groups.
@(private)
Cooked_V2_Cursor :: struct {
	mesh_id: Mesh_Id,
	lod:     u32,
	cluster: u32,
	group:   u32,
	vertex:  u32,
	index:   u32,
}

@(private)
_cooked_v2_record_valid :: proc(
	record: Cooked_V2_Mesh_Record,
	layout: Cooked_V2_Layout,
	cursor: ^Cooked_V2_Cursor,
	offset: int,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	assert(cursor != nil, "_cooked_v2_record_valid: nil cursor")
	assert(offset >= COOKED_MESH_V2_HEADER_SIZE, "_cooked_v2_record_valid: offset in header")
	fail := Cooked_Mesh_Result {
		fault  = .Invalid_Record,
		offset = u32(offset),
		mesh   = record.id,
	}
	if record.id == 0 || record.id <= cursor.mesh_id do return fail, false
	if record.lod_count == 0 || record.lod_count > COOKED_MESH_V2_MAX_MESH_LODS do return fail, false
	if record.lod_first != cursor.lod do return fail, false
	if u64(record.lod_first) + u64(record.lod_count) > u64(layout.lod_count) do return fail, false
	if record.cluster_first != cursor.cluster || record.group_first != cursor.group {
		return fail, false
	}
	if u64(record.cluster_first) + u64(record.cluster_count) > u64(layout.cluster_count) {
		return fail, false
	}
	if u64(record.group_first) + u64(record.group_count) > u64(layout.group_count) {
		return fail, false
	}
	if !bounds_valid(record.bounds) do return fail, false
	if !quantization_valid({record.bounds, record.uv_bounds}) do return fail, false
	cursor.lod += record.lod_count
	cursor.cluster += record.cluster_count
	cursor.group += record.group_count
	return {}, true
}

@(private)
_cooked_v2_chain :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	storage: Cooked_Mesh_V2_Storage,
	record: Cooked_V2_Mesh_Record,
	cursor: ^Cooked_V2_Cursor,
	offset: int,
) -> (
	Cooked_Mesh_Chain,
	Cooked_Mesh_Result,
	bool,
) {
	assert(record.id != 0, "_cooked_v2_chain: zero mesh id")
	assert(cursor != nil, "_cooked_v2_chain: nil cursor")
	lods := storage.lods[record.lod_first:record.lod_first + record.lod_count]
	if result, ok := _cooked_v2_lods(bytes, layout, storage, record, lods, cursor, offset); !ok {
		return {}, result, false
	}
	result := Cooked_Mesh_Chain {
		id        = record.id,
		lods      = lods,
		bounds    = record.bounds,
		uv_bounds = record.uv_bounds,
	}
	if record.cluster_count == 0 {
		if record.group_count != 0 {
			return {}, {fault = .Invalid_Cluster, offset = u32(offset), mesh = record.id}, false
		}
		return result, {}, true
	}
	dag := Cluster_Dag {
		clusters = storage.clusters[record.cluster_first:record.cluster_first + record.cluster_count],
		groups   = storage.groups[record.group_first:record.group_first + record.group_count],
	}
	dag.level_count = _cooked_v2_level_count(dag)
	if cluster_result, ok := cluster_dag_validate(dag, layout.index_count); !ok {
		return {}, _cooked_v2_cluster_fault(cluster_result, record, offset), false
	}
	if !_cooked_v2_clusters_inside_lods(bytes, layout, record, dag) {
		return {}, {fault = .Invalid_Cluster, offset = u32(offset), mesh = record.id}, false
	}
	result.dag = dag
	return result, {}, true
}

@(private)
_cooked_v2_lods :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	storage: Cooked_Mesh_V2_Storage,
	record: Cooked_V2_Mesh_Record,
	lods: []Mesh_Lod,
	cursor: ^Cooked_V2_Cursor,
	offset: int,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	assert(len(lods) > 0, "_cooked_v2_lods: empty chain")
	assert(cursor != nil, "_cooked_v2_lods: nil cursor")
	fail := Cooked_Mesh_Result {
		fault  = .Invalid_Lod,
		offset = u32(offset),
		mesh   = record.id,
	}
	previous_error := f32(-1)
	previous_threshold := max(f32)
	for level in 0 ..< len(lods) {
		span := _cooked_v2_lod_record(bytes, layout, record.lod_first + u32(level))
		error, threshold := _cooked_v2_lod_thresholds(bytes, layout, record.lod_first + u32(level))
		if !_cooked_v2_lod_span_ok(span, storage) do return fail, false
		// Levels are stored back to back across the whole bundle, so a span
		// that does not start where the previous one ended is either an
		// overlap or a hole - both would let one level read another's data.
		if span[0] != cursor.vertex || span[2] != cursor.index do return fail, false
		// Coarser levels must cost strictly more error and apply at strictly
		// smaller screen heights, or two levels would qualify at once and the
		// runtime's choice would depend on iteration order.
		if error <= previous_error || error < 0 || !_cluster_error_valid(error) do return fail, false
		if threshold >= previous_threshold || threshold < 0 do return fail, false
		if !_cluster_error_valid(threshold) do return fail, false
		vertices := storage.vertices[span[0]:span[0] + span[1]]
		indices := storage.indices[span[2]:span[2] + span[3]]
		view := Mesh_View{record.id, vertices, indices, .Triangles, record.bounds}
		if !mesh_validate(view) do return fail, false
		lods[level] = {
			view                    = view,
			error                   = error,
			screen_height_threshold = threshold,
		}
		previous_error = error
		previous_threshold = threshold
		cursor.vertex = span[0] + span[1]
		cursor.index = span[2] + span[3]
	}
	return {}, true
}

@(private)
_cooked_v2_lod_span_ok :: proc(span: [4]u32, storage: Cooked_Mesh_V2_Storage) -> bool {
	assert(len(storage.vertices) <= int(max(u32)), "_cooked_v2_lod_span_ok: vertex overflow")
	assert(len(storage.indices) <= int(max(u32)), "_cooked_v2_lod_span_ok: index overflow")
	if span[1] == 0 || span[3] == 0 || span[3] % 3 != 0 do return false
	if u64(span[0]) + u64(span[1]) > u64(len(storage.vertices)) do return false
	if u64(span[2]) + u64(span[3]) > u64(len(storage.indices)) do return false
	return true
}

// The DAG's level count is derived rather than stored: it is one past the
// highest level any cluster or group claims, which is exactly what
// `cluster_dag_validate` needs to bound its checks.
@(private)
_cooked_v2_level_count :: proc(dag: Cluster_Dag) -> u8 {
	assert(len(dag.clusters) > 0, "_cooked_v2_level_count: empty graph")
	assert(len(dag.clusters) <= COOKED_MESH_V2_MAX_CLUSTERS, "_cooked_v2_level_count: overflow")
	highest := u8(0)
	for cluster in dag.clusters do highest = max(highest, cluster.level)
	for group in dag.groups do highest = max(highest, group.level)
	if int(highest) >= CLUSTER_MAX_LEVELS do return u8(CLUSTER_MAX_LEVELS)
	return highest + 1
}

// A cluster whose index span crossed a LOD boundary would mix triangles from
// two resolutions into one draw, so every cluster must nest inside exactly one
// level's index span.
@(private)
_cooked_v2_clusters_inside_lods :: proc(
	bytes: []u8,
	layout: Cooked_V2_Layout,
	record: Cooked_V2_Mesh_Record,
	dag: Cluster_Dag,
) -> bool {
	assert(len(dag.clusters) > 0, "_cooked_v2_clusters_inside_lods: empty graph")
	assert(record.lod_count > 0, "_cooked_v2_clusters_inside_lods: empty chain")
	spans: [COOKED_MESH_V2_MAX_MESH_LODS][2]u64
	for level in 0 ..< int(record.lod_count) {
		span := _cooked_v2_lod_record(bytes, layout, record.lod_first + u32(level))
		spans[level] = {u64(span[2]), u64(span[2]) + u64(span[3])}
	}
	for cluster in dag.clusters {
		first := u64(cluster.first_index)
		last := first + u64(cluster.index_count)
		contained := false
		for level in 0 ..< int(record.lod_count) {
			if first >= spans[level][0] && last <= spans[level][1] {
				contained = true
				break
			}
		}
		if !contained do return false
	}
	return true
}

@(private)
_cooked_v2_cluster_fault :: proc(
	result: Cluster_Result,
	record: Cooked_V2_Mesh_Record,
	offset: int,
) -> Cooked_Mesh_Result {
	assert(result.fault != .None, "_cooked_v2_cluster_fault: no fault")
	assert(record.id != 0, "_cooked_v2_cluster_fault: zero mesh id")
	return {fault = .Invalid_Cluster, offset = u32(offset), mesh = record.id}
}
