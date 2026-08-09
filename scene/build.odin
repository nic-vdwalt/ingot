package scene

import "core:math"
import "ingot:asset"

Build_Input :: struct {
	frustum:         Frustum,
	camera_position: [3]f32,
	lod_distances:   [SCENE_MAX_LODS]f32,
}

build_draw_list :: proc(value: ^Scene, input: Build_Input, output: ^Draw_List) {
	assert(value != nil, "build_draw_list: nil scene")
	assert(output != nil, "build_draw_list: nil output")
	assert(value.object_count <= SCENE_MAX_OBJECTS, "build_draw_list: object count overflow")
	output^ = {}
	for object in value.objects[:value.object_count] {
		if !object.visible || !frustum_intersects_bounds(input.frustum, object.bounds) {
			output.culled_count += 1
			continue
		}
		if output.count >= SCENE_MAX_DRAWS {
			output.overflow_count += 1
			continue
		}
		mesh := _scene_lod_mesh(object, input)
		output.draws[output.count] = {
			mesh      = mesh,
			material  = object.material,
			transform = object.transform,
			sort_key  = _scene_sort_key(mesh, object.material),
			object_id = object.id,
		}
		output.count += 1
	}
	_scene_stable_sort(output.draws[:output.count])
}

@(private)
_scene_lod_mesh :: proc(object: Object, input: Build_Input) -> asset.Mesh_Id {
	assert(object.mesh != 0, "_scene_lod_mesh: zero base mesh")
	if object.lod_count == 0 do return object.mesh
	center := asset.Vec3 {
		(object.bounds.minimum[0] + object.bounds.maximum[0]) * 0.5,
		(object.bounds.minimum[1] + object.bounds.maximum[1]) * 0.5,
		(object.bounds.minimum[2] + object.bounds.maximum[2]) * 0.5,
	}
	dx := center[0] - input.camera_position[0]
	dy := center[1] - input.camera_position[1]
	dz := center[2] - input.camera_position[2]
	distance := math.sqrt(dx * dx + dy * dy + dz * dz)
	selected := object.mesh
	for index in 0 ..< min(int(object.lod_count), SCENE_MAX_LODS) {
		if distance < input.lod_distances[index] do break
		if object.lod_meshes[index] != 0 do selected = object.lod_meshes[index]
	}
	return selected
}

@(private)
_scene_sort_key :: proc(mesh: asset.Mesh_Id, material: asset.Material_Id) -> u64 {
	return u64(material) << 32 | u64(mesh)
}

@(private)
_scene_stable_sort :: proc(draws: []Draw) {
	for index in 1 ..< len(draws) {
		value := draws[index]
		cursor := index
		for cursor > 0 && draws[cursor - 1].sort_key > value.sort_key {
			draws[cursor] = draws[cursor - 1]
			cursor -= 1
		}
		draws[cursor] = value
	}
}
