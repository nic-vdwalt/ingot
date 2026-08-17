#+build !js
package procgen

import "core:math"
import "core:testing"
import "ingot:asset"

TERRAIN_V3_TEST_CELLS :: 6
TERRAIN_V3_TEST_DENSITY ::
	(TERRAIN_V3_TEST_CELLS + 2) * (TERRAIN_V3_TEST_CELLS + 2) * (TERRAIN_V3_TEST_CELLS + 2)
TERRAIN_V3_TEST_VERTICES ::
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_VOLUME_VERTICES_PER_CELL_V3
TERRAIN_V3_TEST_INDICES ::
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_VOLUME_INDICES_PER_CELL_V3

Terrain_V3_Test_Storage :: struct {
	density:  [TERRAIN_V3_TEST_DENSITY]f32,
	vertices: [TERRAIN_V3_TEST_VERTICES]asset.Vertex,
	indices:  [TERRAIN_V3_TEST_INDICES]u32,
}

@(test)
terrain_v3_presets_are_valid_and_normal_disables_abstract_terms :: proc(t: ^testing.T) {
	normal := terrain_normal_recipe_v3(42)
	abstract := terrain_abstract_recipe_v3(42)
	testing.expect(t, terrain_recipe_validate_v3(&normal))
	testing.expect(t, terrain_recipe_validate_v3(&abstract))
	testing.expect_value(t, normal.preset, Terrain_Preset_V3.Normal)
	testing.expect_value(t, normal.parameters.floating_strength, f32(0))
	testing.expect_value(t, normal.parameters.cave_strength, f32(0))
	testing.expect(t, abstract.parameters.floating_strength > 0)
	testing.expect(t, abstract.parameters.cave_strength > 0)
}

@(test)
terrain_v3_normal_primary_surface_matches_v2 :: proc(t: ^testing.T) {
	recipe := terrain_normal_recipe_v3(123)
	for y in -4 ..= 4 {
		for x in -4 ..= 4 {
			world_x, world_y := f32(x * 13), f32(y * 11)
			v2, ok_v2 := terrain_sample_v2(&recipe.surface, world_x, world_y, 2)
			v3, ok_v3 := terrain_primary_surface_v3(&recipe, world_x, world_y, 2)
			testing.expect(t, ok_v2 && ok_v3)
			testing.expect_value(t, v3.height, v2.height)
			testing.expect_value(t, v3.biomes, v2.biomes)
		}
	}
}

@(test)
terrain_v3_abstract_biomes_use_transformed_surface :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(0xC0FFEE)
	for y in -8 ..= 8 {
		for x in -8 ..= 8 {
			world_x, world_y := f32(x * 8), f32(y * 8)
			v3, ok := terrain_primary_surface_v3(&recipe, world_x, world_y, 2)
			testing.expect(t, ok)
			expected, blend_ok := terrain_biome_blend_v2(
				&recipe.surface,
				v3.height,
				v3.moisture,
				v3.temperature,
				v3.slope,
			)
			testing.expect(t, blend_ok)
			testing.expect_value(t, v3.biomes, expected)
		}
	}
}

@(test)
terrain_v3_density_is_deterministic_and_abstract_is_volumetric :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(0xC0FFEE)
	different_from_normal := false
	normal := terrain_normal_recipe_v3(0xC0FFEE)
	for z in -8 ..= 16 {
		value_a, ok_a := terrain_density_v3(&recipe, 17, -23, f32(z * 3))
		value_b, ok_b := terrain_density_v3(&recipe, 17, -23, f32(z * 3))
		normal_value, normal_ok := terrain_density_v3(&normal, 17, -23, f32(z * 3))
		testing.expect(t, ok_a && ok_b && normal_ok)
		testing.expect_value(t, value_a, value_b)
		different_from_normal = different_from_normal || value_a != normal_value
	}
	testing.expect(t, different_from_normal)
}

@(test)
terrain_v3_volume_mesh_is_deterministic_bounded_and_valid :: proc(t: ^testing.T) {
	storage_a, storage_b: Terrain_V3_Test_Storage
	buffer_a := _terrain_v3_test_buffer(&storage_a, 1)
	buffer_b := _terrain_v3_test_buffer(&storage_b, 2)
	recipe := terrain_abstract_recipe_v3(77)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	testing.expect(t, terrain_generate_volume_v3(&recipe, request, &buffer_a))
	testing.expect(t, terrain_generate_volume_v3(&recipe, request, &buffer_b))
	testing.expect_value(t, buffer_a.mesh.vertex_count, buffer_b.mesh.vertex_count)
	testing.expect_value(t, buffer_a.mesh.index_count, buffer_b.mesh.index_count)
	interpolated := false
	for vertex, index in buffer_a.mesh.vertices[:buffer_a.mesh.vertex_count] {
		testing.expect_value(t, vertex, buffer_b.mesh.vertices[index])
		length := math.sqrt(
			vertex.normal.x * vertex.normal.x +
			vertex.normal.y * vertex.normal.y +
			vertex.normal.z * vertex.normal.z,
		)
		testing.expect(t, abs(length - 1) < 0.001)
		local := (vertex.position - request.origin) / request.step
		for coordinate in local {
			interpolated = interpolated || abs(coordinate - math.round(coordinate)) > 0.001
		}
	}
	testing.expect(t, interpolated)
	view, ok := asset.mesh_view(&buffer_a.mesh)
	testing.expect(t, ok && asset.mesh_validate(view))
}

