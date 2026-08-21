#+build !js
package procgen

import asset "../asset"
import "core:testing"

@(test)
cook_thresholds_follow_the_offline_tool :: proc(t: ^testing.T) {
	testing.expect_value(t, cook_lod_threshold(0), COOK_LOD_SCREEN_BASE)
	testing.expect_value(t, cook_lod_threshold(1), COOK_LOD_SCREEN_BASE / 4)
	testing.expect_value(t, cook_lod_threshold(2), COOK_LOD_SCREEN_BASE / 16)
	// Strictly decreasing is a decoder rule, not a preference.
	previous := max(f32)
	for level in 0 ..< COOK_LOD_MAX_LEVELS {
		threshold := cook_lod_threshold(level)
		testing.expect(t, threshold < previous)
		previous = threshold
	}
}

@(test)
cook_chain_from_policy_builds_a_monotonic_chain :: proc(t: ^testing.T) {
	vertices := make([]asset.Vertex, 33 * 33)
	defer delete(vertices)
	indices := make([]u32, 32 * 32 * 6)
	defer delete(indices)
	source := mesh_test_grid(32, vertices, indices)
	for policy in Cook_Lod_Policy {
		storage := _cook_test_storage(len(vertices), len(indices), policy)
		defer _cook_test_storage_free(storage)
		chain, ok := cook_chain_from_policy(source, policy, storage)
		testing.expectf(t, ok, "policy %v was rejected", policy)
		testing.expect(t, len(chain.lods) >= 1)
		testing.expect(t, len(chain.lods) <= len(cook_lod_ratios(policy)))
		previous_error := f32(-1)
		previous_threshold := max(f32)
		previous_indices := max(int)
		for lod in chain.lods {
			testing.expect(t, lod.error > previous_error)
			testing.expect(t, lod.screen_height_threshold < previous_threshold)
			// A level that removed nothing would be a duplicate, which the
			// chain must end before rather than store.
			testing.expect(t, len(lod.view.indices) < previous_indices)
			previous_error = lod.error
			previous_threshold = lod.screen_height_threshold
			previous_indices = len(lod.view.indices)
		}
	}
}

// The milestone: a generated mesh reaches INGMESH2 bytes and comes back out
// intact, without leaving the process.
@(test)
cook_terrain_volume_round_trips_through_ingmesh2 :: proc(t: ^testing.T) {
	storage := new(Terrain_V3_Test_Storage)
	defer free(storage)
	buffer := _terrain_v3_test_buffer(storage, 7)
	recipe := terrain_abstract_recipe_v3(2024)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	result, generated := terrain_generate_volume_v3(&recipe, request, &buffer)
	testing.expect(t, generated)
	testing.expect(t, result.index_count > 0)
	source, view_ok := asset.mesh_view(&buffer.mesh)
	testing.expect(t, view_ok)
	cook := _cook_test_storage(len(source.vertices), len(source.indices), .Structure_3)
	defer _cook_test_storage_free(cook)
	chain, chain_ok := cook_chain_from_policy(source, .Structure_3, cook)
	testing.expect(t, chain_ok)
	_cook_test_expect_round_trip(t, chain, 0)
	_cook_test_expect_round_trip(t, chain, asset.COOKED_MESH_V2_FLAG_PACKED_VERTICES)
}

