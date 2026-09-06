package shared

import "core:math"

tectonic_ocean_cooling_depth :: proc(age_years: f64) -> f64 {
	return 2_500 + 3_200 * (1 - math.exp(-math.sqrt(max(age_years, f64(0)) / 100_000_000)))
}

tectonic_isostatic_height :: proc(continental_fraction, thickness_m, age_years, sediment_m: f64) -> f64 {
	continental := 700 + (thickness_m - 38_000) * (1 - 2_800.0 / 3_300)
	oceanic := -tectonic_ocean_cooling_depth(age_years) + (thickness_m - 7_000) * (1 - 2_900.0 / 3_300)
	return continental * continental_fraction + oceanic * (1 - continental_fraction) - sediment_m * 2_400 / 3_300
}

tectonic_units_to_height_fixed :: proc(metres: f64) -> i32 {
	return i32(clamp(math.round(metres * f64(HEIGHT_DELTA_SCALE) / 250), f64(-30_000), f64(30_000)))
}
