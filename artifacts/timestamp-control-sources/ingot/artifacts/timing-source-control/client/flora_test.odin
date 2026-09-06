#+build !js
package main

import shared "../shared"
import "core:math"
import "core:testing"
import asset "ingot:asset"
import rl "ingot:gfx"

// One quantization step of the packed scalar channel. Half a step is the
// encoder's own error; the extra half absorbs the f32 round-off of comparing a
// reconstructed value against the authored one.
FLORA_TEST_SCALAR_TOLERANCE :: asset.VERTEX_PACKED_SCALAR_MAX / asset.VERTEX_PACKED_SCALAR_RANGE

_flora_test_sample :: proc(moisture, slope: f32) -> shared.Terrain_Sample {
	return {
		height = 4,
		moisture = moisture,
		temperature = 0.5,
		slope = slope,
		primary_biome = .Grassland,
		secondary_biome = .Forest,
		primary_weight = 0.5,
	}
}

@(test)
flora_embedded_bundle_contains_every_mesh :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, len(bundle.meshes), FLORA_ASSET_MESH_COUNT)
	for id in Flora_Asset_Id {
		mesh, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(id) + 1))
		testing.expect(t, found)
		if found do testing.expect_value(t, mesh.bounds.minimum.z, f32(0))
	}
}

@(test)
flora_bundle_carries_cooked_lod_chains :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	testing.expect_value(
		t,
		asset.cooked_mesh_format(FLORA_ASSET_BYTES),
		asset.Cooked_Mesh_Format.V2,
	)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	for id in Flora_Asset_Id {
		chain, found := _flora_asset_chain(bundle, asset.Mesh_Id(u32(id) + 1))
		testing.expect(t, found)
		if !found do continue
		// The upload path stops at FLORA_LOD_COUNT, so a chain deeper than
		// that would ship geometry no client can select.
		testing.expect(t, len(chain.lods) >= 1 && len(chain.lods) <= FLORA_LOD_COUNT)
		tolerance := asset.vertex_position_tolerance({chain.bounds, chain.uv_bounds})
		for level in 0 ..< len(chain.lods) {
			view := chain.lods[level].view
			// Every flora asset is authored grounded, and a coarse level that
			// lost its base would hover once the near level swapped out.
			minimum_z := view.vertices[0].position.z
			for vertex in view.vertices do minimum_z = min(minimum_z, vertex.position.z)
			testing.expect(t, minimum_z <= tolerance.z)
			if level == 0 do continue
			previous := chain.lods[level - 1]
			// A level that failed to shrink would cost a draw bucket to render
			// what the level above already renders.
			testing.expect(t, len(view.indices) < len(previous.view.indices))
			testing.expect(t, chain.lods[level].error > previous.error)
		}
	}
}

// Every biome must yield a finite, non-negative density, or a new roster entry
// would silently scale a placement chance by garbage. Water staying at zero is
// the case that keeps trees and grass off lake and ocean cells.
@(test)
flora_biome_densities_are_defined_for_every_biome :: proc(t: ^testing.T) {
	for biome in shared.Biome_Id {
		tree := _flora_tree_density(biome)
		ground := _flora_ground_density(biome)
		testing.expectf(t, tree >= 0, "tree density for %v is negative", biome)
		testing.expectf(t, ground >= 0, "ground density for %v is negative", biome)
		if biome == .Ocean || biome == .Lake {
			testing.expectf(t, tree == 0, "%v grows trees", biome)
			testing.expectf(t, ground == 0, "%v grows grass", biome)
		}
	}
	// The roster only reads as distinct if the wooded biomes actually out-plant
	// the arid ones.
	testing.expect(t, _flora_tree_density(.Forest) > _flora_tree_density(.Grassland))
	testing.expect(t, _flora_tree_density(.Taiga) > _flora_tree_density(.Tundra))
	testing.expect(t, _flora_tree_density(.Grassland) > _flora_tree_density(.Desert))
	testing.expect(t, _flora_ground_density(.Savannah) > _flora_ground_density(.Desert))
}

@(test)
flora_tree_species_follow_biome_climate :: proc(t: ^testing.T) {
	cold := [?]shared.Biome_Id{.Taiga, .Snowlands, .Tundra, .Mountain}
	arid := [?]shared.Biome_Id{.Savannah, .Desert}
	for variant in 0 ..< 8 {
		amount := f32(variant) / 8
		for biome in cold {
			mesh := _flora_tree_species(biome, amount, 0.5)
			testing.expectf(
				t,
				mesh == .Conifer_A || mesh == .Conifer_B,
				"%v produced %v instead of a conifer",
				biome,
				mesh,
			)
		}
		for biome in arid {
			mesh := _flora_tree_species(biome, amount, 0.5)
			testing.expectf(t, mesh == .Baobab, "%v produced %v instead of a baobab", biome, mesh)
		}
	}
}

@(test)
flora_grass_assets_preserve_authored_contracts :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	heights: [3]f32
	for grass_index in 0 ..< len(heights) {
		id := Flora_Asset_Id(int(Flora_Asset_Id.Grass_Upright) + grass_index)
		mesh, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(id) + 1))
		testing.expect(t, found)
		if !found do continue
		testing.expect_value(t, mesh.bounds.minimum.z, f32(0))
		testing.expect(t, mesh.bounds.maximum.x > mesh.bounds.minimum.x)
		testing.expect(t, mesh.bounds.maximum.y > mesh.bounds.minimum.y)
		testing.expect(t, mesh.bounds.maximum.z > 0)
		testing.expect(t, len(mesh.vertices) >= 120)
		testing.expect(t, len(mesh.indices) >= 180)
		for vertex in mesh.vertices {
			// Packed vertices quantize the scalar over the documented 0-2
			// range, so grass reads back a step away from the authored 1.5
			// rather than exactly on it. The shader's grass test is
			// step(1.25, scalar), which a quantization step cannot cross.
			testing.expect(t, abs(vertex.scalar - 1.5) <= FLORA_TEST_SCALAR_TOLERANCE)
			testing.expect(t, vertex.uv.x >= 0.5568 && vertex.uv.x <= 0.9432)
			testing.expect(t, vertex.uv.y >= 0.0568 && vertex.uv.y <= 0.4432)
		}
		heights[grass_index] = mesh.bounds.maximum.z
	}
	testing.expect(t, heights[2] > heights[0])
	testing.expect(t, heights[2] > heights[1])
}

