#+build !js
package gfx

import "core:testing"

@(test)
graphics_capabilities_are_explicit :: proc(t: ^testing.T) {
	caps := capabilities()
	testing.expect(t, caps.gpu_3d)
	testing.expect(t, !caps.raylib_meshes)
	testing.expect(t, caps.path_textures)
	testing.expect(t, !caps.text_shaping)
	testing.expect(t, !caps.text_fallback)
	testing.expect(t, !caps.text_bidi)
	testing.expect(t, !caps.text_color_colr)
	testing.expect(t, !caps.text_color_cbdt)
	testing.expect(t, !caps.text_color_sbix)
	testing.expect(t, !caps.svg_images)
	testing.expect(t, !caps.animated_images)
	testing.expect(t, caps.pointer_events)
	testing.expect(t, !caps.multi_pointer)
	testing.expect(t, !caps.pointer_pressure)
	testing.expect(t, caps.render_targets)
	testing.expect(t, !caps.general_rlgl)
	when INGOT_DEFAULT_FONT do testing.expect(t, caps.default_text)
}
