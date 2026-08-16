package procgen

import asset "../asset"

// Level construction for the cluster DAG: group boundary detection, gathering,
// simplification, and re-clustering. Kept apart from `mesh_cluster.odin` so the
// public contract stays readable next to the policy that produces it.

@(private)
_cluster_levels :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
	result: ^Cluster_Build_Result,
) -> bool {
	assert(state != nil, "_cluster_levels: nil state")
	assert(result != nil, "_cluster_levels: nil result")
	for _ in 1 ..< asset.CLUSTER_MAX_LEVELS {
		level_clusters := state.cluster_count - state.level_first
		if level_clusters <= 1 do return true
		if state.level_count >= asset.CLUSTER_MAX_LEVELS do return true
		previous := state^
		source_indices := state.index_count - state.level_index
		new_vertex := state.vertex_count
		new_index := state.index_count
		error := f32(0)
		if !_cluster_level_step(storage, state, settings, &error) do return false
		produced := state.index_count - new_index
		// A level that failed to shrink would repeat forever. Rewinding leaves
		// the previous level as the root set, which is still a valid DAG - just
		// a shallower one than the source geometry could have supported.
		if produced == 0 || produced >= source_indices {
			state^ = previous
			return true
		}
		result.levels[state.level_count] = {
			first_vertex = u32(new_vertex),
			vertex_count = u32(state.vertex_count - new_vertex),
			first_index  = u32(new_index),
			index_count  = u32(produced),
			error        = error,
		}
		state.level_count += 1
		state.level += 1
		state.level_index = new_index
		state.level_vertex = new_vertex
	}
	return true
}

@(private)
_cluster_level_step :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
	error: ^f32,
) -> bool {
	assert(error != nil, "_cluster_level_step: nil error")
	assert(state.cluster_count > state.level_first, "_cluster_level_step: empty level")
	first := state.level_first
	count := state.cluster_count - first
	_cluster_owners(storage, state, settings)
	produced_first := state.cluster_count
	for start := 0; start < count; start += settings.group_size {
		children := min(settings.group_size, count - start)
		group_error, ok := _cluster_group(storage, state, settings, first + start, children)
		if !ok do return false
		error^ = max(error^, group_error)
	}
	state.level_first = produced_first
	return state.cluster_count > produced_first
}

// Marks every vertex used by more than one group. Those are the positions a
// group's simplification must leave untouched, and pinning them is the whole
// crack-free guarantee. One sweep is enough because a triangle belongs to
// exactly one group.
@(private)
_cluster_owners :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
) {
	assert(state.cluster_count > state.level_first, "_cluster_owners: empty level")
	assert(settings.group_size > 0, "_cluster_owners: zero group size")
	for index in 0 ..< state.vertex_count {
		storage.owner[index] = max(u32)
		storage.stamp[index] = max(u32)
		storage.shared[index] = false
	}
	first := state.level_first
	for offset in 0 ..< state.cluster_count - first {
		cluster := storage.clusters[first + offset]
		group := u32(offset / settings.group_size)
		for step in 0 ..< cluster.index_count {
			vertex := storage.indices[cluster.first_index + step]
			if storage.owner[vertex] == max(u32) {
				storage.owner[vertex] = group
				continue
			}
			if storage.owner[vertex] != group do storage.shared[vertex] = true
		}
	}
}

@(private)
_cluster_group :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
	first_child, child_count: int,
) -> (
	f32,
	bool,
) {
	assert(child_count > 0, "_cluster_group: empty group")
	assert(child_count <= asset.CLUSTER_MAX_GROUP_CHILDREN, "_cluster_group: group overflow")
	gather, gather_ok := _cluster_gather(storage, first_child, child_count)
	if !gather_ok do return 0, false
	child_error := f32(0)
	for offset in 0 ..< child_count {
		child_error = max(child_error, storage.clusters[first_child + offset].error)
	}
	simplified, simplify_ok := _cluster_simplify(storage, gather, settings)
	if !simplify_ok do return 0, false
	group_error := max(child_error, simplified.error)
	if group_error <= child_error {
		group_error = child_error + max(child_error, 1) * CLUSTER_BUILD_ERROR_STEP
	}
	if state.group_count >= len(storage.groups) do return 0, false
	group_index := u32(state.group_count)
	for offset in 0 ..< child_count {
		storage.clusters[first_child + offset].group = group_index
		storage.clusters[first_child + offset].parent_error = group_error
	}
	if !_cluster_append(storage, state, simplified, settings, group_error) do return 0, false
	center, radius := _cluster_group_sphere(storage, first_child, child_count)
	storage.groups[state.group_count] = {
		first_child = u32(first_child),
		child_count = u32(child_count),
		center      = center,
		radius      = radius,
		error       = group_error,
		level       = u8(state.level + 1),
	}
	state.group_count += 1
	return group_error, true
}

@(private)
Cluster_Gather :: struct {
	vertex_count: int,
	index_count:  int,
}

