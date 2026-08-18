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
	TERRAIN_VOLUME_EDGES_PER_CELL_V3
TERRAIN_V3_TEST_INDICES ::
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_V3_TEST_CELLS *
	TERRAIN_VOLUME_INDICES_PER_CELL_V3
TERRAIN_V3_TEST_SLOTS :: 16384

Terrain_V3_Test_Storage :: struct {
	density:     [TERRAIN_V3_TEST_DENSITY]f32,
	normals:     [TERRAIN_V3_TEST_DENSITY]asset.Vec3,
	weld_keys:   [TERRAIN_V3_TEST_SLOTS]u64,
	weld_values: [TERRAIN_V3_TEST_SLOTS]u32,
	vertices:    [TERRAIN_V3_TEST_VERTICES]asset.Vertex,
	indices:     [TERRAIN_V3_TEST_INDICES]u32,
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
	testing.expect_value(t, normal.parameters.fissure_strength, f32(0))
	testing.expect(t, abstract.parameters.floating_strength > 0)
	testing.expect(t, abstract.parameters.cave_strength > 0)
	testing.expect(t, abstract.parameters.fissure_strength > 0)
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
				v3.continentalness,
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
	storage_a, storage_b := new(Terrain_V3_Test_Storage), new(Terrain_V3_Test_Storage)
	defer free(storage_a)
	defer free(storage_b)
	buffer_a := _terrain_v3_test_buffer(storage_a, 1)
	buffer_b := _terrain_v3_test_buffer(storage_b, 2)
	recipe := terrain_abstract_recipe_v3(77)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	result_a, ok_a := terrain_generate_volume_v3(&recipe, request, &buffer_a)
	result_b, ok_b := terrain_generate_volume_v3(&recipe, request, &buffer_b)
	testing.expect(t, ok_a && ok_b)
	testing.expect_value(t, result_a, result_b)
	testing.expect_value(t, result_a.occupancy, Terrain_Volume_Occupancy_V3.Mixed)
	testing.expect_value(t, result_a.vertex_count, buffer_a.mesh.vertex_count)
	testing.expect_value(t, result_a.index_count, buffer_a.mesh.index_count)
	// Welding must actually share: three fresh vertices per triangle would
	// make these equal, and then the index buffer would carry no information.
	testing.expect(t, result_a.vertex_count < result_a.index_count)
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
	for index in buffer_a.mesh.indices[:buffer_a.mesh.index_count] {
		testing.expect_value(t, buffer_a.mesh.indices[index], buffer_b.mesh.indices[index])
	}
	view, ok := asset.mesh_view(&buffer_a.mesh)
	testing.expect(t, ok && asset.mesh_validate(view))
}

@(test)
terrain_v3_volume_projection_uvs_follow_dominant_normal :: proc(t: ^testing.T) {
	position := asset.Vec3{32, 64, 96}
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({1, 0, 0}, position, 32),
		asset.Vec2{2, 3},
	)
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({0, 1, 0}, position, 32),
		asset.Vec2{1, 3},
	)
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({0, 0, 1}, position, 32),
		asset.Vec2{1, 2},
	)
	// The scale is a recipe field, so halving it must double the coordinates.
	testing.expect_value(
		t,
		_terrain_volume_projection_uv_v3({0, 0, 1}, position, 16),
		asset.Vec2{2, 4},
	)
}

@(test)
terrain_v3_volume_mesh_rejects_short_capacity_without_publication :: proc(t: ^testing.T) {
	storage := new(Terrain_V3_Test_Storage)
	defer free(storage)
	buffer := _terrain_v3_test_buffer(storage, 1)
	buffer.mesh.vertices = buffer.mesh.vertices[:8]
	buffer.mesh.vertex_count = 7
	recipe := terrain_abstract_recipe_v3(9)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	_, ok := terrain_generate_volume_v3(&recipe, request, &buffer)
	testing.expect(t, !ok)
	testing.expect_value(t, buffer.mesh.vertex_count, u32(7))
}

