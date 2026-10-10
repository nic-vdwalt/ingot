package ui

import "core:strings"

// markdown_track_link records whether the pointer is over this link span.
//
// Called from the draw pass so the rect it tests is the same one the glyphs
// were laid into. The hit box is the text box grown by a hairline on each
// side: an exact glyph box makes a single-line link feel like it slips out
// from under the cursor at the boundary.
@(private = "package")
markdown_track_link :: proc(
	ctx: ^Markdown_Context,
	span: ^Text_Span,
	x, y, width, font_size: i32,
) {
	assert(ctx != nil, "markdown_track_link: nil ctx")
	assert(span != nil, "markdown_track_link: nil span")
	if len(span.href) == 0 || width <= 0 do return
	pad := ui_frame_sc(ctx.frame, 2)
	box := Rect{f32(x - pad), f32(y - pad), f32(width + pad * 2), f32(font_size + pad * 2)}
	link_widget := WIDGET_ID_NONE
	link_focus := Focus_Opt{}
	if ctx.document != WIDGET_ID_NONE {
		hash := id_hash_u64(u64(ctx.document), u64(span.raw_start))
		hash = id_hash_u64(hash, u64(span.raw_end))
		link_widget = Widget_Id(id_finish(hash))
		if ctx.link_focus != nil do link_focus = {ctx.link_focus, span.raw_start + 1}
		link_id := sem_node_id(.Link, link_focus, "", 0, link_widget)
		existing: ^Sem_Node
		sem := sem_frame(ctx.frame)
		for index in 0 ..< sem.count {
			if sem.nodes[index].id == link_id {
				existing = &sem.nodes[index]
				break
			}
		}
		if existing != nil {
			right := max(existing.rect.x + existing.rect.w, x + width)
			bottom := max(existing.rect.y + existing.rect.h, y + font_size)
			existing.rect.x = min(existing.rect.x, x)
			existing.rect.y = min(existing.rect.y, y)
			existing.rect.w = right - existing.rect.x
			existing.rect.h = bottom - existing.rect.y
		} else {
			semantic_push(
				ctx.frame,
				.Link,
				{x, y, width, font_size},
				span.text,
				focus = link_focus,
				description = span.href,
				widget = link_widget,
			)
		}
		if link_focus.focus != nil &&
		   focus_opt_activated(ctx.frame, link_focus, .Link, link_widget) {
			ctx.hovered_link = span.href
			ctx.link_pressed = true
		}
	}
	if !point_in_rect(get_mouse_position(ctx.frame), box) do return
	ctx.hovered_link = span.href
	request_cursor(ctx.frame, .POINTING_HAND)
	if is_mouse_button_pressed(ctx.frame, .LEFT) do ctx.link_pressed = true
}

// markdown_link_activated reports a link the user just clicked, if any.
//
// The package cannot follow the link itself: it imports only core:*, and
// opening a URL is a platform capability that lives in `sys`. Reporting it is
// also the right split on merit - an application may want to route a relative
// target internally rather than hand every click to a browser.
markdown_link_activated :: proc(ctx: ^Markdown_Context) -> (string, bool) {
	assert(ctx != nil, "markdown_link_activated: nil ctx")
	// Both fields are tested rather than asserting that a press implies a
	// link. That assertion looked like an invariant and was not: a caller may
	// draw one context twice - a measure pass then a real pass, or two
	// documents sharing a context - and the second pass can clear
	// hovered_link after the first recorded a press. That is an ordinary
	// sequence of events, not corrupt state, so it reports "no link" rather
	// than aborting the application.
	if !ctx.link_pressed || len(ctx.hovered_link) == 0 do return "", false
	return ctx.hovered_link, true
}

markdown_line_spans_hit :: proc(
	ctx: ^Markdown_Context,
	x, mouse_x, font_size: i32,
	dl_start, dl_end: int,
	spans: []Text_Span,
) -> int {
	assert(ctx != nil && ctx.frame != nil, "markdown span hit: invalid context")
	assert(dl_start >= 0 && dl_end >= dl_start, "markdown span hit: invalid range")
	cursor_x, display_offset := x, 0
	for &span in spans {
		span_start := display_offset
		span_end := display_offset + len(span.text)
		display_offset = span_end
		segment_start := max(span_start, dl_start)
		segment_end := min(span_end, dl_end)
		if segment_start >= segment_end do continue
		segment := span.text[segment_start - span_start:segment_end - span_start]
		segment_c := strings.clone_to_cstring(segment, context.temp_allocator)
		width := measure_text_frame(ctx.frame, segment_c, font_size)
		if mouse_x <= cursor_x + width {
			column := caret_pixel_to_col_frame(ctx.frame, segment, mouse_x - cursor_x, font_size)
			return segment_start + caret_col_to_byte(segment, column)
		}
		cursor_x += width
	}
	return dl_end
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

	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, text))
	if len(spans) == 1 && !spans[0].bold && !spans[0].pill && !spans[0].code && !spans[0].link {
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

	display_text := frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))
	lines := wrap_text_frame(ctx.frame, display_text, max_width, font_size)
	row := clamp(int((mouse_y - y) / ui_frame_metrics(ctx.frame).LINE_HEIGHT), 0, len(lines) - 1)
	display_offset := markdown_line_spans_hit(
		ctx,
		x,
		mouse_x,
		font_size,
		lines[row].start,
		lines[row].end,
		spans,
	)
	return display_to_raw(spans, display_offset)
}

hit_test_markdown_context :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	assert(ctx != nil && ctx.frame != nil, "hit_test_markdown_context: invalid context")
	return hit_test_markdown_unprepared(ctx, x, y, max_width, text, mouse_x, mouse_y)
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
		column := caret_pixel_to_col_frame(
			state.ctx.frame,
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
hit_test_markdown_unprepared :: proc(
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

markdown_source_y_unprepared :: proc(
	ctx: ^Markdown_Context,
	width: i32,
	text: string,
	offset: int,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil, "markdown_source_y: invalid context")
	assert(width > 0, "markdown_source_y: non-positive width")
	assert(offset >= 0 && offset <= len(text), "markdown_source_y: invalid offset")
	state := Markdown_Hit_State {
		ctx       = ctx,
		text      = text,
		max_width = width,
		mouse_x   = min(i32) / 4,
		mouse_y   = min(i32) / 4,
	}
	line_start := 0
	for index := 0; index <= len(text); index += 1 {
		is_end := index == len(text)
		if !is_end && text[index] != '\n' do continue
		if offset >= line_start && offset <= index do return state.current_y
		_, next, skipped := markdown_hit_line(&state, text[line_start:index], line_start, index)
		if skipped {
			assert(next > line_start, "markdown_source_y: table made no progress")
			if offset < next do return state.current_y
			line_start = next
			index = next - 1
			continue
		}
		line_start = index + 1
	}
	return state.current_y
}

hit_test_markdown :: proc(
	ctx: ^Markdown_Context,
	x, y, max_width: i32,
	text: string,
	mouse_x, mouse_y: i32,
) -> int {
	prepared := markdown_prepare(ctx, max_width, text)
	return markdown_prepared_hit_test(ctx, &prepared, x, y, mouse_x, mouse_y)
}

markdown_source_y :: proc(ctx: ^Markdown_Context, width: i32, text: string, offset: int) -> i32 {
	prepared := markdown_prepare(ctx, width, text)
	return markdown_prepared_source_y(ctx, &prepared, offset)
}
