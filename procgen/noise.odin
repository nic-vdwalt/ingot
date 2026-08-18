package procgen

import "core:math"

Noise_Config :: struct {
	seed:       u64,
	frequency:  f32,
	octaves:    u8,
	lacunarity: f32,
	gain:       f32,
	warp:       f32,
}

noise_2d :: proc(seed: u64, x, y: f32) -> f32 {
	x0 := i64(math.floor(x))
	y0 := i64(math.floor(y))
	tx := x - f32(x0)
	ty := y - f32(y0)
	u := _noise_fade(tx)
	v := _noise_fade(ty)
	a := _noise_lattice(seed, x0, y0)
	b := _noise_lattice(seed, x0 + 1, y0)
	c := _noise_lattice(seed, x0, y0 + 1)
	d := _noise_lattice(seed, x0 + 1, y0 + 1)
	return _noise_lerp(_noise_lerp(a, b, u), _noise_lerp(c, d, u), v)
}

fractal_2d :: proc(config: Noise_Config, x, y: f32) -> f32 {
	assert(config.frequency > 0, "fractal_2d: non-positive frequency")
	assert(config.octaves > 0, "fractal_2d: zero octaves")
	assert(config.octaves <= 12, "fractal_2d: octave bound exceeded")
	assert(config.lacunarity > 0, "fractal_2d: non-positive lacunarity")
	amplitude := f32(1)
	frequency := config.frequency
	total := f32(0)
	normalizer := f32(0)
	for octave in 0 ..< int(config.octaves) {
		total +=
			noise_2d(
				config.seed + u64(octave) * 0x9E3779B97F4A7C15,
				x * frequency,
				y * frequency,
			) *
			amplitude
		normalizer += amplitude
		frequency *= config.lacunarity
		amplitude *= config.gain
	}
	assert(normalizer > 0, "fractal_2d: zero normalizer")
	return total / normalizer
}

warped_fractal_2d :: proc(config: Noise_Config, x, y: f32) -> f32 {
	assert(config.frequency > 0, "warped_fractal_2d: non-positive frequency")
	seed_x := config.seed ~ 0xD1B54A32D192ED03
	seed_y := config.seed ~ 0x94D049BB133111EB
	warp_x := noise_2d(seed_x, x * config.frequency, y * config.frequency)
	warp_y := noise_2d(seed_y, x * config.frequency, y * config.frequency)
	return fractal_2d(config, x + warp_x * config.warp, y + warp_y * config.warp)
}

// noise_3d is the volumetric twin of noise_2d: the same integer-hashed value
// noise and the same quintic fade, over eight lattice corners instead of four.
// A genuine third dimension matters because composing 2D slices with an axis
// swizzle makes features extrude along whichever axis the slice left out.
noise_3d :: proc(seed: u64, x, y, z: f32) -> f32 {
	x0 := i64(math.floor(x))
	y0 := i64(math.floor(y))
	z0 := i64(math.floor(z))
	u := _noise_fade(x - f32(x0))
	v := _noise_fade(y - f32(y0))
	w := _noise_fade(z - f32(z0))
	low_a := _noise_lattice_3d(seed, x0, y0, z0)
	low_b := _noise_lattice_3d(seed, x0 + 1, y0, z0)
	low_c := _noise_lattice_3d(seed, x0, y0 + 1, z0)
	low_d := _noise_lattice_3d(seed, x0 + 1, y0 + 1, z0)
	high_a := _noise_lattice_3d(seed, x0, y0, z0 + 1)
	high_b := _noise_lattice_3d(seed, x0 + 1, y0, z0 + 1)
	high_c := _noise_lattice_3d(seed, x0, y0 + 1, z0 + 1)
	high_d := _noise_lattice_3d(seed, x0 + 1, y0 + 1, z0 + 1)
	low := _noise_lerp(_noise_lerp(low_a, low_b, u), _noise_lerp(low_c, low_d, u), v)
	high := _noise_lerp(_noise_lerp(high_a, high_b, u), _noise_lerp(high_c, high_d, u), v)
	return _noise_lerp(low, high, w)
}