@(test)
flora_tree_assets_are_detailed_and_taller_than_grass :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	max_grass_height: f32
	for asset_index in int(Flora_Asset_Id.Grass_Upright) ..= int(Flora_Asset_Id.Grass_Reed) {
		mesh, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(asset_index) + 1))
		testing.expect(t, found)
		if found do max_grass_height = max(max_grass_height, mesh.bounds.maximum.z)
	}
	for asset_index in int(Flora_Asset_Id.Conifer_A) ..= int(Flora_Asset_Id.Baobab) {
		mesh, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(asset_index) + 1))
		testing.expect(t, found)
		if !found do continue
		testing.expect_value(t, mesh.bounds.minimum.z, f32(0))
		testing.expect(t, mesh.bounds.maximum.z > max_grass_height * 1.5)
		testing.expect(t, len(mesh.vertices) >= 100)
		testing.expect(t, len(mesh.indices) >= 240)
	}
}

@(test)
flora_baobab_topology_and_material_classes_are_valid :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, result, ok := _flora_assets_decode_result(chains, lods, vertices, indices)
	testing.expect_value(t, result.fault, asset.Cooked_Mesh_Fault.None)
	testing.expect(t, ok)
	if !ok do return
	baobab, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(Flora_Asset_Id.Baobab) + 1))
	testing.expect(t, found)
	if !found do return
	testing.expect_value(t, baobab.bounds.minimum.z, f32(0))
	testing.expect(t, baobab.bounds.maximum.z > 5 && baobab.bounds.maximum.z < 7)
	bark_count, foliage_count := 0, 0
	for vertex in baobab.vertices {
		for component in vertex.position do testing.expect(t, !math.is_nan(component))
		for component in vertex.normal do testing.expect(t, !math.is_nan(component))
		normal_length := math.sqrt(
			vertex.normal.x * vertex.normal.x +
			vertex.normal.y * vertex.normal.y +
			vertex.normal.z * vertex.normal.z,
		)
		testing.expect(t, abs(normal_length - 1) < 0.00001)
		if abs(vertex.scalar) <= FLORA_TEST_SCALAR_TOLERANCE {
			bark_count += 1
		} else if abs(vertex.scalar - 1) <= FLORA_TEST_SCALAR_TOLERANCE {
			foliage_count += 1
		} else {
			testing.expect(t, false)
		}
	}
	testing.expect(t, bark_count > 0)
	testing.expect(t, foliage_count > 0)
	testing.expect_value(t, len(baobab.indices) % 3, 0)
	for index in 0 ..< len(baobab.indices) / 3 {
		first := baobab.indices[index * 3]
		second := baobab.indices[index * 3 + 1]
		third := baobab.indices[index * 3 + 2]
		testing.expect(t, first < u32(len(baobab.vertices)))
		testing.expect(t, second < u32(len(baobab.vertices)))
		testing.expect(t, third < u32(len(baobab.vertices)))
		if first >= u32(len(baobab.vertices)) ||
		   second >= u32(len(baobab.vertices)) ||
		   third >= u32(len(baobab.vertices)) {
			continue
		}
		first_position := baobab.vertices[first].position
		second_delta := baobab.vertices[second].position - first_position
		third_delta := baobab.vertices[third].position - first_position
		area_vector := [3]f32 {
			second_delta.y * third_delta.z - second_delta.z * third_delta.y,
			second_delta.z * third_delta.x - second_delta.x * third_delta.z,
			second_delta.x * third_delta.y - second_delta.y * third_delta.x,
		}
		area_length := math.sqrt(
			area_vector.x * area_vector.x +
			area_vector.y * area_vector.y +
			area_vector.z * area_vector.z,
		)
		testing.expect(t, area_length > 0.0000001)
	}
}

@(test)
flora_mesh_recipes_are_complete_deterministic_and_positive :: proc(t: ^testing.T) {
	testing.expect_value(t, FLORA_MESH_RECIPES[.Boulder_A].asset_id, Flora_Asset_Id.Rock_Gray)
	testing.expect_value(t, FLORA_MESH_RECIPES[.Boulder_B].asset_id, Flora_Asset_Id.Rock_Gray)
	testing.expect_value(t, FLORA_MESH_RECIPES[.Boulder_C].asset_id, Flora_Asset_Id.Rock_Dry)
	testing.expect_value(t, FLORA_MESH_RECIPES[.Rock_A].asset_id, Flora_Asset_Id.Rock_Gray)
	testing.expect_value(t, FLORA_MESH_RECIPES[.Rock_B].asset_id, Flora_Asset_Id.Rock_Dry)
	seeds: [5]u64
	seed_count := 0
	for id in Flora_Mesh_Id {
		first := FLORA_MESH_RECIPES[id]
		second := FLORA_MESH_RECIPES[id]
		testing.expect_value(t, first, second)
		for component in first.recipe.scale do testing.expect(t, component > 0)
		expect_deform := id >= .Boulder_A && id <= .Rock_B
		testing.expect_value(t, first.deform, expect_deform)
		if first.deform {
			testing.expect(t, first.recipe.seed != 0)
			seeds[seed_count] = first.recipe.seed
			seed_count += 1
		}
	}
	testing.expect_value(t, seed_count, len(seeds))
	for left in 0 ..< len(seeds) {
		for right in left + 1 ..< len(seeds) do testing.expect(t, seeds[left] != seeds[right])
	}
}

