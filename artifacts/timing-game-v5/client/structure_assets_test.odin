#+build !js
package main

import "core:testing"
import asset "ingot:asset"

@(test)
structure_embedded_bundle_contains_every_mesh :: proc(t: ^testing.T) {
	@(static) meshes: [STRUCTURE_ASSET_MESH_COUNT]asset.Mesh_View
	@(static) chains: [STRUCTURE_ASSET_MESH_COUNT]asset.Cooked_Mesh_Chain
	@(static) lods: [STRUCTURE_ASSET_LOD_COUNT]asset.Mesh_Lod
	@(static) vertices: [STRUCTURE_ASSET_MAX_VERTICES]asset.Vertex
	@(static) indices: [STRUCTURE_ASSET_MAX_INDICES]u32
	testing.expect_value(
		t,
		asset.cooked_mesh_format(STRUCTURE_ASSET_BYTES),
		asset.Cooked_Mesh_Format.V2,
	)
	bundle, ok := _structure_assets_decode(meshes[:], chains[:], lods[:], vertices[:], indices[:])
	testing.expect(t, ok)
	if !ok do return
	testing.expect_value(t, len(bundle.meshes), STRUCTURE_ASSET_MESH_COUNT)
	for id in Structure_Mesh_Id {
		mesh, found := asset.cooked_mesh_find(bundle, _structure_asset_id(id))
		testing.expect(t, found)
		if found do testing.expect_value(t, mesh.bounds.minimum.z, f32(0))
	}
}

@(test)
structure_building_models_use_authored_components :: proc(t: ^testing.T) {
	for model, kind in BUILDING_MODELS {
		expected_count := 1 if kind == .Habitat else MODEL_COMPONENT_COUNT
		testing.expect_value(t, model.component_count, expected_count)
		testing.expect(t, model.socket_radius > 0)
		for index in 0 ..< model.component_count do testing.expect(t, int(model.components[index].mesh) < 12)
	}
	testing.expect_value(
		t,
		BUILDING_MODELS[.Habitat].components[0].mesh,
		Structure_Mesh_Id.Habitat_Hull,
	)
}

@(test)
structure_ruin_meshes_are_append_only :: proc(t: ^testing.T) {
	testing.expect_value(t, int(Structure_Mesh_Id.Ruin_Wall_A), 27)
	testing.expect_value(t, int(Structure_Mesh_Id.Ruin_Wall_D), 30)
	for mesh in RUIN_MESHES do testing.expect(t, mesh >= .Ruin_Wall_A && mesh <= .Ruin_Wall_D)
}

@(test)
structure_node_variants_are_deterministic_and_complete :: proc(t: ^testing.T) {
	seen := [NODE_VARIANT_COUNT]bool{}
	for coordinate in 0 ..< 512 {
		first := _node_variant_index(i32(coordinate), i32(coordinate * 7))
		second := _node_variant_index(i32(coordinate), i32(coordinate * 7))
		testing.expect_value(t, first, second)
		testing.expect(t, first >= 0 && first < NODE_VARIANT_COUNT)
		seen[first] = true
	}
	for present in seen do testing.expect(t, present)
	for variant in NODE_VARIANTS[.Ore] do testing.expect_value(t, variant.component_count, 2)
	for variant in NODE_VARIANTS[.Energy] {
		testing.expect_value(t, variant.component_count, 3)
		testing.expect(t, variant.mouth_height > 0)
	}
}

@(test)
structure_richness_scale_preserves_endpoints :: proc(t: ^testing.T) {
	testing.expect(t, abs(_node_cluster_scale(100) - f32(0.925)) < 0.000001)
	testing.expect(t, abs(_node_cluster_scale(400) - f32(1.15)) < 0.000001)
}
