package main

import asset "ingot:asset"
import rl "ingot:gfx"
import scene_gfx "ingot:scene_gfx"

STRUCTURE_ASSET_MESH_COUNT :: 31
// Totals for the whole INGMESH2 payload: version 2 keeps every cooked level
// resident even though the structure draw path uploads only the finest one.
STRUCTURE_ASSET_LOD_COUNT :: 93
STRUCTURE_ASSET_MAX_VERTICES :: 19942
STRUCTURE_ASSET_MAX_INDICES :: 56874
STRUCTURE_ASSET_BYTES := #load("../assets/generated/structures.ingmesh")

Structure_Mesh_Id :: enum u8 {
	Headquarters_Hull,
	Headquarters_Structure,
	Headquarters_Accent,
	Mine_Hull,
	Mine_Structure,
	Mine_Accent,
	Solar_Array_Hull,
	Solar_Array_Structure,
	Solar_Array_Accent,
	Habitat_Hull,
	Habitat_Structure,
	Habitat_Accent,
	Ore_A_Rock,
	Ore_A_Ore,
	Ore_B_Rock,
	Ore_B_Ore,
	Ore_C_Rock,
	Ore_C_Ore,
	Energy_A_Basalt,
	Energy_A_Throat,
	Energy_A_Rim,
	Energy_B_Basalt,
	Energy_B_Throat,
	Energy_B_Rim,
	Energy_C_Basalt,
	Energy_C_Throat,
	Energy_C_Rim,
	Ruin_Wall_A,
	Ruin_Wall_B,
	Ruin_Wall_C,
	Ruin_Wall_D,
}

Structure_Assets :: struct {
	meshes: [Structure_Mesh_Id]rl.Gpu_Mesh,
	bounds: [Structure_Mesh_Id]asset.Bounds_3D,
	ready:  bool,
}

_structure_asset_id :: proc(id: Structure_Mesh_Id) -> asset.Mesh_Id {
	return asset.Mesh_Id(u32(id) + 1)
}

// Structures are drawn instanced per component with one shared transform
// array and no per-instance distance, so there is nothing here to select a
// level with yet. The decode therefore takes the documented version 2
// projection onto LOD 0: the chains the manifest declares stay in the bundle,
// ready for the day the draw path buckets instances by distance.
_structure_assets_decode :: proc(
	meshes: []asset.Mesh_View,
	chains: []asset.Cooked_Mesh_Chain,
	lods: []asset.Mesh_Lod,
	vertices: []asset.Vertex,
	indices: []u32,
) -> (
	asset.Cooked_Mesh_Bundle,
	bool,
) {
	bundle, _, ok := asset.cooked_mesh_decode(
		STRUCTURE_ASSET_BYTES,
		{meshes, vertices, indices},
		{chains = chains, lods = lods},
	)
	if !ok || len(bundle.meshes) != STRUCTURE_ASSET_MESH_COUNT do return {}, false
	for id in Structure_Mesh_Id {
		_, found := asset.cooked_mesh_find(bundle, _structure_asset_id(id))
		if !found do return {}, false
	}
	return bundle, true
}

structure_assets_init :: proc(value: ^Structure_Assets) -> bool {
	assert(value != nil, "structure_assets_init: nil assets")
	if value.ready do return true
	@(static) mesh_storage: [STRUCTURE_ASSET_MESH_COUNT]asset.Mesh_View
	@(static) chain_storage: [STRUCTURE_ASSET_MESH_COUNT]asset.Cooked_Mesh_Chain
	@(static) lod_storage: [STRUCTURE_ASSET_LOD_COUNT]asset.Mesh_Lod
	@(static) vertex_storage: [STRUCTURE_ASSET_MAX_VERTICES]asset.Vertex
	@(static) index_storage: [STRUCTURE_ASSET_MAX_INDICES]u32
	bundle, ok := _structure_assets_decode(
		mesh_storage[:],
		chain_storage[:],
		lod_storage[:],
		vertex_storage[:],
		index_storage[:],
	)
	if !ok do return false
	uploaded: [Structure_Mesh_Id]rl.Gpu_Mesh
	bounds: [Structure_Mesh_Id]asset.Bounds_3D
	for id in Structure_Mesh_Id {
		mesh, found := asset.cooked_mesh_find(bundle, _structure_asset_id(id))
		if !found {
			for uploaded_id in Structure_Mesh_Id do if uploaded[uploaded_id].id != 0 do rl.destroy_gpu_mesh(&uploaded[uploaded_id])
			return false
		}
		uploaded[id], ok = scene_gfx.mesh_view_upload(mesh)
		if !ok {
			for uploaded_id in Structure_Mesh_Id do if uploaded[uploaded_id].id != 0 do rl.destroy_gpu_mesh(&uploaded[uploaded_id])
			return false
		}
		bounds[id] = mesh.bounds
	}
	value.meshes = uploaded
	value.bounds = bounds
	value.ready = true
	return true
}

structure_assets_deinit :: proc(value: ^Structure_Assets) {
	if value == nil do return
	for id in Structure_Mesh_Id {
		if value.meshes[id].id != 0 do rl.destroy_gpu_mesh(&value.meshes[id])
	}
	value^ = {}
}

structure_mesh :: proc(value: ^Client_State, id: Structure_Mesh_Id) -> rl.Gpu_Mesh {
	assert(value != nil && value.structures.ready, "structure_mesh: assets not ready")
	return value.structures.meshes[id]
}