@(test)
flora_mesh_recipes_derive_grounded_valid_meshes :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	derived_vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(derived_vertices)
	derived_indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(derived_indices)
	for id in Flora_Mesh_Id {
		recipe := FLORA_MESH_RECIPES[id]
		source, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(recipe.asset_id) + 1))
		testing.expect(t, found)
		if !found do continue
		derived := asset.Mesh_Buffer {
			id       = asset.Mesh_Id(u32(id) + 1),
			vertices = derived_vertices,
			indices  = derived_indices,
		}
		testing.expect(t, _flora_derive(source, recipe, &derived))
		mesh, derived_ok := asset.mesh_view(&derived)
		testing.expect(t, derived_ok)
		if derived_ok do testing.expect_value(t, mesh.bounds.minimum.z, f32(0))
	}
}

@(test)
flora_rock_deformation_is_deterministic_and_reachable :: proc(t: ^testing.T) {
	chains := make([]asset.Cooked_Mesh_Chain, FLORA_ASSET_MESH_COUNT)
	defer delete(chains)
	lods := make([]asset.Mesh_Lod, FLORA_ASSET_LOD_COUNT)
	defer delete(lods)
	vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(vertices)
	indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(indices)
	bundle, ok := _flora_assets_decode(chains, lods, vertices, indices)
	testing.expect(t, ok)
	if !ok do return
	first_vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(first_vertices)
	second_vertices := make([]asset.Vertex, FLORA_ASSET_MAX_VERTICES)
	defer delete(second_vertices)
	first_indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(first_indices)
	second_indices := make([]u32, FLORA_ASSET_MAX_INDICES)
	defer delete(second_indices)
	for mesh_index in int(Flora_Mesh_Id.Boulder_A) ..= int(Flora_Mesh_Id.Rock_B) {
		id := Flora_Mesh_Id(mesh_index)
		recipe := FLORA_MESH_RECIPES[id]
		source, found := _flora_asset_mesh(bundle, asset.Mesh_Id(u32(recipe.asset_id) + 1))
		testing.expect(t, found)
		if !found do continue
		first := asset.Mesh_Buffer {
			id       = 20,
			vertices = first_vertices,
			indices  = first_indices,
		}
		second := asset.Mesh_Buffer {
			id       = 20,
			vertices = second_vertices,
			indices  = second_indices,
		}
		testing.expect(t, _flora_derive(source, recipe, &first))
		testing.expect(t, _flora_derive(source, recipe, &second))
		first_mesh, first_ok := asset.mesh_view(&first)
		second_mesh, second_ok := asset.mesh_view(&second)
		testing.expect(t, first_ok && second_ok)
		position_changed := false
		for index in 0 ..< len(first_mesh.vertices) {
			first_vertex := first_mesh.vertices[index]
			testing.expect_value(t, first_vertex, second_mesh.vertices[index])
			testing.expect_value(t, first_vertex.uv, source.vertices[index].uv)
			testing.expect_value(t, first_vertex.scalar, source.vertices[index].scalar)
			scaled := source.vertices[index].position * recipe.recipe.scale
			if first_vertex.position != scaled do position_changed = true
			normal_length := math.sqrt(
				first_vertex.normal.x * first_vertex.normal.x +
				first_vertex.normal.y * first_vertex.normal.y +
				first_vertex.normal.z * first_vertex.normal.z,
			)
			testing.expect(t, abs(normal_length - 1) < 0.00001)
		}
		for index in 0 ..< len(first_mesh.indices) {
			testing.expect_value(t, first_mesh.indices[index], source.indices[index])
		}
		testing.expect(t, position_changed)
	}
}

@(test)
flora_culling_uses_transformed_authored_bounds_center :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	flora.mesh_bounds[.Boulder_A] = {
		minimum = {-1, -1, 0},
		maximum = {1, 1, 10},
	}
	camera := rl.Camera3D {
		position   = {0, 0, 0},
		target     = {0, 0, 1},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 90,
		projection = .PERSPECTIVE,
		near_plane = 1,
		far_plane  = 100,
	}
	boundary := Flora_Instance {
		position = {0, 0, -5},
		up       = {0, 0, 1},
		east     = {1, 0, 0},
		north    = {0, 1, 0},
		yaw      = math.PI / 3,
		scale    = 1,
		mesh     = .Boulder_A,
	}
	testing.expect(t, _flora_candidate_visible(flora, &boundary, camera))
	boundary.scale = 0.8
	testing.expect(t, _flora_candidate_visible(flora, &boundary, camera))
	offscreen := Flora_Instance {
		position = {100, 0, 10},
		up       = {0, 0, 1},
		east     = {1, 0, 0},
		north    = {0, 1, 0},
		scale    = 1,
		mesh     = .Boulder_A,
	}
	testing.expect(t, !_flora_candidate_visible(flora, &offscreen, camera))
}

@(test)
flora_classification_is_deterministic :: proc(t: ^testing.T) {
	config := flora_default_config()
	sample := _flora_test_sample(0.72, 0.12)
	hash := _flora_hash(shared.TERRAIN_SEED, 18, 27)
	mesh_a, scale_a, keep_a := _flora_pick_large(config, sample, 4, -2, 12, hash)
	mesh_b, scale_b, keep_b := _flora_pick_large(config, sample, 4, -2, 12, hash)
	testing.expect_value(t, mesh_a, mesh_b)
	testing.expect_value(t, scale_a, scale_b)
	testing.expect_value(t, keep_a, keep_b)
}

