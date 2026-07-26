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
	if !has_selection || selection_start >= selection_end do return
	highlight_start := max(selection_start, segment_start)
	highlight_end := min(selection_end, segment_end)
	if highlight_start >= highlight_end do return
	pre := strings.clone_to_cstring(text[:highlight_start - segment_start], context.temp_allocator)
	selected := strings.clone_to_cstring(
		text[highlight_start - segment_start:highlight_end - segment_start], context.temp_allocator,
	)
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE
	highlight_x := cursor_x + measure_text_frame(ctx.frame, pre, font_size)
	highlight_w := measure_text_frame(ctx.frame, selected, font_size)
	draw_rectangle(
		ctx.frame, highlight_x, y, highlight_w,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT, ui_frame_theme(ctx.frame).bg_selection,
	)
}

@(private = "file")
draw_markdown_span_chip :: proc(ctx: ^Markdown_Context, text: cstring, x, y: i32) {
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE
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
	if workspace_has_path_with(ctx.workspace_files, span.text) {
		draw_markdown_span_chip(ctx, text, x, y)
		return
	}
	draw_text_frame(
		ctx.frame, text, x, y, ui_frame_metrics(ctx.frame).FONT_SIZE,
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
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE
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
			ctx, cursor_x, y, segment, segment_start, segment_end,
			sel_display_start, sel_display_end, has_sel,
		)
		draw_markdown_span_style(ctx, &span, segment_c, cursor_x, y, base_color)
		cursor_x += measure_text_frame(
			ctx.frame, segment_c, ui_frame_metrics(ctx.frame).FONT_SIZE,
		) + 1
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
	cells, starts := split_table_row_offsets_with(
		text,
		line_start,
		line_end,
		ui_frame_allocator(frame),
	)
	return frame_view(frame, cells), frame_view(frame, starts)
}

