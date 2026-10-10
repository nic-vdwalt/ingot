package ui

import "core:strings"

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
	highlight_w := max(measure_text_frame(ctx.frame, selected, font_size), 1)
	highlight := text_selection_rect(
		ctx.frame,
		highlight_x,
		y,
		highlight_w,
		font_size,
		ui_frame_metrics(ctx.frame).LINE_HEIGHT,
	)
	draw_rectangle_rec(ctx.frame, highlight, ui_frame_theme(ctx.frame).bg_selection)
}

@(private = "file")
draw_markdown_span_chip :: proc(ctx: ^Markdown_Context, text: cstring, x, y: i32) {
	assert(ctx != nil, "draw_markdown_span_chip: nil ctx")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	width := measure_text_frame(ctx.frame, text, font_size)
	rect := Rectangle{f32(x - 3), f32(y - 1), f32(width + 6), f32(font_size + 4)}
	draw_rounded_fill(ctx.frame, rect, .Pill, ui_frame_theme(ctx.frame).bg_chip)
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
	if markdown_reference_resolves_cached(ctx, span.text) {
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
		markdown_track_link(ctx, span, x, y, width, font_size)
		// A hovered link brightens, so the pointer cursor is not the only
		// feedback: touch and keyboard users see nothing from a cursor change.
		color := style.fg_accent
		if len(span.href) > 0 && span.href == ctx.hovered_link do color = style.fg_accent_light
		draw_text_frame(ctx.frame, text, x, y, font_size, color)
		draw_line(ctx.frame, x, y + font_size + 1, x + width, y + font_size + 1, color)
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
		if markdown_reference_resolves_cached(ctx, span.text) {
			draw_markdown_span_chip(ctx, text, x, y)
		} else {
			draw_text_frame(
				ctx.frame,
				text,
				x,
				y,
				ui_frame_metrics(ctx.frame).FONT_SIZE_BODY,
				base_color,
			)
		}
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
		cursor_x += measure_text_frame(
			ctx.frame,
			segment_c,
			ui_frame_metrics(ctx.frame).FONT_SIZE_BODY,
		)
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

	// Fast path: single plain span - delegate to existing function.
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
	return markdown_draw_unprepared(
		ctx,
		{x, y, max_width, 0},
		text,
		base_color,
		sel_start,
		sel_end,
		out_w,
		draw,
	)
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
markdown_draw_unprepared :: proc(
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
	// Link state is per-draw and must be cleared here, not accumulated.
	//
	// Without this a press recorded on one frame survives into the next, so
	// the application opens the URL again on every subsequent frame until the
	// pointer happens to move off the link. The one-frame lifetime matches how
	// the rest of the frame state in this package behaves, and it is why the
	// hovered link may be borrowed from `text` - it never outlives this call.
	//
	// A measure pass clears it too: a caller that measures after drawing
	// should not be left holding a click the user already made.
	ctx.hovered_link = ""
	ctx.link_pressed = false
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
	when UI_TELEMETRY_ENABLED do ctx.frame.markdown_telemetry.layout_walks += 1
	return state.current_y - y
}

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
	assert(ctx != nil, "markdown draw: nil context")
	prepared := markdown_prepare(ctx, bounds.w, text)
	if !draw do return markdown_prepared_measure(ctx, &prepared, out_w)
	return markdown_prepared_draw(ctx, &prepared, bounds, base_color, sel_start, sel_end, out_w)
}
