package main

import asset "ingot:asset"
import rl "ingot:gfx"
import procgen "ingot:procgen"
import scene_gfx "ingot:scene_gfx"

FLORA_ASSET_MESH_COUNT :: 12
// Totals for the whole INGMESH2 payload, not for level zero: version 2 keeps
// every level resident, so the decode storage is sized against the file.
FLORA_ASSET_LOD_COUNT :: 24
FLORA_ASSET_MAX_VERTICES :: 17435
FLORA_ASSET_MAX_INDICES :: 19626
// Largest single level in the bundle, which is what one derived variant needs.
FLORA_ASSET_MAX_LOD_VERTICES :: 4542
FLORA_ASSET_MAX_LOD_INDICES :: 4992
FLORA_ASSET_BYTES := #load("../assets/generated/flora.ingmesh")

_flora_assets_decode_result :: proc(
	chains: []asset.Cooked_Mesh_Chain,
	lods: []asset.Mesh_Lod,
	vertices: []asset.Vertex,
	indices: []u32,
) -> (
	asset.Cooked_Mesh_V2_Bundle,
	asset.Cooked_Mesh_Result,
	bool,
) {
	bundle, result, ok := asset.cooked_mesh_v2_decode(
		FLORA_ASSET_BYTES,
		{meshes = chains, lods = lods, vertices = vertices, indices = indices},
	)
	if !ok do return {}, result, false
	if len(bundle.meshes) < 8 || len(bundle.meshes) > FLORA_ASSET_MESH_COUNT {
		return {}, {fault = .Invalid_Record, offset = 12}, false
	}
	for id in Flora_Asset_Id {
		if int(id) >= len(bundle.meshes) do continue
		mesh_id := asset.Mesh_Id(u32(id) + 1)
		_, found := _flora_asset_chain(bundle, mesh_id)
		if !found do return {}, {fault = .Invalid_Record, offset = 12, mesh = mesh_id}, false
	}
	return bundle, {}, true
}

_flora_assets_decode :: proc(
	chains: []asset.Cooked_Mesh_Chain,
	lods: []asset.Mesh_Lod,
	vertices: []asset.Vertex,
	indices: []u32,
) -> (
	asset.Cooked_Mesh_V2_Bundle,
	bool,
) {
	bundle, _, ok := _flora_assets_decode_result(chains, lods, vertices, indices)
	return bundle, ok
}

// Chains are stored under strictly increasing IDs, so the lookup is the same
// binary search `asset.cooked_mesh_find` performs over a version 1 bundle.
_flora_asset_chain :: proc(
	bundle: asset.Cooked_Mesh_V2_Bundle,
	id: asset.Mesh_Id,
) -> (
	asset.Cooked_Mesh_Chain,
	bool,
) {
	if id == 0 do return {}, false
	low := 0
	high := len(bundle.meshes)
	for low < high {
		middle := low + (high - low) / 2
		candidate := bundle.meshes[middle]
		if candidate.id < id {
			low = middle + 1
		} else if candidate.id > id {
			high = middle
		} else {
			return candidate, true
		}
	}
	return {}, false
}

// _flora_asset_mesh exposes a chain's finest level, which is what any caller
// that only cares about the authored geometry wants.
_flora_asset_mesh :: proc(
	bundle: asset.Cooked_Mesh_V2_Bundle,
	id: asset.Mesh_Id,
) -> (
	asset.Mesh_View,
	bool,
) {
	chain, found := _flora_asset_chain(bundle, id)
	if !found do return {}, false
	assert(len(chain.lods) > 0, "_flora_asset_mesh: validated empty chain")
	return chain.lods[0].view, true
}

// A runtime mesh is a variant of an asset mesh, so every cooked level passes
// through the same recipe before it is uploaded.
_flora_derive :: proc(
	source: asset.Mesh_View,
	recipe: Flora_Mesh_Recipe,
	destination: ^asset.Mesh_Buffer,
) -> bool {
	assert(destination != nil, "_flora_derive: nil destination")
	if recipe.deform do return procgen.mesh_deform_variant(source, recipe.recipe, destination)
	return procgen.mesh_scale_variant(source, {scale = recipe.recipe.scale}, destination)
}

_flora_uploaded_destroy :: proc(uploaded: ^[Flora_Mesh_Id][FLORA_LOD_COUNT]rl.Gpu_Mesh) {
	assert(uploaded != nil, "_flora_uploaded_destroy: nil meshes")
	for id in Flora_Mesh_Id {
		_flora_mesh_chain_destroy(&uploaded[id])
	}
}

