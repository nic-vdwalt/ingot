package ui

import "core:strings"

@(private)
match_heading :: proc(line: string) -> (Heading_Match, bool) {
	if strings.has_prefix(line, "### ") {
		return Heading_Match{text = line[4:], level = 3, prefix_len = 4}, true
	}
	if strings.has_prefix(line, "## ") {
		return Heading_Match{text = line[3:], level = 2, prefix_len = 3}, true
	}
	if strings.has_prefix(line, "# ") {
		return Heading_Match{text = line[2:], level = 1, prefix_len = 2}, true
	}
	return {}, false
}

// --- Inline bold (**) parsing ---

@(private = "file")
Inline_Span_Parse_State :: struct {
	line:      string,
	spans:     [dynamic]Text_Span,
	index:     int,
	seg_start: int,
}

// match_url returns the exclusive end of a bare URL starting at byte i in
// line, or ok=false when line[i:] does not start with http:// or https://.
// Trailing sentence punctuation is not considered part of the URL.
match_url :: proc(line: string, i: int) -> (int, bool) {
	rest := line[i:]
	scheme_len := 0
	if strings.has_prefix(rest, "https://") {
		scheme_len = 8
	} else if strings.has_prefix(rest, "http://") {
		scheme_len = 7
	} else {
		return 0, false
	}
	j := i + scheme_len
	loop: for j < len(line) {
		switch line[j] {
		case '\x00' ..= ' ', '<', '>', '"', '\'', '`', PILL_OPEN, PILL_CLOSE:
			break loop
		}
		j += 1
	}
	// Trim trailing punctuation that usually belongs to the sentence.
	trim: for j > i + scheme_len {
		switch line[j - 1] {
		case '.', ',', ';', ':', '!', '?', ')', ']', '}':
			j -= 1
		case:
			break trim
		}
	}
	if j <= i + scheme_len do return 0, false
	return j, true
}

@(private = "file")
inline_span_append_plain :: proc(state: ^Inline_Span_Parse_State, start, end: int) {
	assert(state != nil, "inline_span_append_plain: nil state")
	assert(start >= 0 && end <= len(state.line), "inline_span_append_plain: range out of bounds")
	if start >= end do return
	append(
		&state.spans,
		Text_Span {
			text = state.line[start:end],
			raw_start = start,
			raw_end = end,
			text_raw_start = start,
			text_raw_end = end,
		},
	)
}

@(private = "file")
inline_span_find :: proc(line: string, start: int, marker: u8) -> int {
	for index := start; index < len(line); index += 1 {
		if line[index] == marker do return index
	}
	return -1
}

@(private = "file")
inline_span_parse_pill :: proc(state: ^Inline_Span_Parse_State) {
	assert(state != nil, "inline_span_parse_pill: nil state")
	assert(
		state.index >= 0 && state.index < len(state.line),
		"inline_span_parse_pill: invalid index",
	)
	inline_span_append_plain(state, state.seg_start, state.index)
	close := inline_span_find(state.line, state.index + 1, PILL_CLOSE)
	if close < 0 {
		append(
			&state.spans,
			Text_Span {
				text = state.line[state.index + 1:],
				raw_start = state.index,
				raw_end = len(state.line),
				text_raw_start = state.index + 1,
				text_raw_end = len(state.line),
			},
		)
		state.index = len(state.line)
		state.seg_start = state.index
		return
	}
	append(
		&state.spans,
		Text_Span {
			text = state.line[state.index + 1:close],
			raw_start = state.index,
			raw_end = close + 1,
			text_raw_start = state.index + 1,
			text_raw_end = close,
			pill = true,
		},
	)
	state.index = close + 1
	state.seg_start = state.index
}

@(private = "file")
inline_span_parse_code :: proc(state: ^Inline_Span_Parse_State) {
	assert(state != nil, "inline_span_parse_code: nil state")
	assert(
		state.index >= 0 && state.index < len(state.line),
		"inline_span_parse_code: invalid index",
	)
	inline_span_append_plain(state, state.seg_start, state.index)
	close := inline_span_find(state.line, state.index + 1, '`')
	if close < 0 {
		append(
			&state.spans,
			Text_Span {
				text = state.line[state.index:state.index + 1],
				raw_start = state.index,
				raw_end = state.index + 1,
				text_raw_start = state.index,
				text_raw_end = state.index + 1,
			},
		)
		state.index += 1
		state.seg_start = state.index
		return
	}
	append(
		&state.spans,
		Text_Span {
			text = state.line[state.index + 1:close],
			raw_start = state.index,
			raw_end = close + 1,
			text_raw_start = state.index + 1,
			text_raw_end = close,
			code = true,
		},
	)
	state.index = close + 1
	state.seg_start = state.index
}

@(private = "file")
inline_span_parse_link :: proc(state: ^Inline_Span_Parse_State) -> bool {
	assert(state != nil, "inline_span_parse_link: nil state")
	assert(
		state.index >= 0 && state.index < len(state.line),
		"inline_span_parse_link: invalid index",
	)
	end, ok := match_url(state.line, state.index)
	if !ok do return false
	inline_span_append_plain(state, state.seg_start, state.index)
	url := state.line[state.index:end]
	append(
		&state.spans,
		Text_Span {
			text           = url,
			raw_start      = state.index,
			raw_end        = end,
			text_raw_start = state.index,
			text_raw_end   = end,
			link           = true,
			// A bare URL is its own target: display and destination coincide.
			href           = url,
		},
	)
	state.index = end
	state.seg_start = state.index
	return true
}

