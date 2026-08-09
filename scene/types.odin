package scene

import "ingot:asset"

SCENE_MAX_OBJECTS :: 4096
SCENE_MAX_DRAWS :: 2048
SCENE_MAX_LODS :: 4
SCENE_MAX_MATERIALS :: 256

Matrix_4 :: [16]f32
Object_Id :: distinct u32

Material :: struct {
	color_low:  [4]u8,
	color_high: [4]u8,
	use_scalar: bool,
}

Object :: struct {
	id:         Object_Id,
	mesh:       asset.Mesh_Id,
	material:   asset.Material_Id,
	transform:  Matrix_4,
	bounds:     asset.Bounds_3D,
	lod_meshes: [SCENE_MAX_LODS]asset.Mesh_Id,
	lod_count:  u8,
	visible:    bool,
}

Draw :: struct {
	mesh:      asset.Mesh_Id,
	material:  asset.Material_Id,
	transform: Matrix_4,
	sort_key:  u64,
	object_id: Object_Id,
}

Draw_List :: struct {
	draws:          [SCENE_MAX_DRAWS]Draw,
	count:          u32,
	overflow_count: u32,
	culled_count:   u32,
}

Scene :: struct {
	objects:        [SCENE_MAX_OBJECTS]Object,
	object_count:   u32,
	materials:      [SCENE_MAX_MATERIALS]Material,
	material_count: u16,
}

scene_reset :: proc(value: ^Scene) {
	assert(value != nil, "scene_reset: nil scene")
	value.object_count = 0
	value.material_count = 0
}

scene_add_object :: proc(value: ^Scene, object: Object) -> bool {
	assert(value != nil, "scene_add_object: nil scene")
	if value.object_count >= SCENE_MAX_OBJECTS do return false
	if object.id == 0 || object.mesh == 0 do return false
	if object.material == 0 || object.material > asset.Material_Id(SCENE_MAX_MATERIALS) do return false
	value.objects[value.object_count] = object
	value.object_count += 1
	return true
}

scene_add_material :: proc(value: ^Scene, material: Material) -> (asset.Material_Id, bool) {
	assert(value != nil, "scene_add_material: nil scene")
	if value.material_count >= SCENE_MAX_MATERIALS do return 0, false
	value.materials[value.material_count] = material
	value.material_count += 1
	return asset.Material_Id(value.material_count), true
}
