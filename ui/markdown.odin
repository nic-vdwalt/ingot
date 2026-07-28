// LIB-CANDIDATE: imports only core:*.
// Inline markdown (bold/code/links/pills), GFM tables, headings. Merged
// from openalloy/alloy (adds file pills via ui.workspace_has_path +
// PILL_OPEN/CLOSE from mention_pills.odin). No app-package imports.
package ui

import "core:strings"

// Tables beyond these dimensions are neither legible nor safe to process in one frame.
MARKDOWN_TABLE_COLS_MAX :: 64
MARKDOWN_TABLE_ROWS_MAX :: 512

Markdown_Context :: struct {
	frame:           ^Ui_Frame,
	workspace_files: []string,
	cull_top:        i32,
	cull_bottom:     i32,
}

markdown_context :: proc(frame: ^Ui_Frame, workspace_files: []string = nil) -> Markdown_Context {
	assert(frame != nil && frame.open, "markdown_context: invalid frame")
	return Markdown_Context {
		frame = frame,
		workspace_files = workspace_files,
		cull_top = min(i32),
		cull_bottom = max(i32),
	}
}

markdown_line_culled :: proc(ctx: ^Markdown_Context, y, line_height: i32) -> bool {
	assert(ctx != nil && ctx.frame != nil, "markdown_line_culled: invalid context")
	assert(line_height > 0, "markdown_line_culled: invalid line height")
	return y + line_height < ctx.cull_top || y > ctx.cull_bottom
}

Heading_Match :: struct {
	text:       string,
	level:      int,
	prefix_len: int,
}

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

Text_Span :: struct {
	text:      string, // Display text (no ** markers)
	raw_start: int, // Byte offset into original text where this span's source begins
	raw_end:   int, // Byte offset where source ends (exclusive)
	bold:      bool,
	pill:      bool, // PILL_OPEN..PILL_CLOSE file-mention chip
	code:      bool, // `backtick` inline code; rendered as a file pill when it
	// names a real workspace path, else as inline-code text.
	link:      bool, // Bare http(s):// URL; rendered accent+underline, clickable.
}

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
	if start >= end do return
	append(&state.spans, Text_Span{text = state.line[start:end], raw_start = start, raw_end = end})
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
	inline_span_append_plain(state, state.seg_start, state.index)
	close := inline_span_find(state.line, state.index + 1, PILL_CLOSE)
	if close < 0 {
		append(
			&state.spans,
			Text_Span {
				text = state.line[state.index + 1:],
				raw_start = state.index,
				raw_end = len(state.line),
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
			pill = true,
		},
	)
	state.index = close + 1
	state.seg_start = state.index
}