// inline_span_parse_reference_link parses [label](target).
//
// Without this the syntax was not handled at all, and the failure was not a
// clean one: parsing began at the 'h' of the scheme, so `[docs](https://x)`
// rendered as the literal text "[docs](", then a live link reading
// "https://x", then ")". The reader saw the markup *and* the wrong text.
//
// Returns false without consuming anything when the shape does not match, so
// a lone '[' still falls through to plain text.
@(private = "file")
inline_span_parse_reference_link :: proc(state: ^Inline_Span_Parse_State) -> bool {
	assert(state != nil, "inline_span_parse_reference_link: nil state")
	line := state.line
	label_end := inline_span_find(line, state.index + 1, ']')
	if label_end < 0 do return false
	// The parenthesis must follow the bracket immediately; "[a] (b)" is two
	// pieces of ordinary text, not a link.
	if label_end + 1 >= len(line) || line[label_end + 1] != '(' do return false
	target_end := inline_span_find(line, label_end + 2, ')')
	if target_end < 0 do return false

	label := line[state.index + 1:label_end]
	target := line[label_end + 2:target_end]
	// An empty label would render as a zero-width link the reader cannot see
	// or click; an empty target has nowhere to go. Both fall back to plain
	// text, which at least shows the author what they wrote.
	if len(label) == 0 || len(target) == 0 do return false

	inline_span_append_plain(state, state.seg_start, state.index)
	append(
		&state.spans,
		Text_Span {
			text           = label,
			// The raw range covers the whole [label](target) source, so text
			// selection offsets stay aligned with the original document.
			raw_start      = state.index,
			raw_end        = target_end + 1,
			text_raw_start = state.index + 1,
			text_raw_end   = label_end,
			link           = true,
			href           = target,
		},
	)
	state.index = target_end + 1
	state.seg_start = state.index
	return true
}

@(private = "file")
inline_span_parse_bold :: proc(state: ^Inline_Span_Parse_State) {
	assert(state != nil, "inline_span_parse_bold: nil state")
	assert(
		state.index >= 0 && state.index + 1 < len(state.line),
		"inline_span_parse_bold: invalid index",
	)
	inline_span_append_plain(state, state.seg_start, state.index)
	close := -1
	for index := state.index + 2; index + 1 < len(state.line); index += 1 {
		if state.line[index] == '*' && state.line[index + 1] == '*' {
			close = index
			break
		}
	}
	if close < 0 || close == state.index + 2 {
		append(
			&state.spans,
			Text_Span {
				text = state.line[state.index:state.index + 2],
				raw_start = state.index,
				raw_end = state.index + 2,
				text_raw_start = state.index,
				text_raw_end = state.index + 2,
			},
		)
		state.index += 2
		state.seg_start = state.index
		return
	}
	append(
		&state.spans,
		Text_Span {
			text = state.line[state.index + 2:close],
			raw_start = state.index,
			raw_end = close + 2,
			text_raw_start = state.index + 2,
			text_raw_end = close,
			bold = true,
		},
	)
	state.index = close + 2
	state.seg_start = state.index
}

// Parse a line into spans, stripping **bold** markers and PILL sentinels.
parse_inline_spans_with :: proc(line: string, allocator := context.temp_allocator) -> []Text_Span {
	has_bold := strings.contains(line, "**")
	has_pill := strings.index_byte(line, PILL_OPEN) >= 0
	has_code := strings.index_byte(line, '`') >= 0
	has_link := strings.contains(line, "http://") || strings.contains(line, "https://")
	// A reference link needs no scheme in the target - [spec](#anchor) is
	// valid - so the bracket is its own fast-path signal.
	has_reference := strings.index_byte(line, '[') >= 0
	if !has_bold && !has_pill && !has_code && !has_link && !has_reference {
		spans := make([]Text_Span, 1, allocator)
		spans[0] = Text_Span {
			text           = line,
			raw_start      = 0,
			raw_end        = len(line),
			text_raw_start = 0,
			text_raw_end   = len(line),
		}
		return spans
	}
	state := Inline_Span_Parse_State {
		line  = line,
		spans = make([dynamic]Text_Span, 0, 8, allocator),
	}
	for state.index < len(line) {
		switch {
		case line[state.index] == PILL_OPEN:
			inline_span_parse_pill(&state)
		case line[state.index] == '`':
			inline_span_parse_code(&state)
		case line[state.index] == '[' && inline_span_parse_reference_link(&state):
		case line[state.index] == 'h' && inline_span_parse_link(&state):
		case state.index + 1 < len(line) &&
		     line[state.index] == '*' &&
		     line[state.index + 1] == '*':
			inline_span_parse_bold(&state)
		case:
			state.index += 1
		}
	}
	inline_span_append_plain(&state, state.seg_start, len(line))
	return state.spans[:]
}