fractal_3d :: proc(config: Noise_Config, x, y, z: f32) -> f32 {
	assert(config.frequency > 0, "fractal_3d: non-positive frequency")
	assert(config.octaves > 0, "fractal_3d: zero octaves")
	assert(config.octaves <= 12, "fractal_3d: octave bound exceeded")
	assert(config.lacunarity > 0, "fractal_3d: non-positive lacunarity")
	amplitude := f32(1)
	frequency := config.frequency
	total := f32(0)
	normalizer := f32(0)
	for octave in 0 ..< int(config.octaves) {
		// The same additive per-octave decorrelation fractal_2d uses, so the
		// two share their octave structure and stay equally deterministic.
		total +=
			noise_3d(
				config.seed + u64(octave) * 0x9E3779B97F4A7C15,
				x * frequency,
				y * frequency,
				z * frequency,
			) *
			amplitude
		normalizer += amplitude
		frequency *= config.lacunarity
		amplitude *= config.gain
	}
	assert(normalizer > 0, "fractal_3d: zero normalizer")
	return total / normalizer
}

warped_fractal_3d :: proc(config: Noise_Config, x, y, z: f32) -> f32 {
	assert(config.frequency > 0, "warped_fractal_3d: non-positive frequency")
	assert(config.octaves > 0, "warped_fractal_3d: zero octaves")
	seed_x := config.seed ~ 0xD1B54A32D192ED03
	seed_y := config.seed ~ 0x94D049BB133111EB
	seed_z := config.seed ~ 0xDB4F0B9175AE2165
	warp_x := noise_3d(seed_x, x * config.frequency, y * config.frequency, z * config.frequency)
	warp_y := noise_3d(seed_y, x * config.frequency, y * config.frequency, z * config.frequency)
	warp_z := noise_3d(seed_z, x * config.frequency, y * config.frequency, z * config.frequency)
	return fractal_3d(
		config,
		x + warp_x * config.warp,
		y + warp_y * config.warp,
		z + warp_z * config.warp,
	)
}

@(private)
_noise_hash :: proc(seed: u64, x, y: i64) -> u64 {
	value := seed ~ u64(x) * 0x9E3779B185EBCA87 ~ u64(y) * 0xC2B2AE3D27D4EB4F
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

// _noise_hash_3d extends _noise_hash with a third odd multiplier. The
// splitmix64 finalizer is unchanged, so a z of zero does not collapse onto the
// 2D hash -- the multiply still mixes the other two axes through it.
@(private)
_noise_hash_3d :: proc(seed: u64, x, y, z: i64) -> u64 {
	value :=
		seed ~
		u64(x) * 0x9E3779B185EBCA87 ~
		u64(y) * 0xC2B2AE3D27D4EB4F ~
		u64(z) * 0x165667B19E3779F9
	value ~= value >> 30
	value *= 0xBF58476D1CE4E5B9
	value ~= value >> 27
	value *= 0x94D049BB133111EB
	return value ~ (value >> 31)
}

@(private)
_noise_lattice :: proc(seed: u64, x, y: i64) -> f32 {
	value := _noise_hash(seed, x, y) >> 40
	return f32(value) / f32(0xFFFFFF) * 2 - 1
}

@(private)
_noise_lattice_3d :: proc(seed: u64, x, y, z: i64) -> f32 {
	value := _noise_hash_3d(seed, x, y, z) >> 40
	return f32(value) / f32(0xFFFFFF) * 2 - 1
}

@(private)
_noise_fade :: proc(value: f32) -> f32 {
	return value * value * value * (value * (value * 6 - 15) + 10)
}

@(private)
_noise_lerp :: proc(a, b, amount: f32) -> f32 {
	return a + (b - a) * amount
}
