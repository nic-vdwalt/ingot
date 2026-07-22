#+build !js
package ui

// Unit tests for mention-pill geometry, encode/strip, and the workspace-path
// registry — pure logic previously untested.

import "core:testing"
import "ingot:testx"

@(test)
pills_shift_insert_moves_later_pills :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{0, 4})
	append(&pills, Mention_Span{10, 14})
	pills_shift_after_insert(&pills, 5, 3)
	// Pill before the insert point is untouched; pill after shifts right.
	testing.expect_value(t, pills[0], Mention_Span{0, 4})
	testing.expect_value(t, pills[1], Mention_Span{13, 17})
}

@(test)
pills_shift_delete_drops_overlaps :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{0, 4})   // before deletion — kept
	append(&pills, Mention_Span{5, 9})   // overlaps [6,10) — dropped
	append(&pills, Mention_Span{12, 16}) // after — shifted left by 4
	pills_shift_after_delete(&pills, 6, 4)
	testing.expect_value(t, len(pills), 2)
	testing.expect_value(t, pills[0], Mention_Span{0, 4})
	testing.expect_value(t, pills[1], Mention_Span{8, 12})
}

@(test)
pill_lookup_and_snap :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{4, 10})
	idx, ok := pill_ending_at(&pills, 10)
	testing.expect(t, ok)
	testing.expect_value(t, idx, 0)
	_, ok = pill_ending_at(&pills, 3)
	testing.expect(t, !ok)
	idx, ok = pill_starting_at(&pills, 4)
	testing.expect(t, ok)
	testing.expect_value(t, idx, 0)
	// Caret strictly inside snaps to the nearest edge.
	testing.expect_value(t, pill_snap_caret(&pills, 5), 4)
	testing.expect_value(t, pill_snap_caret(&pills, 9), 10)
	testing.expect_value(t, pill_snap_left(&pills, 7), 4)
	testing.expect_value(t, pill_snap_right(&pills, 7), 10)
	// Outside a pill nothing snaps.
	testing.expect_value(t, pill_snap_caret(&pills, 2), 2)
}

@(test)
pill_remove_returns_range :: proc(t: ^testing.T) {
	pills := make([dynamic]Mention_Span, context.temp_allocator)
	append(&pills, Mention_Span{2, 6})
	ps, pe := pill_remove(&pills, 0)
	testing.expect_value(t, ps, 2)
	testing.expect_value(t, pe, 6)
	testing.expect_value(t, len(pills), 0)
}

@(test)
encode_strip_roundtrip :: proc(t: ^testing.T) {
	text := "see file.odin now"
	pills := []Mention_Span{{4, 13}}
	encoded := encode_pills(text, pills)
	// Sentinels bracket the pill range and stripping restores the original.
	testing.expect(t, len(encoded) == len(text) + 2)
	testing.expect_value(t, strip_pill_markers(encoded), text)
	// No pills: text passes through untouched.
	testing.expect_value(t, encode_pills(text, nil), text)
	testing.expect_value(t, strip_pill_markers(text), text)
}

@(test)
encode_pills_skips_invalid_ranges :: proc(t: ^testing.T) {
	text := "abcdef"
	// Out-of-bounds and out-of-order ranges are skipped, not encoded.
	pills := []Mention_Span{{4, 99}}
	testing.expect_value(t, strip_pill_markers(encode_pills(text, pills)), text)
}

@(test)
workspace_path_registry :: proc(t: ^testing.T) {
	files := []string{"src/main.odin", "docs/"}
	set_md_file_ctx(files)
	defer clear_md_file_ctx()
	testing.expect(t, workspace_has_path("src/main.odin"))
	// Directory entries carry a trailing '/' in the registry.
	testing.expect(t, workspace_has_path("docs"))
	testing.expect(t, !workspace_has_path("missing.odin"))
	// Cheap rejects: spaces and newlines are never paths.
	testing.expect(t, !workspace_has_path("a b"))
	testing.expect(t, !workspace_has_path(""))
}

// Invariant fuzz: after any random insert/delete sequence every surviving
// pill stays in bounds and pills remain non-overlapping and ordered.
@(test)
pills_shift_fuzz_invariants :: proc(t: ^testing.T) {
	p := testx.prng_make(0xD1CE)
	for _ in 0 ..< 2000 {
		text_len := int(testx.next_u64(&p) % 64) + 8
		pills := make([dynamic]Mention_Span, context.temp_allocator)
		// Seed with two ordered, disjoint pills.
		a := int(testx.next_u64(&p) % u64(text_len / 2))
		b := a + 1 + int(testx.next_u64(&p) % 4)
		c := b + int(testx.next_u64(&p) % 4)
		d := c + 1 + int(testx.next_u64(&p) % 4)
		if d > text_len do d = text_len
		if c < d do append(&pills, Mention_Span{a, b}, Mention_Span{c, d})
		for _ in 0 ..< 8 {
			at := int(testx.next_u64(&p) % u64(text_len + 1))
			n := int(testx.next_u64(&p) % 5)
			if testx.next_u64(&p) % 2 == 0 {
				pills_shift_after_insert(&pills, at, n)
				text_len += n
			} else {
				if n > text_len - at do n = text_len - at
				pills_shift_after_delete(&pills, at, n)
				text_len -= n
			}
		}
		prev_end := 0
		for pl in pills {
			testing.expect(t, pl.start >= 0 && pl.end <= text_len, "pill out of bounds")
			testing.expect(t, pl.start < pl.end, "empty pill survived")
			testing.expect(t, pl.start >= prev_end, "pills overlap or unordered")
			prev_end = pl.end
		}
		free_all(context.temp_allocator)
	}
}
