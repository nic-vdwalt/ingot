package ui

import "core:mem"
import "core:strings"
import "core:unicode/utf8"

markdown_layout_add_run :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	text: string,
	source_start: int,
	x, y, size, height: i32,
	style: Markdown_Layout_Style,
	href: string = "",
) -> i32 {
	assert(ctx != nil && layout != nil && layout.initialized)
	assert(source_start >= 0 && size > 0 && height > 0)
	if len(text) == 0 do return 0
	if len(layout.runs) >= MARKDOWN_LAYOUT_RUNS_MAX ||
	   len(layout.stops) + len(text) + 1 > MARKDOWN_LAYOUT_STOPS_MAX ||
	   len(layout.text) + len(text) + len(href) > MARKDOWN_LAYOUT_SOURCE_MAX * 4 {
		layout.status = .Truncated
		return 0
	}
	run := Markdown_Layout_Run {
		bounds       = {x, y, 0, height},
		hit_top = y,
		hit_bottom = y + height,
		font_size    = size,
		style        = style,
		source_start = source_start,
		source_end   = source_start + len(text),
		text_start   = len(layout.text),
		stop_start   = len(layout.stops),
	}
	append(&layout.text, ..transmute([]u8)text)
	run.text_end = len(layout.text)
	run.href_start = len(layout.text)
	append(&layout.text, ..transmute([]u8)href)
	run.href_end = len(layout.text)
	append(&layout.stops, Markdown_Layout_Stop{0, source_start})
	position := 0
	for position < len(text) {
		_, count := utf8.decode_rune_in_string(text[position:])
		position += max(count, 1)
		prefix := strings.clone_to_cstring(text[:position], context.temp_allocator)
		width := measure_text_frame(ctx.frame, prefix, size)
		append(&layout.stops, Markdown_Layout_Stop{width, source_start + position})
	}
	run.stop_end = len(layout.stops)
	run.bounds.w = layout.stops[run.stop_end - 1].x
	append(&layout.runs, run)
	layout.content_w = max(layout.content_w, x + run.bounds.w)
	return run.bounds.w
}

markdown_layout_add_text :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	text: string,
	source_start: int,
	x, y, width, size, height: i32,
	style: Markdown_Layout_Style,
	inline_spans: bool,
) -> i32 {
	assert(ctx != nil && layout != nil && layout.initialized)
	assert(width > 0 && size > 0 && height > 0)
	if len(text) == 0 do return 0
	if !inline_spans {
		current_y := y
		for line in wrap_text_frame(ctx.frame, text, width, size) {
			markdown_layout_add_run(
				ctx,
				layout,
				text[line.start:line.end],
				source_start + line.start,
				x,
				current_y,
				size,
				height,
				style,
			)
			current_y += height
		}
		return current_y - y
	}
	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, text))
	display := frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))
	current_y := y
	for line in wrap_text_frame(ctx.frame, display, width, size) {
		cursor_x, display_start := x, 0
		for span in spans {
			start := max(display_start, line.start)
			end := min(display_start + len(span.text), line.end)
			if start < end {
				segment := span.text[start - display_start:end - display_start]
				run_style := style
				if span.pill || span.code {
					if markdown_reference_resolves_cached(ctx, span.text) {
						run_style = .Chip
					} else if span.code {
						run_style = .Code
					}
				} else if span.bold {
					run_style = .Bold
				} else if span.link {
					run_style = .Link
				}
				previous_runs := len(layout.runs)
				cursor_x += markdown_layout_add_run(
					ctx,
					layout,
					segment,
					source_start + span.text_raw_start + start - display_start,
					cursor_x,
					current_y,
					size,
					height,
					run_style,
					span.href,
				)
				if len(layout.runs) > previous_runs {
					run := &layout.runs[len(layout.runs) - 1]
					for &stop in layout.stops[run.stop_start:run.stop_end] {
						local := stop.source - run.source_start
						stop.source = source_start + display_to_raw(spans, start + local)
					}
					run.source_end = layout.stops[run.stop_end - 1].source
				}
			}
			display_start += len(span.text)
		}
		current_y += height
	}
	return current_y - y
}

MARKDOWN_LAYOUT_SOURCE_MAX :: 1024 * 1024
MARKDOWN_LAYOUT_RUNS_MAX :: 131072
MARKDOWN_LAYOUT_STOPS_MAX :: 1048576

Markdown_Layout_Style :: enum u8 {
	Body,
	Heading,
	Bold,
	Table_Bold,
	Code,
	Chip,
	Link,
	Primary,
}

