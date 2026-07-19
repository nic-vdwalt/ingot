// LIB-CANDIDATE: imports only core:* and ingot:gfx.
// Inline markdown (bold/code/links/pills), GFM tables, headings. Merged
// from openalloy/alloy (adds file pills via ui.workspace_has_path +
// PILL_OPEN/CLOSE from mention_pills.odin). No app-package imports.
package ui

import rl "ingot:gfx"
import "core:strings"

// --- Inline bold (**) parsing ---

Text_Span :: struct {
	text:      string,  // Display text (no ** markers)
	raw_start: int,     // Byte offset into original text where this span's source begins
	raw_end:   int,     // Byte offset where source ends (exclusive)
	bold:      bool,
	pill:      bool,    // PILL_OPEN..PILL_CLOSE file-mention chip
	code:      bool,    // `backtick` inline code; rendered as a file pill when it
	                    // names a real workspace path, else as inline-code text.
	link:      bool,    // Bare http(s):// URL; rendered accent+underline, clickable.
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
		case '\x00'..=' ', '<', '>', '"', '\'', '`', PILL_OPEN, PILL_CLOSE:
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

// Parse a line into spans, stripping **bold** markers and PILL sentinels.
// Returns a slice allocated with temp_allocator.
parse_inline_spans :: proc(line: string) -> []Text_Span {
	has_bold := strings.contains(line, "**")
	has_pill := strings.index_byte(line, PILL_OPEN) >= 0
	has_code := strings.index_byte(line, '`') >= 0
	has_link := strings.contains(line, "http://") || strings.contains(line, "https://")
	// Fast path: no markers at all.
	if !has_bold && !has_pill && !has_code && !has_link {
		spans := make([]Text_Span, 1, context.temp_allocator)
		spans[0] = Text_Span{text = line, raw_start = 0, raw_end = len(line), bold = false}
		return spans
	}

	buf := make([dynamic]Text_Span, 0, 8, context.temp_allocator)
	i := 0
	seg_start := 0 // start of pending normal text
	for i < len(line) {
		// Pill chip: PILL_OPEN ... PILL_CLOSE (single-byte sentinels).
		if line[i] == PILL_OPEN {
			if i > seg_start {
				append(&buf, Text_Span{text = line[seg_start:i], raw_start = seg_start, raw_end = i, bold = false})
			}
			close := -1
			for j := i + 1; j < len(line); j += 1 {
				if line[j] == PILL_CLOSE {
					close = j
					break
				}
			}
			if close < 0 {
				// Unmatched open — treat the remainder as normal text.
				append(&buf, Text_Span{text = line[i + 1:], raw_start = i, raw_end = len(line), bold = false})
				seg_start = len(line)
				i = len(line)
				break
			}
			inner := line[i + 1:close]
			append(&buf, Text_Span{text = inner, raw_start = i, raw_end = close + 1, pill = true})
			i = close + 1
			seg_start = i
			continue
		}

		// Inline code: `text` (single-byte backtick markers).
		if line[i] == '`' {
			if i > seg_start {
				append(&buf, Text_Span{text = line[seg_start:i], raw_start = seg_start, raw_end = i, bold = false})
			}
			close := -1
			for j := i + 1; j < len(line); j += 1 {
				if line[j] == '`' {
					close = j
					break
				}
			}
			if close < 0 {
				// Unmatched backtick — treat the marker as literal text.
				append(&buf, Text_Span{text = line[i:i + 1], raw_start = i, raw_end = i + 1, bold = false})
				i += 1
				seg_start = i
				continue
			}
			inner := line[i + 1:close]
			append(&buf, Text_Span{text = inner, raw_start = i, raw_end = close + 1, code = true})
			i = close + 1
			seg_start = i
			continue
		}

		// Bare URL: http:// or https:// (no markers — raw text == display text).
		if line[i] == 'h' {
			if end, ok := match_url(line, i); ok {
				if i > seg_start {
					append(&buf, Text_Span{text = line[seg_start:i], raw_start = seg_start, raw_end = i, bold = false})
				}
				append(&buf, Text_Span{text = line[i:end], raw_start = i, raw_end = end, link = true})
				i = end
				seg_start = i
				continue
			}
		}

		// Bold: **text**.
		if i + 1 < len(line) && line[i] == '*' && line[i + 1] == '*' {
			if i > seg_start {
				append(&buf, Text_Span{text = line[seg_start:i], raw_start = seg_start, raw_end = i, bold = false})
			}
			close := -1
			for j := i + 2; j + 1 < len(line); j += 1 {
				if line[j] == '*' && line[j + 1] == '*' {
					close = j
					break
				}
			}
			if close < 0 || close == i + 2 {
				// Unmatched or empty (****): treat the marker as literal.
				append(&buf, Text_Span{text = line[i:i + 2], raw_start = i, raw_end = i + 2, bold = false})
				i += 2
				seg_start = i
				continue
			}
			inner := line[i + 2:close]
			append(&buf, Text_Span{text = inner, raw_start = i, raw_end = close + 2, bold = true})
			i = close + 2
			seg_start = i
			continue
		}

		i += 1
	}
	if seg_start < len(line) {
		append(&buf, Text_Span{text = line[seg_start:], raw_start = seg_start, raw_end = len(line), bold = false})
	}

	return buf[:]
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
spans_display_string :: proc(spans: []Text_Span) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for &s in spans {
		strings.write_string(&sb, s.text)
	}
	return strings.to_string(sb)
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
		if s.bold || s.pill || s.code {
			// Opening marker before the text: 2 bytes for bold (**), 1 for pill/code.
			marker_len := 1 if (s.pill || s.code) else 2
			text_raw_start := s.raw_start + marker_len
			if raw_off < text_raw_start {
				return display_pos
			}
			inner_off := raw_off - text_raw_start
			if inner_off > len(s.text) do inner_off = len(s.text)
			return display_pos + inner_off
		} else {
			inner_off := raw_off - s.raw_start
			if inner_off > len(s.text) do inner_off = len(s.text)
			return display_pos + inner_off
		}
	}
	return display_pos
}