// Parse, lay out, and (when draw==true) render a GFM table block beginning at
// source byte `blk_start` (start of the header line). Returns the byte index just
// past the block and the pixel height consumed. The `draw` flag gates raylib draw
// calls so the same routine measures/hit-tests; both paths compute identical
// heights so scroll/selection stay in sync. When draw==false and out_hit != nil,
// out_hit is set to a source byte offset if the mouse falls inside the table.
// When out_table_w != nil it receives the rendered table width in pixels.
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
	// Why assert: blk_start must reference a real line start inside text or
	// every row scan below slices out of bounds.
	assert(blk_start >= 0 && blk_start <= len(text), "layout_table: blk_start out of bounds")
	assert(max_width > 0, "layout_table: non-positive max_width")
	Row :: struct {
		cells:  []string,
		starts: []int,
	}
	rows := make([dynamic]Row, 0, 8, ui_frame_allocator(ctx.frame))
	cols := 0

	pos := blk_start
	phys := 0
	next_byte := blk_start
	for pos < len(text) && len(rows) < MARKDOWN_TABLE_ROWS_MAX {
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
		cells_view, starts_view := split_table_row_offsets(ctx.frame, text, pos, line_end)
		cells := frame_view_items(ctx.frame, cells_view)
		starts := frame_view_items(ctx.frame, starts_view)
		append(&rows, Row{cells = cells, starts = starts})
		if len(cells) > cols do cols = min(len(cells), MARKDOWN_TABLE_COLS_MAX)
		phys += 1
		next_byte = advance
		pos = advance
	}

	if cols == 0 || len(rows) == 0 {
		return blk_start, 0
	}

	pad := ui_frame_metrics(ctx.frame).TABLE_CELL_PAD
	// Natural width per column: widest cell plus horizontal padding.
	naturals: [MARKDOWN_TABLE_COLS_MAX]i32
	for row in rows {
		for cell, ci in row.cells {
			if len(cell) == 0 do continue
			cell_c := strings.clone_to_cstring(cell, ui_frame_allocator(ctx.frame))
			w :=
				measure_text_frame(ctx.frame, cell_c, ui_frame_metrics(ctx.frame).FONT_SIZE) +
				pad * 2
			if w > naturals[ci] do naturals[ci] = w
		}
	}
	fair := max_width / i32(cols)
	min_w := pad * 2 + ui_frame_metrics(ctx.frame).FONT_SIZE * 2
	if min_w > fair do min_w = fair
	if min_w < 1 do min_w = 1
	for ci in 0 ..< cols {
		if naturals[ci] < min_w do naturals[ci] = min_w
	}

	col_widths: [MARKDOWN_TABLE_COLS_MAX]i32
	natural_total: i32 = 0
	for ci in 0 ..< cols do natural_total += naturals[ci]

	shrunk := natural_total > max_width
	if !shrunk {
		// Everything fits at natural width — table may be narrower than max_width.
		copy(col_widths[:cols], naturals[:cols])
	} else {
		// Columns at/below their fair share keep natural width; wide columns
		// split the remaining space proportionally to their natural widths.
		// Fixing a column changes the fair share of the rest, so iterate.
		fixed: [MARKDOWN_TABLE_COLS_MAX]bool
		remaining := max_width
		flex := cols
		changed := false
		for _ in 0 ..< cols {
			changed = false
			share := remaining / i32(max(flex, 1))
			for ci in 0 ..< cols {
				if fixed[ci] do continue
				if naturals[ci] <= share {
					fixed[ci] = true
					col_widths[ci] = naturals[ci]
					remaining -= naturals[ci]
					flex -= 1
					changed = true
				}
			}
			if !changed || flex == 0 do break
		}
		assert(flex == 0 || !changed)
		if flex > 0 {
			flex_natural: i32 = 0
			for ci in 0 ..< cols {
				if !fixed[ci] do flex_natural += naturals[ci]
			}
			left := remaining
			last := -1
			for ci in 0 ..< cols {
				if fixed[ci] do continue
				w := remaining * naturals[ci] / max(flex_natural, 1)
				if w < min_w do w = min_w
				col_widths[ci] = w
				left -= w
				last = ci
			}
			// Give rounding leftovers to the last flexible column.
			if last >= 0 && left > 0 do col_widths[last] += left
		}
	}

	table_w: i32 = 0
	for ci in 0 ..< cols do table_w += col_widths[ci]
	if out_table_w != nil {
		// When columns were shrunk the layout depends on max_width; report
		// max_width so re-layout at the reported width is identical.
		out_table_w^ = max_width if shrunk else table_w
	}

	// Per-row height: tallest wrapped cell (min one line).
	row_heights: [MARKDOWN_TABLE_ROWS_MAX]i32
	for row, ri in rows {
		h := i32(ui_frame_metrics(ctx.frame).LINE_HEIGHT)
		for cell, ci in row.cells {
			if ci >= cols || len(cell) == 0 do continue
			inner := col_widths[ci] - pad * 2
			if inner < 1 do inner = 1
			ch := wrapped_height_px_frame(
				ctx.frame,
				cell,
				inner,
				ui_frame_metrics(ctx.frame).FONT_SIZE,
				ui_frame_metrics(ctx.frame).LINE_HEIGHT,
			)
			if ch > h do h = ch
		}
		row_heights[ri] = h
	}

	cell_pad_y :=
		(i32(ui_frame_metrics(ctx.frame).LINE_HEIGHT) - ui_frame_metrics(ctx.frame).FONT_SIZE) / 2
	if cell_pad_y < 0 do cell_pad_y = 0

	row_y := y
	for row, ri in rows {
		row_h := row_heights[ri]
		is_header := ri == 0

		if draw {
			if is_header {
				draw_rectangle(
					ctx.frame,
					x,
					row_y,
					table_w,
					row_h,
					ui_frame_theme(ctx.frame).bg_table_header,
				)
			}
			cell_x := x
			for ci in 0 ..< cols {
				if ci > 0 {
					draw_rectangle(
						ctx.frame,
						cell_x,
						row_y,
						1,
						row_h,
						ui_frame_theme(ctx.frame).border_color,
					)
				}
				if ci < len(row.cells) && len(row.cells[ci]) > 0 {
					cell := row.cells[ci]
					cell_color := ui_frame_theme(ctx.frame).fg_bold if is_header else base_color
					inner := col_widths[ci] - pad * 2
					if inner < 1 do inner = 1
					ty := row_y + cell_pad_y
					for ln in wrap_text_frame(
						ctx.frame,
						cell,
						inner,
						ui_frame_metrics(ctx.frame).FONT_SIZE,
					) {
						if ln.end > ln.start {
							line_c := strings.clone_to_cstring(
								cell[ln.start:ln.end],
								context.temp_allocator,
							)
							draw_text_frame(
								ctx.frame,
								line_c,
								cell_x + pad,
								ty,
								ui_frame_metrics(ctx.frame).FONT_SIZE,
								cell_color,
							)
						}
						ty += i32(ui_frame_metrics(ctx.frame).LINE_HEIGHT)
					}
				}
				cell_x += col_widths[ci]
			}
			if is_header {
				draw_rectangle(
					ctx.frame,
					x,
					row_y + row_h,
					table_w,
					1,
					ui_frame_theme(ctx.frame).border_color,
				)
			}
		} else if out_hit != nil && mouse_y >= row_y && mouse_y < row_y + row_h {
			// Find the column under the mouse by walking the variable widths.
			ci := cols - 1
			cx := x
			for c in 0 ..< cols {
				if mouse_x < cx + col_widths[c] {
					ci = c
					break
				}
				cx += col_widths[c]
			}
			cell_x := x
			for c in 0 ..< ci do cell_x += col_widths[c]
			if ci < len(row.cells) && len(row.cells[ci]) > 0 {
				inner := col_widths[ci] - pad * 2
				if inner < 1 do inner = 1
				local := hit_test_wrapped_frame(
					ctx.frame,
					cell_x + pad,
					row_y + cell_pad_y,
					inner,
					row.cells[ci],
					mouse_x,
					mouse_y,
					ui_frame_metrics(ctx.frame).FONT_SIZE,
				)
				if local < 0 do local = 0
				out_hit^ = row.starts[ci] + local
			} else {
				out_hit^ = blk_start
			}
		}
		row_y += row_h
	}

	total_h := row_y - y + 1 // +1 for header separator rule
	if draw {
		draw_rectangle_lines(
			ctx.frame,
			x,
			y,
			table_w,
			total_h,
			ui_frame_theme(ctx.frame).border_color,
		)
	}
	total_h += 4 // bottom margin

	return next_byte, total_h
}

