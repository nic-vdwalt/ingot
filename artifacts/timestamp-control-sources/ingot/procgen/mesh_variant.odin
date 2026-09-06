package procgen

import asset "../asset"
import "core:math"

MESH_DEFORM_GENERATOR_VERSION :: u32(1)
MESH_DEFORM_FREQUENCY_MAX :: f32(4)
MESH_DEFORM_RADIAL_AMPLITUDE_MAX :: f32(0.35)
MESH_DEFORM_VERTICAL_AMPLITUDE_MAX :: f32(0.25)
MESH_DEFORM_EPSILON :: f32(0.000001)

Mesh_Deform_Recipe :: struct {
	scale:              asset.Vec3,
	seed:               u64,
	radial_amplitude:   f32,
	vertical_amplitude: f32,
	frequency:          f32,
	taper:              f32,
	preserve_ground:    bool,
}

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
			destination.bounds = {
				minimum = vertex.position,
				maximum = vertex.position,
			}
		} else {
			for axis in 0 ..< 3 {
				destination.bounds.minimum[axis] = min(
					destination.bounds.minimum[axis],
					vertex.position[axis],
				)
				destination.bounds.maximum[axis] = max(
					destination.bounds.maximum[axis],
					vertex.position[axis],
				)
			}
		}
	}
	copy(destination.indices, source.indices)
	destination.vertex_count = u32(len(source.vertices))
	destination.index_count = u32(len(source.indices))
	_, ok := asset.mesh_view(destination)
	return ok
}

mesh_deform_variant :: proc(
	source: asset.Mesh_View,
	recipe: Mesh_Deform_Recipe,
	destination: ^asset.Mesh_Buffer,
) -> bool {
	assert(destination != nil, "mesh_deform_variant: nil destination")
	asset.mesh_reset(destination)
	if !_mesh_deform_validate(source, recipe, destination) do return false
	assert(source.primitive == .Triangles, "mesh_deform_variant: validated primitive")
	destination.primitive = source.primitive
	minimum_z := f32(0)
	for index in 0 ..< len(source.vertices) {
		vertex := source.vertices[index]
		vertex.position = _mesh_deform_position(vertex.position, source.bounds, recipe)
		vertex.normal = {}
		destination.vertices[index] = vertex
		if index == 0 || vertex.position.z < minimum_z do minimum_z = vertex.position.z
	}
	if recipe.preserve_ground {
		for index in 0 ..< len(source.vertices) {
			destination.vertices[index].position.z -= minimum_z
		}
	}
	copy(destination.indices, source.indices)
	if !_mesh_deform_accumulate_normals(source.indices, destination.vertices) {
		asset.mesh_reset(destination)
		return false
	}
	if !_mesh_deform_normalize_normals(destination.vertices[:len(source.vertices)]) {
		asset.mesh_reset(destination)
		return false
	}
	_mesh_deform_bounds(destination.vertices[:len(source.vertices)], &destination.bounds)
	destination.vertex_count = u32(len(source.vertices))
	destination.index_count = u32(len(source.indices))
	_, ok := asset.mesh_view(destination)
	if !ok do asset.mesh_reset(destination)
	return ok
}

@(private)
_mesh_deform_validate :: proc(
	source: asset.Mesh_View,
	recipe: Mesh_Deform_Recipe,
	destination: ^asset.Mesh_Buffer,
) -> bool {
	assert(destination != nil, "_mesh_deform_validate: nil destination")
	if !asset.mesh_validate(source) || source.primitive != .Triangles do return false
	if len(source.vertices) > len(destination.vertices) do return false
	if len(source.indices) > len(destination.indices) do return false
	for component in recipe.scale {
		if component <= 0 || !_mesh_deform_finite(component) do return false
	}
	if !_mesh_deform_finite(recipe.frequency) do return false
	if recipe.frequency <= 0 || recipe.frequency > MESH_DEFORM_FREQUENCY_MAX do return false
	if !_mesh_deform_finite(recipe.radial_amplitude) do return false
	if recipe.radial_amplitude < 0 || recipe.radial_amplitude > MESH_DEFORM_RADIAL_AMPLITUDE_MAX {
		return false
	}
	if !_mesh_deform_finite(recipe.vertical_amplitude) do return false
	if recipe.vertical_amplitude < 0 ||
	   recipe.vertical_amplitude > MESH_DEFORM_VERTICAL_AMPLITUDE_MAX {
		return false
	}
	if !_mesh_deform_finite(recipe.taper) || recipe.taper < 0 || recipe.taper > 1 do return false
	return true
}

