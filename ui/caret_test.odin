#+build !js
package ui

import "core:strings"
import "core:testing"
import "ingot:testx"

// é is a 2-byte UTF-8 sequence (0xC3 0xA9); used to check rune-boundary safety.
@(private = "file")
MULTI :: "aébc"

@(test)
caret_rune_nav :: proc(t: ^testing.T) {
	// next_rune skips the full 2-byte 'é'; prev_rune returns to its start.
	// "aébc": bytes a(0) é(1,2) b(3) c(4)
	testing.expect_value(t, caret_next_rune(MULTI, 1), 3)
	testing.expect_value(t, caret_prev_rune(MULTI, 3), 1)
	testing.expect_value(t, caret_prev_rune(MULTI, 0), 0)
	testing.expect_value(t, caret_next_rune(MULTI, len(MULTI)), len(MULTI))
}

@(test)
caret_clamp_idempotent :: proc(t: ^testing.T) {
	// Landing mid-'é' (byte 2) snaps back to the rune start (byte 1).
	c := caret_clamp(MULTI, 2)
	testing.expect_value(t, c, 1)
	testing.expect_value(t, caret_clamp(MULTI, c), c)
	testing.expect_value(t, caret_clamp(MULTI, -5), 0)
	testing.expect_value(t, caret_clamp(MULTI, 999), len(MULTI))
}

@(test)
caret_row_col_roundtrip :: proc(t: ^testing.T) {
	s := "ab\ncde\nf"
	p := testx.prng_make(0xCA7E)
	for _ in 0 ..< 2000 {
		pos := testx.int_range(&p, 0, len(s) + 1)
		pos = caret_clamp(s, pos)
		row, col := caret_row_col(s, pos)
		back := caret_from_row_col(s, row, col)
		testing.expect_value(t, back, pos)
	}
}

@(test)
caret_line_helpers :: proc(t: ^testing.T) {
	s := "ab\ncde\nf"
	testing.expect_value(t, caret_line_count(s), 3)
	// pos 4 is inside "cde": line start 3, line end 6.
	testing.expect_value(t, caret_line_start(s, 4), 3)
	testing.expect_value(t, caret_line_end(s, 4), 6)
}

@(test)
caret_word_jump :: proc(t: ^testing.T) {
	s := "foo bar baz"
	// From end, word-left lands at start of "baz".
	testing.expect_value(t, caret_word_left(s, len(s)), 8)
	// From 0, word-right skips "foo" to the space boundary.
	testing.expect_value(t, caret_word_right(s, 0), 3)
}

@(test)
caret_insert_and_delete :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	strings.write_string(&sb, "ac")
	// Insert "b" between a and c.
	pos := caret_insert(&sb, 1, "b")
	testing.expect_value(t, pos, 2)
	testing.expect_value(t, strings.to_string(sb), "abc")
	// Backspace at pos removes 'b'.
	pos = caret_delete_prev(&sb, 2)
	testing.expect_value(t, pos, 1)
	testing.expect_value(t, strings.to_string(sb), "ac")
	// Forward-delete at 1 removes 'c'.
	pos = caret_delete_next(&sb, 1)
	testing.expect_value(t, pos, 1)
	testing.expect_value(t, strings.to_string(sb), "a")
}

@(test)
caret_insert_respects_max_len :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	// Fill to one byte below the cap, then try to insert two runes.
	base := strings.repeat("x", INPUT_MAX_LEN - 1, context.temp_allocator)
	strings.write_string(&sb, base)
	pos := caret_insert(&sb, INPUT_MAX_LEN - 1, "yz")
	// Only room for one byte: length is clamped exactly to the cap.
	testing.expect_value(t, strings.builder_len(sb), INPUT_MAX_LEN)
	testing.expect_value(t, pos, INPUT_MAX_LEN)
}

// Property: caret_next_rune/prev_rune always land on rune boundaries and are
// mutually inverse on a randomly generated string.
@(test)
caret_boundary_fuzz :: proc(t: ^testing.T) {
	p := testx.prng_make(0xB0DE)
	for _ in 0 ..< 3000 {
		s := testx.ascii_string(&p, 40)
		pos := caret_clamp(s, testx.int_range(&p, 0, len(s) + 1))
		nxt := caret_next_rune(s, pos)
		// Landing point must be a rune boundary (not a continuation byte).
		if nxt < len(s) {
			testing.expect(t, (s[nxt] & 0xC0) != 0x80, "next_rune must land on a boundary")
		}
		if nxt > pos {
			testing.expect_value(t, caret_prev_rune(s, nxt), pos)
		}
		free_all(context.temp_allocator)
	}
}

@(test)
caret_insert_does_not_split_utf8_at_max_len :: proc(t: ^testing.T) {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
	base := strings.repeat("x", INPUT_MAX_LEN - 1, context.temp_allocator)
	strings.write_string(&sb, base)

	pos := caret_insert(&sb, INPUT_MAX_LEN - 1, "é")
	testing.expect_value(t, pos, INPUT_MAX_LEN - 1)
	testing.expect_value(t, strings.builder_len(sb), INPUT_MAX_LEN - 1)
	testing.expect_value(t, strings.to_string(sb), base)
}