// Get font size for a heading level.
heading_font_size :: proc(ctx: ^Markdown_Context, level: int) -> i32 {
	switch level {
	case 1:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_LARGE + 6 // 26
	case 2:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_LARGE + 2 // 22
	case:
		return ui_frame_metrics(ctx.frame).FONT_SIZE_LARGE // 20
	}
}

// Get total height consumed by a heading (wrapped text + padding + rule + margin).
heading_total_height :: proc(
	ctx: ^Markdown_Context,
	heading_text: string,
	level: int,
	max_width: i32,
) -> i32 {
	fs := heading_font_size(ctx, level)
	text_h := wrapped_height_px_frame(
		ctx.frame,
		heading_text,
		max_width,
		fs,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
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
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
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
	return draw_markdown(ctx, x, y, max_width, text, base_color, sel_start, sel_end, out_w, draw)
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
		ui_frame_metrics(state.ctx.frame).FONT_SIZE,
	)
	if state.has_sel {
		draw_line_with_selection_frame(
			state.ctx.frame,
			state.x + ui_frame_metrics(state.ctx.frame).CODE_BLOCK_PAD,
			state.current_y,
			display_line,
			ui_frame_metrics(state.ctx.frame).FONT_SIZE,
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
			ui_frame_metrics(state.ctx.frame).FONT_SIZE,
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
			measure_text_frame(state.ctx.frame, line_c, metrics.FONT_SIZE),
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
	font_size := ui_frame_metrics(state.ctx.frame).FONT_SIZE_LARGE
	if level == 3 do font_size = ui_frame_metrics(state.ctx.frame).FONT_SIZE
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
			state.current_y + metrics.FONT_SIZE / 2 + 1,
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
		metrics.FONT_SIZE,
		sel_start,
		sel_end,
		state.draw,
	)
	if height == 0 do height = metrics.LINE_HEIGHT
	state.current_y += height
	width :=
		metrics.BULLET_INDENT +
		wrapped_max_line_width_md_frame(state.ctx.frame, content, content_width, metrics.FONT_SIZE)
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
		metrics.FONT_SIZE,
		sel_start,
		sel_end,
		state.draw,
	)
	width := wrapped_max_line_width_md_frame(
		state.ctx.frame,
		line,
		state.max_width,
		metrics.FONT_SIZE,
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

// Render markdown-formatted text with optional selection highlighting.
// Supports: # headings (H1-H3), - * + bullets, ``` fenced code blocks.
// Returns the total height drawn.
draw_markdown :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	base_color: Color,
	sel_start: int = -1,
	sel_end: int = -1,
	out_w: ^i32 = nil,
	draw: bool = true,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil, "draw_markdown: invalid context")
	assert(max_width > 0, "draw_markdown: non-positive max_width")
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
	if len(text) == 0 do return 0
	// draw=false runs the identical layout math but emits no glyph quads.
	h := draw_markdown(
		ctx,
		0,
		0,
		width,
		text,
		ui_frame_theme(ctx.frame).fg_assistant,
		-1,
		-1,
		out_w,
		false,
	)
	return h
}
// Mirrors draw_markdown layout exactly.
// Returns valid byte offsets for all positions within the content area, including
// empty-line gaps, code fence margins, heading/bullet margins, and past-end areas.
hit_test_markdown :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	// Why assert: layout must mirror draw_markdown exactly, so it shares the
	// same argument contract (positive wrap width).
	assert(max_width > 0, "hit_test_markdown: non-positive max_width")
	assert(x >= min(i32) / 2 && y >= min(i32) / 2, "hit_test_markdown: origin overflow risk")
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
			if mouse_y >= current_y &&
			   mouse_y < current_y + ui_frame_metrics(ctx.frame).LINE_HEIGHT {
				col := caret_pixel_to_col_with(
					ui_frame_text(ctx.frame),
					line,
					mouse_x - (x + ui_frame_metrics(ctx.frame).CODE_BLOCK_PAD),
					ui_frame_metrics(ctx.frame).FONT_SIZE,
				)
				return line_start + caret_col_to_byte(line, col)
			}
			current_y += ui_frame_metrics(ctx.frame).LINE_HEIGHT
			line_start = i + 1
			continue
		}

		// H3 heading.
		if heading, ok := match_heading(line); ok && heading.level == 3 {
			heading_text := line[4:]
			h := heading_total_height(ctx, heading_text, 3, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(ctx, 3)
				offset := hit_test_wrapped_frame(
					ctx.frame,
					x,
					current_y,
					max_width,
					heading_text,
					mouse_x,
					mouse_y,
					fs,
				)
				if offset >= 0 do return line_start + 4 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 4 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}
		// H2 heading.
		if heading, ok := match_heading(line); ok && heading.level == 2 {
			heading_text := line[3:]
			h := heading_total_height(ctx, heading_text, 2, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(ctx, 2)
				offset := hit_test_wrapped_frame(
					ctx.frame,
					x,
					current_y,
					max_width,
					heading_text,
					mouse_x,
					mouse_y,
					fs,
				)
				if offset >= 0 do return line_start + 3 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 3 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}
		// H1 heading.
		if heading, ok := match_heading(line); ok && heading.level == 1 {
			heading_text := line[2:]
			h := heading_total_height(ctx, heading_text, 1, max_width)
			if mouse_y >= current_y && mouse_y < current_y + h {
				fs := heading_font_size(ctx, 1)
				offset := hit_test_wrapped_frame(
					ctx.frame,
					x,
					current_y,
					max_width,
					heading_text,
					mouse_x,
					mouse_y,
					fs,
				)
				if offset >= 0 do return line_start + 2 + offset
				// Mouse is in heading margin area — snap to end of heading text.
				return line_start + 2 + len(heading_text)
			}
			current_y += h
			line_start = i + 1
			continue
		}

		// Bullet point.
		if len(line) >= 2 &&
		   (line[0] == '-' || line[0] == '*' || line[0] == '+') &&
		   line[1] == ' ' {
			content := line[2:]
			content_x := x + ui_frame_metrics(ctx.frame).BULLET_INDENT
			content_width := max_width - ui_frame_metrics(ctx.frame).BULLET_INDENT
			h := measure_wrapped_height_md(
				ctx,
				content,
				content_width,
				ui_frame_metrics(ctx.frame).FONT_SIZE,
			)
			if h == 0 do h = ui_frame_metrics(ctx.frame).LINE_HEIGHT

			if mouse_y >= current_y && mouse_y < current_y + h {
				offset := hit_test_wrapped_md(
					ctx,
					content_x,
					current_y,
					content_width,
					content,
					mouse_x,
					mouse_y,
					ui_frame_metrics(ctx.frame).FONT_SIZE,
				)
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
				next_byte, h := layout_table(
					ctx,
					x,
					current_y,
					max_width,
					text,
					line_start,
					ui_frame_theme(ctx.frame).fg_primary,
					false,
					mouse_x,
					mouse_y,
					&offset,
				)
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
			gap: i32 = ui_frame_metrics(ctx.frame).LINE_HEIGHT / 2
			if mouse_y >= current_y && mouse_y < current_y + gap {
				return line_start
			}
			current_y += gap
			line_start = i + 1
			continue
		}

		// Normal text.
		h := measure_wrapped_height_md(ctx, line, max_width, ui_frame_metrics(ctx.frame).FONT_SIZE)

		if mouse_y >= current_y && mouse_y < current_y + h {
			offset := hit_test_wrapped_md(
				ctx,
				x,
				current_y,
				max_width,
				line,
				mouse_x,
				mouse_y,
				ui_frame_metrics(ctx.frame).FONT_SIZE,
			)
			if offset >= 0 do return line_start + offset
		}

		current_y += h
		line_start = i + 1
	}

	// Mouse is just past the last line — snap to end of text. Bounded to one
	// line of slack so clicks far below the content (e.g. in the gap or on a
	// following tool card) miss this block instead of selecting to its end.
	if mouse_y >= current_y && mouse_y < current_y + ui_frame_metrics(ctx.frame).LINE_HEIGHT {
		return len(text)
	}

	return -1
}