@(test)
flora_tree_and_grass_scales_stay_in_category_ranges :: proc(t: ^testing.T) {
	config := flora_default_config()
	config.tree_chance_scale = 100
	config.tree_chance_max = 1
	config.grass_chance = 1
	tree_sample := _flora_test_sample(0.82, 0.10)
	grass_sample := _flora_test_sample(0.60, 0.10)
	for cell in 0 ..< 512 {
		hash := _flora_hash(shared.TERRAIN_SEED, i32(cell), 53)
		tree_mesh, tree_scale, tree_keep := _flora_pick_large(config, tree_sample, 4, -2, 12, hash)
		if tree_keep && tree_mesh >= .Conifer_A && tree_mesh <= .Baobab {
			testing.expect(t, tree_scale >= FLORA_TREE_SCALE_MIN)
			testing.expect(t, tree_scale <= FLORA_TREE_SCALE_MIN + FLORA_TREE_SCALE_VARIATION)
		}
		grass_mesh, grass_scale, grass_keep := _flora_pick_ground(
			config,
			grass_sample,
			4,
			-2,
			12,
			hash,
		)
		if grass_keep && _flora_is_grass(grass_mesh) {
			testing.expect(t, grass_scale >= FLORA_GRASS_SCALE_MIN)
			testing.expect(t, grass_scale <= FLORA_GRASS_SCALE_MIN + FLORA_GRASS_SCALE_VARIATION)
		}
	}
}

@(test)
flora_tree_density_is_monotonic_and_streams_are_independent :: proc(t: ^testing.T) {
	high := flora_default_config()
	low := high
	low.tree_chance_scale *= 0.5
	low.tree_chance_max *= 0.5
	sample := _flora_test_sample(0.82, 0.10)
	for cell in 0 ..< 256 {
		hash := _flora_hash(shared.TERRAIN_SEED, i32(cell), 11)
		high_mesh, high_scale, high_keep := _flora_pick_large(high, sample, 4, -2, 12, hash)
		low_mesh, low_scale, low_keep := _flora_pick_large(low, sample, 4, -2, 12, hash)
		if low_keep && !_flora_is_grass(low_mesh) {
			testing.expect(t, high_keep)
			testing.expect_value(t, low_mesh, high_mesh)
			testing.expect_value(t, low_scale, high_scale)
		}
	}

	no_trees := high
	no_trees.tree_chance_scale = 0
	no_trees.tree_chance_max = 0
	for cell in 0 ..< 256 {
		hash := _flora_hash(shared.TERRAIN_SEED, i32(cell), 29)
		mesh_a, scale_a, keep_a := _flora_pick_large(
			low,
			_flora_test_sample(0.40, 0.30),
			4,
			-2,
			12,
			hash,
		)
		mesh_b, scale_b, keep_b := _flora_pick_large(
			no_trees,
			_flora_test_sample(0.40, 0.30),
			4,
			-2,
			12,
			hash,
		)
		testing.expect_value(t, mesh_a, mesh_b)
		testing.expect_value(t, scale_a, scale_b)
		testing.expect_value(t, keep_a, keep_b)
	}
}

@(test)
flora_ground_scatter_is_dense_deterministic_and_bounded :: proc(t: ^testing.T) {
	config := flora_default_config()
	sample := _flora_test_sample(0.60, 0.12)
	kept := 0
	cells_per_tile := FLORA_GROUND_CELLS_PER_TILE
	// One canonical tile of absolute ground cells away from the origin: the
	// pick must be deterministic per absolute cell and dense on suitable
	// terrain regardless of which stream window contains the tile.
	tile_x, tile_y := 7, 3
	for cell in 0 ..< cells_per_tile * cells_per_tile {
		cell_x := i32(tile_x * cells_per_tile + cell % cells_per_tile)
		cell_y := i32(tile_y * cells_per_tile + cell / cells_per_tile)
		hash := _flora_hash(shared.TERRAIN_SEED ~ 0x6A0D_C10D, cell_x, cell_y)
		mesh_a, scale_a, keep_a := _flora_pick_ground(config, sample, 4, -2, 12, hash)
		mesh_b, scale_b, keep_b := _flora_pick_ground(config, sample, 4, -2, 12, hash)
		testing.expect_value(t, mesh_a, mesh_b)
		testing.expect_value(t, scale_a, scale_b)
		testing.expect_value(t, keep_a, keep_b)
		if keep_a do kept += 1
	}
	testing.expect(t, kept > cells_per_tile * cells_per_tile / 4)
	testing.expect_value(t, FLORA_MAX, FLORA_LARGE_MAX + FLORA_GROUND_MAX)
	// Streaming capacities are window-derived and independent of world size.
	testing.expect_value(t, FLORA_STREAM_TILE_COUNT, 121)
	testing.expect_value(
		t,
		FLORA_LARGE_MAX,
		FLORA_STREAM_TILE_COUNT * FLORA_LARGE_CELLS_PER_TILE * FLORA_LARGE_CELLS_PER_TILE,
	)
	testing.expect_value(
		t,
		FLORA_GROUND_MAX,
		FLORA_STREAM_TILE_COUNT *
		FLORA_GROUND_CELLS_PER_TILE *
		FLORA_GROUND_CELLS_PER_TILE *
		FLORA_GRASS_CLUSTER,
	)
}