@(private = "file")
inline_span_parse_code :: proc(state: ^Inline_Span_Parse_State) {
	assert(state != nil, "inline_span_parse_code: nil state")
	inline_span_append_plain(state, state.seg_start, state.index)
	close := inline_span_find(state.line, state.index + 1, '`')
	if close < 0 {
		append(
			&state.spans,
			Text_Span {
				text = state.line[state.index:state.index + 1],
				raw_start = state.index,
				raw_end = state.index + 1,
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
			code = true,
		},
	)
	state.index = close + 1
	state.seg_start = state.index
}

@(private = "file")
inline_span_parse_link :: proc(state: ^Inline_Span_Parse_State) -> bool {
	assert(state != nil, "inline_span_parse_link: nil state")
	end, ok := match_url(state.line, state.index)
	if !ok do return false
	inline_span_append_plain(state, state.seg_start, state.index)
	append(
		&state.spans,
		Text_Span {
			text = state.line[state.index:end],
			raw_start = state.index,
			raw_end = end,
			link = true,
		},
	)
	state.index = end
	state.seg_start = state.index
	return true
}

@(private = "file")
inline_span_parse_bold :: proc(state: ^Inline_Span_Parse_State) {
	assert(state != nil, "inline_span_parse_bold: nil state")
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
	if !has_bold && !has_pill && !has_code && !has_link {
		spans := make([]Text_Span, 1, allocator)
		spans[0] = Text_Span {
			text      = line,
			raw_start = 0,
			raw_end   = len(line),
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

@(private = "file")
draw_markdown_span_selection :: proc(
	ctx: ^Markdown_Context,
	cursor_x, y: i32,
	text: string,
	segment_start, segment_end: int,
	selection_start, selection_end: int,
	has_selection: bool,
) {
	assert(ctx != nil, "draw_markdown_span_selection: nil ctx")
	if !has_selection || selection_start >= selection_end do return
	highlight_start := max(selection_start, segment_start)
	highlight_end := min(selection_end, segment_end)
	if highlight_start >= highlight_end do return
	pre := strings.clone_to_cstring(text[:highlight_start - segment_start], context.temp_allocator)
	selected := strings.clone_to_cstring(
		text[highlight_start - segment_start:highlight_end - segment_start],
		context.temp_allocator,
	)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	highlight_x := cursor_x + measure_text_frame(ctx.frame, pre, font_size)
	highlight_w := measure_text_frame(ctx.frame, selected, font_size)
	draw_rectangle(
		ctx.frame,
		highlight_x,
		y,
		highlight_w,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
		ui_frame_theme(ctx.frame).bg_selection,
	)
}

@(private = "file")
draw_markdown_span_chip :: proc(ctx: ^Markdown_Context, text: cstring, x, y: i32) {
	assert(ctx != nil, "draw_markdown_span_chip: nil ctx")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	width := measure_text_frame(ctx.frame, text, font_size)
	rect := Rectangle{f32(x - 3), f32(y - 1), f32(width + 6), f32(font_size + 4)}
	draw_rectangle_rounded(ctx.frame, rect, 0.5, 6, ui_frame_theme(ctx.frame).bg_chip)
	draw_text_frame(ctx.frame, text, x, y, font_size, ui_frame_theme(ctx.frame).fg_accent)
}

@(private = "file")
draw_markdown_span_code :: proc(
	ctx: ^Markdown_Context,
	span: ^Text_Span,
	text: cstring,
	x, y: i32,
) {
	assert(ctx != nil, "draw_markdown_span_code: nil ctx")
	assert(span != nil, "draw_markdown_span_code: nil span")
	if workspace_has_path_with(ctx.workspace_files, span.text) {
		draw_markdown_span_chip(ctx, text, x, y)
		return
	}
	draw_text_frame(
		ctx.frame,
		text,
		x,
		y,
		ui_frame_metrics(ctx.frame).FONT_SIZE_BODY,
		ui_frame_theme(ctx.frame).fg_code_inline,
	)
}

@(private = "file")
draw_markdown_span_emphasis :: proc(
	ctx: ^Markdown_Context,
	span: ^Text_Span,
	text: cstring,
	x, y: i32,
	base_color: Color,
) {
	assert(ctx != nil, "draw_markdown_span_emphasis: nil ctx")
	assert(span != nil, "draw_markdown_span_emphasis: nil span")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	style := ui_frame_theme(ctx.frame)
	if span.bold {
		draw_text_frame(ctx.frame, text, x + 1, y, font_size, style.fg_bold)
		draw_text_frame(ctx.frame, text, x, y, font_size, style.fg_bold)
	} else if span.link {
		width := measure_text_frame(ctx.frame, text, font_size)
		draw_text_frame(ctx.frame, text, x, y, font_size, style.fg_accent)
		draw_line(ctx.frame, x, y + font_size + 1, x + width, y + font_size + 1, style.fg_accent)
	} else {
		draw_text_frame(ctx.frame, text, x, y, font_size, base_color)
	}
}

@(private = "file")
draw_markdown_span_style :: proc(
	ctx: ^Markdown_Context,
	span: ^Text_Span,
	text: cstring,
	x, y: i32,
	base_color: Color,
) {
	assert(ctx != nil, "draw_markdown_span_style: nil ctx")
	assert(span != nil, "draw_markdown_span_style: nil span")
	if span.pill {
		draw_markdown_span_chip(ctx, text, x, y)
	} else if span.code {
		draw_markdown_span_code(ctx, span, text, x, y)
	} else {
		draw_markdown_span_emphasis(ctx, span, text, x, y, base_color)
	}
}

// Draw a single visual (wrapped) line using spans. Renders bold spans as pills.
draw_markdown_line_spans :: proc(
	ctx: ^Markdown_Context,
	x, y: i32,
	display_line: string,
	dl_start, dl_end: int,
	spans: []Text_Span,
	base_color: Color,
	sel_display_start, sel_display_end: int,
	has_sel: bool,
) {
	assert(ctx != nil, "draw_markdown_line_spans: nil ctx")
	_ = display_line
	cursor_x := x
	display_offset := 0
	for &span in spans {
		span_start := display_offset
		span_end := display_offset + len(span.text)
		display_offset = span_end
		segment_start := max(span_start, dl_start)
		segment_end := min(span_end, dl_end)
		if segment_start >= segment_end do continue
		segment := span.text[segment_start - span_start:segment_end - span_start]
		segment_c := strings.clone_to_cstring(segment, context.temp_allocator)
		draw_markdown_span_selection(
			ctx,
			cursor_x,
			y,
			segment,
			segment_start,
			segment_end,
			sel_display_start,
			sel_display_end,
			has_sel,
		)
		draw_markdown_span_style(ctx, &span, segment_c, cursor_x, y, base_color)
		cursor_x +=
			measure_text_frame(ctx.frame, segment_c, ui_frame_metrics(ctx.frame).FONT_SIZE_BODY) +
			1
	}
}

// Like draw_text_wrapped but handles **bold** inline spans as pills.
draw_text_wrapped_md :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	color: Color,
	font_size: i32,
	sel_start: int = -1,
	sel_end: int = -1,
	draw: bool = true,
) -> i32 {
	assert(ctx != nil, "draw_text_wrapped_md: nil ctx")
	if len(text) == 0 do return 0

	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, text))

	// Fast path: single plain span — delegate to existing function.
	if len(spans) == 1 && !spans[0].bold && !spans[0].pill && !spans[0].code && !spans[0].link {
		return draw_text_wrapped_frame(
			ctx.frame,
			x,
			y,
			max_width,
			text,
			color,
			font_size,
			ui_frame_metrics(ctx.frame).LINE_HEIGHT,
			sel_start,
			sel_end,
			draw,
		)
	}

	display_text := frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))
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
	for ln in wrap_text_frame(ctx.frame, display_text, max_width, font_size) {
		if draw && !markdown_line_culled(ctx, current_y, ui_frame_metrics(ctx.frame).LINE_HEIGHT) {
			draw_markdown_line_spans(
				ctx,
				x,
				current_y,
				display_text,
				ln.start,
				ln.end,
				spans,
				color,
				sel_disp_s,
				sel_disp_e,
				has_sel,
			)
		}
		current_y += ui_frame_metrics(ctx.frame).LINE_HEIGHT
	}

	return current_y - y
}

// Like measure_wrapped_height but strips ** markers for wrapping calculations.
measure_wrapped_height_md :: proc(
	ctx: ^Markdown_Context,
	text: string,
	max_width: i32,
	font_size: i32,
) -> i32 {
	assert(ctx != nil, "measure_wrapped_height_md: nil ctx")
	if len(text) == 0 do return 0

	// Fast path: no inline markers.
	if !strings.contains(text, "**") &&
	   strings.index_byte(text, PILL_OPEN) < 0 &&
	   strings.index_byte(text, '`') < 0 {
		return wrapped_height_px_frame(
			ctx.frame,
			text,
			max_width,
			font_size,
			ui_frame_metrics(ctx.frame).LINE_HEIGHT,
		)
	}

	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, text))
	display_text := frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))
	return wrapped_height_px_frame(
		ctx.frame,
		display_text,
		max_width,
		font_size,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
	)
}