// Convert a display char position to raw byte offset.
display_to_raw :: proc(spans: []Text_Span, display_pos: int) -> int {
	remaining := display_pos
	for &s in spans {
		if remaining <= 0 {
			return s.raw_start
		}
		if remaining >= len(s.text) {
			remaining -= len(s.text)
			continue
		}
		// Position is inside this span's text.
		if s.pill {
			return s.raw_start + 1 + remaining // skip opening pill sentinel
		} else if s.code {
			return s.raw_start + 1 + remaining // skip opening backtick
		} else if s.bold {
			return s.raw_start + 2 + remaining // skip opening **
		} else {
			return s.raw_start + remaining
		}
	}
	// Past end — return raw end of last span.
	if len(spans) > 0 {
		return spans[len(spans) - 1].raw_end
	}
	return 0
}

// Draw a single visual (wrapped) line using spans. Renders bold spans as pills.
draw_markdown_line_spans :: proc(x, y: i32, display_line: string, dl_start, dl_end: int, spans: []Text_Span, base_color: rl.Color, sel_display_start, sel_display_end: int, has_sel: bool) {
	cursor_x := x
	// dl_start/dl_end are character offsets into the full display string for this visual line.
	display_offset := 0 // running display char position across all spans

	for &s in spans {
		span_disp_start := display_offset
		span_disp_end := display_offset + len(s.text)
		display_offset = span_disp_end

		// Compute overlap of this span with the current visual line [dl_start, dl_end).
		seg_start := max(span_disp_start, dl_start)
		seg_end := min(span_disp_end, dl_end)
		if seg_start >= seg_end do continue

		seg_text := s.text[seg_start - span_disp_start : seg_end - span_disp_start]
		seg_c := strings.clone_to_cstring(seg_text, context.temp_allocator)
		seg_pixel_w := measure_text(seg_c, FONT_SIZE) + 1

		// Draw selection highlight behind text so text stays visible.
		if has_sel && sel_display_start < sel_display_end {
			hl_s := max(sel_display_start, seg_start)
			hl_e := min(sel_display_end, seg_end)
			if hl_s < hl_e {
				pre_c := strings.clone_to_cstring(seg_text[:hl_s - seg_start], context.temp_allocator)
				span_c := strings.clone_to_cstring(seg_text[hl_s - seg_start:hl_e - seg_start], context.temp_allocator)
				hl_x := cursor_x + measure_text(pre_c, FONT_SIZE)
				hl_w := measure_text(span_c, FONT_SIZE)
				rl.DrawRectangle(hl_x, y, hl_w, LINE_HEIGHT, BG_SELECTION)
			}
		}

		if s.pill {
			// File-mention chip: rounded background + accent text.
			seg_w := measure_text(seg_c, FONT_SIZE)
			rect := rl.Rectangle{f32(cursor_x - 3), f32(y - 1), f32(seg_w + 6), f32(FONT_SIZE + 4)}
			rl.DrawRectangleRounded(rect, 0.5, 6, BG_CHIP)
			draw_text(seg_c, cursor_x, y, FONT_SIZE, FG_ACCENT)
		} else if s.code {
			// Inline code: render as a clickable file/dir pill when the text
			// names a real workspace path; otherwise as plain inline-code text.
			if workspace_has_path(s.text) {
				seg_w := measure_text(seg_c, FONT_SIZE)
				rect := rl.Rectangle{f32(cursor_x - 3), f32(y - 1), f32(seg_w + 6), f32(FONT_SIZE + 4)}
				rl.DrawRectangleRounded(rect, 0.5, 6, BG_CHIP)
				draw_text(seg_c, cursor_x, y, FONT_SIZE, FG_ACCENT)
			} else {
				draw_text(seg_c, cursor_x, y, FONT_SIZE, FG_CODE_INLINE)
			}
		} else if s.bold {
			// Faux-bold: draw text twice with 1px horizontal offset.
			draw_text(seg_c, cursor_x + 1, y, FONT_SIZE, FG_BOLD)
			draw_text(seg_c, cursor_x, y, FONT_SIZE, FG_BOLD)
		} else if s.link {
			// Hyperlink: accent text + underline; click handling lives in chat.odin.
			seg_w := measure_text(seg_c, FONT_SIZE)
			draw_text(seg_c, cursor_x, y, FONT_SIZE, FG_ACCENT)
			rl.DrawLine(cursor_x, y + FONT_SIZE + 1, cursor_x + seg_w, y + FONT_SIZE + 1, FG_ACCENT)
		} else {
			draw_text(seg_c, cursor_x, y, FONT_SIZE, base_color)
		}

		cursor_x += seg_pixel_w
	}
}

