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

@(test)
scissor_rect_flips_y_for_render_targets :: proc(t: ^testing.T) {
	// Render targets are drawn through a y-flipped projection, so a band 10
	// screen-space pixels from the top must clip 10 pixels from the *bottom* of
	// the attachment. Without this, a short clip such as a text input's inner
	// scissor lands on the opposite edge and hides its own content.
	x, y, width, height, visible := _scissor_rect(0, 10, 100, 20, 100, 100, 100, 100, true)
	testing.expect(t, visible)
	testing.expect_value(t, x, u32(0))
	testing.expect_value(t, y, u32(70)) // 100 - (10 + 20)
	testing.expect_value(t, width, u32(100))
	testing.expect_value(t, height, u32(20))

	// The unflipped window path is unchanged by the new parameter's default.
	_, wy, _, wh, window_visible := _scissor_rect(0, 10, 100, 20, 100, 100, 100, 100)
	testing.expect(t, window_visible)
	testing.expect_value(t, wy, u32(10))
	testing.expect_value(t, wh, u32(20))
}

@(test)
scissor_rect_flip_is_its_own_inverse :: proc(t: ^testing.T) {
	// Flipping a band and flipping the result back must return the original,
	// which is what guarantees a render-target clip covers exactly the rows an
	// equivalent window clip would.
	height := i32(24)
	attachment := f32(400)
	for top in i32(0) ..= 376 {
		_, flipped, _, flipped_h, ok := _scissor_rect(
			0,
			top,
			10,
			height,
			400,
			attachment,
			400,
			attachment,
			true,
		)
		testing.expect(t, ok)
		testing.expect_value(t, flipped_h, u32(height))
		testing.expect_value(t, flipped, u32(attachment - f32(top) - f32(height)))
	}
}

@(test)
scissor_rect_flip_clamps_at_the_top_edge :: proc(t: ^testing.T) {
	// A band that starts above the attachment must clamp rather than wrap to a
	// huge unsigned offset.
	_, y, _, height, visible := _scissor_rect(0, -50, 100, 20, 100, 100, 100, 100, true)
	testing.expect_value(t, y, u32(100))
	testing.expect_value(t, height, u32(0))
	testing.expect(t, !visible)
}

@(test)
scissor_rect_full_logical_clip_covers_odd_attachment :: proc(t: ^testing.T) {
	x, y, width, height, visible := _scissor_rect(0, 0, 1440, 833, 1440, 833, 2879, 1665)
	testing.expect(t, visible)
	testing.expect_value(t, x, u32(0))
	testing.expect_value(t, y, u32(0))
	testing.expect_value(t, width, u32(2879))
	testing.expect_value(t, height, u32(1665))
}

@(test)
scissor_rect_right_anchored_clip_reaches_fractional_attachment_edge :: proc(t: ^testing.T) {
	x, _, width, _, visible := _scissor_rect(1080, 0, 360, 833, 1440, 833, 2879, 1665)
	testing.expect(t, visible)
	testing.expect_value(t, x + width, u32(2879))
}

@(test)
scissor_rect_adjacent_fractional_clips_leave_no_gap :: proc(t: ^testing.T) {
	left_x, _, left_width, _, left_visible := _scissor_rect(0, 0, 1080, 833, 1440, 833, 2879, 1665)
	right_x, _, right_width, _, right_visible := _scissor_rect(1080, 0, 360, 833, 1440, 833, 2879, 1665)
	testing.expect(t, left_visible && right_visible)
	testing.expect(t, left_x + left_width >= right_x)
	testing.expect_value(t, right_x + right_width, u32(2879))
}

@(test)
scissor_rect_flipped_clip_preserves_attachment_edges :: proc(t: ^testing.T) {
	x, y, width, height, visible := _scissor_rect(1080, 0, 360, 833, 1440, 833, 2879, 1665, true)
	testing.expect(t, visible)
	testing.expect_value(t, x + width, u32(2879))
	testing.expect_value(t, y, u32(0))
	testing.expect_value(t, height, u32(1665))
}