// Like hit_test_wrapped but maps display position back to raw byte offset.
hit_test_wrapped_md :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
	font_size: i32,
) -> int {
	assert(ctx != nil, "hit_test_wrapped_md: nil ctx")
	if len(text) == 0 do return -1

	// Fast path: no inline markers.
	if !strings.contains(text, "**") &&
	   strings.index_byte(text, PILL_OPEN) < 0 &&
	   strings.index_byte(text, '`') < 0 {
		return hit_test_wrapped_frame(
			ctx.frame,
			x,
			y,
			max_width,
			text,
			mouse_x,
			mouse_y,
			font_size,
		)
	}

	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, text))
	display_text := frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))

	display_offset := hit_test_wrapped_frame(
		ctx.frame,
		x,
		y,
		max_width,
		display_text,
		mouse_x,
		mouse_y,
		font_size,
	)
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

Markdown_Table_Row :: struct {
	cells:  []string,
	starts: []int,
}

Markdown_Table_Widths :: [MARKDOWN_TABLE_COLS_MAX]i32
Markdown_Table_Heights :: [MARKDOWN_TABLE_ROWS_MAX]i32

@(private = "file")
markdown_table_parse_rows :: proc(
	ctx: ^Markdown_Context,
	text: string,
	block_start: int,
) -> (
	[dynamic]Markdown_Table_Row,
	int,
	int,
) {
	assert(ctx != nil, "markdown_table_parse_rows: nil ctx")
	rows := make([dynamic]Markdown_Table_Row, 0, 8, ui_frame_allocator(ctx.frame))
	columns := 0
	position := block_start
	physical_line := 0
	next_byte := block_start
	for position < len(text) && len(rows) < MARKDOWN_TABLE_ROWS_MAX {
		newline := strings.index_byte(text[position:], '\n')
		line_end := len(text) if newline < 0 else position + newline
		line := text[position:line_end]
		if !strings.contains(line, "|") do break
		advance := len(text) if newline < 0 else line_end + 1
		if physical_line == 1 && is_table_separator(line) {
			physical_line += 1
			next_byte = advance
			position = advance
			continue
		}
		cells_view, starts_view := split_table_row_offsets(ctx.frame, text, position, line_end)
		cells := frame_view_items(ctx.frame, cells_view)
		starts := frame_view_items(ctx.frame, starts_view)
		append(&rows, Markdown_Table_Row{cells = cells, starts = starts})
		columns = max(columns, min(len(cells), MARKDOWN_TABLE_COLS_MAX))
		physical_line += 1
		next_byte = advance
		position = advance
	}
	return rows, columns, next_byte
}

@(private = "file")
markdown_table_natural_widths :: proc(
	ctx: ^Markdown_Context,
	rows: []Markdown_Table_Row,
	columns: int,
	max_width: i32,
) -> (
	Markdown_Table_Widths,
	i32,
) {
	assert(ctx != nil, "markdown_table_natural_widths: nil ctx")
	widths: Markdown_Table_Widths
	padding := ui_frame_metrics(ctx.frame).TABLE_CELL_PAD
	for row in rows {
		for cell, column in row.cells {
			if len(cell) == 0 do continue
			cell_c := strings.clone_to_cstring(cell, ui_frame_allocator(ctx.frame))
			width :=
				measure_text_frame(ctx.frame, cell_c, ui_frame_metrics(ctx.frame).FONT_SIZE_BODY) +
				padding * 2
			widths[column] = max(widths[column], width)
		}
	}
	minimum := padding * 2 + ui_frame_metrics(ctx.frame).FONT_SIZE_BODY * 2
	minimum = clamp(minimum, i32(1), max_width / i32(columns))
	for column in 0 ..< columns do widths[column] = max(widths[column], minimum)
	return widths, minimum
}

@(private = "file")
markdown_table_fix_columns :: proc(
	naturals: Markdown_Table_Widths,
	columns: int,
	max_width: i32,
	widths: ^Markdown_Table_Widths,
	fixed: ^[MARKDOWN_TABLE_COLS_MAX]bool,
) -> (
	i32,
	int,
) {
	assert(widths != nil, "markdown_table_fix_columns: nil widths")
	assert(fixed != nil, "markdown_table_fix_columns: nil fixed")
	remaining := max_width
	flexible := columns
	for _ in 0 ..< columns {
		changed := false
		share := remaining / i32(max(flexible, 1))
		for column in 0 ..< columns {
			if fixed[column] || naturals[column] > share do continue
			fixed[column] = true
			widths[column] = naturals[column]
			remaining -= naturals[column]
			flexible -= 1
			changed = true
		}
		if !changed || flexible == 0 do break
	}
	return remaining, flexible
}

@(private = "file")
markdown_table_distribute_columns :: proc(
	naturals: Markdown_Table_Widths,
	columns: int,
	minimum, remaining: i32,
	fixed: ^[MARKDOWN_TABLE_COLS_MAX]bool,
	widths: ^Markdown_Table_Widths,
) {
	assert(fixed != nil, "markdown_table_distribute_columns: nil fixed")
	assert(widths != nil, "markdown_table_distribute_columns: nil widths")
	flex_natural: i32
	for column in 0 ..< columns {
		if !fixed[column] do flex_natural += naturals[column]
	}
	left := remaining
	last := -1
	for column in 0 ..< columns {
		if fixed[column] do continue
		width := remaining * naturals[column] / max(flex_natural, 1)
		widths[column] = max(width, minimum)
		left -= widths[column]
		last = column
	}
	if last >= 0 && left > 0 do widths[last] += left
}

@(private = "file")
markdown_table_column_widths :: proc(
	naturals: Markdown_Table_Widths,
	columns: int,
	max_width, minimum: i32,
) -> (
	Markdown_Table_Widths,
	bool,
) {
	widths: Markdown_Table_Widths
	total: i32
	for column in 0 ..< columns do total += naturals[column]
	if total <= max_width {
		for column in 0 ..< columns do widths[column] = naturals[column]
		return widths, false
	}
	fixed: [MARKDOWN_TABLE_COLS_MAX]bool
	remaining, flexible := markdown_table_fix_columns(
		naturals,
		columns,
		max_width,
		&widths,
		&fixed,
	)
	if flexible > 0 {
		markdown_table_distribute_columns(naturals, columns, minimum, remaining, &fixed, &widths)
	}
	return widths, true
}

