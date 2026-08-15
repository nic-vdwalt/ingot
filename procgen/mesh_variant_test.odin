#+build !js
package procgen

import asset "../asset"
import "core:math"
import "core:testing"

@(private = "file")
mesh_variant_source :: proc(vertices: ^[3]asset.Vertex, indices: ^[3]u32) -> asset.Mesh_View {
	vertices^ = {
		{position = {-1, -1, 0}, normal = {0, 0, 1}},
		{position = {1, -1, 0}, normal = {0, 0, 1}},
		{position = {0, 1, 1}, normal = {0, 0, 1}},
	}
	indices^ = {0, 1, 2}
	return {1, vertices^[:], indices^[:], .Triangles, {{-1, -1, 0}, {1, 1, 1}}}
}

@(private = "file")
mesh_deform_source :: proc(vertices: ^[6]asset.Vertex, indices: ^[6]u32) -> asset.Mesh_View {
	vertices^ = {
		{position = {-1, -1, 0}, normal = {0, 0, 1}, scalar = 0.1, uv = {0, 0}},
		{position = {1, -1, 0}, normal = {0, 0, 1}, scalar = 0.2, uv = {1, 0}},
		{position = {1, 1, 1}, normal = {0, 0, 1}, scalar = 0.3, uv = {1, 1}},
		{position = {-1, -1, 0}, normal = {0, 1, 0}, scalar = 0.4, uv = {0.25, 0}},
		{position = {1, 1, 1}, normal = {0, 1, 0}, scalar = 0.5, uv = {0.75, 1}},
		{position = {-1, 1, 0}, normal = {0, 1, 0}, scalar = 0.6, uv = {0, 1}},
	}
	indices^ = {0, 1, 2, 3, 4, 5}
	return {2, vertices^[:], indices^[:], .Triangles, {{-1, -1, 0}, {1, 1, 1}}}
}

@(private = "file")
mesh_deform_recipe :: proc(seed: u64) -> Mesh_Deform_Recipe {
	return {
		scale = {1.1, 0.9, 1.2},
		seed = seed,
		radial_amplitude = 0.2,
		vertical_amplitude = 0.15,
		frequency = 1.5,
		taper = 0.3,
		preserve_ground = true,
	}
}

@(test)
mesh_scale_variant_is_deterministic_and_recomputes_bounds :: proc(t: ^testing.T) {
	source_vertices: [3]asset.Vertex
	source_indices: [3]u32
	source := mesh_variant_source(&source_vertices, &source_indices)
	first_vertices, second_vertices: [3]asset.Vertex
	first_indices, second_indices: [3]u32
	first := asset.Mesh_Buffer {
		id       = 7,
		vertices = first_vertices[:],
		indices  = first_indices[:],
	}
	second := asset.Mesh_Buffer {
		id       = 7,
		vertices = second_vertices[:],
		indices  = second_indices[:],
	}
	recipe := Mesh_Scale_Recipe {
		scale = {2, 3, 4},
	}
	testing.expect(t, mesh_scale_variant(source, recipe, &first))
	testing.expect(t, mesh_scale_variant(source, recipe, &second))
	first_view, first_ok := asset.mesh_view(&first)
	second_view, second_ok := asset.mesh_view(&second)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, len(first_view.vertices), len(second_view.vertices))
	for index in 0 ..< len(first_view.vertices) {
		testing.expect_value(t, first_view.vertices[index], second_view.vertices[index])
		testing.expect_value(t, source.vertices[index], source_vertices[index])
	}
	testing.expect_value(t, len(first_view.indices), len(second_view.indices))
	for index in 0 ..< len(first_view.indices) {
		testing.expect_value(t, first_view.indices[index], second_view.indices[index])
		testing.expect_value(t, first_view.indices[index], source_indices[index])
	}
	testing.expect_value(t, first_view.bounds, asset.Bounds_3D{{-2, -3, 0}, {2, 3, 4}})
}

