#+build !js
// In-package edit-op fuzzer for the text-input state machine: caret,
// selection, undo/redo, and mention pills under random operation sequences.
// Lives in-package because the edit machinery is private (mirrors
// term/term_input_fuzz_test.odin).
//
// Runs at a fast default in `scripts/test.sh`; `fuzz/run.sh input` scales it
// with -define:INGOT_FUZZ_ITER=200000. The seed is logged on entry so any
// failure reproduces via -define:INGOT_FUZZ_SEED=n.
package ui

import "core:log"
import "core:strings"
import "core:testing"
import "core:time"
import "core:unicode/utf8"
import fuzzx "ingot:fuzz/fuzzx"

INGOT_FUZZ_ITER :: #config(INGOT_FUZZ_ITER, 2000)
INGOT_FUZZ_SEED :: #config(INGOT_FUZZ_SEED, 0)

@(private = "file")
FUZZ_RUNES := [?]rune{'a', 'b', ' ', '\n', 'é', '€', '👍', '中', 'z', '@'}

@(private = "file")
Fuzz_Input :: struct {
	sb:     strings.Builder,
	cursor: int,
	sel:    Input_Sel,
	undo:   Input_Undo,
	pills:  [dynamic]Mention_Span,
	clock:  f64, // synthetic time for undo coalescing control
}

@(private = "file")
fz_text :: proc(f: ^Fuzz_Input) -> string {
	return strings.to_string(f.sb)
}

// fz_insert mimics the widget's insert path: record undo, splice at caret,
// shift pills.
@(private = "file")
fz_insert :: proc(f: ^Fuzz_Input, s: string) {
	input_undo_record(&f.undo, fz_text(f), f.cursor, f.pills[:], .Insert, f.clock)
	old := fz_text(f)
	f.cursor = caret_clamp(old, f.cursor)
	combined := strings.concatenate({old[:f.cursor], s, old[f.cursor:]}, context.temp_allocator)
	strings.builder_reset(&f.sb)
	strings.write_string(&f.sb, combined)
	pills_shift_after_insert(&f.pills, f.cursor, len(s))
	f.cursor += len(s)
	sel_reset(&f.sel)
}

@(private = "file")
fz_delete_range :: proc(f: ^Fuzz_Input, lo, hi: int) {
	input_undo_record(&f.undo, fz_text(f), f.cursor, f.pills[:], .Delete, f.clock)
	old := fz_text(f)
	l := caret_clamp(old, min(lo, hi))
	h := caret_clamp(old, max(lo, hi))
	if l >= h do return
	pills_shift_after_delete(&f.pills, l, h - l)
	combined := strings.concatenate({old[:l], old[h:]}, context.temp_allocator)
	strings.builder_reset(&f.sb)
	strings.write_string(&f.sb, combined)
	f.cursor = l
	sel_reset(&f.sel)
}

@(private = "file")
fz_check :: proc(t: ^testing.T, f: ^Fuzz_Input, seed: u64, i: int) -> bool {
	ok := true
	text := fz_text(f)
	// Caret: in range and on a rune boundary.
	ok &&= f.cursor >= 0 && f.cursor <= len(text)
	if ok && f.cursor < len(text) {
		ok &&= utf8.rune_start(text[f.cursor])
	}
	// Selection: stored values are deliberately unclamped (the widget clamps
	// at use time against external rewrites) — the contract is that
	// normalization + clamp-at-use always yields a valid range.
	if ok && f.sel.active && f.sel.sb == &f.sb {
		lo, hi := sel_range(&f.sel)
		ok &&= lo <= hi
		cl := caret_clamp(text, lo)
		ch := caret_clamp(text, hi)
		ok &&= cl >= 0 && ch <= len(text) && cl <= ch
	}
	// Pills: sorted, non-overlapping, in bounds.
	if ok {
		prev_end := 0
		for p in f.pills {
			ok &&= p.start >= prev_end && p.end > p.start && p.end <= len(text)
			prev_end = p.end
			if !ok do break
		}
	}
	// Undo stacks bounded.
	ok &&= len(f.undo.undo) <= INPUT_UNDO_MAX && len(f.undo.redo) <= INPUT_UNDO_MAX
	if !ok {
		log.errorf(
			"text_input_fuzz FAILED seed=%d iteration=%d cursor=%d len=%d pills=%d undo=%d",
			seed, i, f.cursor, len(text), len(f.pills), len(f.undo.undo),
		)
		testing.expect(t, false, "text input invariant violated (see seed above)")
	}
	return ok
}

