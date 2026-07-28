#+build !js
// ingot:gfx - color helper tests. These are pure functions ported to match
// raylib's integer arithmetic exactly, because callers use them to precompute
// colors that must agree with what raylib produced.
package gfx

import "core:testing"

@(test)
color_alpha_replaces_alpha_only :: proc(t: ^testing.T) {
	source := Color{10, 20, 30, 40}
	result := ColorAlpha(source, 0.5)
	testing.expect_value(t, result.r, u8(10))
	testing.expect_value(t, result.g, u8(20))
	testing.expect_value(t, result.b, u8(30))
	testing.expect_value(t, result.a, u8(127))
}

@(test)
color_alpha_clamps_out_of_range :: proc(t: ^testing.T) {
	source := Color{1, 2, 3, 4}
	testing.expect_value(t, ColorAlpha(source, -1).a, u8(0))
	testing.expect_value(t, ColorAlpha(source, 0).a, u8(0))
	testing.expect_value(t, ColorAlpha(source, 1).a, u8(255))
	testing.expect_value(t, ColorAlpha(source, 4).a, u8(255))
}

@(test)
fade_is_color_alpha :: proc(t: ^testing.T) {
	source := Color{200, 100, 50, 255}
	for alpha in ([]f32{0, 0.25, 0.5, 1}) {
		testing.expect_value(t, Fade(source, alpha), ColorAlpha(source, alpha))
	}
}

@(test)
color_alpha_blend_passes_through_the_extremes :: proc(t: ^testing.T) {
	dst := Color{10, 20, 30, 255}
	opaque := Color{200, 100, 50, 255}
	transparent := Color{200, 100, 50, 0}

	// A fully transparent source leaves the destination untouched.
	testing.expect_value(t, ColorAlphaBlend(dst, transparent, WHITE), dst)

	// A fully opaque source replaces it, but the tint step runs first and
	// raylib's tint is (channel * tint) >> 8, which divides by 256 rather than
	// 255. A WHITE tint therefore still costs one unit per channel. That is
	// raylib's behaviour, and matching it byte for byte is the point of this
	// port, so it is asserted rather than corrected.
	testing.expect_value(t, ColorAlphaBlend(dst, opaque, WHITE), Color{199, 99, 49, 255})
}

@(test)
color_alpha_blend_applies_the_tint :: proc(t: ^testing.T) {
	dst := Color{0, 0, 0, 255}
	src := Color{255, 255, 255, 255}
	// The tint modulates the source before compositing, so a half tint
	// halves the result rather than leaving white.
	result := ColorAlphaBlend(dst, src, Color{128, 128, 128, 255})
	testing.expect(t, result.r < 200 && result.r > 100)
	testing.expect_value(t, result.r, result.g)
	testing.expect_value(t, result.g, result.b)
}

@(test)
color_alpha_blend_is_monotonic_in_source_alpha :: proc(t: ^testing.T) {
	// Raising the source alpha must move the result toward the source and
	// never away from it, over the whole 0..255 range.
	dst := Color{0, 0, 0, 255}
	previous: u8 = 0
	for alpha in 0 ..= 255 {
		src := Color{255, 255, 255, u8(alpha)}
		result := ColorAlphaBlend(dst, src, WHITE)
		testing.expectf(
			t,
			result.r >= previous,
			"channel should not decrease as alpha rises: alpha=%v got %v after %v",
			alpha,
			result.r,
			previous,
		)
		previous = result.r
	}
	// The ceiling is 254, not 255, for the same reason: a WHITE tint still
	// runs the >> 8 modulation.
	testing.expect_value(t, previous, u8(254))
}
