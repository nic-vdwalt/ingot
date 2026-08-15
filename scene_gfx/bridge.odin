package scene_gfx

import "ingot:asset"
import gfx "ingot:gfx"
import "ingot:scene"

SCENE_GFX_MAX_RESIDENT_MESHES :: gfx.GPU_3D_MAX_MESHES

Resident_Mesh :: struct {
	asset_id:   asset.Mesh_Id,
	gpu:        gfx.Gpu_Mesh,
	last_epoch: u64,
	occupied:   bool,
}

Bridge :: struct {
	owner:           ^gfx.Context,
	meshes:          [SCENE_GFX_MAX_RESIDENT_MESHES]Resident_Mesh,
	mesh_count:      u16,
	epoch:           u64,
	upload_failures: u32,
	missing_draws:   u32,
}

// Vertices are reinterpreted, never converted: cooked data must ALREADY be in
// Ingot's right-handed ROS basis (+X forward, +Y left, +Z up), with outward
// counter-clockwise winding to match the pipeline's front-face policy.
mesh_view_upload_context :: proc(
	ctx: ^gfx.Context,
	mesh: asset.Mesh_View,
) -> (
	gfx.Gpu_Mesh,
	bool,
) {
	assert(ctx != nil, "mesh_view_upload_context: nil context")
	if !asset.mesh_validate(mesh) do return {}, false
	vertices := transmute([]gfx.Gpu_3D_Vertex)mesh.vertices
	primitive := gfx.Gpu_Primitive(mesh.primitive)
	return gfx.context_create_gpu_mesh(ctx, vertices, mesh.indices, primitive)
}

mesh_view_upload :: proc(mesh: asset.Mesh_View) -> (gfx.Gpu_Mesh, bool) {
	return mesh_view_upload_context(gfx.default_context(), mesh)
}

bridge_upload_mesh_context :: proc(
	ctx: ^gfx.Context,
	bridge: ^Bridge,
	mesh: asset.Mesh_View,
) -> bool {
	assert(ctx != nil, "bridge_upload_mesh_context: nil context")
	assert(bridge != nil, "bridge_upload_mesh_context: nil bridge")
	if bridge.owner != nil && bridge.owner != ctx do return false
	if _bridge_mesh(bridge, mesh.id) != nil do return false
	if int(bridge.mesh_count) >= SCENE_GFX_MAX_RESIDENT_MESHES {
		bridge.upload_failures += 1
		return false
	}
	gpu, ok := mesh_view_upload_context(ctx, mesh)
	if !ok {
		bridge.upload_failures += 1
		return false
	}
	for &entry in bridge.meshes {
		if entry.occupied do continue
		entry = {
			asset_id   = mesh.id,
			gpu        = gpu,
			last_epoch = bridge.epoch,
			occupied   = true,
		}
		bridge.owner = ctx
		bridge.mesh_count += 1
		return true
	}
	assert(false, "bridge_upload_mesh: count mismatch")
	return false
}

bridge_upload_mesh :: proc(bridge: ^Bridge, mesh: asset.Mesh_View) -> bool {
	return bridge_upload_mesh_context(gfx.default_context(), bridge, mesh)
}

bridge_destroy_context :: proc(ctx: ^gfx.Context, bridge: ^Bridge) {
	assert(ctx != nil, "bridge_destroy_context: nil context")
	assert(bridge != nil, "bridge_destroy_context: nil bridge")
	if bridge.owner != nil && bridge.owner != ctx do return
	for &entry in bridge.meshes {
		if entry.occupied do gfx.context_destroy_gpu_mesh(ctx, &entry.gpu)
	}
	bridge^ = {}
}

bridge_destroy :: proc(bridge: ^Bridge) {
	bridge_destroy_context(gfx.default_context(), bridge)
}

bridge_begin_frame :: proc(bridge: ^Bridge) {
	assert(bridge != nil, "bridge_begin_frame: nil bridge")
	bridge.epoch += 1
	assert(bridge.epoch != 0, "bridge_begin_frame: epoch wrapped")
}

bridge_replay :: proc(
	bridge: ^Bridge,
	pass: ^gfx.Gpu_3D_Pass,
	world: ^scene.Scene,
	draws: ^scene.Draw_List,
) {
	assert(bridge != nil, "bridge_replay: nil bridge")
	assert(pass != nil, "bridge_replay: nil pass")
	assert(world != nil, "bridge_replay: nil scene")
	assert(draws != nil, "bridge_replay: nil draw list")
	assert(draws.count <= scene.SCENE_MAX_DRAWS, "bridge_replay: draw count overflow")
	for draw in draws.draws[:draws.count] {
		entry := _bridge_mesh(bridge, draw.mesh)
		material_index := int(draw.material) - 1
		if entry == nil || material_index < 0 || material_index >= int(world.material_count) {
			bridge.missing_draws += 1
			continue
		}
		material := world.materials[material_index]
		entry.last_epoch = bridge.epoch
		gfx.draw_gpu_mesh(
			pass,
			entry.gpu,
			transmute(gfx.Matrix)draw.transform,
			{
				color = gfx.Color(material.color_low),
				color_high = gfx.Color(material.color_high),
				use_scalar = material.use_scalar,
			},
		)
	}
}

@(private)
_bridge_mesh :: proc(bridge: ^Bridge, id: asset.Mesh_Id) -> ^Resident_Mesh {
	assert(bridge != nil, "_bridge_mesh: nil bridge")
	if id == 0 do return nil
	for &entry in bridge.meshes {
		if entry.occupied && entry.asset_id == id do return &entry
	}
	return nil
}

#assert(size_of(asset.Vertex) == size_of(gfx.Gpu_3D_Vertex))
#assert(offset_of(asset.Vertex, position) == offset_of(gfx.Gpu_3D_Vertex, position))
#assert(offset_of(asset.Vertex, normal) == offset_of(gfx.Gpu_3D_Vertex, normal))
#assert(offset_of(asset.Vertex, scalar) == offset_of(gfx.Gpu_3D_Vertex, scalar))
#assert(offset_of(asset.Vertex, uv) == offset_of(gfx.Gpu_3D_Vertex, uv))
#assert(size_of(asset.Primitive) == size_of(gfx.Gpu_Primitive))
#assert(u8(asset.Primitive.Triangles) == u8(gfx.Gpu_Primitive.Triangles))
#assert(u8(asset.Primitive.Lines) == u8(gfx.Gpu_Primitive.Lines))
#assert(u8(asset.Primitive.Points) == u8(gfx.Gpu_Primitive.Points))
#assert(size_of(scene.Matrix_4) == size_of(gfx.Matrix))