// Copies a group's contiguous index range into the working buffers with local
// vertex numbering and carries the shared-vertex marks across as the lock mask.
// The stamp array makes the local numbering valid for exactly one group without
// clearing a whole level's worth of state per group.
@(private)
_cluster_gather :: proc(
	storage: Cluster_Build_Storage,
	first_child, child_count: int,
) -> (
	Cluster_Gather,
	bool,
) {
	assert(child_count > 0, "_cluster_gather: empty group")
	assert(first_child >= 0, "_cluster_gather: negative child index")
	first := storage.clusters[first_child].first_index
	last := first
	for offset in 0 ..< child_count {
		cluster := storage.clusters[first_child + offset]
		if cluster.first_index != last do return {}, false
		last = cluster.first_index + cluster.index_count
	}
	span := int(last - first)
	if span > CLUSTER_BUILD_MAX_GROUP_INDICES do return {}, false
	stamp := u32(first_child)
	result := Cluster_Gather {
		index_count = span,
	}
	for step in 0 ..< span {
		source := storage.indices[int(first) + step]
		if storage.stamp[source] != stamp {
			storage.stamp[source] = stamp
			storage.remap[source] = u32(result.vertex_count)
			storage.work_vertices[result.vertex_count] = storage.vertices[source]
			storage.locked[result.vertex_count] = storage.shared[source]
			result.vertex_count += 1
		}
		storage.work_indices[step] = storage.remap[source]
	}
	return result, true
}

@(private)
_cluster_simplify :: proc(
	storage: Cluster_Build_Storage,
	gather: Cluster_Gather,
	settings: Cluster_Settings,
) -> (
	Simplify_Result,
	bool,
) {
	assert(gather.index_count > 0, "_cluster_simplify: empty gather")
	assert(gather.vertex_count > 0, "_cluster_simplify: empty vertices")
	bounds := asset.Bounds_3D {
		minimum = storage.work_vertices[0].position,
		maximum = storage.work_vertices[0].position,
	}
	for index in 1 ..< gather.vertex_count {
		for axis in 0 ..< 3 {
			value := storage.work_vertices[index].position[axis]
			bounds.minimum[axis] = min(bounds.minimum[axis], value)
			bounds.maximum[axis] = max(bounds.maximum[axis], value)
		}
	}
	view := asset.Mesh_View {
		id        = 1,
		vertices  = storage.work_vertices[:gather.vertex_count],
		indices   = storage.work_indices[:gather.index_count],
		primitive = .Triangles,
		bounds    = bounds,
	}
	target := int(f32(gather.index_count) * settings.simplify_ratio)
	target = max(3, (target / 3) * 3)
	options := Simplify_Options {
		target_index_count = target,
	}
	return simplify_mesh(
		view,
		options,
		storage.locked[:gather.vertex_count],
		storage.out_vertices,
		storage.out_indices,
		storage.simplify,
	)
}

// Appends a simplified group to the level under construction and cuts it into
// parent clusters. Vertices are renumbered into the shared output array so
// cluster index spans stay global, which is what a V2 bundle stores.
@(private)
_cluster_append :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	simplified: Simplify_Result,
	settings: Cluster_Settings,
	error: f32,
) -> bool {
	assert(state != nil, "_cluster_append: nil state")
	assert(simplified.index_count > 0, "_cluster_append: empty result")
	if state.vertex_count + simplified.vertex_count > len(storage.vertices) do return false
	if state.index_count + simplified.index_count > len(storage.indices) do return false
	base := u32(state.vertex_count)
	for index in 0 ..< simplified.vertex_count {
		storage.vertices[state.vertex_count + index] = storage.out_vertices[index]
	}
	for index in 0 ..< simplified.index_count {
		storage.indices[state.index_count + index] = storage.out_indices[index] + base
	}
	first_index := state.index_count
	state.vertex_count += simplified.vertex_count
	state.index_count += simplified.index_count
	return _cluster_emit(storage, state, settings, first_index, simplified.index_count, error)
}

@(private)
_cluster_emit :: proc(
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
	first_index, index_count: int,
	error: f32,
) -> bool {
	assert(index_count > 0, "_cluster_emit: empty span")
	assert(index_count % 3 == 0, "_cluster_emit: incomplete triangle")
	triangles := index_count / 3
	for start := 0; start < triangles; start += settings.cluster_triangles {
		count := min(settings.cluster_triangles, triangles - start)
		if state.cluster_count >= len(storage.clusters) do return false
		first := u32(first_index + start * 3)
		center, radius := _cluster_sphere(storage, first, u32(count * 3))
		storage.clusters[state.cluster_count] = {
			first_index  = first,
			index_count  = u32(count * 3),
			center       = center,
			radius       = radius,
			error        = error,
			parent_error = asset.CLUSTER_ERROR_ROOT,
			group        = asset.CLUSTER_GROUP_NONE,
			level        = u8(state.level + 1),
		}
		state.cluster_count += 1
	}
	return true
}

// Level 0 is the source triangles, reordered for locality and cut into
// clusters. Later levels are produced by `_cluster_append` instead, because
// their geometry is created one group at a time.
@(private)
_cluster_partition_base :: proc(
	bounds: asset.Bounds_3D,
	storage: Cluster_Build_Storage,
	state: ^Cluster_Build_State,
	settings: Cluster_Settings,
) -> bool {
	assert(state != nil, "_cluster_partition_base: nil state")
	assert(settings.cluster_triangles > 0, "_cluster_partition_base: zero cluster size")
	if state.index_count <= 0 || state.index_count % 3 != 0 do return false
	triangles := state.index_count / 3
	if triangles > len(storage.keys) do return false
	_cluster_keys(bounds, storage, 0, triangles)
	_heap_sort(storage.keys[:triangles], _cluster_key_less)
	if !_cluster_reorder(storage, 0, triangles) do return false
	state.level_first = 0
	saved := state.level
	state.level = -1
	// `_cluster_emit` stamps `state.level + 1`, so level 0 is emitted by
	// borrowing the same helper rather than duplicating the cut.
	emitted := _cluster_emit(storage, state, settings, 0, state.index_count, 0)
	state.level = saved
	return emitted && state.cluster_count > 0
}