@(test)
terrain_v3_validation_rejects_invalid_ranges_and_budget :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(1)
	recipe.parameters.minimum_z = recipe.parameters.maximum_z
	testing.expect(t, !terrain_recipe_validate_v3(&recipe))
	_, _, _, _, ok := terrain_volume_requirements_v3({65, 1, 1})
	testing.expect(t, !ok)
	// The parameters promoted from literals in version 4 must be validated,
	// or a zero-valued custom recipe would divide by zero while terracing.
	zeroed := terrain_abstract_recipe_v3(1)
	zeroed.parameters.mountain_terrace_step = 0
	testing.expect(t, !terrain_recipe_validate_v3(&zeroed))
	scaled := terrain_abstract_recipe_v3(1)
	scaled.parameters.surface_uv_scale = 0
	testing.expect(t, !terrain_recipe_validate_v3(&scaled))
	jittered := terrain_abstract_recipe_v3(1)
	jittered.parameters.floating_jitter = 1.5
	testing.expect(t, !terrain_recipe_validate_v3(&jittered))
	fissure_bad := terrain_abstract_recipe_v3(1)
	fissure_bad.parameters.fissure_width = 0
	testing.expect(t, !terrain_recipe_validate_v3(&fissure_bad))
	fissure_depth := terrain_abstract_recipe_v3(1)
	fissure_depth.parameters.fissure_depth_min = 100
	fissure_depth.parameters.fissure_depth_max = -100
	testing.expect(t, !terrain_recipe_validate_v3(&fissure_depth))
}

// A chunk far above every surface is air, and one far below is rock. Both are
// ordinary results in a streaming world, so both must report success with a
// named occupancy rather than the failure the first version returned.
@(test)
terrain_v3_uniform_chunks_report_occupancy_instead_of_failing :: proc(t: ^testing.T) {
	storage := new(Terrain_V3_Test_Storage)
	defer free(storage)
	buffer := _terrain_v3_test_buffer(storage, 1)
	recipe := terrain_normal_recipe_v3(5)
	cells := [3]int{TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS}
	sky := Terrain_Volume_Request_V3{{0, 0, 4096}, cells, 4}
	result, ok := terrain_generate_volume_v3(&recipe, sky, &buffer)
	testing.expect(t, ok)
	testing.expect_value(t, result.occupancy, Terrain_Volume_Occupancy_V3.Empty)
	testing.expect_value(t, result.vertex_count, u32(0))
	testing.expect_value(t, result.index_count, u32(0))
	deep := Terrain_Volume_Request_V3{{0, 0, -4096}, cells, 4}
	deep_result, deep_ok := terrain_generate_volume_v3(&recipe, deep, &buffer)
	testing.expect(t, deep_ok)
	testing.expect_value(t, deep_result.occupancy, Terrain_Volume_Occupancy_V3.Solid)
	testing.expect_value(t, deep_result.index_count, u32(0))
}

// The cull is only useful if it is never wrong in the direction that drops
// geometry: Empty and Solid must be certain, Mixed may be pessimistic.
@(test)
terrain_v3_occupancy_never_contradicts_generated_geometry :: proc(t: ^testing.T) {
	storage := new(Terrain_V3_Test_Storage)
	defer free(storage)
	recipe := terrain_abstract_recipe_v3(31)
	cells := [3]int{TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS, TERRAIN_V3_TEST_CELLS}
	culled := 0
	for z in -2 ..= 2 {
		for x in -1 ..= 1 {
			buffer := _terrain_v3_test_buffer(storage, 1)
			request := Terrain_Volume_Request_V3 {
				origin = {f32(x) * 24, 0, f32(z) * 24},
				cells  = cells,
				step   = 4,
			}
			occupancy, occupancy_ok := terrain_volume_occupancy_v3(&recipe, request)
			result, ok := terrain_generate_volume_v3(&recipe, request, &buffer)
			testing.expect(t, occupancy_ok && ok)
			if occupancy != .Mixed {
				culled += 1
				testing.expectf(
					t,
					result.index_count == 0,
					"occupancy %v culled a chunk that meshed %d indices",
					occupancy,
					result.index_count,
				)
				testing.expect_value(t, occupancy, result.occupancy)
			}
		}
	}
	testing.expect(t, culled > 0)
}

