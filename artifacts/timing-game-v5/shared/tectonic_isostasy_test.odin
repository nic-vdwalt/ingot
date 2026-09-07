package shared

import "core:testing"

@(test)
tectonic_isostasy_tracks_age_thickness_and_loading :: proc(t: ^testing.T) {
	testing.expect(t, tectonic_ocean_cooling_depth(1_000_000) < tectonic_ocean_cooling_depth(100_000_000))
	thin := tectonic_isostatic_height(1, 30_000, 1_000_000_000, 0)
	thick := tectonic_isostatic_height(1, 50_000, 1_000_000_000, 0)
	testing.expect(t, thick > thin)
	testing.expect(t, tectonic_isostatic_height(1, 50_000, 1_000_000_000, 1_000) < thick)
	testing.expect_value(t, tectonic_units_to_height_fixed(250), i32(HEIGHT_DELTA_SCALE))
}
