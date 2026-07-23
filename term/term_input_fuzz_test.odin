#+build !js
package term

import "core:testing"
import rl "ingot:gfx"
import "ingot:testx"

// Fuzz vt_bytes_for_key with arbitrary key codes across the FULL i32 range
// (raylib can surface values outside the KeyboardKey enum for unknown
// hardware keys) and every modifier combination. The mapper must never write
// past the buffer and must always report a byte count within the buffer it
// was given. Seeds are fixed so failures reproduce deterministically.
@(test)
fuzz_vt_bytes_for_key :: proc(t: ^testing.T) {
	p := testx.prng_make(0x7E12)
	skip := []rl.KeyboardKey{.C, .V, .T}
	boundary := [?]i32{min(i32), -1, 0, 1, 511, 512, max(i32) - 1, max(i32)}
	buf: [16]u8
	for _ in 0 ..< 100_000 {
		key_value: i32
		switch testx.int_range(&p, 0, 4) {
		case 0:
			// boundary values on sign/enum edges
			key_value = boundary[testx.int_range(&p, 0, len(boundary))]
		case 1:
			// fully random i32 (both signs)
			key_value = i32(testx.next_u64(&p))
		case:
			// near the real enum range, where most mappings live
			key_value = i32(testx.int_range(&p, 0, 512))
		}
		key := rl.KeyboardKey(key_value)
		ctrl := testx.int_range(&p, 0, 2) == 1
		shift := testx.int_range(&p, 0, 2) == 1
		super := testx.int_range(&p, 0, 2) == 1
		// Canary bytes beyond the longest VT sequence detect silent overruns.
		for i in 0 ..< len(buf) do buf[i] = 0xAA
		n, ok := vt_bytes_for_key(key, ctrl, shift, super, skip, buf[:8])
		testing.expect(t, n >= 0)
		testing.expect(t, n <= 8)
		if !ok do testing.expect_value(t, n, 0)
		for i in 8 ..< len(buf) do testing.expect_value(t, buf[i], u8(0xAA))
	}
}

// Host-app Ctrl+Shift chords listed in skip_ctrl_shift must never be
// forwarded to the terminal — the negative space of the key mapping.
@(test)
fuzz_vt_bytes_skip_list_respected :: proc(t: ^testing.T) {
	skip := []rl.KeyboardKey{.C, .V, .T}
	buf: [8]u8
	for key in skip {
		n, ok := vt_bytes_for_key(key, true, true, false, skip, buf[:])
		testing.expect(t, !ok)
		testing.expect_value(t, n, 0)
	}
}