// Like draw_text_wrapped but handles **bold** inline spans as pills.
draw_text_wrapped_md :: proc(x, y, max_width: i32, text: string, color: rl.Color, font_size: i32 = FONT_SIZE, sel_start: int = -1, sel_end: int = -1, draw: bool = true) -> i32 {
	if len(text) == 0 do return 0

	spans := parse_inline_spans(text)

	// Fast path: single plain span — delegate to existing function.
	if len(spans) == 1 && !spans[0].bold && !spans[0].pill && !spans[0].code && !spans[0].link {
		return draw_text_wrapped(x, y, max_width, text, color, font_size, sel_start, sel_end, draw)
	}

	display_text := spans_display_string(spans)
	if len(display_text) == 0 do return 0

	has_sel := sel_start >= 0 && sel_end > sel_start
	// Convert raw selection offsets to display positions.
	sel_disp_s := -1
	sel_disp_e := -1
	if has_sel {
		sel_disp_s = raw_to_display(spans, sel_start)
		sel_disp_e = raw_to_display(spans, sel_end)
	}

	// Wrap on display text (pixel-accurate).
	current_y := y
	for ln in wrap_text(display_text, max_width, font_size) {
		if draw && !line_culled(current_y) {
			draw_markdown_line_spans(x, current_y, display_text, ln.start, ln.end, spans, color, sel_disp_s, sel_disp_e, has_sel)
		}
		current_y += LINE_HEIGHT
	}

	return current_y - y
}

