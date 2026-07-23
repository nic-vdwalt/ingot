package term

import "core:testing"
import "core:unicode/utf8"
import "ingot:testx"

@(test)
utf8_holdback_examples :: proc(t: ^testing.T) {
	// "é" = C3 A9. A buffer ending after C3 must hold back that lead byte.
	buf := []u8{'a', 0xC3}
	testing.expect_value(t, _utf8_complete_prefix(buf), 1)
	// Complete sequence: nothing held back.
	full := []u8{'a', 0xC3, 0xA9}
	testing.expect_value(t, _utf8_complete_prefix(full), 3)
	// Pure ASCII: full length.
	ascii := []u8{'h', 'i'}
	testing.expect_value(t, _utf8_complete_prefix(ascii), 2)
	// Split 3-byte lead (0xE2 starts a 3-byte sequence): held at the lead.
	three := []u8{'x', 0xE2, 0x82}
	testing.expect_value(t, _utf8_complete_prefix(three), 1)
	// Split 4-byte lead (0xF0): held at the lead.
	four := []u8{0xF0, 0x9F}
	testing.expect_value(t, _utf8_complete_prefix(four), 0)
}

// Property: cutting a valid UTF-8 stream at a random byte boundary and applying
// _utf8_complete_prefix never splits a multi-byte rune — the completed prefix
// always ends on a rune boundary, and the held-back tail is < 4 bytes.
@(test)
utf8_holdback_fuzz :: proc(t: ^testing.T) {
	p := testx.prng_make(0xF00D)
	for _ in 0 ..< 4000 {
		// Build a valid UTF-8 string from random runes (incl. multibyte).
		b := make([dynamic]u8, context.temp_allocator)
		nrunes := testx.int_range(&p, 0, 12)
		for _ in 0 ..< nrunes {
			r := rune(testx.int_range(&p, 0x20, 0x2FFF))
			enc, n := utf8.encode_rune(r)
			for i in 0 ..< n do append(&b, enc[i])
		}
		buf := b[:]
		if len(buf) == 0 do continue
		cut := testx.int_range(&p, 0, len(buf) + 1)
		prefix := _utf8_complete_prefix(buf[:cut])
		testing.expect(t, prefix <= cut, "prefix cannot exceed buffer")
		testing.expect(t, cut-prefix < 4, "held-back tail must be < 4 bytes")
		// The completed prefix ends on a rune boundary of the original stream.
		if prefix < len(buf) {
			testing.expect(
				t,
				(buf[prefix] & 0xC0) != 0x80,
				"completed prefix must end on a rune boundary",
			)
		}
		free_all(context.temp_allocator)
	}
}

// Property: for FULLY ARBITRARY bytes — including malformed UTF-8 (stray
// continuation bytes, overlong leads, 0xFE/0xFF) — the completed prefix stays
// within [0, len] and at most 3 bytes are ever held back. This is the
// hostile-input counterpart of utf8_holdback_fuzz, which only feeds valid
// streams.
@(test)
utf8_holdback_arbitrary_bytes :: proc(t: ^testing.T) {
	p := testx.prng_make(0xBAD5EED)
	for _ in 0 ..< 50_000 {
		buf := testx.random_bytes(&p, 64)
		prefix := _utf8_complete_prefix(buf)
		testing.expect(t, prefix >= 0, "prefix must be non-negative")
		testing.expect(t, prefix <= len(buf), "prefix cannot exceed buffer")
		testing.expect(t, len(buf)-prefix < 4, "held-back tail must be < 4 bytes")
		free_all(context.temp_allocator)
	}
}