// The grass cluster multiplies the ground pool: every accepted grass cell in
// a vegetated biome may emit up to FLORA_GRASS_CLUSTER blades, so the tile
// capacity must carry the full cluster or the scatter assert trips on a
// fully grassed tile.
@(test)
flora_grass_cluster_capacity_and_gating_are_pinned :: proc(t: ^testing.T) {
	testing.expect_value(t, FLORA_GRASS_CLUSTER, 3)
	testing.expect_value(
		t,
		FLORA_TILE_GROUND_CAPACITY,
		FLORA_GROUND_CELLS_PER_TILE * FLORA_GROUND_CELLS_PER_TILE * FLORA_GRASS_CLUSTER,
	)
	testing.expect_value(t, FLORA_TILE_CAPACITY, FLORA_TILE_LARGE_CAPACITY + FLORA_TILE_GROUND_CAPACITY)
	// The extras exist to carpet the wooded biomes; sparse ground must stay
	// a single blade per cell or deserts stop reading as deserts.
	testing.expect(t, _flora_ground_density(.Forest) >= FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Grassland) >= FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Taiga) >= FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Wetland) >= FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Savannah) >= FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Desert) < FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Snowlands) < FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Mountain) < FLORA_GRASS_CLUSTER_DENSITY_MIN)
	testing.expect(t, _flora_ground_density(.Coast) < FLORA_GRASS_CLUSTER_DENSITY_MIN)
	// Extras drop out of submission well before the primary range so the
	// carpet stays a close-range cost.
	testing.expect(t, FLORA_GROUND_EXTRA_DRAW_RANGE < FLORA_GROUND_DRAW_RANGE)
}

// Scatter seats every instance on the collided isosurface through
// terrain_seat_height, which is a Box3D raycast whenever there is a physics
// world. The GPU-less benchmark has none, and a hard assert there is what made
// bench_flora_scatter abort: this pins the documented fallback to the cached
// analytic grid so scatter stays callable against a bare Terrain. The sweep
// must also start idle - it owns re-seating after terraforming only, because
// zoom moves orbit.target and so crosses stream tiles, and a sweep-owned
// initial seat makes the whole window visibly shift as the player zooms.
@(test)
flora_scatter_falls_back_to_the_cached_grid_without_a_physics_world :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain_scatter_prepare(terrain, world)
	flora := new(Flora)
	defer free(flora)
	ruins := new(Ruins)
	defer free(ruins)
	// flora_regenerate is the one rescatter path reachable without a GPU: it
	// skips asset upload but runs the same pooled scatter and cursor reset.
	flora.ready = true
	flora_regenerate(flora, terrain, world, ruins)
	testing.expect(t, flora.count > 0, "scatter produced instances")
	for slot in 0 ..< flora.tile_count {
		span := flora.tiles[slot]
		if !span.occupied do continue
		testing.expect_value(t, span.ecology_revision, flora.ecology_revision)
		// The pooled scatter probed the seat directly, so the sweep must
		// start idle for every tile.
		testing.expect(t, span.reseated, "sweep starts idle")
	}
	// The exact seat arithmetic is world-model-specific, so each demo pins it
	// against its own flora_seat_position seam in flora_seam_test.odin; this
	// shared test pins that the scatter itself runs without a physics world.
}

// The tile-identity seam is world-model-specific (flat grid index vs cube
// face tiles), so flora_world_tile behaviour is pinned per demo in
// flora_seam_test.odin; here only the identity relation itself is shared.
@(test)
flora_world_tile_is_deterministic :: proc(t: ^testing.T) {
	first := flora_world_tile({12, 34, 5})
	second := flora_world_tile({12, 34, 5})
	testing.expect(t, flora_tile_eq(first, second), "same focus maps to the same tile")
	testing.expect(t, flora_tile_eq(first, first), "tile equals itself")
}

@(test)
flora_ecology_stale_slot_uses_per_tile_revisions :: proc(t: ^testing.T) {
	value := new(Flora)
	defer free(value)
	value.ecology_revision = 7
	value.tile_count = 3
	value.tiles[0] = {occupied = true, ecology_revision = 7}
	value.tiles[1] = {occupied = false, ecology_revision = 0}
	value.tiles[2] = {occupied = true, ecology_revision = 6}
	testing.expect_value(t, _flora_ecology_stale_slot(value), 2)
	value.tiles[2].ecology_revision = value.ecology_revision
	testing.expect_value(t, _flora_ecology_stale_slot(value), -1)
	for iteration in 0 ..< 12 {
		value.ecology_revision += 1
		expected := 0 if iteration % 2 == 0 else 2
		slot := _flora_ecology_stale_slot(value)
		testing.expect_value(t, slot, expected)
		value.ecology_cursor = (slot + 1) % value.tile_count
		value.tiles[slot].ecology_revision = value.ecology_revision
	}
}

@(private = "file")
_flora_test_is_rock :: proc(id: Flora_Mesh_Id) -> bool {
	return id == .Boulder_A || id == .Boulder_B || id == .Boulder_C || id == .Rock_A || id == .Rock_B
}

// Rocks and scree are hash-deterministic and never change under the ecology,
// so they must not grow in from zero; only ecology picks (grass, woody) do.
// Instances within each range are also emitted in raster order, which the
// rescatter carry relies on to pair old and new instances by cell.
@(test)
flora_scatter_rocks_spawn_at_full_scale_and_cells_are_ordered :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain_scatter_prepare(terrain, world)
	flora := new(Flora)
	defer free(flora)
	ruins := new(Ruins)
	defer free(ruins)
	flora.ready = true
	flora_regenerate(flora, terrain, world, ruins)
	testing.expect(t, flora.count > 0, "scatter produced instances")
	rocks := 0
	for slot in 0 ..< flora.tile_count {
		span := flora.tiles[slot]
		if !span.occupied do continue
		ranges := [2][2]i32{{span.large_begin, span.large_end}, {span.ground_begin, span.ground_end}}
		for span_range in ranges {
			previous_cell := u32(0)
			for index in span_range[0] ..< span_range[1] {
				instance := flora.instances[index]
				testing.expect(t, instance.cell >= previous_cell, "cells emitted in raster order")
				previous_cell = instance.cell
				testing.expect(t, instance.target_scale > 0, "every instance has a target scale")
				if _flora_test_is_rock(instance.mesh) {
					rocks += 1
					testing.expect_value(t, instance.scale, instance.target_scale)
				}
			}
		}
	}
	testing.expect(t, rocks > 0, "scatter placed rocks")
}