// Like measure_wrapped_height but strips ** markers for wrapping calculations.
measure_wrapped_height_md :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> i32 {
	if len(text) == 0 do return 0

	// Fast path: no inline markers.
	if !strings.contains(text, "**") && strings.index_byte(text, PILL_OPEN) < 0 && strings.index_byte(text, '`') < 0 {
		return wrapped_height_px(text, max_width, font_size)
	}

	spans := parse_inline_spans(text)
	display_text := spans_display_string(spans)
	return wrapped_height_px(display_text, max_width, font_size)
}

// Like hit_test_wrapped but maps display position back to raw byte offset.
hit_test_wrapped_md :: proc(x, y, max_width: i32, text: string, mouse_x, mouse_y: i32, font_size: i32 = FONT_SIZE) -> int {
	if len(text) == 0 do return -1

	// Fast path: no inline markers.
	if !strings.contains(text, "**") && strings.index_byte(text, PILL_OPEN) < 0 && strings.index_byte(text, '`') < 0 {
		return hit_test_wrapped(x, y, max_width, text, mouse_x, mouse_y, font_size)
	}

	spans := parse_inline_spans(text)
	display_text := spans_display_string(spans)

	display_offset := hit_test_wrapped(x, y, max_width, display_text, mouse_x, mouse_y, font_size)
	if display_offset < 0 do return -1

	return display_to_raw(spans, display_offset)
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
		case '-': saw_dash = true
		case '|', ':', ' ', '\t':
		case: return false
		}
	}
	return saw_dash
}

// Split a GFM table row at source [line_start, line_end) into trimmed cells,
// returning both the cell text (temp-allocated) and the source byte offset where
// each cell's trimmed content begins (used for hit-testing). A single leading and
// trailing outer pipe is dropped.
split_table_row_offsets :: proc(text: string, line_start, line_end: int) -> (cells: []string, starts: []int) {
	cell_buf := make([dynamic]string, 0, 8, context.temp_allocator)
	start_buf := make([dynamic]int, 0, 8, context.temp_allocator)

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
			append(&cell_buf, trimmed)
			append(&start_buf, off)
			seg_start = k + 1
		}
		k += 1
	}
	return cell_buf[:], start_buf[:]
}

// Parse, lay out, and (when draw==true) render a GFM table block beginning at
// source byte `blk_start` (start of the header line). Returns the byte index just
// past the block and the pixel height consumed. The `draw` flag gates raylib draw
// calls so the same routine measures/hit-tests; both paths compute identical
// heights so scroll/selection stay in sync. When draw==false and out_hit != nil,
// out_hit is set to a source byte offset if the mouse falls inside the table.
layout_table :: proc(
	x, y, max_width: i32, text: string, blk_start: int,
	base_color: rl.Color, draw: bool,
	mouse_x: i32 = 0, mouse_y: i32 = 0, out_hit: ^int = nil,
) -> (next: int, height: i32) {
	Row :: struct {
		cells:  []string,
		starts: []int,
	}
	rows := make([dynamic]Row, 0, 8, context.temp_allocator)
	cols := 0

	pos := blk_start
	phys := 0
	next_byte := blk_start
	for pos < len(text) {
		nl := strings.index_byte(text[pos:], '\n')
		line_end := len(text) if nl < 0 else pos + nl
		line := text[pos:line_end]
		if !strings.contains(line, "|") {
			break
		}
		advance := len(text) if nl < 0 else line_end + 1
		// The second physical line is the header/body separator — skip it.
		if phys == 1 && is_table_separator(line) {
			phys += 1
			next_byte = advance
			pos = advance
			continue
		}
		cells, starts := split_table_row_offsets(text, pos, line_end)
		append(&rows, Row{cells = cells, starts = starts})
		if len(cells) > cols do cols = len(cells)
		phys += 1
		next_byte = advance
		pos = advance
	}

	if cols == 0 || len(rows) == 0 {
		return blk_start, 0
	}

	col_w := max_width / i32(cols)
	if col_w < 1 do col_w = 1
	table_w := col_w * i32(cols)
	row_h := i32(LINE_HEIGHT)
	cell_pad_y := (row_h - FONT_SIZE) / 2
	if cell_pad_y < 0 do cell_pad_y = 0

	for row, ri in rows {
		row_y := y + i32(ri) * row_h
		is_header := ri == 0

		if draw {
			if is_header {
				rl.DrawRectangle(x, row_y, table_w, row_h, BG_TABLE_HEADER)
			}
			for ci in 0 ..< cols {
				cell_x := x + i32(ci) * col_w
				if ci > 0 {
					rl.DrawRectangle(cell_x, row_y, 1, row_h, BORDER_COLOR)
				}
				if ci < len(row.cells) {
					cell_color := FG_BOLD if is_header else base_color
					draw_text_truncated(row.cells[ci], cell_x + TABLE_CELL_PAD, row_y + cell_pad_y, col_w - TABLE_CELL_PAD * 2, FONT_SIZE, cell_color)
				}
			}
			if is_header {
				rl.DrawRectangle(x, row_y + row_h, table_w, 1, BORDER_COLOR)
			}
		} else if out_hit != nil && mouse_y >= row_y && mouse_y < row_y + row_h {
			ci := int((mouse_x - x) / col_w)
			if ci < 0 do ci = 0
			if ci >= cols do ci = cols - 1
			if ci < len(row.cells) {
				cell_x := x + i32(ci) * col_w
				col := caret_pixel_to_col(row.cells[ci], mouse_x - (cell_x + TABLE_CELL_PAD))
				local := caret_col_to_byte(row.cells[ci], col)
				out_hit^ = row.starts[ci] + local
			} else {
				out_hit^ = blk_start
			}
		}
	}

	total_h := i32(len(rows)) * row_h + 1 // +1 for header separator rule
	if draw {
		rl.DrawRectangleLines(x, y, table_w, total_h, BORDER_COLOR)
	}
	total_h += 4 // bottom margin

	return next_byte, total_h
}