@(private = "file")
markdown_table_row_heights :: proc(
	ctx: ^Markdown_Context,
	rows: []Markdown_Table_Row,
	widths: Markdown_Table_Widths,
	columns: int,
) -> Markdown_Table_Heights {
	assert(ctx != nil, "markdown_table_row_heights: nil ctx")
	heights: Markdown_Table_Heights
	metrics := ui_frame_metrics(ctx.frame)
	for row, row_index in rows {
		height := i32(metrics.LINE_HEIGHT)
		for cell, column in row.cells {
			if column >= columns || len(cell) == 0 do continue
			inner := max(widths[column] - metrics.TABLE_CELL_PAD * 2, i32(1))
			cell_height := wrapped_height_px_frame(
				ctx.frame,
				cell,
				inner,
				metrics.FONT_SIZE_BODY,
				metrics.LINE_HEIGHT,
			)
			height = max(height, cell_height)
		}
		heights[row_index] = height
	}
	return heights
}

@(private = "file")
markdown_table_draw_cell :: proc(
	ctx: ^Markdown_Context,
	cell: string,
	x, y, width: i32,
	color: Color,
) {
	assert(ctx != nil, "markdown_table_draw_cell: nil ctx")
	metrics := ui_frame_metrics(ctx.frame)
	inner := max(width - metrics.TABLE_CELL_PAD * 2, i32(1))
	padding_y := max((i32(metrics.LINE_HEIGHT) - metrics.FONT_SIZE_BODY) / 2, i32(0))
	text_y := y + padding_y
	for line in wrap_text_frame(ctx.frame, cell, inner, metrics.FONT_SIZE_BODY) {
		if line.end > line.start {
			line_c := strings.clone_to_cstring(cell[line.start:line.end], context.temp_allocator)
			draw_text_frame(
				ctx.frame,
				line_c,
				x + metrics.TABLE_CELL_PAD,
				text_y,
				metrics.FONT_SIZE_BODY,
				color,
			)
		}
		text_y += i32(metrics.LINE_HEIGHT)
	}
}

@(private = "file")
markdown_table_draw_row :: proc(
	ctx: ^Markdown_Context,
	row: ^Markdown_Table_Row,
	row_index: int,
	x, y, height, table_width: i32,
	widths: Markdown_Table_Widths,
	columns: int,
	base_color: Color,
) {
	assert(ctx != nil, "markdown_table_draw_row: nil ctx")
	assert(row != nil, "markdown_table_draw_row: nil row")
	style := ui_frame_theme(ctx.frame)
	is_header := row_index == 0
	if is_header do draw_rectangle(ctx.frame, x, y, table_width, height, style.bg_table_header)
	cell_x := x
	for column in 0 ..< columns {
		if column > 0 do draw_rectangle(ctx.frame, cell_x, y, 1, height, style.border_color)
		if column < len(row.cells) && len(row.cells[column]) > 0 {
			color := style.fg_bold if is_header else base_color
			markdown_table_draw_cell(ctx, row.cells[column], cell_x, y, widths[column], color)
		}
		cell_x += widths[column]
	}
	if is_header do draw_rectangle(ctx.frame, x, y + height, table_width, 1, style.border_color)
}

@(private = "file")
markdown_table_hit_row :: proc(
	ctx: ^Markdown_Context,
	row: ^Markdown_Table_Row,
	x, y: i32,
	widths: Markdown_Table_Widths,
	columns: int,
	mouse_x, mouse_y: i32,
	block_start: int,
) -> int {
	assert(ctx != nil, "markdown_table_hit_row: nil ctx")
	assert(row != nil, "markdown_table_hit_row: nil row")
	column := columns - 1
	cell_x := x
	for candidate in 0 ..< columns {
		if mouse_x < cell_x + widths[candidate] {
			column = candidate
			break
		}
		cell_x += widths[candidate]
	}
	cell_x = x
	for candidate in 0 ..< column do cell_x += widths[candidate]
	if column >= len(row.cells) || len(row.cells[column]) == 0 do return block_start
	metrics := ui_frame_metrics(ctx.frame)
	inner := max(widths[column] - metrics.TABLE_CELL_PAD * 2, i32(1))
	padding_y := max((i32(metrics.LINE_HEIGHT) - metrics.FONT_SIZE_BODY) / 2, i32(0))
	local := hit_test_wrapped_frame(
		ctx.frame,
		cell_x + metrics.TABLE_CELL_PAD,
		y + padding_y,
		inner,
		row.cells[column],
		mouse_x,
		mouse_y,
		metrics.FONT_SIZE_BODY,
	)
	return row.starts[column] + max(local, 0)
}

@(private = "file")
markdown_table_total_width :: proc(widths: Markdown_Table_Widths, columns: int) -> i32 {
	total: i32
	for column in 0 ..< columns do total += widths[column]
	return total
}

layout_table :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	blk_start: int,
	base_color: Color,
	draw: bool,
	mouse_x: i32 = 0,
	mouse_y: i32 = 0,
	out_hit: ^int = nil,
	out_table_w: ^i32 = nil,
) -> (
	next: int,
	height: i32,
) {
	assert(blk_start >= 0 && blk_start <= len(text), "layout_table: blk_start out of bounds")
	assert(max_width > 0, "layout_table: non-positive max_width")
	rows, columns, next_byte := markdown_table_parse_rows(ctx, text, blk_start)
	if columns == 0 || len(rows) == 0 do return blk_start, 0
	naturals, minimum := markdown_table_natural_widths(ctx, rows[:], columns, max_width)
	widths, shrunk := markdown_table_column_widths(naturals, columns, max_width, minimum)
	table_width := markdown_table_total_width(widths, columns)
	if out_table_w != nil do out_table_w^ = max_width if shrunk else table_width
	heights := markdown_table_row_heights(ctx, rows[:], widths, columns)
	row_y := y
	for &row, row_index in rows {
		row_height := heights[row_index]
		if draw {
			markdown_table_draw_row(
				ctx,
				&row,
				row_index,
				x,
				row_y,
				row_height,
				table_width,
				widths,
				columns,
				base_color,
			)
		} else if out_hit != nil && mouse_y >= row_y && mouse_y < row_y + row_height {
			out_hit^ = markdown_table_hit_row(
				ctx,
				&row,
				x,
				row_y,
				widths,
				columns,
				mouse_x,
				mouse_y,
				blk_start,
			)
		}
		row_y += row_height
	}
	total_height := row_y - y + 1
	if draw {
		draw_rectangle_lines(
			ctx.frame,
			x,
			y,
			table_width,
			total_height,
			ui_frame_theme(ctx.frame).border_color,
		)
	}
	return next_byte, total_height + 4
}

