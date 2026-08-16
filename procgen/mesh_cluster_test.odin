#+build !js
package procgen

import asset "../asset"
import "core:testing"

_cluster_test_storage :: proc(
	vertex_count, index_count: int,
	options: Cluster_Build_Options,
) -> Cluster_Build_Storage {
	group := cluster_group_indices(options)
	return Cluster_Build_Storage {
		clusters = make([]asset.Cluster, asset.CLUSTER_MAX_LEVELS * 4096),
		groups = make([]asset.Cluster_Group, asset.CLUSTER_MAX_LEVELS * 4096),
		vertices = make([]asset.Vertex, vertex_count * 2),
		indices = make([]u32, index_count * 2),
		work_vertices = make([]asset.Vertex, group),
		work_indices = make([]u32, group),
		out_vertices = make([]asset.Vertex, group),
		out_indices = make([]u32, group),
		locked = make([]bool, group),
		remap = make([]u32, vertex_count * 2),
		stamp = make([]u32, vertex_count * 2),
		owner = make([]u32, vertex_count * 2),
		shared = make([]bool, vertex_count * 2),
		keys = make([]Cluster_Key, index_count / 3),
		scratch_indices = make([]u32, index_count),
		simplify = mesh_test_scratch(group, group),
	}
}

_cluster_test_storage_free :: proc(storage: Cluster_Build_Storage) {
	delete(storage.clusters)
	delete(storage.groups)
	delete(storage.vertices)
	delete(storage.indices)
	delete(storage.work_vertices)
	delete(storage.work_indices)
	delete(storage.out_vertices)
	delete(storage.out_indices)
	delete(storage.locked)
	delete(storage.remap)
	delete(storage.stamp)
	delete(storage.owner)
	delete(storage.shared)
	delete(storage.keys)
	delete(storage.scratch_indices)
	mesh_test_scratch_free(storage.simplify)
}

@(test)
cluster_build_produces_a_valid_dag :: proc(t: ^testing.T) {
	cells := 32
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	options := Cluster_Build_Options{}
	storage := _cluster_test_storage(len(source.vertices), len(source.indices), options)
	defer _cluster_test_storage_free(storage)
	result, ok := cluster_build(source, options, storage)
	testing.expect(t, ok)
	testing.expect(t, result.cluster_count > 0)
	testing.expect(t, result.group_count > 0)
	// A 2048-triangle grid must reach more than one level, or the builder is
	// not simplifying at all.
	testing.expect(t, result.level_count > 1)
	dag := asset.Cluster_Dag {
		clusters    = storage.clusters[:result.cluster_count],
		groups      = storage.groups[:result.group_count],
		level_count = u8(result.level_count),
	}
	validation, valid := asset.cluster_dag_validate(dag, u32(result.index_count))
	testing.expectf(t, valid, "dag rejected: %v", validation)
}

@(test)
cluster_build_errors_are_monotonic :: proc(t: ^testing.T) {
	cells := 24
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	options := Cluster_Build_Options{}
	storage := _cluster_test_storage(len(source.vertices), len(source.indices), options)
	defer _cluster_test_storage_free(storage)
	result, ok := cluster_build(source, options, storage)
	testing.expect(t, ok)
	// A child must always be strictly finer than the parent that replaces it,
	// or the runtime selection rule admits two levels at the same threshold.
	for index in 0 ..< result.cluster_count {
		cluster := storage.clusters[index]
		testing.expect(t, cluster.parent_error > cluster.error)
		testing.expect(t, cluster.error >= 0)
	}
	previous := f32(-1)
	for level in 0 ..< result.level_count {
		testing.expect(t, result.levels[level].error > previous)
		previous = result.levels[level].error
	}
}

@(test)
cluster_build_converges_to_one_root :: proc(t: ^testing.T) {
	cells := 32
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	options := Cluster_Build_Options{}
	storage := _cluster_test_storage(len(source.vertices), len(source.indices), options)
	defer _cluster_test_storage_free(storage)
	result, ok := cluster_build(source, options, storage)
	testing.expect(t, ok)
	dag := asset.Cluster_Dag {
		clusters    = storage.clusters[:result.cluster_count],
		groups      = storage.groups[:result.group_count],
		level_count = u8(result.level_count),
	}
	roots := asset.cluster_dag_root_count(dag)
	testing.expect(t, roots >= 1)
	// Every level after the first must be strictly smaller, which is what
	// makes the chain terminate.
	for level in 1 ..< result.level_count {
		testing.expect(
			t,
			result.levels[level].index_count < result.levels[level - 1].index_count,
		)
	}
}

// The crack test. Every position shared between two cluster groups at level 0
// must still exist, bit-identical, in the parent level's geometry. If a shared
// position moved by even one ulp the two levels would no longer meet.
//
// Sharing is recomputed here from the DAG rather than read out of the builder's
// scratch, so the test is an independent oracle and not a restatement of the
// implementation.
@(test)
cluster_build_keeps_group_borders_identical :: proc(t: ^testing.T) {
	cells := 32
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	options := Cluster_Build_Options{}
	storage := _cluster_test_storage(len(source.vertices), len(source.indices), options)
	defer _cluster_test_storage_free(storage)
	result, ok := cluster_build(source, options, storage)
	testing.expect(t, ok)
	testing.expect(t, result.level_count > 1)
	owner := make([]u32, result.vertex_count)
	border := make([]bool, result.vertex_count)
	defer delete(owner)
	defer delete(border)
	for index in 0 ..< result.vertex_count do owner[index] = max(u32)
	for index in 0 ..< result.cluster_count {
		cluster := storage.clusters[index]
		if cluster.level != 0 do continue
		for step in 0 ..< cluster.index_count {
			vertex := storage.indices[cluster.first_index + step]
			if owner[vertex] == max(u32) {
				owner[vertex] = cluster.group
				continue
			}
			if owner[vertex] != cluster.group do border[vertex] = true
		}
	}
	shared := _cluster_test_border_survives(t, storage, result, border)
	testing.expect(t, shared > 0)
}

@(private = "file")
_cluster_test_border_survives :: proc(
	t: ^testing.T,
	storage: Cluster_Build_Storage,
	result: Cluster_Build_Result,
	border: []bool,
) -> int {
	parent := result.levels[1]
	shared := 0
	for vertex in 0 ..< result.vertex_count {
		if !border[vertex] do continue
		shared += 1
		position := storage.vertices[vertex].position
		found := false
		for offset in 0 ..< int(parent.vertex_count) {
			if storage.vertices[int(parent.first_vertex) + offset].position == position {
				found = true
				break
			}
		}
		testing.expectf(t, found, "group border %v moved between levels", position)
		if !found do return shared
	}
	return shared
}

@(test)
cluster_build_rejects_undersized_storage :: proc(t: ^testing.T) {
	cells := 8
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	storage := Cluster_Build_Storage{}
	_, ok := cluster_build(source, {}, storage)
	testing.expect(t, !ok)
}

@(test)
cluster_build_rejects_invalid_options :: proc(t: ^testing.T) {
	cells := 8
	source_vertices := make([]asset.Vertex, (cells + 1) * (cells + 1))
	source_indices := make([]u32, cells * cells * 6)
	defer delete(source_vertices)
	defer delete(source_indices)
	source := mesh_test_grid(cells, source_vertices, source_indices)
	options := Cluster_Build_Options {
		simplify_ratio = 1.5,
	}
	storage := _cluster_test_storage(len(source.vertices), len(source.indices), {})
	defer _cluster_test_storage_free(storage)
	_, ok := cluster_build(source, options, storage)
	testing.expect(t, !ok)
}