@(test)
mesh_scale_variant_rejects_invalid_recipe_and_capacity :: proc(t: ^testing.T) {
	source_vertices: [3]asset.Vertex
	source_indices: [3]u32
	source := mesh_variant_source(&source_vertices, &source_indices)
	vertices: [2]asset.Vertex
	indices: [3]u32
	destination := asset.Mesh_Buffer {
		id       = 7,
		vertices = vertices[:],
		indices  = indices[:],
	}
	testing.expect(t, !mesh_scale_variant(source, {scale = {1, 1, 1}}, &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
	full_vertices: [3]asset.Vertex
	destination.vertices = full_vertices[:]
	testing.expect(t, !mesh_scale_variant(source, {scale = {1, 0, 1}}, &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
}

@(test)
mesh_deform_variant_is_deterministic_grounded_and_preserves_channels :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := mesh_deform_source(&source_vertices, &source_indices)
	first_vertices, second_vertices: [6]asset.Vertex
	first_indices, second_indices: [6]u32
	first := asset.Mesh_Buffer {
		id       = 8,
		vertices = first_vertices[:],
		indices  = first_indices[:],
	}
	second := asset.Mesh_Buffer {
		id       = 8,
		vertices = second_vertices[:],
		indices  = second_indices[:],
	}
	testing.expect(t, mesh_deform_variant(source, mesh_deform_recipe(91), &first))
	testing.expect(t, mesh_deform_variant(source, mesh_deform_recipe(91), &second))
	first_view, first_ok := asset.mesh_view(&first)
	second_view, second_ok := asset.mesh_view(&second)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first_view.bounds.minimum.z, f32(0))
	for index in 0 ..< len(first_view.vertices) {
		vertex := first_view.vertices[index]
		testing.expect_value(t, vertex, second_view.vertices[index])
		testing.expect_value(t, source.vertices[index], source_vertices[index])
		testing.expect_value(t, vertex.scalar, source.vertices[index].scalar)
		testing.expect_value(t, vertex.uv, source.vertices[index].uv)
		length := math.sqrt(
			vertex.normal.x * vertex.normal.x +
			vertex.normal.y * vertex.normal.y +
			vertex.normal.z * vertex.normal.z,
		)
		testing.expect(t, abs(length - 1) < 0.00001)
		for axis in 0 ..< 3 {
			testing.expect(t, vertex.position[axis] >= first_view.bounds.minimum[axis])
			testing.expect(t, vertex.position[axis] <= first_view.bounds.maximum[axis])
		}
	}
	for index in 0 ..< len(first_view.indices) {
		testing.expect_value(t, first_view.indices[index], source.indices[index])
		testing.expect_value(t, first_view.indices[index], second_view.indices[index])
	}
}

@(test)
mesh_deform_variant_seed_changes_shape_without_cracking_splits :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := mesh_deform_source(&source_vertices, &source_indices)
	first_vertices, second_vertices: [6]asset.Vertex
	first_indices, second_indices: [6]u32
	first := asset.Mesh_Buffer {
		id       = 8,
		vertices = first_vertices[:],
		indices  = first_indices[:],
	}
	second := asset.Mesh_Buffer {
		id       = 8,
		vertices = second_vertices[:],
		indices  = second_indices[:],
	}
	testing.expect(t, mesh_deform_variant(source, mesh_deform_recipe(91), &first))
	testing.expect(t, mesh_deform_variant(source, mesh_deform_recipe(92), &second))
	first_view, _ := asset.mesh_view(&first)
	second_view, _ := asset.mesh_view(&second)
	testing.expect_value(t, first_view.vertices[0].position, first_view.vertices[3].position)
	testing.expect_value(t, first_view.vertices[2].position, first_view.vertices[4].position)
	testing.expect_value(t, second_view.vertices[0].position, second_view.vertices[3].position)
	changed := false
	for index in 0 ..< len(first_view.vertices) {
		if first_view.vertices[index].position != second_view.vertices[index].position do changed = true
	}
	testing.expect(t, changed)
}

@(test)
mesh_deform_variant_rebuilds_normals_and_preserves_topology :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := mesh_deform_source(&source_vertices, &source_indices)
	vertices: [6]asset.Vertex
	indices: [6]u32
	destination := asset.Mesh_Buffer {
		id       = 8,
		vertices = vertices[:],
		indices  = indices[:],
	}
	testing.expect(t, mesh_deform_variant(source, mesh_deform_recipe(91), &destination))
	mesh, ok := asset.mesh_view(&destination)
	testing.expect(t, ok)
	normal_changed := false
	for index in 0 ..< len(mesh.vertices) {
		if mesh.vertices[index].normal != source.vertices[index].normal do normal_changed = true
	}
	for index in 0 ..< len(mesh.indices) {
		testing.expect_value(t, mesh.indices[index], source.indices[index])
	}
	testing.expect(t, normal_changed)
}

@(test)
mesh_deform_variant_rejects_invalid_input_without_publishing :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := mesh_deform_source(&source_vertices, &source_indices)
	vertices: [6]asset.Vertex
	indices: [6]u32
	destination := asset.Mesh_Buffer {
		id       = 8,
		vertices = vertices[:],
		indices  = indices[:],
	}
	recipes := [6]Mesh_Deform_Recipe {
		mesh_deform_recipe(1),
		mesh_deform_recipe(1),
		mesh_deform_recipe(1),
		mesh_deform_recipe(1),
		mesh_deform_recipe(1),
		mesh_deform_recipe(1),
	}
	recipes[0].scale.x = 0
	recipes[1].frequency = 0
	recipes[2].frequency = 4.1
	recipes[3].radial_amplitude = 0.36
	recipes[4].vertical_amplitude = 0.26
	recipes[5].taper = 1.1
	for recipe in recipes {
		destination.vertex_count = 4
		destination.index_count = 3
		testing.expect(t, !mesh_deform_variant(source, recipe, &destination))
		testing.expect_value(t, destination.vertex_count, u32(0))
		testing.expect_value(t, destination.index_count, u32(0))
	}
	small_vertices: [5]asset.Vertex
	destination.vertices = small_vertices[:]
	testing.expect(t, !mesh_deform_variant(source, mesh_deform_recipe(1), &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
	destination.vertices = vertices[:]
	degenerate_indices := [3]u32{0, 0, 0}
	degenerate := asset.Mesh_View {
		3,
		source.vertices[:3],
		degenerate_indices[:],
		.Triangles,
		source.bounds,
	}
	testing.expect(t, !mesh_deform_variant(degenerate, mesh_deform_recipe(1), &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
}

@(test)
mesh_deform_generator_version_is_one :: proc(t: ^testing.T) {
	testing.expect_value(t, MESH_DEFORM_GENERATOR_VERSION, u32(1))
}