Markdown_Layout_Stop :: struct {
	x:      i32,
	source: int,
}

Markdown_Layout_Run :: struct {
	bounds:                   Rect_I32,
	hit_top, hit_bottom: i32,
	font_size:                i32,
	style:                    Markdown_Layout_Style,
	text_start, text_end:     int,
	source_start, source_end: int,
	stop_start, stop_end:     int,
	href_start, href_end:     int,
}

Markdown_Layout_Decoration_Kind :: enum u8 {
	Border,
	Code_Background,
	Code_Edge,
	Table_Header,
	Bullet,
	Outline,
}

Markdown_Layout_Decoration :: struct {
	bounds: Rect_I32,
	kind:   Markdown_Layout_Decoration_Kind,
}

Markdown_Layout_Block :: struct {
	start, end: int,
	y: i32,
	first_line_end: int,
	bottom: i32,
}

Markdown_Layout :: struct {
	allocator:                   mem.Allocator,
	source:                      string,
	text:                        [dynamic]u8,
	runs:                        [dynamic]Markdown_Layout_Run,
	stops:                       [dynamic]Markdown_Layout_Stop,
	decorations:                 [dynamic]Markdown_Layout_Decoration,
	blocks:                      [dynamic]Markdown_Layout_Block,
	width, content_w, content_h: i32,
	status:                      Markdown_Prepare_Status,
	initialized:                 bool,
}

markdown_layout_init :: proc(layout: ^Markdown_Layout, allocator := context.allocator) {
	assert(layout != nil)
	assert(!layout.initialized)
	layout.allocator = allocator
	layout.text = make([dynamic]u8, allocator)
	layout.runs = make([dynamic]Markdown_Layout_Run, allocator)
	layout.stops = make([dynamic]Markdown_Layout_Stop, allocator)
	layout.decorations = make([dynamic]Markdown_Layout_Decoration, allocator)
	layout.blocks = make([dynamic]Markdown_Layout_Block, allocator)
	layout.initialized = true
}

markdown_layout_destroy :: proc(layout: ^Markdown_Layout) {
	assert(layout != nil)
	if !layout.initialized do return
	assert(layout.allocator.procedure != nil)
	delete(layout.source, layout.allocator)
	delete(layout.text)
	delete(layout.runs)
	delete(layout.stops)
	delete(layout.decorations)
	delete(layout.blocks)
	layout^ = {}
}

markdown_layout_measure :: proc(layout: ^Markdown_Layout) -> (width, height: i32) {
	assert(layout != nil && layout.initialized)
	assert(layout.content_w >= 0 && layout.content_h >= 0)
	return layout.content_w, layout.content_h
}

markdown_layout_source_y :: proc(layout: ^Markdown_Layout, offset: int) -> i32 {
	assert(layout != nil && layout.initialized)
	assert(offset >= 0)
	for block in layout.blocks {
		if offset < block.end {
			return block.bottom if offset > block.first_line_end else block.y
		}
	}
	return layout.content_h
}

markdown_layout_hit_test :: proc(layout: ^Markdown_Layout, x, y, mouse_x, mouse_y: i32) -> int {
	assert(layout != nil && layout.initialized)
	assert(layout.content_h >= 0)
	if len(layout.runs) == 0 do return -1
	local_x, local_y := i64(mouse_x) - i64(x), i64(mouse_y) - i64(y)
	best := 0
	best_distance := max(i64)
	block_start, block_end := 0, len(layout.source) + 1
	for block in layout.blocks {
		if i64(block.y) > local_y do break
		block_start, block_end = block.start, block.end
		if block.end > block.first_line_end + 1 && local_y >= i64(block.bottom - 5) && local_y < i64(block.bottom) {
			return block.start
		}
	}
	for run, index in layout.runs {
		if run.source_start < block_start || run.source_start >= block_end do continue
		distance :=
			max(i64(run.hit_top) - local_y, 0) +
			max(local_y - i64(run.hit_bottom) + 1, 0)
		distance =
			distance * (i64(max(i32)) + 1) +
			max(i64(run.bounds.x) - local_x, 0) +
			max(local_x - i64(run.bounds.x) - i64(run.bounds.w), 0)
		if distance < best_distance {
			best, best_distance = index, distance
		}
	}
	if best_distance == max(i64) do return block_start
	run := layout.runs[best]
	stops := layout.stops[run.stop_start:run.stop_end]
	for index in 1 ..< len(stops) {
		midpoint := i64(run.bounds.x) + (i64(stops[index - 1].x) + i64(stops[index].x)) / 2
		if local_x < midpoint do return stops[index - 1].source
	}
	return run.source_end
}