// _flora_chain_upload derives and uploads every cooked level of one asset
// chain, returning the populated level count and level zero's bounds.
//
// The levels come from the bundle rather than from a load-time simplification
// pass: the cook step owns the ladder each manifest policy declares, the
// decoder has already validated that coarser levels cost strictly more error,
// and every client therefore draws the geometry the bundle was checked
// against. A mesh cooked without a chain simply keeps one level.
_flora_chain_upload :: proc(
	chain: asset.Cooked_Mesh_Chain,
	recipe: Flora_Mesh_Recipe,
	id: Flora_Mesh_Id,
	uploaded: ^[FLORA_LOD_COUNT]rl.Gpu_Mesh,
	vertices: []asset.Vertex,
	indices: []u32,
) -> (
	int,
	asset.Bounds_3D,
) {
	assert(uploaded != nil, "_flora_chain_upload: nil chain")
	assert(len(chain.lods) > 0, "_flora_chain_upload: empty chain")
	levels := 0
	bounds: asset.Bounds_3D
	for level in 0 ..< min(len(chain.lods), FLORA_LOD_COUNT) {
		derived := asset.Mesh_Buffer {
			id       = asset.Mesh_Id(u32(id) + 1),
			vertices = vertices,
			indices  = indices,
		}
		if !_flora_derive(chain.lods[level].view, recipe, &derived) do break
		mesh, view_ok := asset.mesh_view(&derived)
		if !view_ok do break
		upload_ok := false
		uploaded[level], upload_ok = scene_gfx.mesh_view_upload(mesh)
		if !upload_ok do break
		// Selection scales the finest level's radius, so the bounds that feed
		// it must be level zero's rather than a coarser level's.
		if level == 0 do bounds = mesh.bounds
		levels = level + 1
	}
	return levels, bounds
}

_flora_assets_upload :: proc(value: ^Flora) -> bool {
	assert(value != nil, "_flora_assets_upload: nil flora")
	@(static) chain_storage: [FLORA_ASSET_MESH_COUNT]asset.Cooked_Mesh_Chain
	@(static) lod_storage: [FLORA_ASSET_LOD_COUNT]asset.Mesh_Lod
	@(static) vertex_storage: [FLORA_ASSET_MAX_VERTICES]asset.Vertex
	@(static) index_storage: [FLORA_ASSET_MAX_INDICES]u32
	@(static) derived_vertices: [FLORA_ASSET_MAX_LOD_VERTICES]asset.Vertex
	@(static) derived_indices: [FLORA_ASSET_MAX_LOD_INDICES]u32
	bundle, ok := _flora_assets_decode(
		chain_storage[:],
		lod_storage[:],
		vertex_storage[:],
		index_storage[:],
	)
	if !ok do return false
	uploaded: [Flora_Mesh_Id][FLORA_LOD_COUNT]rl.Gpu_Mesh
	lods: [Flora_Mesh_Id]int
	bounds: [Flora_Mesh_Id]asset.Bounds_3D
	for id in Flora_Mesh_Id {
		recipe := FLORA_MESH_RECIPES[id]
		chain, found := _flora_asset_chain(bundle, asset.Mesh_Id(u32(recipe.asset_id) + 1))
		if !found {
			#partial switch recipe.asset_id {
			case .Tree_Open:
				chain, found = _flora_asset_chain(bundle, asset.Mesh_Id(1))
			case .Grass_Tuft:
				chain, found = _flora_asset_chain(bundle, asset.Mesh_Id(5))
			case .Shrub_Rounded, .Shrub_Upright:
				chain, found = _flora_asset_chain(bundle, asset.Mesh_Id(9))
				if !found {
					chain, found = _flora_asset_chain(bundle, asset.Mesh_Id(3))
					recipe.recipe.scale *= [3]f32{0.35, 0.35, 0.25}
				}
			case:
			}
		}
		if !found {
			_flora_uploaded_destroy(&uploaded)
			return false
		}
		lods[id], bounds[id] = _flora_chain_upload(
			chain,
			recipe,
			id,
			&uploaded[id],
			derived_vertices[:],
			derived_indices[:],
		)
		if lods[id] == 0 {
			_flora_uploaded_destroy(&uploaded)
			return false
		}
	}
	for id in Flora_Mesh_Id {
		_flora_mesh_chain_destroy(&value.meshes[id])
		value.meshes[id] = uploaded[id]
		value.mesh_lods[id] = lods[id]
		value.mesh_bounds[id] = bounds[id]
	}
	return true
}
