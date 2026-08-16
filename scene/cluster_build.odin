package scene

import "core:math"
import "ingot:asset"

// Cluster-level draw list construction.
//
// The discrete path in `build.odin` picks one mesh per object from a distance
// table. This one picks a subset of one mesh's clusters, which is the whole
// point of a cluster DAG: a large object can be coarse where it is far and fine
// where it is near, inside a single draw.
//
// The selection rule is the one `asset/cluster.odin` documents:
//
//     draw cluster c  <=>  error(c) <= threshold  and  parent_error(c) > threshold
//
// with the threshold expressed in world units at the cluster's own distance.
// Evaluating it per cluster rather than per object is what lets neighbouring
// clusters land on different levels without cracking, because the cook step
// pinned their shared border.

SCENE_MAX_CLUSTER_DRAWS :: 8192

// A cluster draw references its object by position in the caller's array
// rather than copying the transform. Repeating 64 bytes of matrix for every one
// of a few thousand clusters would dominate the list for no benefit: the caller
// already owns the objects it passed in.
Cluster_Draw :: struct {
	first_index: u32,
	index_count: u32,
	object:      u32,
	material:    asset.Material_Id,
	_pad:        u16,
}

Cluster_Draw_List :: struct {
	draws:          [SCENE_MAX_CLUSTER_DRAWS]Cluster_Draw,
	count:          u32,
	overflow_count: u32,
	culled_count:   u32,
	// Clusters rejected because a coarser ancestor was chosen instead. Tracked
	// separately from frustum culling so a profile can tell "off screen" from
	// "resolved at a lower level".
	refined_count:  u32,
}

Cluster_Build_Input :: struct {
	frustum:         Frustum,
	camera_position: [3]f32,
	// Pixels of screen height per world unit at one unit of distance. A caller
	// derives it from its projection: viewport_height / (2 * tan(fovy / 2)).
	pixels_per_unit: f32,
	// Geometric error, in pixels, the renderer is willing to show. One pixel is
	// the usual choice; larger values trade fidelity for triangles.
	error_pixels:    f32,
}

Cluster_Object :: struct {
	id:        Object_Id,
	material:  asset.Material_Id,
	transform: Matrix_4,
	bounds:    asset.Bounds_3D,
	dag:       asset.Cluster_Dag,
	// Uniform scale applied by `transform`. Cluster errors and radii are in
	// mesh units, so they must be scaled before they can be compared against a
	// world-space threshold.
	scale:     f32,
	visible:   bool,
}

// build_cluster_draw_list selects clusters for one batch of objects. It is a
// separate entry point from `build_draw_list` rather than a mode of it, so the
// discrete LOD path stays exactly as it was for callers that do not cook
// cluster data.
build_cluster_draw_list :: proc(
	objects: []Cluster_Object,
	input: Cluster_Build_Input,
	output: ^Cluster_Draw_List,
) {
	assert(output != nil, "build_cluster_draw_list: nil output")
	assert(len(objects) <= SCENE_MAX_OBJECTS, "build_cluster_draw_list: object overflow")
	output^ = {}
	if !_cluster_input_valid(input) do return
	for index in 0 ..< len(objects) {
		object := objects[index]
		if !object.visible || len(object.dag.clusters) == 0 {
			output.culled_count += 1
			continue
		}
		if !frustum_intersects_bounds(input.frustum, object.bounds) {
			output.culled_count += 1
			continue
		}
		_cluster_select(object, u32(index), input, output)
	}
}

// cluster_screen_error is the selection threshold expressed the other way
// round: given a distance, how much mesh-unit error fits in the pixel budget.
// Comparing errors in world units rather than projecting each one keeps the
// inner loop free of a divide.
cluster_screen_error :: proc(input: Cluster_Build_Input, distance: f32) -> f32 {
	assert(input.pixels_per_unit > 0, "cluster_screen_error: non-positive projection")
	assert(input.error_pixels > 0, "cluster_screen_error: non-positive budget")
	// Behind or at the eye everything is maximally detailed; the clamp keeps
	// the threshold finite instead of dividing by zero.
	safe := max(distance, SCENE_CLUSTER_MIN_DISTANCE)
	return input.error_pixels * safe / input.pixels_per_unit
}

SCENE_CLUSTER_MIN_DISTANCE :: f32(0.001)

@(private)
_cluster_input_valid :: proc(input: Cluster_Build_Input) -> bool {
	if input.pixels_per_unit <= 0 || math.is_inf(input.pixels_per_unit, 0) do return false
	if input.error_pixels <= 0 || math.is_inf(input.error_pixels, 0) do return false
	if math.is_nan(input.pixels_per_unit) || math.is_nan(input.error_pixels) do return false
	for component in input.camera_position {
		if math.is_nan(component) || math.is_inf(component, 0) do return false
	}
	return true
}

@(private)
_cluster_select :: proc(
	object: Cluster_Object,
	position: u32,
	input: Cluster_Build_Input,
	output: ^Cluster_Draw_List,
) {
	assert(output != nil, "_cluster_select: nil output")
	assert(len(object.dag.clusters) > 0, "_cluster_select: empty graph")
	scale := object.scale if object.scale > 0 else 1
	for cluster in object.dag.clusters {
		distance := _cluster_distance(object, cluster, input, scale)
		threshold := cluster_screen_error(input, distance) / scale
		// A cluster is drawn only where its own error is acceptable and its
		// parent's is not, which selects exactly one level along every path
		// through the graph.
		if cluster.error > threshold {
			output.refined_count += 1
			continue
		}
		if cluster.parent_error <= threshold {
			output.refined_count += 1
			continue
		}
		if output.count >= SCENE_MAX_CLUSTER_DRAWS {
			output.overflow_count += 1
			continue
		}
		output.draws[output.count] = {
			first_index = cluster.first_index,
			index_count = cluster.index_count,
			object      = position,
			material    = object.material,
		}
		output.count += 1
	}
}

// Distance is measured to the cluster's bounding sphere surface, not its
// centre, so a large cluster the camera sits inside resolves at full detail
// instead of being treated as distant.
@(private)
_cluster_distance :: proc(
	object: Cluster_Object,
	cluster: asset.Cluster,
	input: Cluster_Build_Input,
	scale: f32,
) -> f32 {
	assert(scale > 0, "_cluster_distance: non-positive scale")
	assert(cluster.radius >= 0, "_cluster_distance: negative radius")
	center := _cluster_world_center(object, cluster, scale)
	dx := center[0] - input.camera_position[0]
	dy := center[1] - input.camera_position[1]
	dz := center[2] - input.camera_position[2]
	distance := math.sqrt(dx * dx + dy * dy + dz * dz)
	return max(distance - cluster.radius * scale, 0)
}

@(private)
_cluster_world_center :: proc(
	object: Cluster_Object,
	cluster: asset.Cluster,
	scale: f32,
) -> [3]f32 {
	assert(scale > 0, "_cluster_world_center: non-positive scale")
	assert(cluster.radius >= 0, "_cluster_world_center: negative radius")
	local := cluster.center
	return {
		object.transform[0] * local[0] +
		object.transform[4] * local[1] +
		object.transform[8] * local[2] +
		object.transform[12],
		object.transform[1] * local[0] +
		object.transform[5] * local[1] +
		object.transform[9] * local[2] +
		object.transform[13],
		object.transform[2] * local[0] +
		object.transform[6] * local[1] +
		object.transform[10] * local[2] +
		object.transform[14],
	}
}

#assert(size_of(Cluster_Draw) == 16)
