#+build !js
package scene_gfx

import "core:testing"
import "ingot:asset"

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
