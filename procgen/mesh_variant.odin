package procgen

import "core:math"
import asset "../asset"

Mesh_Scale_Recipe :: struct {
	scale: asset.Vec3,
}

mesh_scale_variant :: proc(
	source: asset.Mesh_View,
	recipe: Mesh_Scale_Recipe,
	destination: ^asset.Mesh_Buffer,
) -> bool {
	assert(destination != nil, "mesh_scale_variant: nil destination")
	if !asset.mesh_validate(source) do return false
	for component in recipe.scale {
		if component <= 0 || math.is_nan(component) || math.is_inf(component, 0) do return false
	}
	if len(source.vertices) > len(destination.vertices) do return false
	if len(source.indices) > len(destination.indices) do return false

	asset.mesh_reset(destination)
	destination.primitive = source.primitive
	for index in 0 ..< len(source.vertices) {
		vertex := source.vertices[index]
		vertex.position *= recipe.scale
		normal := asset.Vec3 {
			vertex.normal.x / recipe.scale.x,
			vertex.normal.y / recipe.scale.y,
			vertex.normal.z / recipe.scale.z,
		}
		normal_length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
		if normal_length <= 0 do return false
		vertex.normal = normal / normal_length
		destination.vertices[index] = vertex
		if index == 0 {
			destination.bounds = {minimum = vertex.position, maximum = vertex.position}
		} else {
			for axis in 0 ..< 3 {
				destination.bounds.minimum[axis] = min(destination.bounds.minimum[axis], vertex.position[axis])
				destination.bounds.maximum[axis] = max(destination.bounds.maximum[axis], vertex.position[axis])
			}
		}
	}
	copy(destination.indices, source.indices)
	destination.vertex_count = u32(len(source.vertices))
	destination.index_count = u32(len(source.indices))
	_, ok := asset.mesh_view(destination)
	return ok
}
