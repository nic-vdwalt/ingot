#+build !js
package main

import "core:testing"

@(test)
camera_visual_weights_are_continuous_and_normalized :: proc(t: ^testing.T) {
	for distance := f32(0); distance <= 600; distance += 5 {
		close, regional, overview := camera_visual_weights(distance, 80, 160, 320, 480)
		testing.expect(t, close >= 0 && close <= 1)
		testing.expect(t, regional >= 0 && regional <= 1)
		testing.expect(t, overview >= 0 && overview <= 1)
		testing.expect(t, abs(close + regional + overview - 1) < 0.0001)
	}
}

@(test)
camera_visual_weights_are_monotonic :: proc(t: ^testing.T) {
	near_close, _, near_overview := camera_visual_weights(40, 80, 160, 320, 480)
	mid_close, _, mid_overview := camera_visual_weights(240, 80, 160, 320, 480)
	far_close, _, far_overview := camera_visual_weights(560, 80, 160, 320, 480)
	testing.expect(t, near_close > mid_close && mid_close >= far_close)
	testing.expect(t, near_overview <= mid_overview && mid_overview < far_overview)
}

@(test)
camera_visual_projection_scale_responds_to_fov :: proc(t: ^testing.T) {
	narrow := camera_visual_context_make({}, {}, 60, 20, 30, 720, 0.2, 80, 160, 320, 480)
	wide := camera_visual_context_make({}, {}, 60, 20, 70, 720, 0.2, 80, 160, 320, 480)
	testing.expect(t, narrow.projection_scale > wide.projection_scale)
	testing.expect_value(t, narrow.surface_altitude, f32(20))
	testing.expect_value(t, narrow.coverage, f32(0.2))
}
