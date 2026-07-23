#+build !js
package ui

import "core:testing"
import "core:unicode/utf8"
import "ingot:testx"

FUZZ_ITERS :: #config(FUZZ_ITERS, 5000)
FUZZ_SEED :: #config(FUZZ_SEED, 0x1234_5678)

@(private = "file")
CELL :: i32(10)

@(private = "file")
mono :: proc(text: cstring, size: i32) -> i32 {
	return i32(utf8.rune_count(string(text))) * CELL
}

@(test)
wrap_examples :: proc(t: ^testing.T) {
	set_measure_backend(mono)
	defer set_measure_backend(nil)
	// "aaa bbb" at width 5*CELL wraps after "aaa".
	src := "aaa bbb"
	lines := wrap_compute(src, 5 * CELL, 16)
	testing.expect_value(t, len(lines), 2)
	testing.expect_value(t, src[lines[0].start:lines[0].end], "aaa")
	testing.expect_value(t, src[lines[1].start:lines[1].end], "bbb")
	// Explicit newline always breaks.
	nl := wrap_compute("a\nb", 100 * CELL, 16)
	testing.expect_value(t, len(nl), 2)
	// Empty string yields one empty line.
	empty := wrap_compute("", 50, 16)
	testing.expect_value(t, len(empty), 1)
}

// Invariant fuzz: wrapped line byte ranges are ordered and in bounds, and
// coverage advances monotonically through the input.
@(test)
wrap_invariants_fuzz :: proc(t: ^testing.T) {
	set_measure_backend(mono)
	defer set_measure_backend(nil)
	p := testx.prng_make(FUZZ_SEED)
	for iter in 0 ..< FUZZ_ITERS {
		s := testx.ascii_string(&p, 64)
		w := i32(testx.int_range(&p, 1, 12)) * CELL
		lines := wrap_compute(s, w, 16)
		prev := 0
		for ln, i in lines {
			ok := ln.start <= ln.end && ln.end <= len(s) && ln.start >= prev
			if !ok {
				testing.expectf(
					t,
					false,
					"seed=%d iter=%d line=%d bad range %v in %q",
					FUZZ_SEED,
					iter,
					i,
					ln,
					s,
				)
				break
			}
			prev = ln.end
		}
		free_all(context.temp_allocator)
	}
}