// Get font size for a heading level.
heading_font_size :: proc(level: int) -> i32 {
	switch level {
	case 1: return FONT_SIZE_LARGE + 6 // 26
	case 2: return FONT_SIZE_LARGE + 2 // 22
	case:   return FONT_SIZE_LARGE     // 20
	}
}

// Get total height consumed by a heading (wrapped text + padding + rule + margin).
heading_total_height :: proc(heading_text: string, level: int, max_width: i32) -> i32 {
	fs := heading_font_size(level)
	text_h := wrapped_height_px(heading_text, max_width, fs)
	if text_h == 0 do text_h = fs + 4
	h := text_h
	switch level {
	case 1: h += 1 + 8 // 1px rule + 8px margin
	case 2: h += 6     // 6px margin
	case:   h += 4     // 4px margin
	}
	return h
}

// Measure the height that draw_text_wrapped would produce.
measure_wrapped_height :: proc(text: string, max_width: i32, font_size: i32 = FONT_SIZE) -> i32 {
	return wrapped_height_px(text, max_width, font_size)
}

// Render a heading line with wrapping. Returns total height consumed.
draw_heading :: proc(x, y, max_width: i32, text: string, level: int, text_byte_start, sel_start, sel_end: int, has_sel: bool, draw: bool = true) -> i32 {
	font_size := heading_font_size(level)

	// Convert selection coordinates to be relative to the heading text.
	sub_sel_s := -1
	sub_sel_e := -1
	if has_sel {
		text_byte_end := text_byte_start + len(text)
		ov_start := max(sel_start, text_byte_start)
		ov_end := min(sel_end, text_byte_end)
		if ov_start < ov_end {
			sub_sel_s = ov_start - text_byte_start
			sub_sel_e = ov_end - text_byte_start
		}
	}

	text_h := draw_text_wrapped(x, y, max_width, text, FG_HEADING, font_size, sub_sel_s, sub_sel_e, draw)
	if text_h == 0 do text_h = font_size + 4

	total_h := text_h

	if level == 1 {
		if draw do rl.DrawRectangle(x, y + total_h, max_width, 1, BORDER_COLOR)
		total_h += 1
	}

	switch level {
	case 1: total_h += 8
	case 2: total_h += 6
	case:   total_h += 4
	}

	return total_h
}

