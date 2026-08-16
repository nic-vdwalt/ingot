package asset

import "core:math"

// Cluster LOD data. A cooked mesh may carry a directed acyclic graph of
// triangle clusters instead of, or alongside, a discrete LOD chain. The graph
// is built offline by `ingot:procgen`; this package only defines the shape and
// proves a decoded graph cannot crack, cycle, or index out of range.
//
// The selection rule the whole structure exists to serve is:
//
//     draw cluster c  <=>  error(c) <= threshold  and  parent_error(c) > threshold
//
// Because every cluster in a group shares one `parent_error`, and because a
// group's simplification locks its outer boundary vertices, two neighbouring
// clusters resolved at different levels still meet along bit-identical
// positions. That is the entire crack-free guarantee, and `cluster_dag_validate`
// is what checks the encoder actually upheld it.

// A cluster holds at most this many triangles so a future GPU path can map one
// cluster onto one workgroup without a second level of chunking.
CLUSTER_MAX_TRIANGLES :: 128
// The builder aims for this many unique vertices per cluster because a
// well-connected triangle strip averages roughly half a vertex per triangle;
// it is a locality target, not a structural limit.
CLUSTER_TARGET_VERTICES :: 64
// The structural limit: a 128-triangle cluster cannot reference more unique
// vertices than it has corners.
CLUSTER_MAX_VERTICES :: 3 * CLUSTER_MAX_TRIANGLES
// Levels are bounded so the builder's outer loop has a named upper bound and
// `level` fits a u8. Halving cluster count per level, 32 levels covers far
// more geometry than `GPU_3D_MAX_INDICES` can hold.
CLUSTER_MAX_LEVELS :: 32
CLUSTER_MAX_GROUP_CHILDREN :: 16
// The root cluster has no parent, so nothing can ever be coarse enough to
// replace it. A finite sentinel keeps the field inside the finiteness checks
// every other float in the format has to pass.
CLUSTER_ERROR_ROOT :: max(f32)
CLUSTER_GROUP_NONE :: max(u32)

Cluster :: struct {
	// Index span into the bundle's shared index array.
	first_index:  u32,
	index_count:  u32,
	// Bounding sphere in mesh-local space, used for frustum and screen-error
	// tests before the index span is ever touched.
	center:       Vec3,
	radius:       f32,
	// Geometric error this cluster's own simplification introduced, in mesh
	// units. Leaf clusters carry zero: they are the source triangles.
	error:        f32,
	// Error of the group that replaces this cluster one level up. Strictly
	// greater than `error`, so the selection rule picks exactly one level.
	parent_error: f32,
	group:        u32,
	level:        u8,
}

Cluster_Group :: struct {
	// Contiguous span into the DAG's cluster array. Children of a group are
	// always adjacent, which is what lets validation walk the graph without
	// recursion.
	first_child: u32,
	child_count: u32,
	center:      Vec3,
	radius:      f32,
	// Every child of this group reports exactly this value as `parent_error`.
	error:       f32,
	level:       u8,
}

Cluster_Dag :: struct {
	clusters:    []Cluster,
	groups:      []Cluster_Group,
	level_count: u8,
}

Cluster_Fault :: enum u8 {
	None,
	Empty,
	Capacity,
	Invalid_Span,
	Invalid_Bounds,
	Invalid_Error,
	Non_Monotonic,
	Invalid_Group,
	Level_Overflow,
}

Cluster_Result :: struct {
	fault:   Cluster_Fault,
	cluster: u32,
	group:   u32,
}

// cluster_dag_validate proves a decoded graph is safe to select from. It is
// the counterpart of `mesh_validate`: callers may trust a graph that passes and
// must reject one that does not, because every later stage indexes without
// re-checking.
cluster_dag_validate :: proc(dag: Cluster_Dag, index_count: u32) -> (Cluster_Result, bool) {
	assert(len(dag.clusters) <= int(max(u32)), "cluster_dag_validate: cluster count overflow")
	assert(len(dag.groups) <= int(max(u32)), "cluster_dag_validate: group count overflow")
	if len(dag.clusters) == 0 do return {fault = .Empty}, false
	if dag.level_count == 0 || int(dag.level_count) > CLUSTER_MAX_LEVELS {
		return {fault = .Level_Overflow}, false
	}
	if result, ok := _cluster_validate_clusters(dag, index_count); !ok do return result, false
	if result, ok := _cluster_validate_groups(dag); !ok do return result, false
	return {}, true
}

// cluster_dag_root_count reports how many clusters have no parent group. A
// well-formed graph converges, so this is one; the count is exposed because a
// disconnected source mesh legitimately produces one root per component.
cluster_dag_root_count :: proc(dag: Cluster_Dag) -> u32 {
	assert(len(dag.clusters) > 0, "cluster_dag_root_count: empty graph")
	assert(int(dag.level_count) <= CLUSTER_MAX_LEVELS, "cluster_dag_root_count: level overflow")
	result := u32(0)
	for cluster in dag.clusters {
		if cluster.group == CLUSTER_GROUP_NONE do result += 1
	}
	return result
}

