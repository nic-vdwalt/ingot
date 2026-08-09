#+build !js
package scene

import "core:testing"
import "ingot:asset"

@(test)
draw_list_never_exceeds_capacity :: proc(t: ^testing.T) {
	world: Scene
	material, ok := scene_add_material(&world, {})
	testing.expect(t, ok)
	for index in 0 ..< SCENE_MAX_OBJECTS {
		object := _scene_test_object(index + 1, asset.Mesh_Id(index + 1), material)
		testing.expect(t, scene_add_object(&world, object))
	}
	draws: Draw_List
	build_draw_list(&world, _scene_test_input(), &draws)
	testing.expect_value(t, draws.count, SCENE_MAX_DRAWS)
	testing.expect_value(t, draws.overflow_count, SCENE_MAX_OBJECTS - SCENE_MAX_DRAWS)
}

@(test)
draw_list_culls_only_excluded_bounds :: proc(t: ^testing.T) {
	world: Scene
	material, _ := scene_add_material(&world, {})
	inside := _scene_test_object(1, 1, material)
	outside := _scene_test_object(2, 2, material)
	outside.bounds = {{4, 4, 4}, {5, 5, 5}}
	straddling := _scene_test_object(3, 3, material)
	straddling.bounds = {{0.5, -0.5, -0.5}, {1.5, 0.5, 0.5}}
	testing.expect(t, scene_add_object(&world, inside))
	testing.expect(t, scene_add_object(&world, outside))
	testing.expect(t, scene_add_object(&world, straddling))
	draws: Draw_List
	build_draw_list(&world, _scene_test_input(), &draws)
	testing.expect_value(t, draws.count, 2)
	testing.expect_value(t, draws.culled_count, 1)
}

@(test)
draw_list_sort_is_stable_for_equal_keys :: proc(t: ^testing.T) {
	world: Scene
	material, _ := scene_add_material(&world, {})
	for index in 0 ..< 8 {
		testing.expect(t, scene_add_object(&world, _scene_test_object(index + 1, 1, material)))
	}
	draws: Draw_List
	build_draw_list(&world, _scene_test_input(), &draws)
	for draw, index in draws.draws[:draws.count] {
		testing.expect_value(t, draw.object_id, Object_Id(index + 1))
	}
}

@(test)
draw_list_selects_monotonic_lods :: proc(t: ^testing.T) {
	world: Scene
	material, _ := scene_add_material(&world, {})
	object := _scene_test_object(1, 1, material)
	object.lod_meshes = {2, 3, 4, 5}
	object.lod_count = 4
	testing.expect(t, scene_add_object(&world, object))
	input := _scene_test_input()
	previous := asset.Mesh_Id(1)
	distances := [?]f32{0, 12, 24, 48}
	for distance in distances {
		input.camera_position = {-distance, 0, 0}
		draws: Draw_List
		build_draw_list(&world, input, &draws)
		testing.expect(t, draws.draws[0].mesh >= previous)
		previous = draws.draws[0].mesh
	}
}

@(private)
_scene_test_object :: proc(id: int, mesh: asset.Mesh_Id, material: asset.Material_Id) -> Object {
	return {
		id = Object_Id(id),
		mesh = mesh,
		material = material,
		transform = {1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1},
		bounds = {{-0.5, -0.5, -0.5}, {0.5, 0.5, 0.5}},
		visible = true,
	}
}

@(private)
_scene_test_input :: proc() -> Build_Input {
	return {
		frustum = {
			planes = {
				{{1, 0, 0}, 1},
				{{-1, 0, 0}, 1},
				{{0, 1, 0}, 1},
				{{0, -1, 0}, 1},
				{{0, 0, 1}, 1},
				{{0, 0, -1}, 1},
			},
		},
		camera_position = {0, 0, 0},
		lod_distances = {10, 20, 30, 40},
	}
}