// An ecology refresh rescatters a resident tile; instances that survive with
// the same cell and mesh must keep their current size rather than snapping
// back to zero, or every rock in the window cycles through the LOD chain
// forever as the ecology steps.
@(test)
flora_rescatter_preserves_instance_scale :: proc(t: ^testing.T) {
	world := new(shared.World)
	defer free(world)
	testing.expect(t, shared.world_init_seed(world, shared.TERRAIN_SEED), "world init")
	defer shared.world_deinit(world)
	terrain := new(Terrain)
	defer free(terrain)
	terrain.sea_level = f32(world.foundation.sea_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain.snow_level = f32(world.foundation.snow_level) / f32(shared.HEIGHT_DELTA_SCALE)
	terrain_scatter_prepare(terrain, world)
	flora := new(Flora)
	defer free(flora)
	ruins := new(Ruins)
	defer free(ruins)
	flora.ready = true
	flora_regenerate(flora, terrain, world, ruins)
	slot := -1
	for candidate in 0 ..< flora.tile_count {
		span := flora.tiles[candidate]
		if span.occupied && span.large_end > span.large_begin {
			slot = candidate
			break
		}
	}
	testing.expect(t, slot >= 0, "an occupied tile with large instances exists")
	if slot < 0 do return
	span := flora.tiles[slot]
	base := slot * FLORA_TILE_CAPACITY
	before := new([FLORA_TILE_CAPACITY]Flora_Instance)
	defer free(before)
	for index in span.large_begin ..< span.large_end {
		flora.instances[index].scale = flora.instances[index].target_scale
		before[int(index) - base] = flora.instances[index]
	}
	for index in span.ground_begin ..< span.ground_end {
		flora.instances[index].scale = flora.instances[index].target_scale
		before[int(index) - base] = flora.instances[index]
	}
	flora.ecology_revision += 1
	_flora_rescatter_slot(flora, terrain, world, ruins, slot)
	after := flora.tiles[slot]
	testing.expect_value(t, after.ecology_revision, flora.ecology_revision)
	testing.expect(t, after.reseated, "rescatter probes its own seats")
	checked := 0
	ranges := [2][2]i32{{after.large_begin, after.large_end}, {after.ground_begin, after.ground_end}}
	for span_range in ranges {
		for index in span_range[0] ..< span_range[1] {
			instance := flora.instances[index]
			old := before[int(index) - base]
			if old.cell != instance.cell || old.mesh != instance.mesh do continue
			checked += 1
			testing.expect_value(t, instance.scale, old.scale)
			testing.expect(t, instance.scale > 0, "surviving instance kept its size")
		}
	}
	testing.expect(t, checked > 0, "some instances survived the rescatter")
}

@(test)
flora_categories_obey_surface_rules :: proc(t: ^testing.T) {
	config := flora_default_config()
	for cell in 0 ..< 512 {
		hash := _flora_hash(shared.TERRAIN_SEED, i32(cell), 41)
		mesh, _, keep := _flora_pick_large(
			config,
			_flora_test_sample(0.8, 0.1),
			-1.6,
			-2,
			12,
			hash,
		)
		if keep do testing.expect(t, mesh == .Boulder_A || mesh == .Boulder_B || mesh == .Boulder_C)
		mesh, _, keep = _flora_pick_large(config, _flora_test_sample(0.8, 0.8), 4, -2, 12, hash)
		if keep do testing.expect(t, mesh == .Boulder_A || mesh == .Boulder_B || mesh == .Boulder_C)
		mesh, _, keep = _flora_pick_large(config, _flora_test_sample(0.8, 0.1), 11.5, -2, 12, hash)
		if keep do testing.expect(t, !_flora_is_grass(mesh))
	}
}

@(test)
flora_footprint_clear_hides_overlaps :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	flora.count = 4
	flora.instances[0] = {
		position = {0, 0, 0},
		scale    = 1,
		mesh     = .Baobab,
	}
	flora.instances[1] = {
		position = {2, 2, 0},
		scale    = 1,
		mesh     = .Grass_Crossed,
	}
	flora.instances[2] = {
		position = {8, 8, 0},
		scale    = 1,
		mesh     = .Boulder_A,
	}
	flora.instances[3] = {
		position = {3.2, 1, 0},
		scale    = 1,
		mesh     = .Grass_Upright,
	}
	cleared := flora_clear_footprint(flora, {1, 1, 0}, {1, 0, 0}, {0, 1, 0}, 1.5, 1.5)
	testing.expect_value(t, cleared, u32(3))
	testing.expect(t, flora.instances[0].hidden)
	testing.expect(t, flora.instances[1].hidden)
	testing.expect(t, !flora.instances[2].hidden)
	testing.expect(t, flora.instances[3].hidden)
}

// Grass is the only category the distance cutoff may drop. Scree rocks come
// from the same ground scatter pass but must keep their full draw range.
@(test)
flora_grass_classification_excludes_scree :: proc(t: ^testing.T) {
	testing.expect(t, _flora_is_grass(.Grass_Upright), "grass upright is grass")
	testing.expect(t, _flora_is_grass(.Grass_Crossed), "grass crossed is grass")
	testing.expect(t, _flora_is_grass(.Grass_Reed), "grass reed is grass")
	testing.expect(t, !_flora_is_grass(.Rock_A), "scree is not grass")
	testing.expect(t, !_flora_is_grass(.Rock_B), "scree is not grass")
	testing.expect(t, !_flora_is_grass(.Conifer_A), "trees are not grass")
	testing.expect(t, !_flora_is_grass(.Boulder_A), "boulders are not grass")
}