@(test)
cook_chain_from_clusters_round_trips_with_its_dag :: proc(t: ^testing.T) {
	vertices := make([]asset.Vertex, 33 * 33)
	defer delete(vertices)
	indices := make([]u32, 32 * 32 * 6)
	defer delete(indices)
	source := mesh_test_grid(32, vertices, indices)
	options := Cluster_Build_Options{}
	cook := _cook_test_cluster_storage(len(vertices), len(indices), options)
	defer _cook_test_storage_free(cook)
	defer _cluster_test_storage_free(cook.cluster)
	chain, ok := cook_chain_from_clusters(source, options, cook)
	testing.expect(t, ok)
	testing.expect(t, len(chain.dag.clusters) > 0)
	testing.expect_value(t, chain.dag.level_count, u8(len(chain.lods)))
	// The DAG the encoder writes must be the DAG the decoder reads back.
	decoded := _cook_test_expect_round_trip(t, chain, asset.COOKED_MESH_V2_FLAG_CLUSTERS)
	testing.expect_value(t, len(decoded.dag.clusters), len(chain.dag.clusters))
	testing.expect_value(t, len(decoded.dag.groups), len(chain.dag.groups))
	for cluster, index in decoded.dag.clusters {
		source_cluster := chain.dag.clusters[index]
		testing.expect_value(t, cluster.index_count, source_cluster.index_count)
		testing.expect_value(t, cluster.error, source_cluster.error)
		testing.expect_value(t, cluster.parent_error, source_cluster.parent_error)
		testing.expect_value(t, cluster.group, source_cluster.group)
		testing.expect_value(t, cluster.level, source_cluster.level)
	}
}

@(test)
cook_chain_rejects_short_storage_without_publication :: proc(t: ^testing.T) {
	vertices := make([]asset.Vertex, 9 * 9)
	defer delete(vertices)
	indices := make([]u32, 8 * 8 * 6)
	defer delete(indices)
	source := mesh_test_grid(8, vertices, indices)
	storage := _cook_test_storage(len(vertices), len(indices), .Tree_4)
	defer _cook_test_storage_free(storage)
	short := storage
	short.lods = storage.lods[:1]
	_, ok := cook_chain_from_policy(source, .Tree_4, short)
	testing.expect(t, !ok)
	starved := storage
	starved.vertices = storage.vertices[:4]
	_, starved_ok := cook_chain_from_policy(source, .Tree_4, starved)
	testing.expect(t, !starved_ok)
	// A zero id cannot be cooked: the format reserves it as "no mesh".
	anonymous := source
	anonymous.id = 0
	_, anonymous_ok := cook_chain_from_policy(anonymous, .Tree_4, storage)
	testing.expect(t, !anonymous_ok)
}

@(private = "file")
_cook_test_expect_round_trip :: proc(
	t: ^testing.T,
	chain: asset.Cooked_Mesh_Chain,
	flags: u32,
) -> asset.Cooked_Mesh_Chain {
	assert(t != nil, "_cook_test_expect_round_trip: nil test")
	size, size_ok := asset.cooked_mesh_v2_encoded_size({chain}, flags)
	testing.expect(t, size_ok)
	bytes := make([]u8, size)
	defer delete(bytes)
	written, fault, ok := asset.cooked_mesh_v2_encode({chain}, flags, bytes)
	testing.expectf(t, ok, "encode rejected a cooked chain with %v", fault.fault)
	testing.expect_value(t, written, size)
	lod_total, cluster_total, group_total := len(chain.lods), 0, 0
	vertex_total, index_total := 0, 0
	cluster_total = len(chain.dag.clusters)
	group_total = len(chain.dag.groups)
	for lod in chain.lods {
		vertex_total += len(lod.view.vertices)
		index_total += len(lod.view.indices)
	}
	storage := asset.Cooked_Mesh_V2_Storage {
		meshes   = make([]asset.Cooked_Mesh_Chain, 1),
		lods     = make([]asset.Mesh_Lod, lod_total),
		clusters = make([]asset.Cluster, max(cluster_total, 1)),
		groups   = make([]asset.Cluster_Group, max(group_total, 1)),
		vertices = make([]asset.Vertex, vertex_total),
		indices  = make([]u32, index_total),
	}
	defer delete(storage.meshes)
	defer delete(storage.lods)
	defer delete(storage.clusters)
	defer delete(storage.groups)
	defer delete(storage.vertices)
	defer delete(storage.indices)
	bundle, result, decode_ok := asset.cooked_mesh_v2_decode(bytes[:written], storage)
	testing.expectf(t, decode_ok, "decode rejected cooked bytes with %v", result.fault)
	if !decode_ok do return {}
	decoded := bundle.meshes[0]
	testing.expect_value(t, decoded.id, chain.id)
	testing.expect_value(t, len(decoded.lods), len(chain.lods))
	for lod, level in decoded.lods {
		testing.expect_value(t, lod.error, chain.lods[level].error)
		testing.expect_value(
			t,
			lod.screen_height_threshold,
			chain.lods[level].screen_height_threshold,
		)
		testing.expect(t, asset.mesh_validate(lod.view))
	}
	return decoded
}

