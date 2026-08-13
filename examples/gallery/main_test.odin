#+build !js
package main

import "core:testing"

@(test)
nav_strip_respects_scaled_width_and_sidebar_height :: proc(t: ^testing.T) {
	scales := [?]f32{0.5, 1, 1.5, 2, 3}
	heights := [?]i32{221, 440, 659, 878, 1316}
	for scale, index in scales {
		minimum := nav_sidebar_min_height_scale(scale)
		testing.expect_value(t, minimum, heights[index])
		width := gallery_scaled(NARROW_WIDTH_MAX, scale)
		testing.expect(t, nav_uses_strip_scale(scale, width, minimum))
		testing.expect(t, nav_uses_strip_scale(scale, width + 1, minimum - 1))
		testing.expect(t, !nav_uses_strip_scale(scale, width + 1, minimum))
	}
}
