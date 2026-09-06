package asset

// Validation for the INGMESH2 writer. It is split from the byte emission the
// same way `cooked_mesh_v2_chain.odin` is split from `cooked_mesh_v2.odin`, so
// the semantic rules and the layout stay separately reviewable -- and so the
// rules can be read directly against the decoder's.
//
// Every check here has a counterpart in the reader. A bundle this accepts must
// decode; a bundle this rejects would have been rejected on load, and finding
// that out at cook time names the offending mesh instead of a byte offset in a
// file someone already shipped.

@(private)
_cooked_v2_encode_valid :: proc(
	meshes: []Cooked_Mesh_Chain,
	flags: u32,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	if len(meshes) == 0 || len(meshes) > COOKED_MESH_V2_MAX_MESHES {
		return {fault = .Invalid_Record}, false
	}
	if flags & ~u32(COOKED_MESH_V2_FLAG_MASK) != 0 do return {fault = .Invalid_Flags}, false
	clustered := false
	lod_total, cluster_total, group_total := 0, 0, 0
	previous_id := Mesh_Id(0)
	for mesh, index in meshes {
		offset := COOKED_MESH_V2_HEADER_SIZE + index * COOKED_MESH_V2_RECORD_SIZE
		if mesh.id == 0 || mesh.id <= previous_id {
			return {fault = .Invalid_Record, offset = u32(offset), mesh = mesh.id}, false
		}
		previous_id = mesh.id
		if result, ok := _cooked_v2_encode_chain_valid(mesh, offset); !ok do return result, false
		if result, ok := _cooked_v2_encode_dag_valid(mesh, offset); !ok do return result, false
		clustered = clustered || len(mesh.dag.clusters) > 0
		lod_total += len(mesh.lods)
		cluster_total += len(mesh.dag.clusters)
		group_total += len(mesh.dag.groups)
	}
	// The flag and the table have to agree, because the decoder treats a
	// disagreement as a corrupt file rather than a hint.
	if (flags & COOKED_MESH_V2_FLAG_CLUSTERS != 0) != clustered {
		return {fault = .Invalid_Flags}, false
	}
	if lod_total > COOKED_MESH_V2_MAX_LODS do return {fault = .Capacity}, false
	if cluster_total > COOKED_MESH_V2_MAX_CLUSTERS do return {fault = .Capacity}, false
	if group_total > COOKED_MESH_V2_MAX_GROUPS do return {fault = .Capacity}, false
	return {}, true
}

@(private)
_cooked_v2_encode_chain_valid :: proc(
	mesh: Cooked_Mesh_Chain,
	offset: int,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	fail := Cooked_Mesh_Result {
		fault  = .Invalid_Lod,
		offset = u32(offset),
		mesh   = mesh.id,
	}
	if len(mesh.lods) == 0 || len(mesh.lods) > COOKED_MESH_V2_MAX_MESH_LODS do return fail, false
	if !bounds_valid(mesh.bounds) {
		return {fault = .Invalid_Record, offset = u32(offset), mesh = mesh.id}, false
	}
	quantization := Vertex_Quantization{mesh.bounds, mesh.uv_bounds}
	if !quantization_valid(quantization) {
		return {fault = .Invalid_Record, offset = u32(offset), mesh = mesh.id}, false
	}
	previous_error := f32(-1)
	previous_threshold := max(f32)
	for lod in mesh.lods {
		if lod.view.id != mesh.id do return fail, false
		if len(lod.view.vertices) == 0 || len(lod.view.indices) == 0 do return fail, false
		if len(lod.view.indices) % 3 != 0 do return fail, false
		if lod.view.primitive != .Triangles do return fail, false
		// Equality is rejected rather than tolerated: two levels that qualify
		// at one threshold would make level choice depend on iteration order.
		if !(lod.error > previous_error) do return fail, false
		if !(lod.screen_height_threshold < previous_threshold) do return fail, false
		if lod.error < 0 || lod.screen_height_threshold < 0 do return fail, false
		if !_cooked_v2_finite(lod.error) do return fail, false
		if !_cooked_v2_finite(lod.screen_height_threshold) do return fail, false
		// The reader rebuilds each level as a Mesh_View against the mesh
		// record's bounds, so a level that fails here would fail on load.
		level := lod.view
		level.bounds = mesh.bounds
		if !mesh_validate(level) do return fail, false
		previous_error = lod.error
		previous_threshold = lod.screen_height_threshold
	}
	return {}, true
}

@(private)
_cooked_v2_encode_dag_valid :: proc(
	mesh: Cooked_Mesh_Chain,
	offset: int,
) -> (
	Cooked_Mesh_Result,
	bool,
) {
	fail := Cooked_Mesh_Result {
		fault  = .Invalid_Cluster,
		offset = u32(offset),
		mesh   = mesh.id,
	}
	if len(mesh.dag.clusters) == 0 {
		if len(mesh.dag.groups) != 0 do return fail, false
		return {}, true
	}
	index_count := 0
	for lod in mesh.lods do index_count += len(lod.view.indices)
	dag := mesh.dag
	if dag.level_count == 0 do dag.level_count = _cooked_v2_level_count(dag)
	if _, ok := cluster_dag_validate(dag, u32(index_count)); !ok do return fail, false
	// Every cluster must sit inside exactly one level, because a span that
	// straddles two would select geometry from both at once.
	for cluster in dag.clusters {
		first := int(cluster.first_index)
		last := first + int(cluster.index_count)
		nested := false
		cursor := 0
		for lod in mesh.lods {
			span := cursor + len(lod.view.indices)
			if first >= cursor && last <= span {
				nested = true
				break
			}
			cursor = span
		}
		if !nested do return fail, false
	}
	return {}, true
}

@(private)
_cooked_v2_finite :: proc(value: f32) -> bool {
	return value == value && value - value == 0
}