parse_inline_spans :: proc(frame: ^Ui_Frame, line: string) -> Frame_View(Text_Span) {
	return frame_view(frame, parse_inline_spans_with(line, ui_frame_allocator(frame)))
}

// Total display length (without ** markers) for a span array.
spans_display_len :: proc(spans: []Text_Span) -> int {
	total := 0
	for &s in spans {
		total += len(s.text)
	}
	return total
}

// Build display string (markers stripped) from spans.
spans_display_string_with :: proc(
	spans: []Text_Span,
	allocator := context.temp_allocator,
) -> string {
	sb := strings.builder_make(allocator)
	for &s in spans {
		strings.write_string(&sb, s.text)
	}
	return strings.to_string(sb)
}

spans_display_string :: proc(frame: ^Ui_Frame, spans: []Text_Span) -> Frame_String {
	return frame_string(frame, spans_display_string_with(spans, ui_frame_allocator(frame)))
}

// Convert a raw byte offset (in original text with markers) to a display char position.
raw_to_display :: proc(spans: []Text_Span, raw_off: int) -> int {
	display_pos := 0
	for &s in spans {
		if raw_off <= s.raw_start {
			return display_pos
		}
		if raw_off >= s.raw_end {
			display_pos += len(s.text)
			continue
		}
		// raw_off is inside this span's raw range.
		if raw_off < s.text_raw_start do return display_pos
		inner_off := raw_off - s.text_raw_start
		if inner_off > len(s.text) do inner_off = len(s.text)
		return display_pos + inner_off
	}
	return display_pos
}

// Convert a display char position to raw byte offset.
display_to_raw :: proc(spans: []Text_Span, display_pos: int) -> int {
	remaining := display_pos
	for &s, index in spans {
		if remaining <= 0 do return s.text_raw_start
		if remaining == len(s.text) {
			if s.text_raw_end < s.raw_end do return s.text_raw_end
			if index + 1 < len(spans) do return spans[index + 1].text_raw_start
			return s.text_raw_end
		}
		if remaining > len(s.text) {
			remaining -= len(s.text)
			continue
		}
		// Position is inside this span's text.
		return min(s.text_raw_start + remaining, s.text_raw_end)
	}
	// Past end - return raw end of last span.
	if len(spans) > 0 {
		return spans[len(spans) - 1].raw_end
	}
	return 0
}

// Check if a line is a code fence (starts with ```).
is_code_fence :: proc(line: string) -> bool {
	return len(line) >= 3 && line[0] == '`' && line[1] == '`' && line[2] == '`'
}

// --- GFM table rendering ---

// Returns true if line looks like a GFM table separator row, e.g. |---|:--:|.
// Requires at least one dash and only the chars | - : and whitespace.
is_table_separator :: proc(line: string) -> bool {
	saw_dash := false
	for i := 0; i < len(line); i += 1 {
		c := line[i]
		switch c {
		case '-':
			saw_dash = true
		case '|', ':', ' ', '\t':
		case:
			return false
		}
	}
	return saw_dash
}

// Split a GFM table row at source [line_start, line_end) into trimmed cells,
// returning both the cell text (temp-allocated) and the source byte offset where
// each cell's trimmed content begins (used for hit-testing). A single leading and
// trailing outer pipe is dropped.
split_table_row_offsets_with :: proc(
	text: string,
	line_start, line_end: int,
	allocator := context.temp_allocator,
) -> (
	cells: []string,
	starts: []int,
) {
	cell_buf := make([dynamic]string, 0, 8, allocator)
	start_buf := make([dynamic]int, 0, 8, allocator)

	// Determine where the first cell begins: after a leading pipe if present.
	j := line_start
	for j < line_end && (text[j] == ' ' || text[j] == '\t') do j += 1
	seg_start := line_start
	if j < line_end && text[j] == '|' {
		seg_start = j + 1
	}

	k := seg_start
	for k <= line_end {
		if k == line_end || text[k] == '|' {
			raw := text[seg_start:k]
			trimmed := strings.trim_space(raw)
			// Source offset of the trimmed content.
			off := seg_start
			for off < k && (text[off] == ' ' || text[off] == '\t') do off += 1
			// Drop a trailing empty cell produced by the closing outer pipe.
			if k == len(text) || k == line_end {
				if len(trimmed) == 0 && len(cell_buf) > 0 {
					break
				}
			}
			if len(cell_buf) >= MARKDOWN_TABLE_COLS_MAX do break
			append(&cell_buf, trimmed)
			append(&start_buf, off)
			seg_start = k + 1
		}
		k += 1
	}
	return cell_buf[:], start_buf[:]
}

split_table_row_offsets :: proc(
	frame: ^Ui_Frame,
	text: string,
	line_start, line_end: int,
) -> (
	Frame_View(string),
	Frame_View(int),
) {
	assert(frame != nil, "split_table_row_offsets: nil frame")
	cells, starts := split_table_row_offsets_with(
		text,
		line_start,
		line_end,
		ui_frame_allocator(frame),
	)
	return frame_view(frame, cells), frame_view(frame, starts)
}
