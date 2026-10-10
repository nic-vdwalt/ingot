package ui

import "core:strings"
import "core:unicode/utf8"

// --- Caret helpers for multi-line text inputs -------------------------------
// All offsets are byte offsets into `s` on rune boundaries. Lines are split on
// '\n' only (the input does not soft-wrap).

// Byte offset of the start of the logical line containing `pos`.
caret_line_start :: proc(s: string, pos: int) -> int {
	assert(pos >= 0 && pos <= len(s))
	i := pos
	for i > 0 && s[i - 1] != '\n' do i -= 1
	return i
}

// Byte offset of the end of the logical line containing `pos` (the '\n' or len).
caret_line_end :: proc(s: string, pos: int) -> int {
	i := pos
	for i < len(s) && s[i] != '\n' do i += 1
	return i
}

// Convert a byte offset to (row, rune-column).
caret_row_col :: proc(s: string, pos: int) -> (row: int, col: int) {
	for i := 0; i < pos && i < len(s); {
		if s[i] == '\n' {
			row += 1
			col = 0
			i += 1
		} else {
			j := i + 1
			for j < len(s) && (s[j] & 0xC0) == 0x80 do j += 1
			col += 1
			i = j
		}
	}
	return
}

// Convert (row, rune-column) back to a byte offset, clamping to line length.
caret_from_row_col :: proc(s: string, row, col: int) -> int {
	line := 0
	i := 0
	for i < len(s) && line < row {
		if s[i] == '\n' do line += 1
		i += 1
	}
	c := 0
	for i < len(s) && s[i] != '\n' && c < col {
		j := i + 1
		for j < len(s) && (s[j] & 0xC0) == 0x80 do j += 1
		i = j
		c += 1
	}
	return i
}

// Number of logical lines (newline count + 1).
caret_line_count :: proc(s: string) -> int {
	n := 1
	for i := 0; i < len(s); i += 1 {
		if s[i] == '\n' do n += 1
	}
	return n
}

// Move one rune left from `pos`, returning the new byte offset.
caret_prev_rune :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_prev_rune: negative offset")
	assert(pos <= len(s), "caret_prev_rune: offset past end")
	if pos <= 0 do return 0
	i := pos - 1
	for i > 0 && (s[i] & 0xC0) == 0x80 do i -= 1
	return i
}

// Move one rune right from `pos`, returning the new byte offset.
caret_next_rune :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_next_rune: negative offset")
	assert(pos <= len(s), "caret_next_rune: offset past end")
	if pos >= len(s) do return len(s)
	i := pos + 1
	for i < len(s) && (s[i] & 0xC0) == 0x80 do i += 1
	return i
}

// Move one grapheme cluster right from `pos`, returning the new byte offset.
// Emoji ZWJ sequences and combining-mark pairs step as one unit, matching
// what the user perceives as a single character. Scans clusters from the
// line start so a mid-cluster caret still sees full left context (resuming
// segmentation mid-sequence would fabricate boundaries).
caret_next_grapheme :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_next_grapheme: negative offset")
	assert(pos <= len(s), "caret_next_grapheme: offset past end")
	if pos >= len(s) do return len(s)
	p := caret_clamp(s, pos)
	if s[p] == '\n' do return p + 1 // on the newline: step onto the next line
	start := caret_line_start(s, p)
	end := caret_line_end(s, p)
	it := utf8.decode_grapheme_iterator_make(s[start:end])
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start + g.byte_index > p do return start + g.byte_index
	}
	return end // caret in the line's last cluster: next stop is the line end
}

// Move one grapheme cluster left from `pos`, returning the new byte offset.
// Scans clusters from the current line start: cluster boundaries never span
// '\n' (breaks occur around controls), so one line bounds the walk.
caret_prev_grapheme :: proc(s: string, pos: int) -> int {
	assert(pos >= 0, "caret_prev_grapheme: negative offset")
	assert(pos <= len(s), "caret_prev_grapheme: offset past end")
	if pos <= 0 do return 0
	p := caret_clamp(s, pos)
	if p == 0 do return 0
	start := caret_line_start(s, p)
	if p == start do return p - 1 // at a line start: step over the newline
	prev := start
	it := utf8.decode_grapheme_iterator_make(s[start:p])
	for _, g in utf8.decode_grapheme_iterate(&it) {
		if start + g.byte_index >= p do break
		prev = start + g.byte_index
	}
	return prev
}

