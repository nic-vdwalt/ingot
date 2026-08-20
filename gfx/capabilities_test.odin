#+build !js
package gfx

import "core:testing"

@(test)
graphics_capabilities_are_explicit :: proc(t: ^testing.T) {
	caps := capabilities()
	testing.expect(t, caps.gpu_3d)
	testing.expect(t, !caps.raylib_meshes)
	testing.expect(t, caps.path_textures)
	testing.expect(t, caps.render_targets)
	testing.expect(t, !caps.general_rlgl)
	when INGOT_DEFAULT_FONT do testing.expect(t, caps.default_text)
}