// Render markdown-formatted text with optional selection highlighting.
// Supports: # headings (H1-H3), - * + bullets, ``` fenced code blocks.
// Returns the total height drawn.
draw_markdown :: proc(x, y, max_width: i32, text: string, base_color: rl.Color, sel_start: int = -1, sel_end: int = -1, out_w: ^i32 = nil, draw: bool = true) -> i32 {
	if len(text) == 0 do return 0

	current_y := y
	line_start := 0
	in_code_block := false
	has_sel := sel_start >= 0 && sel_end > sel_start
	max_w: i32 = 0   // widest laid-out block, for content-hugging bubbles

	for i := 0; i <= len(text); i += 1 {
		is_end := i == len(text)
		if !is_end && text[i] != '\n' do continue
		if is_end && line_start >= len(text) do break

		line := text[line_start:i]

		// Code fence toggle.
		if is_code_fence(line) {
			if !in_code_block {
				in_code_block = true
				if draw do rl.DrawRectangle(x, current_y + 2, max_width, 1, BORDER_COLOR)
				current_y += 6
			} else {
				in_code_block = false
				if draw do rl.DrawRectangle(x, current_y, max_width, 1, BORDER_COLOR)
				current_y += 8
			}
			line_start = i + 1
			continue
		}

		// Code block line.
		if in_code_block {
			if draw && !line_culled(current_y) {
				rl.DrawRectangle(x, current_y, max_width, LINE_HEIGHT, BG_CODE)
				// Left accent so the block reads as one unit in the flat transcript.
				rl.DrawRectangle(x, current_y, 2, LINE_HEIGHT, BORDER_SUBTLE)
				// Truncate long lines to available width (pixel-accurate, with ellipsis).
				display_line := truncate_to_width(line, max_width - CODE_BLOCK_PAD * 2, FONT_SIZE)
				if has_sel {
					draw_line_with_selection(x + CODE_BLOCK_PAD, current_y, display_line, FONT_SIZE, FG_PRIMARY, line_start, sel_start, sel_end)
				} else {
					line_c := strings.clone_to_cstring(display_line, context.temp_allocator)
					draw_text(line_c, x + CODE_BLOCK_PAD, current_y, FONT_SIZE, FG_PRIMARY)
				}
			}
			if out_w != nil {
				lc := strings.clone_to_cstring(line, context.temp_allocator)
				cw := min(measure_text(lc, FONT_SIZE), max_width - CODE_BLOCK_PAD * 2) + CODE_BLOCK_PAD * 2
				if cw > max_w do max_w = cw
			}
			current_y += LINE_HEIGHT
			line_start = i + 1
			continue
		}

		// H3 heading.
		if len(line) >= 4 && line[0] == '#' && line[1] == '#' && line[2] == '#' && line[3] == ' ' {
			current_y += draw_heading(x, current_y, max_width, line[4:], 3, line_start + 4, sel_start, sel_end, has_sel, draw)
			if out_w != nil {
				hw := wrapped_max_line_width(line[4:], max_width, FONT_SIZE)
				if hw > max_w do max_w = hw
			}
			line_start = i + 1
			continue
		}
		// H2 heading.
		if len(line) >= 3 && line[0] == '#' && line[1] == '#' && line[2] == ' ' {
			current_y += draw_heading(x, current_y, max_width, line[3:], 2, line_start + 3, sel_start, sel_end, has_sel, draw)
			if out_w != nil {
				hw := wrapped_max_line_width(line[3:], max_width, FONT_SIZE_LARGE)
				if hw > max_w do max_w = hw
			}
			line_start = i + 1
			continue
		}
		// H1 heading.
		if len(line) >= 2 && line[0] == '#' && line[1] == ' ' {
			current_y += draw_heading(x, current_y, max_width, line[2:], 1, line_start + 2, sel_start, sel_end, has_sel, draw)
			if out_w != nil {
				hw := wrapped_max_line_width(line[2:], max_width, FONT_SIZE_LARGE)
				if hw > max_w do max_w = hw
			}
			line_start = i + 1
			continue
		}

		// Bullet point.
		if len(line) >= 2 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ' {
			if draw do rl.DrawCircle(x + 8, current_y + FONT_SIZE / 2 + 1, 2.5, FG_BULLET)

			content := line[2:]
			content_x := x + BULLET_INDENT
			content_width := max_width - BULLET_INDENT

			sub_sel_s := -1
			sub_sel_e := -1
			if has_sel {
				content_byte_start := line_start + 2
				content_byte_end := line_start + len(line)
				ov_start := max(sel_start, content_byte_start)
				ov_end := min(sel_end, content_byte_end)
				if ov_start < ov_end {
					sub_sel_s = ov_start - content_byte_start
					sub_sel_e = ov_end - content_byte_start
				}
			}

			h := draw_text_wrapped_md(content_x, current_y, content_width, content, base_color, FONT_SIZE, sub_sel_s, sub_sel_e, draw)
			if h == 0 do h = LINE_HEIGHT
			current_y += h
			if out_w != nil {
				bw := BULLET_INDENT + wrapped_max_line_width_md(content, content_width, FONT_SIZE)
				if bw > max_w do max_w = bw
			}
			line_start = i + 1
			continue
		}

		// GFM table: header row with '|' followed by a separator row.
		if !is_end && strings.contains(line, "|") {
			nl := strings.index_byte(text[i + 1:], '\n')
			next_end := len(text) if nl < 0 else i + 1 + nl
			next_line := text[i + 1:next_end]
			if strings.contains(next_line, "|") && is_table_separator(next_line) {
				next_byte, h := layout_table(x, current_y, max_width, text, line_start, base_color, draw)
				current_y += h
				max_w = max_width   // tables are laid out full width
				line_start = next_byte
				i = next_byte - 1 // loop will i += 1
				continue
			}
		}

		// Empty line.
		if len(line) == 0 {
			current_y += LINE_HEIGHT / 2
			line_start = i + 1
			continue
		}

		// Normal text — delegate to draw_text_wrapped.
		sub_sel_s := -1
		sub_sel_e := -1
		if has_sel {
			line_byte_end := line_start + len(line)
			ov_start := max(sel_start, line_start)
			ov_end := min(sel_end, line_byte_end)
			if ov_start < ov_end {
				sub_sel_s = ov_start - line_start
				sub_sel_e = ov_end - line_start
			}
		}

		h := draw_text_wrapped_md(x, current_y, max_width, line, base_color, FONT_SIZE, sub_sel_s, sub_sel_e, draw)
		current_y += h
		if out_w != nil {
			lw := wrapped_max_line_width_md(line, max_width, FONT_SIZE)
			if lw > max_w do max_w = lw
		}
		line_start = i + 1
	}

	if out_w != nil do out_w^ = max_w
	return current_y - y
}

