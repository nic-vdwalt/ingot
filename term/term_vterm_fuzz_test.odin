package term

// Hostile-input fuzzing of the libvterm ingestion path — the highest-value
// memory-safety target in this package: vterm_input_write parses fully
// untrusted PTY bytes in C (no Odin bounds checks), and the registered screen
// callbacks (_screen_settermprop, _screen_sb_pushline, _screen_sb_popline,
// _screen_sb_clear) perform heap allocation, [^]cell pointer-arithmetic
// copies, and title clone/free cycles driven directly by that input.
//
// These tests are in-package so the production callbacks and the private
// _term_ingest path are reachable, and they run under AddressSanitizer via
// fuzz/run.sh term (part of every soak round). No PTY is spawned:
// term_init_emulator/term_free_emulator set up the exact production emulator
// without a shell process. Seeds are fixed so failures reproduce exactly.

import lv "../libvterm"
import "core:c"
import "core:testing"
import "ingot:testx"

// ---------------------------------------------------------------------------
// Hostile VT stream generator
// ---------------------------------------------------------------------------

// Parameter values that stress CSI arithmetic: missing, zero, huge, negative,
// and INT_MAX-adjacent (overflow in row/col math).
@(private = "file")
FUZZ_CSI_PARAMS := [?]string {
	"",
	"0",
	"1",
	"5",
	"127",
	"9999999",
	"2147483647",
	"2147483648",
	"-5",
	"65535",
}

@(private = "file")
FUZZ_CSI_FINALS := [?]string {
	"H",
	"J",
	"K",
	"m",
	"r",
	"A",
	"B",
	"C",
	"D",
	"L",
	"M",
	"@",
	"P",
	"S",
	"T",
	"d",
	"G",
	"X",
	"f",
}

@(private = "file")
FUZZ_DEC_MODES := [?]string{"?1049h", "?1049l", "?25h", "?25l", "?47h", "?47l", "?2004h", "?2004l"}

// Wide CJK chars, combining marks, and boundary code points — exercises
// width-2 cell handling and the chars[6] array in VTerm_Screen_Cell.
@(private = "file")
FUZZ_TEXT_ATOMS := [?]string {
	"漢",
	"字",
	"e\u0301",
	"a\u0300\u0301\u0302",
	"\u00ff",
	"\U0001F600",
	"x",
	" ",
	"\r\n",
	"\t",
	"\u2500",
}

@(private = "file")
fuzz_vt_append_csi :: proc(p: ^testx.Prng, buf: ^[dynamic]u8) {
	append(buf, 0x1B, '[')
	for i in 0 ..< testx.int_range(p, 0, 4) {
		if i > 0 do append(buf, ';')
		append(buf, FUZZ_CSI_PARAMS[testx.int_range(p, 0, len(FUZZ_CSI_PARAMS))])
	}
	append(buf, FUZZ_CSI_FINALS[testx.int_range(p, 0, len(FUZZ_CSI_FINALS))])
}

@(private = "file")
fuzz_vt_append_osc_title :: proc(p: ^testx.Prng, buf: ^[dynamic]u8, maximum_title: int) {
	append(buf, 0x1B, ']')
	append(buf, testx.int_range(p, 0, 2) == 0 ? '0' : '2')
	append(buf, ';')
	n := testx.int_range(p, 0, maximum_title + 1)
	for _ in 0 ..< n {
		// Printable-ish bytes plus occasional high bytes; ESC/BEL would
		// terminate early, which is itself a valid hostile case sometimes.
		b := u8(testx.int_range(p, 0x20, 0x100))
		append(buf, b)
	}
	switch testx.int_range(p, 0, 3) {
	case 0:
		append(buf, 0x07) // BEL terminator
	case 1:
		append(buf, 0x1B, '\\') // ST terminator
	case:
	// Unterminated — the next document/garbage decides what happens.
	}
}

@(private = "file")
fuzz_vt_append_string_seq :: proc(p: ^testx.Prng, buf: ^[dynamic]u8) {
	// DCS (ESC P) or APC (ESC _) string, randomly terminated.
	append(buf, 0x1B, testx.int_range(p, 0, 2) == 0 ? u8('P') : u8('_'))
	for _ in 0 ..< testx.int_range(p, 0, 128) {
		append(buf, u8(testx.next_u64(p) & 0xFF))
	}
	if testx.int_range(p, 0, 2) == 0 do append(buf, 0x1B, '\\')
}

