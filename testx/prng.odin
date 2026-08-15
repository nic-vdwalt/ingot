package testx

// Deterministic xorshift64* PRNG. Seeds are explicit so any fuzz failure is
// reproducible by re-running with the same seed (TigerBeetle style).
Prng :: struct {
	state: u64,
}

prng_make :: proc(seed: u64) -> Prng {
	return Prng{state = seed == 0 ? 0x9E3779B97F4A7C15 : seed}
}

next_u64 :: proc(p: ^Prng) -> u64 {
	assert(p != nil, "next_u64: nil p")
	x := p.state
	x ~= x >> 12
	x ~= x << 25
	x ~= x >> 27
	p.state = x
	return x * 0x2545F4914F6CDD1D
}

// int_range returns a value in [lo, hi).
int_range :: proc(p: ^Prng, lo, hi: int) -> int {
	assert(p != nil, "int_range: nil p")
	assert(hi >= lo, "int_range: reversed range")
	if hi == lo do return lo
	return lo + int(next_u64(p) % u64(hi - lo))
}

// ascii_string fills a builder-owned string of printable ASCII (plus spaces and
// occasional newlines) of length in [0, max_len). Allocated with the given
// allocator (default: temp).
ascii_string :: proc(p: ^Prng, max_len: int, allocator := context.temp_allocator) -> string {
	assert(p != nil, "ascii_string: nil p")
	assert(max_len >= 0, "ascii_string: negative max_len")
	if max_len == 0 do return ""
	n := int_range(p, 0, max_len)
	b := make([]u8, n, allocator)
	for i in 0 ..< n {
		r := int_range(p, 0, 100)
		switch {
		case r < 12:
			b[i] = ' '
		case r < 15:
			b[i] = '\n'
		case:
			b[i] = u8(int_range(p, 33, 127))
		}
	}
	return string(b)
}

// random_bytes fills arbitrary bytes, including invalid UTF-8 sequences -
// intended for fuzzing parsers that consume untrusted input. Length is in
// [0, max_len). Allocated with the given allocator (default: temp).
random_bytes :: proc(p: ^Prng, max_len: int, allocator := context.temp_allocator) -> []u8 {
	assert(p != nil, "random_bytes: nil p")
	assert(max_len >= 0, "random_bytes: negative max_len")
	if max_len == 0 do return nil
	n := int_range(p, 0, max_len)
	b := make([]u8, n, allocator)
	for i in 0 ..< n do b[i] = u8(next_u64(p) & 0xFF)
	return b
}