@(test)
terrain_v3_volume_projection_uvs_follow_dominant_normal :: proc(t: ^testing.T) {
	position := asset.Vec3{32, 64, 96}
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({1, 0, 0}, position),
		asset.Vec2{2, 3},
	)
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({0, 1, 0}, position),
		asset.Vec2{1, 3},
	)
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({0, 0, 1}, position),
		asset.Vec2{1, 2},
	)
}

@(test)
terrain_v3_volume_mesh_rejects_short_capacity_without_publication :: proc(t: ^testing.T) {
	storage: Terrain_V3_Test_Storage
	buffer := _terrain_v3_test_buffer(&storage, 1)
	buffer.mesh.vertices = buffer.mesh.vertices[:8]
	buffer.mesh.vertex_count = 7
	recipe := terrain_normal_recipe_v3(9)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	testing.expect(t, !terrain_generate_volume_v3(&recipe, request, &buffer))
	testing.expect_value(t, buffer.mesh.vertex_count, u32(7))
}

@(test)
terrain_v3_validation_rejects_invalid_ranges_and_budget :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(1)
	recipe.parameters.minimum_z = recipe.parameters.maximum_z
	testing.expect(t, !terrain_recipe_validate_v3(&recipe))
	_, _, _, ok := terrain_volume_requirements_v3({65, 1, 1})
	testing.expect(t, !ok)
}

// Two chunks that share a face must agree on that face exactly. A difference
// of one bit in the shared density plane moves the isosurface crossing, and
// that is precisely the crack a player walks through.
@(test)
terrain_v3_adjacent_volumes_share_boundary_density :: proc(t: ^testing.T) {
	storage_a, storage_b := new(Terrain_V3_Test_Storage), new(Terrain_V3_Test_Storage)
	defer free(storage_a)
	defer free(storage_b)
	buffer_a := _terrain_v3_test_buffer(storage_a, 1)
	buffer_b := _terrain_v3_test_buffer(storage_b, 2)
	recipe := terrain_abstract_recipe_v3(99)
	step := f32(4)
	span := f32(TERRAIN_V3_TEST_CELLS) * step
	cells := [3]int{TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS}
	request_a := Terrain_Volume_Request_V3{{-span, 0, -16}, cells, step}
	request_b := Terrain_Volume_Request_V3{{0, 0, -16}, cells, step}
	testing.expect(t, terrain_generate_volume_v3(&recipe, request_a, &buffer_a))
	testing.expect(t, terrain_generate_volume_v3(&recipe, request_b, &buffer_b))
	// The one-cell halo makes the requests overlap by two lattice planes: the
	// shared face itself, at A's last halo column and B's second, and the
	// plane one step behind it.
	stride_x := TERRAIN_V3_TEST_CELLS + 2
	stride_y := TERRAIN_V3_TEST_CELLS + 2
	for overlap in 0 ..< 2 {
		left_x := TERRAIN_V3_TEST_CELLS + 1 - overlap
		right_x := 1 - overlap
		for z in 0 ..< TERRAIN_V3_TEST_CELLS + 2 {
			for y in 0 ..< TERRAIN_V3_TEST_CELLS + 2 {
				left := (z * stride_y + y) * stride_x + left_x
				right := (z * stride_y + y) * stride_x + right_x
				testing.expect_value(t, storage_a.density[left], storage_b.density[right])
			}
		}
	}
	_terrain_v3_test_expect_seam_vertices(t, &buffer_a, &buffer_b, 0)
}

// _terrain_v3_test_expect_seam_vertices checks that every vertex one chunk
// places on the shared plane is reproduced exactly by its neighbour. Vertex
// order differs between chunks, so this compares sets rather than sequences.
@(private = "file")
_terrain_v3_test_expect_seam_vertices :: proc(
	t: ^testing.T,
	buffer_a, buffer_b: ^Terrain_Volume_Buffer_V3,
	plane_x: f32,
) {
	assert(t != nil, "_terrain_v3_test_expect_seam_vertices: nil test")
	assert(buffer_a != nil && buffer_b != nil, "_terrain_v3_test_expect_seam_vertices: nil buffer")
	matched := 0
	for vertex in buffer_a.mesh.vertices[:buffer_a.mesh.vertex_count] {
		if vertex.position.x != plane_x do continue
		found := false
		for other in buffer_b.mesh.vertices[:buffer_b.mesh.vertex_count] {
			if other.position == vertex.position {
				found = true
				break
			}
		}
		testing.expectf(t, found, "seam vertex %v has no match in the neighbour", vertex.position)
		matched += 1
	}
	testing.expect(t, matched > 0)
}

@(private)
_terrain_v3_test_buffer :: proc(
	storage: ^Terrain_V3_Test_Storage,
	id: u32,
) -> Terrain_Volume_Buffer_V3 {
	assert(storage != nil, "_terrain_v3_test_buffer: nil storage")
	return {
		density_halo = storage.density[:],
		mesh = {
			id = asset.Mesh_Id(id),
			vertices = storage.vertices[:],
			indices = storage.indices[:],
			primitive = .Triangles,
		},
	}
}
