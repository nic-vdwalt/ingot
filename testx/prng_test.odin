package testx

import "core:testing"

@(test)
prng_known_sequence :: proc(t: ^testing.T) {
	p := prng_make(1)
	expected := [?]u64 {
		0x47E4CE4B896CDD1D,
		0xABCFA6A8E079651D,
		0xB9D10D8FEB731F57,
		0x4DB418A0BB1B019D,
		0x0E6199B04D5AA600,
	}
	for value in expected do testing.expect_value(t, next_u64(&p), value)
}

@(test)
prng_zero_seed_uses_documented_state :: proc(t: ^testing.T) {
	zero := prng_make(0)
	explicit := prng_make(0x9E3779B97F4A7C15)
	for _ in 0 ..< 32 do testing.expect_value(t, next_u64(&zero), next_u64(&explicit))
}

@(test)
prng_ranges_and_bytes_are_deterministic :: proc(t: ^testing.T) {
	a := prng_make(0xCAFE)
	b := prng_make(0xCAFE)
	testing.expect_value(t, int_range(&a, 7, 7), 7)
	testing.expect_value(t, int_range(&b, 7, 7), 7)
	for _ in 0 ..< 128 {
		left := int_range(&a, -17, 29)
		right := int_range(&b, -17, 29)
		testing.expect(t, left >= -17 && left < 29)
		testing.expect_value(t, left, right)
	}
	left := random_bytes(&a, 64)
	right := random_bytes(&b, 64)
	testing.expect_value(t, len(left), len(right))
	for index in 0 ..< len(left) do testing.expect_value(t, left[index], right[index])
	testing.expect_value(t, ascii_string(&a, 64), ascii_string(&b, 64))
	testing.expect_value(t, len(random_bytes(&a, 0)), 0)
	testing.expect_value(t, ascii_string(&a, 0), "")
}
