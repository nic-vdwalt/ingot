package main

import "core:testing"

@(test)
planet_stream_draw_threshold_is_explicit :: proc(t: ^testing.T) {
	testing.expect(t, planet_stream_visible(PLANET_SURFACE_ZOOM))
	testing.expect(t, !planet_stream_visible(PLANET_SURFACE_ZOOM * 1.5))
	testing.expect(t, PLANET_STREAM_DRAW_BLEND_LIMIT > 0)
	testing.expect(t, PLANET_STREAM_DRAW_BLEND_LIMIT < 1)
}
