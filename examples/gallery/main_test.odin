#+build !js
package main

import "core:testing"
import ui "ingot:fit"

@(test)
nav_strip_respects_scaled_width_and_sidebar_height :: proc(t: ^testing.T) {
	scales := [?]f32{0.5, 1, 1.5, 2, 3}
	heights := [?]i32{221, 440, 659, 878, 1316}
	for scale, index in scales {
		runtime: ui.Ui_Runtime
		ui.ui_runtime_init(&runtime)
		ui.ui_runtime_set_scale(&runtime, scale)
		frame: ui.Ui_Frame
		ui.ui_frame_begin(&frame, &runtime)
		minimum := nav_sidebar_min_height(&frame)
		testing.expect_value(t, minimum, heights[index])
		width := ui.ui_frame_sc(&frame, NARROW_WIDTH_MAX)
		testing.expect(t, nav_uses_strip(&frame, width, minimum))
		testing.expect(t, nav_uses_strip(&frame, width + 1, minimum - 1))
		testing.expect(t, !nav_uses_strip(&frame, width + 1, minimum))
		ui.ui_frame_end(&frame)
		ui.ui_runtime_destroy(&runtime)
	}
}