// fuzz_vt_document builds a hostile byte stream mixing escape-sequence
// templates, text atoms, raw random bytes (incl. malformed UTF-8 and C0/C1
// controls), then applies byte-flip and truncation mutations.
// Package-private (not file-private): term_pump_fuzz_test.odin reuses it.
@(private)
fuzz_vt_document :: proc(p: ^testx.Prng, maximum_len: int) -> []u8 {
	buf := make([dynamic]u8, 0, 512, context.temp_allocator)
	for len(buf) < maximum_len {
		switch testx.int_range(p, 0, 10) {
		case 0, 1, 2:
			fuzz_vt_append_csi(p, &buf)
		case 3:
			append(&buf, 0x1B, '[')
			append(&buf, FUZZ_DEC_MODES[testx.int_range(p, 0, len(FUZZ_DEC_MODES))])
		case 4:
			fuzz_vt_append_osc_title(p, &buf, 512)
		case 5:
			fuzz_vt_append_string_seq(p, &buf)
		case 6:
			// ESC c full reset, or ED 3 which clears scrollback (sb_clear).
			if testx.int_range(p, 0, 2) == 0 {
				append(&buf, 0x1B, 'c')
			} else {
				append(&buf, 0x1B, '[', '3', 'J')
			}
		case 7, 8:
			for _ in 0 ..< testx.int_range(p, 1, 20) {
				append(&buf, FUZZ_TEXT_ATOMS[testx.int_range(p, 0, len(FUZZ_TEXT_ATOMS))])
			}
		case:
			for _ in 0 ..< testx.int_range(p, 1, 64) {
				append(&buf, u8(testx.next_u64(p) & 0xFF))
			}
		}
	}
	// Mutations: byte flips reach states templates cannot; truncation leaves
	// sequences dangling across ingest boundaries.
	for _ in 0 ..< testx.int_range(p, 0, 8) {
		if len(buf) > 0 {
			buf[testx.int_range(p, 0, len(buf))] = u8(testx.next_u64(p) & 0xFF)
		}
	}
	cut := testx.int_range(p, 0, len(buf) + 1)
	return buf[:cut]
}

// ---------------------------------------------------------------------------
// Production-path feeding + invariants
// ---------------------------------------------------------------------------

// fuzz_vt_feed drives data through the production ingestion path in random
// chunks, honouring the same hold-prefix protocol as term_pump: held UTF-8
// bytes go at the front of read_buf, fresh bytes after them.
@(private = "file")
fuzz_vt_feed :: proc(p: ^testx.Prng, ts: ^Term_Instance, data: []u8) {
	i := 0
	for i < len(data) {
		hold := ts.utf8_hold_len
		copy(ts.read_buf[:hold], ts.utf8_hold[:hold])
		chunk := min(testx.int_range(p, 1, 4097), len(data) - i)
		n := copy(ts.read_buf[hold:hold + chunk], data[i:i + chunk])
		i += n
		ts.utf8_hold_len = 0
		_term_ingest(ts, hold + n, false)
	}
}

// fuzz_vt_check_invariants verifies emulator + callback state after hostile
// input: cursor inside the grid, every cell readable with sane width,
// scrollback within cap with consistent offsets, and the title (if any)
// fully readable — under ASan each read also proves the memory is live.
// Package-private (not file-private): term_pump_fuzz_test.odin reuses it.
@(private)
fuzz_vt_check_invariants :: proc(t: ^testing.T, ts: ^Term_Instance) {
	rows, cols: c.int
	lv.vterm_get_size(ts.vt, &rows, &cols)
	testing.expect(t, rows >= 1, "grid rows must stay >= 1")
	testing.expect(t, cols >= 1, "grid cols must stay >= 1")

	cursor: lv.VTerm_Pos
	lv.vterm_state_get_cursorpos(ts.state, &cursor)
	testing.expect(t, cursor.row >= 0 && cursor.row < rows, "cursor row inside grid")
	testing.expect(t, cursor.col >= 0 && cursor.col < cols, "cursor col inside grid")

	cell: lv.VTerm_Screen_Cell
	for row in 0 ..< rows {
		for col in 0 ..< cols {
			lv.vterm_screen_get_cell(ts.screen, lv.VTerm_Pos{row = row, col = col}, &cell)
			testing.expect(t, cell.width >= -1 && cell.width <= 2, "cell width corrupt")
		}
	}

	count := term_scrollback_count(ts)
	testing.expect(t, count <= TERM_SCROLLBACK_MAX, "scrollback exceeded cap")
	testing.expect(
		t,
		ts.sb_ring_head >= 0 && ts.sb_ring_head < TERM_SCROLLBACK_MAX,
		"ring head invalid",
	)
	testing.expect(t, ts.sb_view_offset >= 0, "sb_view_offset negative")
	testing.expect(t, ts.sb_view_offset <= count, "sb_view_offset past scrollback")
	testing.expect(t, ts.sb_base >= 0, "sb_base negative")
	for index in 0 ..< count {
		// Touch every scrollback line — ASan flags stale/freed rows.
		for cl in term_scrollback_line(ts, index) {
			testing.expect(t, cl.width >= -1 && cl.width <= 2, "scrollback cell width corrupt")
		}
	}

	// Title must be a fully readable heap string after any clone cycle.
	checksum := 0
	for b in transmute([]u8)ts.title do checksum += int(b)
	_ = checksum
}

@(private = "file")
fuzz_vt_make :: proc(cols, rows: u16) -> ^Term_Instance {
	ts := new(Term_Instance)
	if !term_init_emulator(ts, cols, rows) {
		free(ts)
		return nil
	}
	return ts
}

@(private = "file")
fuzz_vt_destroy :: proc(ts: ^Term_Instance) {
	term_free_emulator(ts)
	free(ts)
}