@(private)
_mesh_deform_position :: proc(
	position: asset.Vec3,
	bounds: asset.Bounds_3D,
	recipe: Mesh_Deform_Recipe,
) -> asset.Vec3 {
	center := (bounds.minimum + bounds.maximum) * 0.5
	extent := bounds.maximum - bounds.minimum
	normalized_x := (position.x - center.x) / max(extent.x, MESH_DEFORM_EPSILON)
	normalized_y := (position.y - center.y) / max(extent.y, MESH_DEFORM_EPSILON)
	normalized_z := (position.z - bounds.minimum.z) / max(extent.z, MESH_DEFORM_EPSILON)
	strength := recipe.taper + (1 - recipe.taper) * normalized_z
	radial_noise :=
		(noise_2d(recipe.seed, normalized_x * recipe.frequency, normalized_z * recipe.frequency) +
			noise_2d(
				recipe.seed ~ 0xD1B54A32D192ED03,
				normalized_y * recipe.frequency,
				normalized_z * recipe.frequency,
			)) *
		0.5
	vertical_noise := noise_2d(
		recipe.seed ~ 0x94D049BB133111EB,
		normalized_x * recipe.frequency,
		normalized_y * recipe.frequency,
	)
	result := position * recipe.scale
	radial_x := result.x - center.x * recipe.scale.x
	radial_y := result.y - center.y * recipe.scale.y
	radial_length := math.sqrt(radial_x * radial_x + radial_y * radial_y)
	if radial_length > MESH_DEFORM_EPSILON {
		displacement := recipe.radial_amplitude * radial_noise * strength / radial_length
		result.x += radial_x * displacement
		result.y += radial_y * displacement
	}
	result.z += recipe.vertical_amplitude * vertical_noise * strength
	return result
}

@(private)
_mesh_deform_accumulate_normals :: proc(indices: []u32, vertices: []asset.Vertex) -> bool {
	assert(len(indices) % 3 == 0, "_mesh_deform_accumulate_normals: incomplete triangle")
	for triangle in 0 ..< len(indices) / 3 {
		index_a := int(indices[triangle * 3])
		index_b := int(indices[triangle * 3 + 1])
		index_c := int(indices[triangle * 3 + 2])
		if index_a >= len(vertices) || index_b >= len(vertices) || index_c >= len(vertices) {
			return false
		}
		edge_ab := vertices[index_b].position - vertices[index_a].position
		edge_ac := vertices[index_c].position - vertices[index_a].position
		normal := asset.Vec3 {
			edge_ab.y * edge_ac.z - edge_ab.z * edge_ac.y,
			edge_ab.z * edge_ac.x - edge_ab.x * edge_ac.z,
			edge_ab.x * edge_ac.y - edge_ab.y * edge_ac.x,
		}
		length_squared := normal.x * normal.x + normal.y * normal.y + normal.z * normal.z
		if length_squared <= MESH_DEFORM_EPSILON * MESH_DEFORM_EPSILON do return false
		vertices[index_a].normal += normal
		vertices[index_b].normal += normal
		vertices[index_c].normal += normal
	}
	return true
}

@(private)
_mesh_deform_normalize_normals :: proc(vertices: []asset.Vertex) -> bool {
	assert(len(vertices) > 0, "_mesh_deform_normalize_normals: empty vertices")
	for index in 0 ..< len(vertices) {
		normal := vertices[index].normal
		length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
		if length <= MESH_DEFORM_EPSILON || !_mesh_deform_finite(length) do return false
		vertices[index].normal = normal / length
	}
	return true
}

@(private)
_mesh_deform_bounds :: proc(vertices: []asset.Vertex, bounds: ^asset.Bounds_3D) {
	assert(len(vertices) > 0, "_mesh_deform_bounds: empty vertices")
	assert(bounds != nil, "_mesh_deform_bounds: nil bounds")
	bounds^ = {
		minimum = vertices[0].position,
		maximum = vertices[0].position,
	}
	for index in 1 ..< len(vertices) {
		for axis in 0 ..< 3 {
			bounds.minimum[axis] = min(bounds.minimum[axis], vertices[index].position[axis])
			bounds.maximum[axis] = max(bounds.maximum[axis], vertices[index].position[axis])
		}
	}
}

@(private)
_mesh_deform_finite :: proc(value: f32) -> bool {
	return !math.is_nan(value) && !math.is_inf(value, 0)
}