// Get font size for a heading level.
heading_font_size :: proc(ctx: ^Markdown_Context, level: int) -> i32 {
	assert(ctx != nil, "heading_font_size: nil ctx")
	switch level {
	case 1:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_TITLE + 6 // 26
	case 2:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_TITLE + 2 // 22
	case:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_TITLE // 20
	}
}

// Get the wrapped line advance for a heading level.
//
// Why not LINE_HEIGHT: that metric is tuned for FONT_SIZE_BODY (22 for 16px).
// A level-1 heading is 26px, so body line height clips its descenders and packs
// multi-line headings tighter than body text. Scale the body ratio by the
// heading's own size, and never advance less than the glyphs occupy.
heading_line_height :: proc(ctx: ^Markdown_Context, level: int) -> i32 {
	assert(ctx != nil, "heading_line_height: nil ctx")
	metrics := ui_frame_metrics(ctx.frame)
	assert(metrics.FONT_SIZE_BODY > 0, "heading_line_height: invalid body metric")
	size := heading_font_size(ctx, level)
	height := (size * metrics.LINE_HEIGHT + metrics.FONT_SIZE_BODY / 2) / metrics.FONT_SIZE_BODY
	if height < size + 1 do height = size + 1
	assert(height > 0, "heading_line_height: non-positive height")
	return height
}

// Get total height consumed by a heading (wrapped text + padding + rule + margin).
heading_total_height :: proc(
	ctx: ^Markdown_Context,
	heading_text: string,
	level: int,
	max_width: i32,
) -> i32 {
	assert(ctx != nil, "heading_total_height: nil ctx")
	fs := heading_font_size(ctx, level)
	text_h := wrapped_height_px_frame(
		ctx.frame,
		heading_text,
		max_width,
		fs,
		heading_line_height(ctx, level),
	)
	if text_h == 0 do text_h = fs + 4
	h := text_h
	switch level {
	case 1:
		h += 1 + 8 // 1px rule + 8px margin
	case 2:
		h += 6 // 6px margin
	case:
		h += 4 // 4px margin
	}
	return h
}

// Measure the height that draw_text_wrapped would produce.
measure_wrapped_height :: proc(
	ctx: ^Markdown_Context,
	text: string,
	max_width: i32,
	font_size: i32,
) -> i32 {
	assert(ctx != nil, "measure_wrapped_height: nil ctx")
	return wrapped_height_px_frame(
		ctx.frame,
		text,
		max_width,
		font_size,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
	)
}

// Render a heading line with wrapping. Returns total height consumed.
draw_heading :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	level: int,
	text_byte_start, sel_start, sel_end: int,
	has_sel: bool,
	draw: bool = true,
) -> i32 {
	assert(ctx != nil, "draw_heading: nil ctx")
	font_size := heading_font_size(ctx, level)

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

	text_h := draw_text_wrapped_frame(
		ctx.frame,
		x,
		y,
		max_width,
		text,
		ui_frame_theme(ctx.frame).fg_heading,
		font_size,
		heading_line_height(ctx, level),
		sub_sel_s,
		sub_sel_e,
		draw,
	)
	if text_h == 0 do text_h = font_size + 4

	total_h := text_h

	if level == 1 {
		if draw {
			draw_rectangle(
				ctx.frame,
				x,
				y + total_h,
				max_width,
				1,
				ui_frame_theme(ctx.frame).border_color,
			)
		}
		total_h += 1
	}

	switch level {
	case 1:
		total_h += 8
	case 2:
		total_h += 6
	case:
		total_h += 4
	}

	return total_h
}

draw_markdown_context :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	base_color: Color,
	sel_start: int = -1,
	sel_end: int = -1,
	out_w: ^i32 = nil,
	draw: bool = true,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil, "draw_markdown_context: invalid context")
	return markdown_draw(ctx, {x, y, max_width, 0}, text, base_color, sel_start, sel_end, out_w, draw)
}

hit_test_markdown_context :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil && ctx.frame != nil, "hit_test_markdown_context: invalid context")
	return hit_test_markdown(ctx, x, y, max_width, text, mouse_x, mouse_y)
}

measure_markdown_context :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	out_w: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil, "measure_markdown_context: invalid context")
	return draw_markdown_context(
		ctx,
		0,
		0,
		width,
		text,
		ui_frame_theme(ctx.frame).fg_assistant,
		out_w = out_w,
		draw = false,
	)
}

@(private = "file")
Markdown_Draw_State :: struct {
	ctx:           ^Markdown_Context,
	text:          string,
	base_color:    Color,
	x:             i32,
	current_y:     i32,
	max_width:     i32,
	sel_start:     int,
	sel_end:       int,
	max_w:         i32,
	in_code_block: bool,
	has_sel:       bool,
	draw:          bool,
}

@(private = "file")
markdown_selection :: proc(state: ^Markdown_Draw_State, start, end: int) -> (int, int) {
	assert(state != nil, "markdown_selection: nil state")
	assert(start >= 0 && end >= start, "markdown_selection: invalid range")
	if !state.has_sel do return -1, -1
	overlap_start := max(state.sel_start, start)
	overlap_end := min(state.sel_end, end)
	if overlap_start >= overlap_end do return -1, -1
	return overlap_start - start, overlap_end - start
}

