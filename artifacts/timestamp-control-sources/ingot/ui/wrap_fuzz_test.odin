#+build !js
package ui

// Fuzz the UTF-8-sensitive text paths with arbitrary bytes (including
// malformed UTF-8): wrap_compute's manual rune-boundary scanning, the caret
// navigation helpers, and the markdown inline/table parsers. The heavier
// ASan harness lives in fuzz/ui; these seeded tests run in CI via
// scripts/test.sh so regressions surface on every push.

import "core:testing"
import "core:unicode/utf8"
import "ingot:testx"

@(private = "file")
FUZZ_CELL :: i32(10)

@(private = "file")
fuzz_mono :: proc(text: cstring, size: i32) -> i32 {
	return i32(utf8.rune_count(string(text))) * FUZZ_CELL
}

// wrap_compute must never panic on malformed UTF-8, and every produced line
// range must be ordered, in bounds, and monotonically advancing.
@(test)
fuzz_wrap_malformed_utf8 :: proc(t: ^testing.T) {
	system: Text_System
	set_measure_backend_with(&system, fuzz_mono)
	defer text_system_destroy(&system)
	p := testx.prng_make(0x3)
	for iter in 0 ..< 10_000 {
		text := string(testx.random_bytes(&p, 512))
		width := i32(testx.int_range(&p, 1, 12)) * FUZZ_CELL
		lines := wrap_compute_with(&system, text, width, 16)
		prev := 0
		for ln, i in lines {
			ok := ln.start <= ln.end && ln.end <= len(text) && ln.start >= prev
			testing.expectf(
				t,
				ok,
				"seed=0x3 iter=%d line=%d bad range %v for %d bytes",
				iter,
				i,
				ln,
				len(text),
			)
			if !ok do return
			prev = ln.start
		}
		free_all(context.temp_allocator)
	}
}

// Caret helpers must accept ANY position (negative, past-end, mid-rune of
// malformed sequences) and return values in [0, len(text)] without panicking.
@(test)
fuzz_caret_helpers_arbitrary_offsets :: proc(t: ^testing.T) {
	p := testx.prng_make(0x4)
	for iter in 0 ..< 10_000 {
		text := string(testx.random_bytes(&p, 256))
		pos := testx.int_range(&p, -4, len(text) + 5)
		in_range :: proc(v, hi: int) -> bool {return v >= 0 && v <= hi}
		clamped := caret_clamp(text, pos)
		ok := in_range(clamped, len(text))
		ok &&= caret_clamp(text, clamped) == clamped
		ok &&= in_range(caret_prev_rune(text, clamped), len(text))
		ok &&= in_range(caret_next_rune(text, clamped), len(text))
		ok &&= in_range(caret_word_left(text, clamped), len(text))
		ok &&= in_range(caret_word_right(text, clamped), len(text))
		ok &&= in_range(caret_line_start(text, clamped), len(text))
		ok &&= in_range(caret_line_end(text, clamped), len(text))
		row, col := caret_row_col(text, clamped)
		ok &&= row >= 0 && col >= 0
		ok &&= in_range(caret_from_row_col(text, row, col), len(text))
		testing.expectf(
			t,
			ok,
			"seed=0x4 iter=%d pos=%d caret invariant broken for %d bytes",
			iter,
			pos,
			len(text),
		)
		if !ok do return
		free_all(context.temp_allocator)
	}
}

// Markdown parsers: spans, offset maps, and table splitting stay in bounds
// for random bytes (compact CI mirror of the fuzz/ui ASan harness).
@(test)
fuzz_markdown_parsers_random_bytes :: proc(t: ^testing.T) {
	p := testx.prng_make(0x5)
	for iter in 0 ..< 10_000 {
		line := string(testx.random_bytes(&p, 512))
		spans := parse_inline_spans_with(line)
		display_len := spans_display_len(spans)
		ok := display_len >= 0 && display_len <= len(line)
		for span in spans {
			ok &&=
				span.raw_start >= 0 && span.raw_end <= len(line) && span.raw_start <= span.raw_end
		}
		display_position := raw_to_display(spans, testx.int_range(&p, 0, len(line) + 2))
		ok &&= display_position >= 0 && display_position <= display_len
		raw_position := display_to_raw(spans, testx.int_range(&p, 0, display_len + 2))
		ok &&= raw_position >= 0 && raw_position <= len(line)
		_ = is_code_fence(line)
		_ = is_table_separator(line)
		line_end := testx.int_range(&p, 0, len(line) + 1)
		line_start := testx.int_range(&p, 0, line_end + 1)
		cells, starts := split_table_row_offsets_with(line, line_start, line_end)
		ok &&= len(cells) == len(starts)
		for start in starts {
			ok &&= start >= 0 && start <= len(line)
		}
		testing.expectf(
			t,
			ok,
			"seed=0x5 iter=%d markdown invariant broken for %d bytes",
			iter,
			len(line),
		)
		if !ok do return
		free_all(context.temp_allocator)
	}
}
