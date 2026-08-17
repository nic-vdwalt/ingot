#+build !js
package scene

import "core:testing"
import "ingot:asset"

_cluster_scene_test_dag :: proc(
	clusters: []asset.Cluster,
	groups: []asset.Cluster_Group,
) -> asset.Cluster_Dag {
	clusters[0] = {
		first_index  = 0,
		index_count  = 3,
		center       = {-1, 0, 0},
		radius       = 1,
		error        = 0,
		parent_error = 1,
		group        = 0,
		level        = 0,
	}
	clusters[1] = {
		first_index  = 3,
		index_count  = 3,
		center       = {1, 0, 0},
		radius       = 1,
		error        = 0,
		parent_error = 1,
		group        = 0,
		level        = 0,
	}
	clusters[2] = {
		first_index  = 6,
		index_count  = 3,
		center       = {0, 0, 0},
		radius       = 2,
		error        = 1,
		parent_error = asset.CLUSTER_ERROR_ROOT,
		group        = asset.CLUSTER_GROUP_NONE,
		level        = 1,
	}
	groups[0] = {
		first_child = 0,
		child_count = 2,
		center      = {0, 0, 0},
		radius      = 2,
		error       = 1,
		level       = 1,
	}
	return {clusters = clusters[:3], groups = groups[:1], level_count = 2}
}

_cluster_scene_test_object :: proc(dag: asset.Cluster_Dag) -> Cluster_Object {
	identity := Matrix_4{1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1}
	return Cluster_Object {
		id = 1,
		material = 1,
		transform = identity,
		bounds = {minimum = {-2, -2, -2}, maximum = {2, 2, 2}},
		dag = dag,
		scale = 1,
		visible = true,
	}
}

_cluster_scene_test_frustum :: proc() -> Frustum {
	// Six planes facing inward around a generous box, so the frustum test never
	// interferes with what these cases are actually measuring.
	result: Frustum
	normals := [6][3]f32{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}
	for normal, index in normals {
		result.planes[index] = {
			normal   = normal,
			distance = 10_000,
		}
	}
	return result
}

@(test)
cluster_draw_list_picks_leaves_up_close :: proc(t: ^testing.T) {
	clusters: [3]asset.Cluster
	groups: [1]asset.Cluster_Group
	dag := _cluster_scene_test_dag(clusters[:], groups[:])
	objects := [1]Cluster_Object{_cluster_scene_test_object(dag)}
	input := Cluster_Build_Input {
		frustum         = _cluster_scene_test_frustum(),
		camera_position = {0, 0, 3},
		pixels_per_unit = 1000,
		error_pixels    = 1,
	}
	output: Cluster_Draw_List
	build_cluster_draw_list(objects[:], input, &output)
	// Close in, the parent's error exceeds the budget, so both leaves draw.
	testing.expect_value(t, output.count, u32(2))
	testing.expect_value(t, output.overflow_count, u32(0))
}

@(test)
cluster_draw_list_picks_the_root_far_away :: proc(t: ^testing.T) {
	clusters: [3]asset.Cluster
	groups: [1]asset.Cluster_Group
	dag := _cluster_scene_test_dag(clusters[:], groups[:])
	objects := [1]Cluster_Object{_cluster_scene_test_object(dag)}
	input := Cluster_Build_Input {
		frustum         = _cluster_scene_test_frustum(),
		camera_position = {0, 0, 100_000},
		pixels_per_unit = 1000,
		error_pixels    = 1,
	}
	output: Cluster_Draw_List
	build_cluster_draw_list(objects[:], input, &output)
	testing.expect_value(t, output.count, u32(1))
	testing.expect_value(t, output.draws[0].first_index, u32(6))
	testing.expect_value(t, output.refined_count, u32(2))
}

// The rule must select exactly one level along every path, at every distance.
// Sweeping the camera out is the cheapest way to catch a boundary where two
// levels qualify at once (double geometry) or neither does (a hole).
@(test)
cluster_draw_list_selects_one_level_at_every_distance :: proc(t: ^testing.T) {
	clusters: [3]asset.Cluster
	groups: [1]asset.Cluster_Group
	dag := _cluster_scene_test_dag(clusters[:], groups[:])
	objects := [1]Cluster_Object{_cluster_scene_test_object(dag)}
	for step in 1 ..= 400 {
		input := Cluster_Build_Input {
			frustum         = _cluster_scene_test_frustum(),
			camera_position = {0, 0, f32(step) * 25},
			pixels_per_unit = 1000,
			error_pixels    = 1,
		}
		output: Cluster_Draw_List
		build_cluster_draw_list(objects[:], input, &output)
		leaves := u32(0)
		roots := u32(0)
		for index in 0 ..< output.count {
			if output.draws[index].first_index == 6 do roots += 1
			else do leaves += 1
		}
		testing.expectf(
			t,
			(leaves == 2 && roots == 0) || (leaves == 0 && roots == 1),
			"step %v selected %v leaves and %v roots",
			step,
			leaves,
			roots,
		)
	}
}

@(test)
cluster_draw_list_rejects_invalid_input :: proc(t: ^testing.T) {
	clusters: [3]asset.Cluster
	groups: [1]asset.Cluster_Group
	dag := _cluster_scene_test_dag(clusters[:], groups[:])
	objects := [1]Cluster_Object{_cluster_scene_test_object(dag)}
	output: Cluster_Draw_List
	build_cluster_draw_list(objects[:], {frustum = _cluster_scene_test_frustum()}, &output)
	testing.expect_value(t, output.count, u32(0))
}

@(test)
cluster_draw_list_culls_invisible_objects :: proc(t: ^testing.T) {
	clusters: [3]asset.Cluster
	groups: [1]asset.Cluster_Group
	dag := _cluster_scene_test_dag(clusters[:], groups[:])
	object := _cluster_scene_test_object(dag)
	object.visible = false
	objects := [1]Cluster_Object{object}
	input := Cluster_Build_Input {
		frustum         = _cluster_scene_test_frustum(),
		camera_position = {0, 0, 3},
		pixels_per_unit = 1000,
		error_pixels    = 1,
	}
	output: Cluster_Draw_List
	build_cluster_draw_list(objects[:], input, &output)
	testing.expect_value(t, output.count, u32(0))
	testing.expect_value(t, output.culled_count, u32(1))
}

@(test)
cluster_screen_error_grows_with_distance :: proc(t: ^testing.T) {
	input := Cluster_Build_Input {
		pixels_per_unit = 500,
		error_pixels    = 2,
	}
	near := cluster_screen_error(input, 10)
	far := cluster_screen_error(input, 100)
	testing.expect(t, far > near)
	testing.expect(t, near > 0)
	// At the eye the threshold must stay finite rather than divide by zero.
	testing.expect(t, cluster_screen_error(input, 0) > 0)
}