@(private = "file")
markdown_draw_fence :: proc(state: ^Markdown_Draw_State, line: string) -> bool {
	assert(state != nil, "markdown_draw_fence: nil state")
	if !is_code_fence(line) do return false
	if !state.in_code_block {
		state.in_code_block = true
		if state.draw {
			draw_rectangle(
				state.ctx.frame,
				state.x,
				state.current_y + 2,
				state.max_width,
				1,
				ui_frame_theme(state.ctx.frame).border_color,
			)
		}
		state.current_y += 6
	} else {
		state.in_code_block = false
		if state.draw {
			draw_rectangle(
				state.ctx.frame,
				state.x,
				state.current_y,
				state.max_width,
				1,
				ui_frame_theme(state.ctx.frame).border_color,
			)
		}
		state.current_y += 8
	}
	return true
}

@(private = "file")
markdown_draw_code_text :: proc(state: ^Markdown_Draw_State, line: string, line_start: int) {
	assert(state != nil, "markdown_draw_code_text: nil state")
	display_line := truncate_to_width_frame(
		state.ctx.frame,
		line,
		state.max_width - ui_frame_metrics(state.ctx.frame).CODE_BLOCK_PAD * 2,
		ui_frame_metrics(state.ctx.frame).FONT_SIZE_BODY,
	)
	if state.has_sel {
		draw_line_with_selection_frame(
			state.ctx.frame,
			state.x + ui_frame_metrics(state.ctx.frame).CODE_BLOCK_PAD,
			state.current_y,
			display_line,
			ui_frame_metrics(state.ctx.frame).FONT_SIZE_BODY,
			ui_frame_metrics(state.ctx.frame).LINE_HEIGHT,
			ui_frame_theme(state.ctx.frame).fg_primary,
			line_start,
			state.sel_start,
			state.sel_end,
		)
	} else {
		line_c := strings.clone_to_cstring(display_line, context.temp_allocator)
		draw_text_frame(
			state.ctx.frame,
			line_c,
			state.x + ui_frame_metrics(state.ctx.frame).CODE_BLOCK_PAD,
			state.current_y,
			ui_frame_metrics(state.ctx.frame).FONT_SIZE_BODY,
			ui_frame_theme(state.ctx.frame).fg_primary,
		)
	}
}

@(private = "file")
markdown_draw_code_line :: proc(state: ^Markdown_Draw_State, line: string, line_start: int) {
	assert(state != nil, "markdown_draw_code_line: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	if state.draw && !markdown_line_culled(state.ctx, state.current_y, metrics.LINE_HEIGHT) {
		draw_rectangle(
			state.ctx.frame,
			state.x,
			state.current_y,
			state.max_width,
			metrics.LINE_HEIGHT,
			ui_frame_theme(state.ctx.frame).bg_code,
		)
		draw_rectangle(
			state.ctx.frame,
			state.x,
			state.current_y,
			2,
			metrics.LINE_HEIGHT,
			ui_frame_theme(state.ctx.frame).border_subtle,
		)
		markdown_draw_code_text(state, line, line_start)
	}
	line_c := strings.clone_to_cstring(line, context.temp_allocator)
	width :=
		min(
			measure_text_frame(state.ctx.frame, line_c, metrics.FONT_SIZE_BODY),
			state.max_width - metrics.CODE_BLOCK_PAD * 2,
		) +
		metrics.CODE_BLOCK_PAD * 2
	state.max_w = max(state.max_w, width)
	state.current_y += metrics.LINE_HEIGHT
}

@(private = "file")
markdown_draw_heading_line :: proc(
	state: ^Markdown_Draw_State,
	line: string,
	line_start, level: int,
) {
	assert(state != nil, "markdown_draw_heading_line: nil state")
	assert(level >= 1 && level <= 3, "markdown_draw_heading_line: invalid level")
	prefix_length := level + 1
	content := line[prefix_length:]
	state.current_y += draw_heading(
		state.ctx,
		state.x,
		state.current_y,
		state.max_width,
		content,
		level,
		line_start + prefix_length,
		state.sel_start,
		state.sel_end,
		state.has_sel,
		state.draw,
	)
	// Why heading_font_size: this used to re-derive the size by hand as TITLE
	// (or BODY for level 3), which is not what draw_heading paints (26/22/20).
	// Every heading was measured narrower than it renders, so both the wrap
	// decision and the reported content width were wrong.
	font_size := heading_font_size(state.ctx, level)
	width := wrapped_max_line_width_frame(state.ctx.frame, content, state.max_width, font_size)
	state.max_w = max(state.max_w, width)
}

@(private = "file")
markdown_draw_bullet_line :: proc(state: ^Markdown_Draw_State, line: string, line_start: int) {
	assert(state != nil, "markdown_draw_bullet_line: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	if state.draw {
		draw_circle(
			state.ctx.frame,
			state.x + 8,
			state.current_y + metrics.FONT_SIZE_BODY / 2 + 1,
			2.5,
			ui_frame_theme(state.ctx.frame).fg_bullet,
		)
	}
	content := line[2:]
	content_x := state.x + metrics.BULLET_INDENT
	content_width := state.max_width - metrics.BULLET_INDENT
	sel_start, sel_end := markdown_selection(state, line_start + 2, line_start + len(line))
	height := draw_text_wrapped_md(
		state.ctx,
		content_x,
		state.current_y,
		content_width,
		content,
		state.base_color,
		metrics.FONT_SIZE_BODY,
		sel_start,
		sel_end,
		state.draw,
	)
	if height == 0 do height = metrics.LINE_HEIGHT
	state.current_y += height
	width :=
		metrics.BULLET_INDENT +
		wrapped_max_line_width_md_frame(
			state.ctx.frame,
			content,
			content_width,
			metrics.FONT_SIZE_BODY,
		)
	state.max_w = max(state.max_w, width)
}