// Word-jump left (skip trailing whitespace/newlines, then a run of non-space).
caret_word_left :: proc(s: string, pos: int) -> int {
	assert(pos >= 0 && pos <= len(s))
	i := pos
	for i > 0 && (s[i - 1] == ' ' || s[i - 1] == '\n') do i -= 1
	for i > 0 {
		c := s[i - 1]
		if c == ' ' || c == '\n' do break
		i -= 1
	}
	return i
}

// Word-jump right (skip leading whitespace/newlines, then a run of non-space).
caret_word_right :: proc(s: string, pos: int) -> int {
	i := pos
	for i < len(s) && (s[i] == ' ' || s[i] == '\n') do i += 1
	for i < len(s) {
		c := s[i]
		if c == ' ' || c == '\n' do break
		i += 1
	}
	return i
}

// Clamp `pos` into [0, len(s)] and snap down to the nearest rune boundary.
caret_clamp :: proc(s: string, pos: int) -> int {
	p := pos
	if p < 0 do p = 0
	if p > len(s) do p = len(s)
	for p > 0 && p < len(s) && (s[p] & 0xC0) == 0x80 do p -= 1
	// Why assert: every caller trusts the result as a safe slicing offset;
	// a mid-rune result would split a UTF-8 sequence on the next edit. p == 0
	// is exempt because malformed input may begin with a continuation byte.
	assert(p >= 0 && p <= len(s), "caret_clamp: result out of bounds")
	assert(p == 0 || p == len(s) || (s[p] & 0xC0) != 0x80, "caret_clamp: mid-rune result")
	return p
}

