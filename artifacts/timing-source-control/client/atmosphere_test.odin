#+build !js
package main

import "core:math"
import "core:testing"

@(test)
atmosphere_fog_is_monotonic_and_denser_below :: proc(t: ^testing.T) {
	value := atmosphere_preset(.Dark_Overcast, .High)
	near := atmosphere_fog_transmittance(&value, 10, 0)
	far := atmosphere_fog_transmittance(&value, 200, 0)
	high := atmosphere_fog_transmittance(&value, 200, 80)
	testing.expect(t, near > far)
	testing.expect(t, high > far)
	testing.expect(t, near >= 0 && near <= 1)
	testing.expect(t, far >= 0 && far <= 1)
}

@(test)
atmosphere_sky_is_finite_and_horizon_is_brighter :: proc(t: ^testing.T) {
	value := atmosphere_preset(.Dark_Overcast, .High)
	horizon := atmosphere_sky_color(&value, {1, 0, 0.01})
	zenith := atmosphere_sky_color(&value, {0, 0, 1})
	horizon_luma := horizon.x + horizon.y + horizon.z
	zenith_luma := zenith.x + zenith.y + zenith.z
	testing.expect(t, horizon_luma > zenith_luma)
	for component in horizon {
		testing.expect(t, !math.is_nan(component))
		testing.expect(t, component >= 0)
	}
	for component in zenith {
		testing.expect(t, !math.is_nan(component))
		testing.expect(t, component >= 0)
	}
}

@(test)
atmosphere_quality_bounds_expensive_resources :: proc(t: ^testing.T) {
	testing.expect_value(t, atmosphere_post_scale(.Low), f32(0))
	testing.expect_value(t, atmosphere_post_scale(.High), f32(0.5))
	testing.expect_value(t, atmosphere_shadow_size(.Low), i32(0))
	testing.expect_value(t, atmosphere_shadow_size(.High), i32(0))
	testing.expect_value(t, atmosphere_shadow_size(.Ultra), i32(2048))
}

@(test)
atmosphere_presets_are_deterministic_and_distinct :: proc(t: ^testing.T) {
	first := atmosphere_preset(.Dark_Overcast, .High)
	second := atmosphere_preset(.Dark_Overcast, .High)
	clear := atmosphere_preset(.Clear_Dusk, .High)
	heavy := atmosphere_preset(.Heavy_Fog, .High)
	testing.expect_value(t, first, second)
	testing.expect_value(t, clear.ambient_intensity, f32(0.34))
	testing.expect_value(t, first.ambient_intensity, f32(0.42))
	testing.expect_value(t, heavy.ambient_intensity, f32(0.34))
	testing.expect_value(t, clear.sun_intensity, f32(0.92))
	testing.expect_value(t, first.sun_intensity, f32(0.62))
	testing.expect_value(t, heavy.sun_intensity, f32(0.38))
	testing.expect(t, heavy.fog_density > first.fog_density)
	testing.expect(t, heavy.exposure < first.exposure)
}

@(test)
atmosphere_light_separates_ambient_and_direct_sun :: proc(t: ^testing.T) {
	clear := atmosphere_preset(.Clear_Dusk, .High)
	overcast := atmosphere_preset(.Dark_Overcast, .High)
	heavy := atmosphere_preset(.Heavy_Fog, .High)
	clear_light := atmosphere_light(&clear)
	overcast_light := atmosphere_light(&overcast)
	heavy_light := atmosphere_light(&heavy)
	testing.expect_value(t, clear_light.ambient, clear.ambient_intensity)
	testing.expect_value(t, overcast_light.ambient, overcast.ambient_intensity)
	testing.expect_value(t, heavy_light.ambient, heavy.ambient_intensity)
	testing.expect_value(t, clear_light.diffuse, clear.sun_intensity)
	testing.expect_value(t, overcast_light.diffuse, overcast.sun_intensity)
	testing.expect_value(t, heavy_light.diffuse, heavy.sun_intensity)
	testing.expect(t, overcast_light.ambient > clear_light.ambient)
	testing.expect(t, clear_light.diffuse > overcast_light.diffuse)
	testing.expect(t, overcast_light.diffuse > heavy_light.diffuse)
}

@(test)
atmosphere_fog_extinction_is_independent_of_fog_color :: proc(t: ^testing.T) {
	value := atmosphere_preset(.Dark_Overcast, .High)
	first := atmosphere_fog_transmittance(&value, 100, 0)
	value.fog_color = {1, 0, 1}
	second := atmosphere_fog_transmittance(&value, 100, 0)
	testing.expect_value(t, first, second)
}

@(test)
atmosphere_exposure_is_monotonic_and_bounded :: proc(t: ^testing.T) {
	black := atmosphere_expose({0, 0, 0}, 1)
	mid := atmosphere_expose({1, 1, 1}, 1)
	brighter := atmosphere_expose({1, 1, 1}, 2)
	testing.expect_value(t, black, [3]f32{0, 0, 0})
	testing.expect_value(t, mid, [3]f32{0.5, 0.5, 0.5})
	for index in 0 ..< 3 {
		testing.expect(t, brighter[index] > mid[index])
		testing.expect(t, brighter[index] < 1)
		testing.expect(t, !math.is_nan(brighter[index]))
	}
}

@(test)
atmosphere_sky_material_bounds_weather_inputs :: proc(t: ^testing.T) {
	value := atmosphere_preset(.Dark_Overcast, .High)
	value.cloud_coverage = 2
	value.cloud_speed = -1
	value.cloud_wind = {500, -500}
	value.storm_intensity = 3
	material := atmosphere_sky_material(&value)
	testing.expect_value(t, material.custom_params.x, f32(1))
	testing.expect_value(t, material.custom_params.y, f32(0))
	testing.expect_value(t, material.custom_params_3, [4]f32{200, -200, 1, 0})
}

@(test)
atmosphere_effect_readiness_is_independent :: proc(t: ^testing.T) {
	value := atmosphere_preset(.Dark_Overcast, .High)
	value.sky_ready = true
	testing.expect(t, value.sky_ready)
	testing.expect(t, !value.object_ready)
	testing.expect(t, !value.post_ready)
	value.object_ready = true
	testing.expect(t, value.object_ready)
	testing.expect(t, !value.post_ready)
}