@(private = "file")
_cook_test_storage :: proc(
	vertex_count, index_count: int,
	policy: Cook_Lod_Policy,
) -> Cook_Chain_Storage {
	lod_max, vertex_max, index_max, ok := cook_chain_requirements(
		vertex_count,
		index_count,
		policy,
	)
	assert(ok, "_cook_test_storage: unsupported policy")
	return Cook_Chain_Storage {
		lods = make([]asset.Mesh_Lod, lod_max),
		vertices = make([]asset.Vertex, vertex_max),
		indices = make([]u32, index_max),
		clusters = make([]asset.Cluster, asset.CLUSTER_MAX_LEVELS * 4096),
		groups = make([]asset.Cluster_Group, asset.CLUSTER_MAX_LEVELS * 4096),
		simplify = mesh_test_scratch(vertex_count, index_count),
		optimize = mesh_test_optimize_scratch(vertex_count, index_count),
		work_vertices = make([]asset.Vertex, vertex_count),
		work_indices = make([]u32, index_count),
	}
}

@(test)
mesh_workspace_carves_both_scratch_views :: proc(t: ^testing.T) {
	vertex_count := 81
	index_count := 384
	bytes := mesh_workspace_size(vertex_count, index_count)
	block := make([]u8, bytes)
	defer delete(block)
	workspace, ok := mesh_workspace_make(block, vertex_count, index_count)
	testing.expect(t, ok)
	simplify, simplify_ok := mesh_workspace_simplify(workspace, vertex_count, index_count)
	testing.expect(t, simplify_ok)
	optimize, optimize_ok := mesh_workspace_optimize(workspace, vertex_count, index_count)
	testing.expect(t, optimize_ok)
	testing.expect_value(
		t,
		uintptr(raw_data(simplify.quadrics)),
		uintptr(raw_data(optimize.adjacency_offset)),
	)
	_, short_ok := mesh_workspace_make(block[:len(block) - 1], vertex_count, index_count)
	testing.expect(t, !short_ok)
}

@(private = "file")
_cook_test_cluster_storage :: proc(
	vertex_count, index_count: int,
	options: Cluster_Build_Options,
) -> Cook_Chain_Storage {
	lod_max, index_max, ok := cook_cluster_requirements(vertex_count, index_count)
	assert(ok, "_cook_test_cluster_storage: unsupported source")
	return Cook_Chain_Storage {
		lods = make([]asset.Mesh_Lod, lod_max),
		indices = make([]u32, index_max),
		clusters = make([]asset.Cluster, asset.CLUSTER_MAX_LEVELS * 4096),
		groups = make([]asset.Cluster_Group, asset.CLUSTER_MAX_LEVELS * 4096),
		cluster = _cluster_test_storage(vertex_count, index_count, options),
	}
}

@(private = "file")
_cook_test_storage_free :: proc(storage: Cook_Chain_Storage) {
	delete(storage.lods)
	delete(storage.vertices)
	delete(storage.indices)
	delete(storage.clusters)
	delete(storage.groups)
	mesh_test_scratch_free(storage.simplify)
	mesh_test_optimize_scratch_free(storage.optimize)
	delete(storage.work_vertices)
	delete(storage.work_indices)
}