// terrain_volume_count_v3 exists so a streaming caller can size real buffers.
// If it disagreed with generation by one triangle that caller would either
// overflow or silently truncate, so the two must be exactly equal.
@(test)
terrain_v3_counts_match_generated_output :: proc(t: ^testing.T) {
	storage := new(Terrain_V3_Test_Storage)
	defer free(storage)
	buffer := _terrain_v3_test_buffer(storage, 1)
	recipe := terrain_abstract_recipe_v3(77)
	request := Terrain_Volume_Request_V3{{-12, -12, -12}, {6, 6, 6}, 4}
	vertices, indices, count_ok := terrain_volume_count_v3(&recipe, request, storage.density[:])
	testing.expect(t, count_ok)
	result, ok := terrain_generate_volume_v3(&recipe, request, &buffer)
	testing.expect(t, ok)
	testing.expect_value(t, u32(indices), result.index_count)
	// The counting pass bounds vertices before welding, so it is an upper
	// bound the welded output must stay within.
	testing.expect(t, u32(vertices) >= result.vertex_count)
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
	_, ok_a := terrain_generate_volume_v3(&recipe, request_a, &buffer_a)
	_, ok_b := terrain_generate_volume_v3(&recipe, request_b, &buffer_b)
	testing.expect(t, ok_a && ok_b)
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
		normal_halo = storage.normals[:],
		weld_keys = storage.weld_keys[:],
		weld_values = storage.weld_values[:],
		mesh = {
			id = asset.Mesh_Id(id),
			vertices = storage.vertices[:],
			indices = storage.indices[:],
			primitive = .Triangles,
		},
	}
}

@(test)
terrain_v3_fissure_carves_into_solid_ground :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(0xC0FFEE)
	no_fissure := recipe
	no_fissure.parameters.fissure_strength = 0
	carved := 0
	for y in -16 ..= 16 {
		for x in -16 ..= 16 {
			world_x, world_y := f32(x * 6), f32(y * 6)
			for z_i in -4 ..= 8 {
				world_z := f32(z_i * 4)
				full, ok_f := terrain_density_v3(&recipe, world_x, world_y, world_z)
				base, ok_b := terrain_density_v3(&no_fissure, world_x, world_y, world_z)
				testing.expect(t, ok_f && ok_b)
				if base > 0 && full <= 0 do carved += 1
			}
		}
	}
	testing.expect(t, carved > 0, "fissures must carve at least one sample")
}

@(test)
terrain_v3_fissure_mouth_is_not_buildable :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(0xC0FFEE)
	no_fissure := recipe
	no_fissure.parameters.fissure_strength = 0
	unbuildable := 0
	for y in -64 ..= 64 {
		for x in -64 ..= 64 {
			world_x, world_y := f32(x * 2), f32(y * 2)
			full, ok_f := terrain_primary_surface_v3(&recipe, world_x, world_y, 4)
			base, ok_b := terrain_primary_surface_v3(&no_fissure, world_x, world_y, 4)
			testing.expect(t, ok_f && ok_b)
			if base.buildable && !full.buildable do unbuildable += 1
		}
	}
	testing.expect(t, unbuildable > 0, "fissure mouths must suppress buildability")
}

@(test)
terrain_v3_cave_creates_enclosed_void :: proc(t: ^testing.T) {
	recipe := terrain_abstract_recipe_v3(0xC0FFEE)
	no_cave := recipe
	no_cave.parameters.cave_strength = 0
	enclosed := 0
	for y in -12 ..= 12 {
		for x in -12 ..= 12 {
			world_x, world_y := f32(x * 8), f32(y * 8)
			for z_i in -6 ..= 6 {
				world_z := f32(z_i * 4)
				full, ok_f := terrain_density_v3(&recipe, world_x, world_y, world_z)
				base, ok_b := terrain_density_v3(&no_cave, world_x, world_y, world_z)
				testing.expect(t, ok_f && ok_b)
				if base > 0 && full <= 0 {
					above, ok_a := terrain_density_v3(&recipe, world_x, world_y, world_z + 12)
					testing.expect(t, ok_a)
					if above > 0 do enclosed += 1
				}
			}
		}
	}
	testing.expect(t, enclosed > 0, "caves must create enclosed voids")
}
