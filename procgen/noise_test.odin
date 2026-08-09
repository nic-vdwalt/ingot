#+build !js
package procgen

import "core:testing"

@(test)
noise_is_deterministic_and_bounded :: proc(t: ^testing.T) {
	for y in -16 ..= 16 {
		for x in -16 ..= 16 {
			a := noise_2d(1234, f32(x) * 0.125, f32(y) * 0.125)
			b := noise_2d(1234, f32(x) * 0.125, f32(y) * 0.125)
			testing.expect_value(t, a, b)
			testing.expect(t, a >= -1 && a <= 1)
		}
	}
}

@(test)
fractal_changes_with_seed :: proc(t: ^testing.T) {
	config := Noise_Config {
		seed       = 1,
		frequency  = 0.01,
		octaves    = 4,
		lacunarity = 2,
		gain       = 0.5,
	}
	a := fractal_2d(config, 11, 17)
	config.seed = 2
	b := fractal_2d(config, 11, 17)
	testing.expect(t, a != b)
}
