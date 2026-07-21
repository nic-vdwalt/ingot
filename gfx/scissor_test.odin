#+build !js
package gfx

import "core:testing"

@(test)
scissor_rect_rejects_empty_dimensions :: proc(t: ^testing.T) {
	_, _, width, height, visible := _scissor_rect(10, 10, 0, 20, 100, 100, 200, 200)
	testing.expect(t, !visible)
	testing.expect_value(t, width, u32(0))
	testing.expect_value(t, height, u32(0))
}

@(test)
scissor_rect_rejects_fully_clipped_rect :: proc(t: ^testing.T) {
	x, y, width, height, visible := _scissor_rect(100, 100, 20, 20, 100, 100, 200, 200)
	testing.expect(t, !visible)
	testing.expect_value(t, x, u32(200))
	testing.expect_value(t, y, u32(200))
	testing.expect_value(t, width + height, u32(0))
}

@(test)
scissor_rect_scales_and_clips_visible_rect :: proc(t: ^testing.T) {
	x, y, width, height, visible := _scissor_rect(25, 10, 100, 100, 100, 100, 200, 200)
	testing.expect(t, visible)
	testing.expect_value(t, x, u32(50))
	testing.expect_value(t, y, u32(20))
	testing.expect_value(t, width, u32(150))
	testing.expect_value(t, height, u32(180))
}
