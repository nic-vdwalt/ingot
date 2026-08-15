#+build !js
package procgen

import "core:testing"
import asset "../asset"

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

@(test)
mesh_scale_variant_is_deterministic_and_recomputes_bounds :: proc(t: ^testing.T) {
	source_vertices: [3]asset.Vertex
	source_indices: [3]u32
	source := mesh_variant_source(&source_vertices, &source_indices)
	first_vertices, second_vertices: [3]asset.Vertex
	first_indices, second_indices: [3]u32
	first := asset.Mesh_Buffer{id = 7, vertices = first_vertices[:], indices = first_indices[:]}
	second := asset.Mesh_Buffer{id = 7, vertices = second_vertices[:], indices = second_indices[:]}
	recipe := Mesh_Scale_Recipe{scale = {2, 3, 4}}
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
	destination := asset.Mesh_Buffer{id = 7, vertices = vertices[:], indices = indices[:]}
	testing.expect(t, !mesh_scale_variant(source, {scale = {1, 1, 1}}, &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
	full_vertices: [3]asset.Vertex
	destination.vertices = full_vertices[:]
	testing.expect(t, !mesh_scale_variant(source, {scale = {1, 0, 1}}, &destination))
	testing.expect_value(t, destination.vertex_count, u32(0))
}