@(private = "file")
markdown_draw_table_line :: proc(
	state: ^Markdown_Draw_State,
	line: string,
	line_start, line_end: int,
) -> (
	next: int,
	handled: bool,
) {
	assert(state != nil, "markdown_draw_table_line: nil state")
	if line_end == len(state.text) || !strings.contains(line, "|") do return 0, false
	newline := strings.index_byte(state.text[line_end + 1:], '\n')
	next_end := len(state.text) if newline < 0 else line_end + 1 + newline
	next_line := state.text[line_end + 1:next_end]
	if !strings.contains(next_line, "|") || !is_table_separator(next_line) {
		return 0, false
	}
	table_width: i32
	next_byte, height := layout_table(
		state.ctx,
		state.x,
		state.current_y,
		state.max_width,
		state.text,
		line_start,
		state.base_color,
		state.draw,
		out_table_w = &table_width,
	)
	state.current_y += height
	state.max_w = max(state.max_w, table_width)
	return next_byte, true
}

@(private = "file")
markdown_draw_plain_line :: proc(state: ^Markdown_Draw_State, line: string, line_start: int) {
	assert(state != nil, "markdown_draw_plain_line: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	sel_start, sel_end := markdown_selection(state, line_start, line_start + len(line))
	state.current_y += draw_text_wrapped_md(
		state.ctx,
		state.x,
		state.current_y,
		state.max_width,
		line,
		state.base_color,
		metrics.FONT_SIZE_BODY,
		sel_start,
		sel_end,
		state.draw,
	)
	width := wrapped_max_line_width_md_frame(
		state.ctx.frame,
		line,
		state.max_width,
		metrics.FONT_SIZE_BODY,
	)
	state.max_w = max(state.max_w, width)
}

@(private = "file")
markdown_draw_line :: proc(
	state: ^Markdown_Draw_State,
	line: string,
	line_start, line_end: int,
) -> (
	next: int,
	handled: bool,
) {
	assert(state != nil, "markdown_draw_line: nil state")
	assert(line_start >= 0, "markdown_draw_line: negative line start")
	if markdown_draw_fence(state, line) do return 0, false
	if state.in_code_block {
		markdown_draw_code_line(state, line, line_start)
		return 0, false
	}
	if heading, ok := match_heading(line); ok {
		markdown_draw_heading_line(state, line, line_start, heading.level)
		return 0, false
	}
	if len(line) >= 2 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ' {
		markdown_draw_bullet_line(state, line, line_start)
		return 0, false
	}
	if next, handled = markdown_draw_table_line(state, line, line_start, line_end); handled {
		return next, true
	}
	if len(line) == 0 {
		state.current_y += ui_frame_metrics(state.ctx.frame).LINE_HEIGHT / 2
		return 0, false
	}
	markdown_draw_plain_line(state, line, line_start)
	return 0, false
}

// markdown_draw renders markdown with optional selection highlighting. Bounds
// are physical: x/y are the origin and w is the wrapping width. Height is not
// a clip; the returned content height may exceed bounds.h.
markdown_draw :: proc(
	ctx: ^Markdown_Context,
	bounds: Rect_I32,
	text: string,
	base_color: Color,
	sel_start: int = -1,
	sel_end: int = -1,
	out_w: ^i32 = nil,
	draw: bool = true,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil, "markdown_draw: invalid context")
	assert(bounds.w > 0, "markdown_draw: non-positive width")
	x, y, max_width := bounds.x, bounds.y, bounds.w
	assert(
		sel_start < 0 || sel_end < 0 || sel_start <= sel_end,
		"draw_markdown: inverted selection",
	)
	if len(text) == 0 do return 0
	state := Markdown_Draw_State {
		ctx        = ctx,
		text       = text,
		base_color = base_color,
		x          = x,
		current_y  = y,
		max_width  = max_width,
		sel_start  = sel_start,
		sel_end    = sel_end,
		has_sel    = sel_start >= 0 && sel_end > sel_start,
		draw       = draw,
	}
	line_start := 0
	for i := 0; i <= len(text); i += 1 {
		is_end := i == len(text)
		if !is_end && text[i] != '\n' do continue
		if is_end && line_start >= len(text) do break
		line := text[line_start:i]
		if next, handled := markdown_draw_line(&state, line, line_start, i); handled {
			assert(next > line_start, "draw_markdown: table made no progress")
			line_start = next
			i = next - 1
			continue
		}
		line_start = i + 1
	}
	if out_w != nil do out_w^ = state.max_w
	return state.current_y - y
}

// measure_markdown returns the pixel height draw_markdown would produce for
// `text` at `width`, without any visible output. It calls draw_markdown inside a
// zero-size scissor so all raylib draws are clipped (cheap, invisible) while the
// identical layout math runs — guaranteeing the scroll predictor matches what is
// actually rendered. draw_markdown performs no input handling, so re-running it
// here is side-effect free.
measure_markdown :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	out_w: ^i32 = nil,
) -> i32 {
	assert(ctx != nil, "measure_markdown: nil ctx")
	assert(out_w != nil, "measure_markdown: nil out_w")
	if len(text) == 0 do return 0
	// draw=false runs the identical layout math but emits no glyph quads.
	h := markdown_draw(
		ctx,
		{0, 0, width, 0},
		text,
		ui_frame_theme(ctx.frame).fg_assistant,
		-1,
		-1,
		out_w,
		false,
	)
	return h
}
@(private = "file")
Markdown_Hit_State :: struct {
	ctx:           ^Markdown_Context,
	text:          string,
	x, current_y:  i32,
	max_width:     i32,
	mouse_x:       i32,
	mouse_y:       i32,
	in_code_block: bool,
}

@(private = "file")
markdown_hit_fence :: proc(
	state: ^Markdown_Hit_State,
	line: string,
	line_start: int,
) -> (
	int,
	bool,
) {
	assert(state != nil, "markdown_hit_fence: nil state")
	if !is_code_fence(line) do return -1, false
	gap: i32 = 6
	if state.in_code_block do gap = 8
	state.in_code_block = !state.in_code_block
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + gap {
		return line_start, true
	}
	state.current_y += gap
	return -1, true
}

@(private = "file")
markdown_hit_code :: proc(state: ^Markdown_Hit_State, line: string, line_start: int) -> int {
	assert(state != nil, "markdown_hit_code: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + metrics.LINE_HEIGHT {
		column := caret_pixel_to_col_with(
			ui_frame_text(state.ctx.frame),
			line,
			state.mouse_x - (state.x + metrics.CODE_BLOCK_PAD),
			metrics.FONT_SIZE_BODY,
		)
		return line_start + caret_col_to_byte(line, column)
	}
	state.current_y += metrics.LINE_HEIGHT
	return -1
}