// ---------------------------------------------------------------------------
// Fuzz cases
// ---------------------------------------------------------------------------

// Hostile documents through the production ingest path on random grids, with
// interleaved resizes (grow triggers _screen_sb_popline, shrink triggers
// _screen_sb_pushline) and random scrolled-back view offsets.
@(test)
fuzz_vterm_ingest :: proc(t: ^testing.T) {
	p := testx.prng_make(0x57E4_0001)
	for _ in 0 ..< 2_000 {
		cols := u16(testx.int_range(&p, 1, 141))
		rows := u16(testx.int_range(&p, 1, 61))
		ts := fuzz_vt_make(cols, rows)
		testing.expect(t, ts != nil, "vterm allocation failed")
		if ts == nil do continue

		for _ in 0 ..< testx.int_range(&p, 1, 5) {
			doc := fuzz_vt_document(&p, testx.int_range(&p, 1, 8192))
			fuzz_vt_feed(&p, ts, doc)
			// Simulate a user scrolled back mid-stream; pushline pins this.
			if testx.int_range(&p, 0, 4) == 0 {
				ts.sb_view_offset = testx.int_range(&p, 0, term_scrollback_count(ts) + 1)
			}
			if testx.int_range(&p, 0, 3) == 0 {
				lv.vterm_set_size(
					ts.vt,
					c.int(testx.int_range(&p, 1, 61)),
					c.int(testx.int_range(&p, 1, 141)),
				)
			}
			fuzz_vt_check_invariants(t, ts)
		}

		fuzz_vt_destroy(ts)
		free_all(context.temp_allocator)
	}
}

// Scrollback eviction churn: a tiny grid floods past TERM_SCROLLBACK_MAX to
// exercise delete + ordered_remove + sb_base advancing, then grow/shrink
// resizes churn popline/pushline, then ESC c hits sb_clear.
@(test)
fuzz_vterm_scrollback_churn :: proc(t: ^testing.T) {
	p := testx.prng_make(0x57E4_0002)
	ts := fuzz_vt_make(10, 4)
	testing.expect(t, ts != nil, "vterm allocation failed")
	if ts == nil do return

	line := transmute([]u8)string("line of scrollback text\r\n")
	flood := make([dynamic]u8, 0, len(line) * 64, context.temp_allocator)
	for _ in 0 ..< 64 do append(&flood, ..line)

	// > TERM_SCROLLBACK_MAX pushed lines in total (5500 * ~1 line each).
	for _ in 0 ..< (TERM_SCROLLBACK_MAX + 500) / 64 + 1 {
		fuzz_vt_feed(&p, ts, flood[:])
	}
	testing.expect_value(t, term_scrollback_count(ts), TERM_SCROLLBACK_MAX)
	testing.expect(t, ts.sb_base > 0, "eviction must advance sb_base")
	fuzz_vt_check_invariants(t, ts)

	// Grow/shrink churn: growing rows pops scrollback into the screen,
	// shrinking pushes screen rows back out.
	for _ in 0 ..< 200 {
		ts.sb_view_offset = testx.int_range(&p, 0, term_scrollback_count(ts) + 1)
		lv.vterm_set_size(
			ts.vt,
			c.int(testx.int_range(&p, 1, 61)),
			c.int(testx.int_range(&p, 1, 31)),
		)
		fuzz_vt_check_invariants(t, ts)
	}

	// ED 3 (CSI 3 J) drops the scrollback via sb_clear.
	reset := [?]u8{0x1B, '[', '3', 'J'}
	fuzz_vt_feed(&p, ts, reset[:])
	testing.expect_value(t, term_scrollback_count(ts), 0)
	testing.expect_value(t, ts.sb_view_offset, 0)
	fuzz_vt_check_invariants(t, ts)

	fuzz_vt_destroy(ts)
	free_all(context.temp_allocator)
}

// OSC title churn: long/empty/truncated titles with mixed terminators split
// across ingest calls stress the settermprop clone/delete cycle.
@(test)
fuzz_vterm_title_churn :: proc(t: ^testing.T) {
	p := testx.prng_make(0x57E4_0003)
	ts := fuzz_vt_make(80, 24)
	testing.expect(t, ts != nil, "vterm allocation failed")
	if ts == nil do return

	for _ in 0 ..< 2_000 {
		buf := make([dynamic]u8, 0, 512, context.temp_allocator)
		fuzz_vt_append_osc_title(&p, &buf, 8192)
		if testx.int_range(&p, 0, 3) == 0 {
			// Garbage between titles keeps the parser honest about state.
			for _ in 0 ..< testx.int_range(&p, 1, 32) {
				append(&buf, u8(testx.next_u64(&p) & 0xFF))
			}
		}
		fuzz_vt_feed(&p, ts, buf[:])
		// Full readability check of the (possibly replaced) title.
		checksum := 0
		for b in transmute([]u8)ts.title do checksum += int(b)
		_ = checksum
		free_all(context.temp_allocator)
	}
	fuzz_vt_check_invariants(t, ts)

	fuzz_vt_destroy(ts)
	free_all(context.temp_allocator)
}