@(test)
text_input_edit_op_fuzz :: proc(t: ^testing.T) {
	seed := u64(INGOT_FUZZ_SEED)
	if seed == 0 do seed = u64(time.now()._nsec)
	log.infof("text_input_fuzz seed=%d iterations=%d", seed, INGOT_FUZZ_ITER)
	p := fuzzx.prng_make(seed)

	f: Fuzz_Input
	defer {
		input_undo_destroy(&f.undo)
		strings.builder_destroy(&f.sb)
		delete(f.pills)
	}

	for i in 0 ..< INGOT_FUZZ_ITER {
		f.clock += f64(fuzzx.int_range(&p, 0, 3000)) / 1000.0 // 0..3 s: crosses coalesce window
		text := fz_text(&f)
		switch fuzzx.int_range(&p, 0, 14) {
		case 0, 1, 2:
			// Insert a random rune (multi-byte included) at the caret.
			buf, n := utf8.encode_rune(FUZZ_RUNES[fuzzx.int_range(&p, 0, len(FUZZ_RUNES))])
			fz_insert(&f, string(buf[:n]))
		case 3:
			// Insert a longer string (paste path).
			fz_insert(&f, "pasted €text👍")
		case 4:
			// Backspace: delete one rune before the caret.
			if f.cursor > 0 {
				fz_delete_range(&f, caret_prev_rune(text, f.cursor), f.cursor)
			}
		case 5:
			// Delete-forward.
			if f.cursor < len(text) {
				fz_delete_range(&f, f.cursor, caret_next_rune(text, f.cursor))
			}
		case 6:
			// Caret moves.
			switch fuzzx.int_range(&p, 0, 4) {
			case 0: f.cursor = caret_prev_rune(text, caret_clamp(text, f.cursor))
			case 1: f.cursor = caret_next_rune(text, caret_clamp(text, f.cursor))
			case 2: f.cursor = 0
			case 3: f.cursor = len(text)
			}
		case 7:
			// Word bounds selection at a random (possibly mid-rune) offset.
			off := caret_clamp(text, fuzzx.int_range(&p, 0, len(text) + 1))
			ws, we := find_word_bounds(text, off)
			sel_set(&f.sel, &f.sb, ws, we)
			f.cursor = we
		case 8:
			// Random (hostile, unclamped) selection.
			sel_set(
				&f.sel, &f.sb,
				fuzzx.int_range(&p, 0, len(text) + 3),
				fuzzx.int_range(&p, 0, len(text) + 3),
			)
		case 9:
			// Delete active selection via the widget's own path.
			if f.sel.active && f.sel.sb == &f.sb {
				input_undo_record(&f.undo, text, f.cursor, f.pills[:], .Delete, f.clock)
				f.cursor = selection_delete(&f.sel, &f.sb, &f.pills)
			}
		case 10:
			// Undo.
			undo_apply(&f.sel, &f.undo, &f.sb, &f.cursor, &f.pills, redo = false)
		case 11:
			// Redo.
			undo_apply(&f.sel, &f.undo, &f.sb, &f.cursor, &f.pills, redo = true)
		case 12:
			// Mention pill insert: "@name " at the caret becomes a pill.
			mention := "@name"
			start := caret_clamp(text, f.cursor)
			fz_insert(&f, mention)
			append(&f.pills, Mention_Span{start, start + len(mention)})
			// Keep sorted: re-sort by simple insertion (bounded list).
			for j := len(f.pills) - 1; j > 0; j -= 1 {
				if f.pills[j].start < f.pills[j - 1].start {
					f.pills[j], f.pills[j - 1] = f.pills[j - 1], f.pills[j]
				}
			}
			// Overlapping pills are invalid caller state; drop overlaps the
			// way pill acceptance does (last write wins).
			for j := len(f.pills) - 1; j > 0; j -= 1 {
				if f.pills[j].start < f.pills[j - 1].end {
					ordered_remove(&f.pills, j - 1)
				}
			}
		case 13:
			// External buffer rewrite (mention completion path): text
			// replaced wholesale; caret must clamp.
			input_undo_record(&f.undo, text, f.cursor, f.pills[:], .Other, f.clock)
			strings.builder_reset(&f.sb)
			strings.write_string(&f.sb, "rewritten")
			clear(&f.pills)
			f.cursor = caret_clamp(fz_text(&f), f.cursor)
			sel_reset(&f.sel)
		}
		if !fz_check(t, &f, seed, i) do return

		// Undo→redo round-trip must restore exact text+caret.
		if fuzzx.int_range(&p, 0, 50) == 0 && len(f.undo.undo) > 0 {
			before_text := strings.clone(fz_text(&f), context.temp_allocator)
			before_cursor := f.cursor
			undo_apply(&f.sel, &f.undo, &f.sb, &f.cursor, &f.pills, redo = false)
			undo_apply(&f.sel, &f.undo, &f.sb, &f.cursor, &f.pills, redo = true)
			if fz_text(&f) != before_text || f.cursor != before_cursor {
				log.errorf(
					"undo/redo round-trip mismatch seed=%d iteration=%d %q(%d) != %q(%d)",
					seed, i, fz_text(&f), f.cursor, before_text, before_cursor,
				)
				testing.expect(t, false, "undo/redo round-trip failed (see seed above)")
				return
			}
		}
		free_all(context.temp_allocator)
	}
}
