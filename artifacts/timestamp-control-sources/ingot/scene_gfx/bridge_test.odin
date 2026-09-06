#+build !js
package scene_gfx

import "core:testing"
import "ingot:asset"
import gfx "ingot:gfx"

@(test)
bridge_lookup_rejects_missing_mesh :: proc(t: ^testing.T) {
	bridge: Bridge
	testing.expect(t, _bridge_mesh(&bridge, 1) == nil)
	bridge.meshes[0] = {
		asset_id = asset.Mesh_Id(7),
		occupied = true,
	}
	bridge.mesh_count = 1
	testing.expect(t, _bridge_mesh(&bridge, 1) == nil)
	testing.expect(t, _bridge_mesh(&bridge, 7) != nil)
}

@(test)
bridge_epoch_is_monotonic :: proc(t: ^testing.T) {
	bridge: Bridge
	bridge_begin_frame(&bridge)
	testing.expect_value(t, bridge.epoch, 1)
	bridge_begin_frame(&bridge)
	testing.expect_value(t, bridge.epoch, 2)
}

@(test)
bridge_owner_is_context_bound :: proc(t: ^testing.T) {
	first := new(gfx.Context)
	defer free(first)
	second := new(gfx.Context)
	defer free(second)
	bridge: Bridge
	bridge.owner = first
	bridge_destroy_context(second, &bridge)
	testing.expect(t, bridge.owner == first)
	bridge_destroy_context(first, &bridge)
	testing.expect(t, bridge.owner == nil)
}

@(test)
mesh_view_upload_rejects_invalid_cooked_mesh :: proc(t: ^testing.T) {
	ctx := new(gfx.Context)
	defer free(ctx)
	mesh: asset.Mesh_View
	_, ok := mesh_view_upload_context(ctx, mesh)
	testing.expect(t, !ok)
}