@(private = "file")
markdown_hit_heading :: proc(
	state: ^Markdown_Hit_State,
	heading: Heading_Match,
	line_start: int,
) -> int {
	assert(state != nil, "markdown_hit_heading: nil state")
	height := heading_total_height(state.ctx, heading.text, heading.level, state.max_width)
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + height {
		offset := hit_test_wrapped_frame(
			state.ctx.frame,
			state.x,
			state.current_y,
			state.max_width,
			heading.text,
			state.mouse_x,
			state.mouse_y,
			heading_font_size(state.ctx, heading.level),
		)
		if offset < 0 do offset = len(heading.text)
		return line_start + heading.prefix_len + offset
	}
	state.current_y += height
	return -1
}

@(private = "file")
markdown_hit_bullet :: proc(state: ^Markdown_Hit_State, line: string, line_start: int) -> int {
	assert(state != nil, "markdown_hit_bullet: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	content := line[2:]
	content_x := state.x + metrics.BULLET_INDENT
	content_width := state.max_width - metrics.BULLET_INDENT
	height := measure_wrapped_height_md(state.ctx, content, content_width, metrics.FONT_SIZE_BODY)
	if height == 0 do height = metrics.LINE_HEIGHT
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + height {
		offset := hit_test_wrapped_md(
			state.ctx,
			content_x,
			state.current_y,
			content_width,
			content,
			state.mouse_x,
			state.mouse_y,
			metrics.FONT_SIZE_BODY,
		)
		if offset < 0 do offset = 0
		return line_start + 2 + offset
	}
	state.current_y += height
	return -1
}

@(private = "file")
markdown_hit_table :: proc(
	state: ^Markdown_Hit_State,
	line: string,
	line_start, line_end: int,
) -> (
	int,
	int,
	bool,
) {
	assert(state != nil, "markdown_hit_table: nil state")
	if line_end == len(state.text) || !strings.contains(line, "|") do return -1, 0, false
	newline := strings.index_byte(state.text[line_end + 1:], '\n')
	next_end := len(state.text) if newline < 0 else line_end + 1 + newline
	next_line := state.text[line_end + 1:next_end]
	if !strings.contains(next_line, "|") || !is_table_separator(next_line) {
		return -1, 0, false
	}
	offset := -1
	next_byte, height := layout_table(
		state.ctx,
		state.x,
		state.current_y,
		state.max_width,
		state.text,
		line_start,
		ui_frame_theme(state.ctx.frame).fg_primary,
		false,
		state.mouse_x,
		state.mouse_y,
		&offset,
	)
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + height {
		if offset < 0 do offset = line_start
		return offset, next_byte, true
	}
	state.current_y += height
	return -1, next_byte, true
}

@(private = "file")
markdown_hit_plain :: proc(state: ^Markdown_Hit_State, line: string, line_start: int) -> int {
	assert(state != nil, "markdown_hit_plain: nil state")
	metrics := ui_frame_metrics(state.ctx.frame)
	if len(line) == 0 {
		gap: i32 = metrics.LINE_HEIGHT / 2
		if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + gap {
			return line_start
		}
		state.current_y += gap
		return -1
	}
	height := measure_wrapped_height_md(state.ctx, line, state.max_width, metrics.FONT_SIZE_BODY)
	if state.mouse_y >= state.current_y && state.mouse_y < state.current_y + height {
		offset := hit_test_wrapped_md(
			state.ctx,
			state.x,
			state.current_y,
			state.max_width,
			line,
			state.mouse_x,
			state.mouse_y,
			metrics.FONT_SIZE_BODY,
		)
		if offset >= 0 do return line_start + offset
	}
	state.current_y += height
	return -1
}

@(private = "file")
markdown_hit_line :: proc(
	state: ^Markdown_Hit_State,
	line: string,
	line_start, line_end: int,
) -> (
	int,
	int,
	bool,
) {
	assert(state != nil, "markdown_hit_line: nil state")
	if result, handled := markdown_hit_fence(state, line, line_start); handled {
		return result, 0, false
	}
	if state.in_code_block do return markdown_hit_code(state, line, line_start), 0, false
	if heading, ok := match_heading(line); ok {
		return markdown_hit_heading(state, heading, line_start), 0, false
	}
	if len(line) >= 2 && (line[0] == '-' || line[0] == '*' || line[0] == '+') && line[1] == ' ' {
		return markdown_hit_bullet(state, line, line_start), 0, false
	}
	if result, next, table := markdown_hit_table(state, line, line_start, line_end); table {
		return result, next, true
	}
	return markdown_hit_plain(state, line, line_start), 0, false
}

// Mirrors draw_markdown layout exactly.
hit_test_markdown :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil, "hit_test_markdown: nil ctx")
	assert(max_width > 0, "hit_test_markdown: non-positive max_width")
	assert(x >= min(i32) / 2 && y >= min(i32) / 2, "hit_test_markdown: origin overflow risk")
	if len(text) == 0 || mouse_y < y do return -1
	state := Markdown_Hit_State {
		ctx       = ctx,
		text      = text,
		x         = x,
		current_y = y,
		max_width = max_width,
		mouse_x   = mouse_x,
		mouse_y   = mouse_y,
	}
	line_start := 0
	for index := 0; index <= len(text); index += 1 {
		is_end := index == len(text)
		if !is_end && text[index] != '\n' do continue
		if is_end && line_start >= len(text) do break
		result, next, skipped := markdown_hit_line(
			&state,
			text[line_start:index],
			line_start,
			index,
		)
		if result >= 0 do return result
		if skipped {
			assert(next > line_start, "hit_test_markdown: table made no progress")
			line_start = next
			index = next - 1
			continue
		}
		line_start = index + 1
	}
	if mouse_y >= state.current_y &&
	   mouse_y < state.current_y + ui_frame_metrics(ctx.frame).LINE_HEIGHT {
		return len(text)
	}
	return -1
}