markdown_layout_run_color :: proc(
	ctx: ^Markdown_Context,
	run: Markdown_Layout_Run,
	base: Color,
) -> Color {
	assert(ctx != nil && ctx.frame != nil)
	assert(run.font_size > 0)
	theme := ui_frame_theme(ctx.frame)
	switch run.style {
	case .Body:
		return base
	case .Heading:
		return theme.fg_heading
	case .Bold, .Table_Bold:
		return theme.fg_bold
	case .Code:
		return theme.fg_code_inline
	case .Chip, .Link:
		return theme.fg_accent
	case .Primary:
		return theme.fg_primary
	}
	return base
}

markdown_layout_draw :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	bounds: Rect_I32,
	color: Color,
	sel_start: int = -1,
	sel_end: int = -1,
	out_width: ^i32 = nil,
) -> i32 {
	assert(ctx != nil && ctx.frame != nil && ctx.frame.open)
	assert(layout != nil && layout.initialized && bounds.w == layout.width)
	ctx.hovered_link = ""
	ctx.link_pressed = false
	if out_width != nil do out_width^ = layout.content_w
	theme := ui_frame_theme(ctx.frame)
	for decoration in layout.decorations {
		rect := decoration.bounds
		rect.x += bounds.x
		rect.y += bounds.y
		if markdown_line_culled(ctx, rect.y, max(rect.h, 1)) do continue
		fill := theme.border_color
		switch decoration.kind {
		case .Code_Background:
			fill = theme.bg_code
		case .Code_Edge:
			fill = theme.border_subtle
		case .Table_Header:
			fill = theme.bg_table_header
		case .Bullet:
			draw_circle(ctx.frame, rect.x, rect.y, 2.5, theme.fg_bullet)
			continue
		case .Outline:
			draw_rectangle_lines(ctx.frame, rect.x, rect.y, rect.w, rect.h, fill)
			continue
		case .Border:
		}
		draw_rectangle(ctx.frame, rect.x, rect.y, rect.w, rect.h, fill)
	}
	for run in layout.runs {
		if markdown_line_culled(ctx, bounds.y + run.bounds.y, run.bounds.h) do continue
		markdown_layout_draw_run(ctx, layout, run, bounds.x, bounds.y, color, sel_start, sel_end)
	}
	return layout.content_h
}

markdown_layout_draw_run :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	run: Markdown_Layout_Run,
	origin_x, origin_y: i32,
	base: Color,
	sel_start, sel_end: int,
) {
	assert(ctx != nil && layout != nil)
	assert(run.text_start >= 0 && run.text_end <= len(layout.text))
	x := origin_x + run.bounds.x
	y := origin_y + run.bounds.y
	theme := ui_frame_theme(ctx.frame)
	text := string(layout.text[run.text_start:run.text_end])
	if sel_start >= 0 && sel_end > sel_start {
		stops := layout.stops[run.stop_start:run.stop_end]
		for index in 1 ..< len(stops) {
			if stops[index].source <= sel_start || stops[index - 1].source >= sel_end do continue
			rect := text_selection_rect(
				ctx.frame,
				x + stops[index - 1].x,
				y,
				max(stops[index].x - stops[index - 1].x, 1),
				run.font_size,
				run.bounds.h,
			)
			draw_rectangle_rec(ctx.frame, rect, theme.bg_selection)
		}
	}
	color := markdown_layout_run_color(ctx, run, base)
	if run.style == .Chip {
		draw_rounded_fill(
			ctx.frame,
			{f32(x - 3), f32(y - 1), f32(run.bounds.w + 6), f32(run.font_size + 4)},
			.Pill,
			theme.bg_chip,
		)
	}
	if run.style == .Link {
		span := Text_Span {
			text      = text,
			href      = string(layout.text[run.href_start:run.href_end]),
			raw_start = run.source_start,
			raw_end   = run.source_end,
			link      = true,
		}
		markdown_track_link(ctx, &span, x, y, run.bounds.w, run.font_size)
		if span.href == ctx.hovered_link do color = theme.fg_accent_light
		draw_line(
			ctx.frame,
			x,
			y + run.font_size + 1,
			x + run.bounds.w,
			y + run.font_size + 1,
			color,
		)
	}
	text_c := strings.clone_to_cstring(text, context.temp_allocator)
	if run.style == .Bold do draw_text_frame(ctx.frame, text_c, x + 1, y, run.font_size, color)
	draw_text_frame(ctx.frame, text_c, x, y, run.font_size, color)
}