@(private)
_cluster_validate_clusters :: proc(dag: Cluster_Dag, index_count: u32) -> (Cluster_Result, bool) {
	assert(len(dag.clusters) > 0, "_cluster_validate_clusters: empty graph")
	assert(dag.level_count > 0, "_cluster_validate_clusters: zero levels")
	for index in 0 ..< len(dag.clusters) {
		cluster := dag.clusters[index]
		position := u32(index)
		if cluster.index_count == 0 ||
		   cluster.index_count % 3 != 0 ||
		   cluster.index_count > u32(CLUSTER_MAX_TRIANGLES * 3) {
			return {fault = .Invalid_Span, cluster = position}, false
		}
		if u64(cluster.first_index) + u64(cluster.index_count) > u64(index_count) {
			return {fault = .Invalid_Span, cluster = position}, false
		}
		if !_cluster_sphere_valid(cluster.center, cluster.radius) {
			return {fault = .Invalid_Bounds, cluster = position}, false
		}
		if !_cluster_error_valid(cluster.error) || cluster.error < 0 {
			return {fault = .Invalid_Error, cluster = position}, false
		}
		// A parent that is not strictly coarser would make the selection rule
		// ambiguous: two levels would qualify at the same threshold.
		if !_cluster_error_valid(cluster.parent_error) || cluster.parent_error <= cluster.error {
			return {fault = .Non_Monotonic, cluster = position}, false
		}
		if int(cluster.level) >= int(dag.level_count) {
			return {fault = .Level_Overflow, cluster = position}, false
		}
		if cluster.group != CLUSTER_GROUP_NONE && int(cluster.group) >= len(dag.groups) {
			return {fault = .Invalid_Group, cluster = position, group = cluster.group}, false
		}
		if cluster.group == CLUSTER_GROUP_NONE && cluster.parent_error != CLUSTER_ERROR_ROOT {
			return {fault = .Non_Monotonic, cluster = position}, false
		}
	}
	return {}, true
}

@(private)
_cluster_validate_groups :: proc(dag: Cluster_Dag) -> (Cluster_Result, bool) {
	assert(len(dag.clusters) > 0, "_cluster_validate_groups: empty graph")
	assert(dag.level_count > 0, "_cluster_validate_groups: zero levels")
	for index in 0 ..< len(dag.groups) {
		group := dag.groups[index]
		position := u32(index)
		if group.child_count == 0 || group.child_count > CLUSTER_MAX_GROUP_CHILDREN {
			return {fault = .Invalid_Group, group = position}, false
		}
		last := u64(group.first_child) + u64(group.child_count)
		if last > u64(len(dag.clusters)) {
			return {fault = .Invalid_Group, group = position}, false
		}
		if !_cluster_sphere_valid(group.center, group.radius) {
			return {fault = .Invalid_Bounds, group = position}, false
		}
		if !_cluster_error_valid(group.error) || group.error < 0 {
			return {fault = .Invalid_Error, group = position}, false
		}
		if int(group.level) >= int(dag.level_count) {
			return {fault = .Level_Overflow, group = position}, false
		}
		if result, ok := _cluster_validate_children(dag, group, position); !ok do return result, false
	}
	return {}, true
}

// A group's children must all sit one level below it and agree on the error
// this group will replace them with. The level rule is also what forbids
// cycles: an edge always decreases `level` by exactly one, so no walk can
// return to where it started.
@(private)
_cluster_validate_children :: proc(
	dag: Cluster_Dag,
	group: Cluster_Group,
	position: u32,
) -> (
	Cluster_Result,
	bool,
) {
	assert(group.child_count > 0, "_cluster_validate_children: empty group")
	assert(
		u64(group.first_child) + u64(group.child_count) <= u64(len(dag.clusters)),
		"_cluster_validate_children: unchecked span",
	)
	for offset in 0 ..< group.child_count {
		child_index := group.first_child + offset
		child := dag.clusters[child_index]
		if child.group != position {
			return {fault = .Invalid_Group, cluster = child_index, group = position}, false
		}
		if int(child.level) + 1 != int(group.level) {
			return {fault = .Level_Overflow, cluster = child_index, group = position}, false
		}
		if child.parent_error != group.error {
			return {fault = .Non_Monotonic, cluster = child_index, group = position}, false
		}
	}
	return {}, true
}

@(private)
_cluster_sphere_valid :: proc(center: Vec3, radius: f32) -> bool {
	for component in center {
		if math.is_nan(component) || math.is_inf(component, 0) do return false
	}
	if math.is_nan(radius) || math.is_inf(radius, 0) do return false
	return radius >= 0
}

@(private)
_cluster_error_valid :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value, 0)
}

#assert(CLUSTER_MAX_VERTICES == 3 * CLUSTER_MAX_TRIANGLES)
#assert(CLUSTER_TARGET_VERTICES <= CLUSTER_MAX_VERTICES)
#assert(CLUSTER_MAX_LEVELS <= int(max(u8)))
