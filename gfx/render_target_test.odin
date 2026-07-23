#+build !js
// Render-target orientation lock-in: the y-flip convention is a compatibility
// contract (openalloy's nvim render texture and any migrated bloom chain
// sample against it — docs/rendering.md "Render-target orientation" and
// "Consumer migration guide"). These tests fence the pure projection math;
// the visual fence is examples/render_fixture's two-pass ping-pong chain
// blitted with a negative source height.
package gfx

import "core:testing"

@(test)
test_rt_projection_y_flip_convention :: proc(t: ^testing.T) {
	// The named constant is the contract: RT projections flip y so stored
	// textures match raylib's bottom-left origin. Consumers blit upright
	// with a negative source height; changing this breaks every consumer.
	testing.expect_value(t, RT_PROJECTION_Y_FLIP, f32(-1.0))

	p := _rt_projection_vec(256, 160)
	testing.expect_value(t, p.x, f32(1.0) / 256.0)
	testing.expect_value(t, p.y, f32(1.0) / 160.0)
	testing.expect_value(t, p.z, RT_PROJECTION_Y_FLIP)
	testing.expect_value(t, p.w, f32(0))
}

@(test)
test_rt_projection_degenerate_extent :: proc(t: ^testing.T) {
	// Zero/negative extents clamp to 1 (never divide by zero); orientation
	// stays flipped regardless of target size — pass count and target
	// dimensions must not affect the convention.
	p := _rt_projection_vec(0, -5)
	testing.expect_value(t, p.x, f32(1))
	testing.expect_value(t, p.y, f32(1))
	testing.expect_value(t, p.z, RT_PROJECTION_Y_FLIP)
}