// measure_markdown returns the pixel height draw_markdown would produce for
// `text` at `width`, without any visible output. It calls draw_markdown inside a
// zero-size scissor so all raylib draws are clipped (cheap, invisible) while the
// identical layout math runs — guaranteeing the scroll predictor matches what is
// actually rendered. draw_markdown performs no input handling, so re-running it
// here is side-effect free.
measure_markdown :: proc(width: i32, text: string, out_w: ^i32 = nil) -> i32 {
	if len(text) == 0 do return 0
	// draw=false runs the identical layout math but emits no glyph quads.
	h := draw_markdown(0, 0, width, text, FG_ASSISTANT, -1, -1, out_w, false)
	return h
}
// Mirrors draw_markdown layout exactly.
// Returns valid byte offsets for all positions within the content area, including
// empty-line gaps, code fence margins, heading/bullet margins, and past-end areas.
hit_test_markdown :: proc(x, y, max_width: i32, text: string, mouse_x, mouse_y: i32) -> int {
	if len(text) == 0 do return -1

	// Mouse is above the content area.
	if mouse_y < y do return -1

	current_y := y
	line_start := 0
	in_code_block := false

	for i := 0; i <= len(text); i += 1 {
		is_end := i == len(text)
		if !is_end && text[i] != '\n' do continue
		if is_end && line_start >= len(text) do break

		line := text[line_start:i]

		// Code fence toggle.
		if is_code_fence(line) {
			if !in_code_block {
				in_code_block = true
				// Opening fence: 6px gap. Snap to fence line_start.
				if mouse_y >= current_y && mouse_y < current_y + 6 {
					return line_start
				}
				current_y += 6
			} else {
				in_code_block = false
				// Closing fence: 8px gap. Snap to fence line_start.
				if mouse_y >= current_y && mouse_y < current_y + 8 {
					return line_start
				}
				current_y += 8
			}
			line_start = i + 1
			continue
		}

		// Code block line.
		if in_code_block {
			if mouse_y >= current_y && mouse_y < current_y + LINE_HEIGHT {
				col := caret_pixel_to_col(line, mouse_x - (x + CODE_BLOCK_PAD))
				return line_start + caret_col_to_byte(line, col)
			}
			current_y += LINE_HEIGHT
			line_start = i + 1
			continue
		}

		// H3 heading.
		if len(line) >= 4 && line[0] == '#' && line[1] == '#' && line[2] == '#' && line[3] == ' ' {
			heading_text := line[4:]
			h := heading_total_height(heading_text, 3, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(3)
				offset := hit_test_wrapped(x, current_y, max_width, heading_text, mouse_x, mouse_y, fs)
				if offset >= 0 do return line_start + 4 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 4 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}
		// H2 heading.
		if len(line) >= 3 && line[0] == '#' && line[1] == '#' && line[2] == ' ' {
			heading_text := line[3:]
			h := heading_total_height(heading_text, 2, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(2)
				offset := hit_test_wrapped(x, current_y, max_width, heading_text, mouse_x, mouse_y, fs)
				if offset >= 0 do return line_start + 3 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 3 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}
		// H1 heading.
		if len(line) >= 2 && line[0] == '#' && line[1] == ' ' {
			heading_text := line[2:]
			h := heading_total_height(heading_text, 1, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(1)
				offset := hit_test_wrapped(x, current_y, max_width, heading_text, mouse_x, mouse_y, fs)
				if offset >= 0 do return line_start + 2 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 2 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}

		// Bullet point.
		if len(line) >= 2 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ' {
			content := line[2:]
			content_x := x + BULLET_INDENT
			content_width := max_width - BULLET_INDENT
			h := measure_wrapped_height_md(content, content_width)
			if h == 0 do h = LINE_HEIGHT

			if mouse_y >= current_y && mouse_y < current_y + h {
				offset := hit_test_wrapped_md(content_x, current_y, content_width, content, mouse_x, mouse_y)
				if offset >= 0 do return line_start + 2 + offset
				// Mouse is in bullet indent area — snap to start of bullet content.
				return line_start + 2
			}

			current_y += h
			line_start = i + 1
			continue
		}

		// GFM table.
		if !is_end && strings.contains(line, "|") {
			nl := strings.index_byte(text[i + 1:], '\n')
			next_end := len(text) if nl < 0 else i + 1 + nl
			next_line := text[i + 1:next_end]
			if strings.contains(next_line, "|") && is_table_separator(next_line) {
				offset := -1
				next_byte, h := layout_table(x, current_y, max_width, text, line_start, FG_PRIMARY, false, mouse_x, mouse_y, &offset)
				if mouse_y >= current_y && mouse_y < current_y + h {
					if offset >= 0 do return offset
					return line_start
				}
				current_y += h
				line_start = next_byte
				i = next_byte - 1
				continue
			}
		}

		// Empty line — half-height gap. Snap to line_start (the newline boundary).
		if len(line) == 0 {
			gap : i32 = LINE_HEIGHT / 2
			if mouse_y >= current_y && mouse_y < current_y + gap {
				return line_start
			}
			current_y += gap
			line_start = i + 1
			continue
		}

		// Normal text.
		h := measure_wrapped_height_md(line, max_width)

		if mouse_y >= current_y && mouse_y < current_y + h {
			offset := hit_test_wrapped_md(x, current_y, max_width, line, mouse_x, mouse_y)
			if offset >= 0 do return line_start + offset
		}

		current_y += h
		line_start = i + 1
	}

	// Mouse is just past the last line — snap to end of text. Bounded to one
	// line of slack so clicks far below the content (e.g. in the gap or on a
	// following tool card) miss this block instead of selecting to its end.
	if mouse_y >= current_y && mouse_y < current_y + LINE_HEIGHT {
		return len(text)
	}

	return -1
}
