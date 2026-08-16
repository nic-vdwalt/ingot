#+build !js
package asset

import "core:math"
import "core:testing"

_cluster_test_dag :: proc(clusters: []Cluster, groups: []Cluster_Group) -> Cluster_Dag {
	// Two leaf clusters replaced by one parent: the smallest graph that still
	// exercises every rule - span bounds, monotonic error, group membership,
	// and the level relationship that forbids cycles.
	clusters[0] = {
		first_index  = 0,
		index_count  = 3,
		center       = {0, 0, 0},
		radius       = 1,
		error        = 0,
		parent_error = 0.5,
		group        = 0,
		level        = 0,
	}
	clusters[1] = {
		first_index  = 3,
		index_count  = 3,
		center       = {1, 0, 0},
		radius       = 1,
		error        = 0,
		parent_error = 0.5,
		group        = 0,
		level        = 0,
	}
	clusters[2] = {
		first_index  = 6,
		index_count  = 3,
		center       = {0.5, 0, 0},
		radius       = 2,
		error        = 0.5,
		parent_error = CLUSTER_ERROR_ROOT,
		group        = CLUSTER_GROUP_NONE,
		level        = 1,
	}
	groups[0] = {
		first_child = 0,
		child_count = 2,
		center      = {0.5, 0, 0},
		radius      = 2,
		error       = 0.5,
		level       = 1,
	}
	return {clusters = clusters[:3], groups = groups[:1], level_count = 2}
}

@(test)
cluster_dag_validate_accepts_a_well_formed_graph :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	result, ok := cluster_dag_validate(dag, 9)
	testing.expectf(t, ok, "rejected: %v", result)
	testing.expect_value(t, cluster_dag_root_count(dag), u32(1))
}

@(test)
cluster_dag_validate_rejects_non_monotonic_error :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	// A parent no coarser than its child leaves the selection rule ambiguous.
	clusters[0].error = 0.5
	result, ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Non_Monotonic)
}

@(test)
cluster_dag_validate_rejects_group_error_disagreement :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	// Children of one group must agree on what replaces them, or the two would
	// switch level at different distances and crack apart.
	clusters[1].parent_error = 0.75
	result, ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Non_Monotonic)
}

// Cycles are impossible by construction: an edge always decreases `level` by
// exactly one, so a walk can never return to its start. This checks the rule
// that enforces it rather than searching for a cycle.
@(test)
cluster_dag_validate_rejects_level_inversion :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	clusters[0].level = 1
	result, ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Level_Overflow)
}

@(test)
cluster_dag_validate_rejects_out_of_range_span :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	result, ok := cluster_dag_validate(dag, 6)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Invalid_Span)
}

@(test)
cluster_dag_validate_rejects_unclosed_group :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	clusters[1].group = CLUSTER_GROUP_NONE
	result, ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !ok)
	testing.expect(t, result.fault == .Invalid_Group || result.fault == .Non_Monotonic)
}

@(test)
cluster_dag_validate_rejects_empty_and_oversized :: proc(t: ^testing.T) {
	empty := Cluster_Dag{}
	result, ok := cluster_dag_validate(empty, 0)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Empty)
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	dag.level_count = 0
	_, level_ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !level_ok)
}

@(test)
cluster_dag_validate_rejects_non_finite_bounds :: proc(t: ^testing.T) {
	clusters: [3]Cluster
	groups: [1]Cluster_Group
	dag := _cluster_test_dag(clusters[:], groups[:])
	clusters[0].radius = math.nan_f32()
	result, ok := cluster_dag_validate(dag, 9)
	testing.expect(t, !ok)
	testing.expect_value(t, result.fault, Cluster_Fault.Invalid_Bounds)
}
