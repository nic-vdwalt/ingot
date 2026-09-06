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

@(test)
noise_3d_is_deterministic_and_bounded :: proc(t: ^testing.T) {
	for z in -8 ..= 8 {
		for y in -8 ..= 8 {
			for x in -8 ..= 8 {
				point := [3]f32{f32(x) * 0.125, f32(y) * 0.125, f32(z) * 0.125}
				a := noise_3d(1234, point.x, point.y, point.z)
				b := noise_3d(1234, point.x, point.y, point.z)
				testing.expect_value(t, a, b)
				testing.expect(t, a >= -1 && a <= 1)
			}
		}
	}
}

// At integer coordinates the fade is zero on every axis, so the result must be
// exactly the corner's lattice value rather than a blend of eight.
@(test)
noise_3d_reproduces_lattice_values_at_integers :: proc(t: ^testing.T) {
	for z in -3 ..= 3 {
		for y in -3 ..= 3 {
			for x in -3 ..= 3 {
				expected := _noise_lattice_3d(99, i64(x), i64(y), i64(z))
				testing.expect_value(t, noise_3d(99, f32(x), f32(y), f32(z)), expected)
			}
		}
	}
}

// The whole point of a 3D field is that it is not a 2D field wearing a
// disguise: moving along any one axis alone must change the value, and the
// three axes must not be interchangeable.
@(test)
noise_3d_varies_independently_on_every_axis :: proc(t: ^testing.T) {
	base := noise_3d(7, 0.5, 0.5, 0.5)
	testing.expect(t, noise_3d(7, 1.5, 0.5, 0.5) != base)
	testing.expect(t, noise_3d(7, 0.5, 1.5, 0.5) != base)
	testing.expect(t, noise_3d(7, 0.5, 0.5, 1.5) != base)
	// A swizzle-built field would be symmetric under an axis swap here.
	testing.expect(t, noise_3d(7, 1.25, 2.5, 3.75) != noise_3d(7, 3.75, 1.25, 2.5))
	testing.expect(t, noise_3d(7, 1.25, 2.5, 3.75) != noise_3d(7, 1.25, 3.75, 2.5))
}

// Continuity across a cell boundary is what keeps a cave wall from showing a
// crease at every integer plane.
@(test)
noise_3d_is_continuous_across_cell_boundaries :: proc(t: ^testing.T) {
	step := f32(0.0009765625)
	for axis in 0 ..< 3 {
		before, after := [3]f32{2, 2, 2}, [3]f32{2, 2, 2}
		before[axis] = 3 - step
		after[axis] = 3 + step
		low := noise_3d(21, before.x, before.y, before.z)
		high := noise_3d(21, after.x, after.y, after.z)
		testing.expectf(t, abs(high - low) < 0.02, "axis %d jumps by %v", axis, abs(high - low))
	}
}

@(test)
fractal_3d_changes_with_seed_and_stays_bounded :: proc(t: ^testing.T) {
	config := Noise_Config {
		seed       = 1,
		frequency  = 0.01,
		octaves    = 4,
		lacunarity = 2,
		gain       = 0.5,
	}
	a := fractal_3d(config, 11, 17, 23)
	config.seed = 2
	b := fractal_3d(config, 11, 17, 23)
	testing.expect(t, a != b)
	for z in -4 ..= 4 {
		for y in -4 ..= 4 {
			for x in -4 ..= 4 {
				value := fractal_3d(config, f32(x * 37), f32(y * 41), f32(z * 43))
				testing.expect(t, value >= -1 && value <= 1)
			}
		}
	}
}