@(test)
flora_tile_bounds_build_measures_instance_extent :: proc(t: ^testing.T) {
	value := new(Flora)
	defer free(value)
	value.instances[0] = {
		position = {0, 0, 5},
	}
	value.instances[1] = {
		position = {0, 0, -3},
	}
	value.count = 2
	value.tile_count = 1
	value.tiles[0] = {
		tile        = {face = -1, tile_u = 5, tile_v = 5},
		large_begin = 0,
		large_end   = 1,
		ground_begin = 1,
		ground_end  = 2,
	}
	_flora_tile_bounds_build(value)
	testing.expect_value(t, value.tiles[0].bounds_min, [3]f32{0, 0, -3})
	testing.expect_value(t, value.tiles[0].bounds_max, [3]f32{0, 0, 5})
}

// An empty span must produce a degenerate box rather than an inverted one,
// which would make the cull test behave unpredictably.
@(test)
flora_tile_bounds_build_handles_empty_tile :: proc(t: ^testing.T) {
	value := new(Flora)
	defer free(value)
	value.tile_count = 1
	value.tiles[0] = {
		tile = {face = -1, tile_u = 0, tile_v = 0},
	}
	_flora_tile_bounds_build(value)
	testing.expect_value(t, value.tiles[0].bounds_min, [3]f32{0, 0, 0})
	testing.expect_value(t, value.tiles[0].bounds_max, [3]f32{0, 0, 0})
}

// A tile the camera looks straight at must survive the cull, and one directly
// behind the camera must not: a false reject silently deletes flora.
@(test)
flora_tile_visible_accepts_ahead_and_rejects_behind :: proc(t: ^testing.T) {
	view := Flora_View {
		position   = {0, 0, 20},
		forward    = {0, 1, 0},
		near_plane = 1,
		far_plane  = 4000,
		tan_limit  = 1,
	}
	// A 64-unit tile two tile-lengths ahead of the camera along +Y.
	span := Flora_Tile_Span {
		bounds_min = {0, 128, 0},
		bounds_max = {64, 192, 10},
	}
	testing.expect(t, _flora_tile_visible(span, view), "tile ahead of the camera is visible")
	behind := span
	behind.bounds_min = {0, -400, 0}
	behind.bounds_max = {64, -336, 10}
	testing.expect(t, !_flora_tile_visible(behind, view), "tile behind the camera is culled")
}

// The scan must never emit a hidden instance, and must drop distant grass
// while keeping a distant tree.
@(test)
flora_visible_scan_range_applies_hidden_and_grass_range :: proc(t: ^testing.T) {
	value := new(Flora)
	defer free(value)
	view := Flora_View {
		position   = {0, 0, 0},
		forward    = {0, 1, 0},
		near_plane = 1,
		far_plane  = 4000,
		tan_limit  = 1,
	}
	centers: [Flora_Mesh_Id][3]f32
	radii: [Flora_Mesh_Id]f32
	near_grass := f32(10)
	far_grass := FLORA_GROUND_DRAW_RANGE + 50
	extra_band := FLORA_GROUND_EXTRA_DRAW_RANGE + 50
	value.instances[0] = {
		position = {0, near_grass, 0},
		mesh     = .Grass_Upright,
		scale    = 1,
	}
	value.instances[1] = {
		position = {0, far_grass, 0},
		mesh     = .Grass_Upright,
		scale    = 1,
	}
	value.instances[2] = {
		position = {0, far_grass, 0},
		mesh     = .Conifer_A,
		scale    = 1,
	}
	value.instances[3] = {
		position = {0, near_grass, 0},
		mesh     = .Grass_Upright,
		scale    = 1,
		hidden   = true,
	}
	// A cluster extra past its shorter range is dropped even though a
	// primary blade at the same distance would still draw.
	value.instances[4] = {
		position      = {0, extra_band, 0},
		mesh          = .Grass_Upright,
		scale         = 1,
		cluster_extra = true,
	}
	value.instances[5] = {
		position = {0, extra_band, 0},
		mesh     = .Grass_Upright,
		scale    = 1,
	}
	value.count = 6
	// view_ok = false isolates the range and hidden rules from the frustum.
	_flora_visible_scan_range(value, view, false, centers, radii, 0, 6)
	testing.expect_value(t, value.candidate_count, 3)
	testing.expect_value(t, value.candidates[0], 0)
	testing.expect_value(t, value.candidates[1], 2)
	testing.expect_value(t, value.candidates[2], 5)
}

// With no spans recorded the scan must still see every instance, so the
// coarse cull can never be the reason flora disappears before a scatter.
@(test)
flora_visible_scan_without_spans_falls_back_to_full_scan :: proc(t: ^testing.T) {
	value := new(Flora)
	defer free(value)
	value.instances[0] = {
		position = {0, 10, 0},
		mesh     = .Conifer_A,
		scale    = 1,
	}
	value.count = 1
	value.tile_count = 0
	camera := rl.Camera3D {
		position   = {0, 0, 0},
		target     = {0, 1, 0},
		up         = rl.CAMERA_WORLD_UP,
		fovy       = 45,
		projection = .PERSPECTIVE,
		near_plane = 1,
		far_plane  = 4000,
	}
	_flora_visible_scan(value, camera)
	testing.expect_value(t, value.candidate_count, 1)
}

@(test)
flora_lod_falls_off_monotonically_with_distance :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	flora.mesh_lods[.Baobab] = FLORA_LOD_COUNT
	view := Flora_View {
		position   = {0, 0, 0},
		forward    = {0, 1, 0},
		near_plane = 1,
		far_plane  = 1000,
		tan_limit  = 1,
	}
	instance := Flora_Instance {
		scale = 1,
		mesh  = .Baobab,
	}
	radius := f32(4)
	previous := u8(0)
	seen: [FLORA_LOD_COUNT]bool
	// A level must never get finer as the instance recedes, or the chain would
	// visibly pop backwards; sweeping the whole band also proves every level is
	// reachable rather than dead weight.
	for step in 1 ..= 400 {
		instance.position = {0, f32(step) * 2, 0}
		level := _flora_instance_lod(flora, &instance, view, radius)
		testing.expect(t, int(level) < FLORA_LOD_COUNT)
		testing.expect(t, level >= previous)
		seen[level] = true
		previous = level
	}
	for level in 0 ..< FLORA_LOD_COUNT {
		testing.expect(t, seen[level])
	}
}