// Insert `text` at `pos`, returning the new caret position (pos + len(inserted)).
caret_insert :: proc(sb: ^strings.Builder, pos: int, text: string) -> int {
	assert(sb != nil, "caret_insert: nil sb")
	old := strings.to_string(sb^)
	insert := text
	before := old[:pos]
	after := old[pos:]
	if len(before) + len(insert) + len(after) > INPUT_MAX_LEN {
		room := INPUT_MAX_LEN - (len(before) + len(after))
		if room <= 0 do return pos
		r := room
		if r > len(insert) do r = len(insert)
		for r > 0 && r < len(insert) && (insert[r] & 0xC0) == 0x80 do r -= 1
		insert = insert[:r]
	}
	combined := strings.concatenate({before, insert, after}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return pos + len(insert)
}

// Byte offset within a single line for a given rune column.
caret_col_to_byte :: proc(line: string, col: int) -> int {
	i := 0
	c := 0
	for i < len(line) && c < col {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		i = j
		c += 1
	}
	return i
}

@(private = "file")
caret_measure_with :: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32 {
	assert(data != nil, "caret_measure_with: nil system")
	assert(font_size > 0, "caret_measure_with: invalid font size")
	return measure_text_with((^Text_System)(data), prefix, font_size)
}

@(private = "file")
caret_measure_frame :: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32 {
	assert(data != nil, "caret_measure_frame: nil frame")
	assert(font_size > 0, "caret_measure_frame: invalid font size")
	return measure_text_frame((^Ui_Frame)(data), prefix, font_size)
}

caret_pixel_to_col_with :: proc(system: ^Text_System, line: string, px, font_size: i32) -> int {
	assert(system != nil, "caret_pixel_to_col_with: nil text system")
	assert(font_size > 0, "caret_pixel_to_col_with: invalid font size")
	return caret_pixel_to_col_search(system, caret_measure_with, line, px, font_size)
}

caret_pixel_to_col_frame :: proc(frame: ^Ui_Frame, line: string, px, font_size: i32) -> int {
	assert(frame != nil && frame.open, "caret_pixel_to_col_frame: invalid frame")
	assert(font_size > 0, "caret_pixel_to_col_frame: invalid font size")
	return caret_pixel_to_col_search(frame, caret_measure_frame, line, px, font_size)
}

// caret_pixel_to_col_search maps a pixel offset to the nearest rune column
// by binary-searching prefix widths (monotonic in prefix length). The old
// linear scan measured every prefix - O(n^2) work per call, re-run every
// frame of a mouse drag; the search does O(log n) prefix measures and
// returns the identical nearest-boundary column.
@(private = "file")
caret_pixel_to_col_search :: proc(
	measure_data: rawptr,
	measure: proc(data: rawptr, prefix: cstring, font_size: i32) -> i32,
	line: string,
	px, font_size: i32,
) -> int {
	assert(measure != nil, "caret_pixel_to_col_search: nil measure")
	assert(font_size > 0, "caret_pixel_to_col_search: invalid font size")
	if px <= 0 do return 0
	// Rune-start offsets plus the end-of-line sentinel: starts[k] is the byte
	// length of the k-rune prefix.
	starts := make([dynamic]int, context.temp_allocator)
	append(&starts, 0)
	for i := 0; i < len(line); {
		j := i + 1
		for j < len(line) && (line[j] & 0xC0) == 0x80 do j += 1
		append(&starts, j)
		i = j
	}
	count := len(starts) - 1
	if count == 0 do return 0
	full := strings.clone_to_cstring(line, context.temp_allocator)
	hi_width := measure(measure_data, full, font_size)
	if hi_width <= px do return count
	// Invariant: width(lo runes) <= px < width(hi runes); the gap halves
	// every iteration, so the loop is bounded by log2(count).
	lo, hi := 0, count
	lo_width: i32 = 0
	for hi - lo > 1 {
		mid := lo + (hi - lo) / 2
		prefix := strings.clone_to_cstring(line[:starts[mid]], context.temp_allocator)
		width := measure(measure_data, prefix, font_size)
		if width > px {
			hi, hi_width = mid, width
		} else {
			lo, lo_width = mid, width
		}
	}
	assert(lo_width <= px && px < hi_width, "caret_pixel_to_col_search: invariant broken")
	// Snap to whichever boundary of the straddling rune is nearer, exactly
	// as the linear scan did.
	if px - lo_width < hi_width - px do return lo
	return hi
}

// Delete the rune before `pos` (backspace). Returns the new caret position.
caret_delete_prev :: proc(sb: ^strings.Builder, pos: int) -> int {
	assert(sb != nil, "caret_delete_prev: nil sb")
	if pos <= 0 do return 0
	old := strings.to_string(sb^)
	start := caret_prev_rune(old, pos)
	combined := strings.concatenate({old[:start], old[pos:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return start
}

// Delete the rune at `pos` (forward delete). Returns `pos` unchanged.
caret_delete_next :: proc(sb: ^strings.Builder, pos: int) -> int {
	assert(sb != nil, "caret_delete_next: nil sb")
	old := strings.to_string(sb^)
	if pos >= len(old) do return pos
	end := caret_next_rune(old, pos)
	combined := strings.concatenate({old[:pos], old[end:]}, context.temp_allocator)
	strings.builder_reset(sb)
	strings.write_string(sb, combined)
	return pos
}


@(private = "file")
is_identifier_byte :: proc(value: u8) -> bool {
	return(
		(value >= 'a' && value <= 'z') ||
		(value >= 'A' && value <= 'Z') ||
		(value >= '0' && value <= '9') ||
		value == '_' ||
		value >= 0x80 \
	)
}

// Find word boundaries around a byte offset. A word is alphanumeric,
// underscore, or any non-ASCII rune.
find_word_bounds :: proc(text: string, byte_offset: int) -> (start: int, end: int) {
	assert(byte_offset >= 0 && byte_offset <= len(text))
	start = byte_offset
	for start > 0 {
		if !is_identifier_byte(text[start - 1]) do break
		start -= 1
	}
	end = byte_offset
	for end < len(text) {
		if !is_identifier_byte(text[end]) do break
		end += 1
	}
	return
}
