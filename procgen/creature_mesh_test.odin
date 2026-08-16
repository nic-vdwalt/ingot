#+build !js
package procgen

import asset "../asset"
import "core:math"
import "core:testing"

@(private = "file")
creature_test_source :: proc(vertices: ^[6]asset.Vertex, indices: ^[6]u32) -> asset.Mesh_View {
	vertices^ = {
		{position = {0, -1, 0}, normal = {0, 0, 1}, scalar = 0.1, uv = {0, 0}},
		{position = {2, -1, 0}, normal = {0, 0, 1}, scalar = 0.2, uv = {1, 0}},
		{position = {2, 1, 2}, normal = {0, 0, 1}, scalar = 0.3, uv = {1, 1}},
		{position = {0, -1, 0}, normal = {0, 1, 0}, scalar = 0.4, uv = {0.25, 0}},
		{position = {2, 1, 2}, normal = {0, 1, 0}, scalar = 0.5, uv = {0.75, 1}},
		{position = {0, 1, 1}, normal = {0, 1, 0}, scalar = 0.6, uv = {0, 1}},
	}
	indices^ = {0, 1, 2, 3, 4, 5}
	return {31, vertices^[:], indices^[:], .Triangles, {{0, -1, 0}, {2, 1, 2}}}
}

@(private = "file")
creature_test_recipe :: proc(seed: u64) -> Creature_Mesh_Recipe {
	return {
		source_identity = 901,
		creature_seed = seed,
		progression_revision = 4,
		level = 12,
		morphology = {0.8, 0.7, 0.65, 0.6, 0.55, 0.5, 0.4, 0.35},
		profile = {0.7, 0.45, 0.3, 0.25, true, .Positive_X, .Positive_Y, .Positive_Z},
	}
}

@(private = "file")
creature_test_buffer :: proc(vertices: ^[6]asset.Vertex, indices: ^[6]u32) -> asset.Mesh_Buffer {
	return {id = 71, vertices = vertices^[:], indices = indices^[:]}
}

@(test)
creature_mesh_is_deterministic_and_preserves_authored_data :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := creature_test_source(&source_vertices, &source_indices)
	first_vertices, second_vertices: [6]asset.Vertex
	first_indices, second_indices: [6]u32
	first := creature_test_buffer(&first_vertices, &first_indices)
	second := creature_test_buffer(&second_vertices, &second_indices)
	first_key, first_ok := creature_mesh_evolve(source, creature_test_recipe(19), &first)
	second_key, second_ok := creature_mesh_evolve(source, creature_test_recipe(19), &second)
	testing.expect(t, first_ok && second_ok)
	testing.expect_value(t, first_key, second_key)
	first_view, first_view_ok := asset.mesh_view(&first)
	second_view, second_view_ok := asset.mesh_view(&second)
	testing.expect(t, first_view_ok && second_view_ok)
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
	}
}

@(test)
creature_mesh_progression_and_seed_change_shape_and_key :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := creature_test_source(&source_vertices, &source_indices)
	base_recipe := creature_test_recipe(19)
	grown_recipe := base_recipe
	grown_recipe.level += 1
	grown_recipe.progression_revision += 1
	grown_recipe.morphology.maturity = 1
	seed_recipe := grown_recipe
	seed_recipe.creature_seed += 1
	base_key, base_ok := creature_mesh_key(source, base_recipe)
	grown_key, grown_ok := creature_mesh_key(source, grown_recipe)
	seed_key, seed_ok := creature_mesh_key(source, seed_recipe)
	testing.expect(t, base_ok && grown_ok && seed_ok)
	testing.expect(t, base_key != grown_key && grown_key != seed_key)
	base_vertices, grown_vertices, seed_vertices: [6]asset.Vertex
	base_indices, grown_indices, seed_indices: [6]u32
	base := creature_test_buffer(&base_vertices, &base_indices)
	grown := creature_test_buffer(&grown_vertices, &grown_indices)
	seeded := creature_test_buffer(&seed_vertices, &seed_indices)
	_, base_mesh_ok := creature_mesh_evolve(source, base_recipe, &base)
	_, grown_mesh_ok := creature_mesh_evolve(source, grown_recipe, &grown)
	_, seed_mesh_ok := creature_mesh_evolve(source, seed_recipe, &seeded)
	testing.expect(t, base_mesh_ok && grown_mesh_ok && seed_mesh_ok)
	testing.expect(t, base.vertices[2].position != grown.vertices[2].position)
	seed_changed := false
	for index in 0 ..< len(seed_vertices) {
		seed_changed =
			seed_changed || grown.vertices[index].position != seeded.vertices[index].position
	}
	testing.expect(t, seed_changed)
}

@(test)
creature_mesh_keeps_coincident_seams_together :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := creature_test_source(&source_vertices, &source_indices)
	vertices: [6]asset.Vertex
	indices: [6]u32
	destination := creature_test_buffer(&vertices, &indices)
	_, ok := creature_mesh_evolve(source, creature_test_recipe(44), &destination)
	testing.expect(t, ok)
	testing.expect_value(t, destination.vertices[0].position, destination.vertices[3].position)
	testing.expect_value(t, destination.vertices[2].position, destination.vertices[4].position)
}

@(test)
creature_mesh_rejects_invalid_input_without_publishing :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := creature_test_source(&source_vertices, &source_indices)
	vertices: [6]asset.Vertex
	indices: [6]u32
	destination := creature_test_buffer(&vertices, &indices)
	recipes := [5]Creature_Mesh_Recipe {
		creature_test_recipe(1),
		creature_test_recipe(1),
		creature_test_recipe(1),
		creature_test_recipe(1),
		creature_test_recipe(1),
	}
	recipes[0].morphology.bulk = 1.1
	recipes[1].profile.influence_falloff = 0
	recipes[2].profile.head_front_threshold = -0.1
	recipes[3].profile.max_deformation = 1.1
	recipes[4].profile.forward_axis = .Positive_Y
	for recipe in recipes {
		destination.vertex_count = 4
		destination.index_count = 3
		_, ok := creature_mesh_evolve(source, recipe, &destination)
		testing.expect(t, !ok)
		testing.expect_value(t, destination.vertex_count, u32(0))
		testing.expect_value(t, destination.index_count, u32(0))
	}
	small_vertices: [5]asset.Vertex
	destination.vertices = small_vertices[:]
	_, capacity_ok := creature_mesh_evolve(source, creature_test_recipe(1), &destination)
	testing.expect(t, !capacity_ok)
	testing.expect_value(t, destination.vertex_count, u32(0))
}

@(test)
creature_mesh_rejects_zero_span_and_degenerate_sources :: proc(t: ^testing.T) {
	source_vertices: [6]asset.Vertex
	source_indices: [6]u32
	source := creature_test_source(&source_vertices, &source_indices)
	vertices: [6]asset.Vertex
	indices: [6]u32
	destination := creature_test_buffer(&vertices, &indices)
	flat := source
	flat.bounds.maximum.y = flat.bounds.minimum.y
	for index in 0 ..< len(source_vertices) do flat.vertices[index].position.y = flat.bounds.minimum.y
	_, flat_ok := creature_mesh_evolve(flat, creature_test_recipe(1), &destination)
	testing.expect(t, !flat_ok)
	source = creature_test_source(&source_vertices, &source_indices)
	source_indices[0] = source_indices[1]
	_, degenerate_ok := creature_mesh_evolve(source, creature_test_recipe(1), &destination)
	testing.expect(t, !degenerate_ok)
	testing.expect_value(t, destination.vertex_count, u32(0))
}
