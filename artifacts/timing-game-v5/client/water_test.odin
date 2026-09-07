#+build !js
package main

import "core:math"
import "core:testing"

@(test)
water_render_sample_preserves_continuous_shallow_depth :: proc(t: ^testing.T) {
	ground := f32(7)
	dry_surface, dry_shallow, dry_coverage := water_render_sample(ground, 0)
	shallow_surface, shallow_shallow, shallow_coverage := water_render_sample(ground, 0.125)
	wet_surface, wet_shallow, wet_coverage := water_render_sample(ground, 0.25)
	deep_surface, deep_shallow, deep_coverage := water_render_sample(ground, WATER_DEPTH_MAX)
	testing.expect_value(t, dry_surface, ground - WATER_SURFACE_DROP)
	testing.expect_value(t, dry_shallow, f32(1))
	testing.expect_value(t, dry_coverage, f32(0))
	testing.expect_value(t, shallow_surface, ground + 0.125 - WATER_SURFACE_DROP)
	testing.expect(t, shallow_shallow < dry_shallow)
	testing.expect_value(t, shallow_coverage, f32(0.5))
	testing.expect(t, wet_shallow < shallow_shallow)
	testing.expect_value(t, wet_coverage, f32(1))
	testing.expect(t, wet_surface > shallow_surface)
	testing.expect(t, deep_surface > wet_surface)
	testing.expect_value(t, deep_shallow, f32(0))
	testing.expect_value(t, deep_coverage, f32(1))
}

@(test)
water_render_sample_clamps_invalid_negative_depth :: proc(t: ^testing.T) {
	ground := f32(-3)
	surface, shallow, coverage := water_render_sample(ground, -2)
	testing.expect_value(t, surface, ground - WATER_SURFACE_DROP)
	testing.expect_value(t, shallow, f32(1))
	testing.expect_value(t, coverage, f32(0))
	testing.expect(t, !math.is_nan(surface))
	testing.expect(t, !math.is_nan(shallow))
	testing.expect(t, !math.is_nan(coverage))
}