@(test)
flora_lod_respects_the_populated_level_count :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	view := Flora_View {
		position   = {0, 0, 0},
		forward    = {0, 1, 0},
		near_plane = 1,
		far_plane  = 1000,
		tan_limit  = 1,
	}
	instance := Flora_Instance {
		position = {0, 600, 0},
		scale    = 1,
		mesh     = .Grass_Upright,
	}
	// A mesh too small to simplify keeps one level, and selection must never
	// name a level that was never uploaded.
	flora.mesh_lods[.Grass_Upright] = 1
	testing.expect_value(t, _flora_instance_lod(flora, &instance, view, 0.5), u8(0))
	flora.mesh_lods[.Grass_Upright] = 2
	testing.expect_value(t, _flora_instance_lod(flora, &instance, view, 0.5), u8(1))
	// A degenerate bounding radius has no apparent size to divide by, so the
	// finest level is the only honest answer.
	flora.mesh_lods[.Grass_Upright] = FLORA_LOD_COUNT
	testing.expect_value(t, _flora_instance_lod(flora, &instance, view, 0), u8(0))
}

@(test)
flora_lod_scale_moves_the_switch_distance :: proc(t: ^testing.T) {
	flora := new(Flora)
	defer free(flora)
	flora.mesh_lods[.Conifer_A] = FLORA_LOD_COUNT
	view := Flora_View {
		position   = {0, 0, 0},
		forward    = {0, 1, 0},
		near_plane = 1,
		far_plane  = 1000,
		tan_limit  = 1,
	}
	// Selection is on apparent size, so a larger instance of the same mesh
	// holds its finer level further out. That is the whole reason the rule is
	// not a shared distance threshold.
	small := Flora_Instance {
		position = {0, 120, 0},
		scale    = 1,
		mesh     = .Conifer_A,
	}
	large := small
	large.scale = 4
	small_level := _flora_instance_lod(flora, &small, view, 2)
	large_level := _flora_instance_lod(flora, &large, view, 2)
	testing.expect(t, large_level < small_level)
}

// Aspect ratios worth pinning: square, 16:9, the ~2512x1480 window the corner
// artifact was first reported on, and an ultrawide.
FLORA_TEST_CORNER_ASPECTS := [4]f32{1, 16.0 / 9.0, 1.697, 21.0 / 9.0}
FLORA_TEST_CORNER_FOVY :: f32(42)

// The culling cone has to contain the frustum, and the frustum's widest
// direction is a corner. The value this replaced used the edge-midpoint extent,
// which is strictly narrower at every aspect ratio.
@(test)
view_tan_limit_reaches_the_frustum_corner :: proc(t: ^testing.T) {
	half := math.tan(FLORA_TEST_CORNER_FOVY * math.PI / 360)
	for aspect in FLORA_TEST_CORNER_ASPECTS {
		limit := _view_tan_limit(FLORA_TEST_CORNER_FOVY, aspect)
		expected := half * math.sqrt(1 + aspect * aspect)
		testing.expectf(
			t,
			abs(limit - expected) <= 1e-6,
			"aspect %v: tan_limit %v, want %v",
			aspect,
			limit,
			expected,
		)
		testing.expectf(
			t,
			limit >= half * max(aspect, 1),
			"aspect %v: tan_limit %v narrower than the edge-midpoint extent %v",
			aspect,
			limit,
			half * max(aspect, 1),
		)
	}
}

// A point just inside the frustum corner is visible geometry. Culling it is not
// a wasted draw, it is a hole in the world: terrain chunks share this test, and
// a dropped chunk shows the sky dome behind it.
@(test)
flora_visibility_keeps_geometry_in_the_frustum_corner :: proc(t: ^testing.T) {
	half := math.tan(FLORA_TEST_CORNER_FOVY * math.PI / 360)
	depth := f32(400)
	for aspect in FLORA_TEST_CORNER_ASPECTS {
		view := Flora_View {
			position   = {0, 0, 0},
			forward    = {0, 1, 0},
			near_plane = 1,
			far_plane  = 4000,
			tan_limit  = _view_tan_limit(FLORA_TEST_CORNER_FOVY, aspect),
		}
		// Forward is +Y, so the lateral axes are X (screen horizontal, scaled
		// by aspect) and Z (screen vertical). A zero radius makes this a pure
		// test of the cone rather than of the bounding-sphere slack.
		inside := Flora_Instance {
			position = {depth * half * aspect * 0.99, depth, depth * half * 0.99},
			scale    = 1,
			cos_yaw  = 1,
		}
		testing.expectf(
			t,
			_flora_instance_visible(&inside, view, {}, 0),
			"aspect %v: corner point culled",
			aspect,
		)
		// The regression guard: the old edge-midpoint limit rejects that exact
		// point, so this test fails if the narrow cone ever comes back.
		narrow := view
		narrow.tan_limit = half * max(aspect, 1)
		testing.expectf(
			t,
			!_flora_instance_visible(&inside, narrow, {}, 0),
			"aspect %v: edge-midpoint limit unexpectedly accepts the corner",
			aspect,
		)
		// The fix must not degenerate into accepting everything.
		outside := inside
		outside.position = {depth * half * aspect * 1.6, depth, depth * half * 1.6}
		testing.expectf(
			t,
			!_flora_instance_visible(&outside, view, {}, 0),
			"aspect %v: point well outside the corner accepted",
			aspect,
		)
	}
}

// With no target to measure, the aspect falls back to the screen query rather
// than to a degenerate zero that would collapse the cone.
@(test)
view_aspect_without_a_target_is_positive :: proc(t: ^testing.T) {
	testing.expect(t, _view_aspect(nil) > 0)
}
