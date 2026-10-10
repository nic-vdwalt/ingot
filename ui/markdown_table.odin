package ui

import "core:strings"

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
markdown_table_cell_pad_y :: proc(ctx: ^Markdown_Context) -> i32 {
	assert(ctx != nil, "markdown_table_cell_pad_y: nil ctx")
	return max(ui_frame_metrics(ctx.frame).TABLE_CELL_PAD / 2, i32(1))
}

@(private = "file")
markdown_table_cell_display :: proc(ctx: ^Markdown_Context, cell: string) -> string {
	assert(ctx != nil, "markdown_table_cell_display: nil ctx")
	if !strings.contains(cell, "**") &&
	   strings.index_byte(cell, PILL_OPEN) < 0 &&
	   strings.index_byte(cell, '`') < 0 &&
	   strings.index_byte(cell, '[') < 0 {
		return cell
	}
	spans := frame_view_items(ctx.frame, parse_inline_spans(ctx.frame, cell))
	return frame_string_value(ctx.frame, spans_display_string(ctx.frame, spans))
}

@(private = "file")
markdown_table_longest_word_width :: proc(ctx: ^Markdown_Context, display: string) -> i32 {
	assert(ctx != nil, "markdown_table_longest_word_width: nil ctx")
	font_size := ui_frame_metrics(ctx.frame).FONT_SIZE_BODY
	longest, word: i32
	for value in display {
		if value == ' ' || value == '\n' {
			word = 0
			continue
		}
		word += rune_width_frame(ctx.frame, value, font_size) + 1
		longest = max(longest, word)
	}
	return longest
}

@(private = "file")
markdown_table_column_bounds :: proc(
	ctx: ^Markdown_Context,
	rows: []Markdown_Table_Row,
	columns: int,
	max_width: i32,
) -> Markdown_Table_Column_Bounds {
	assert(ctx != nil, "markdown_table_column_bounds: nil ctx")
	assert(
		columns > 0 && columns <= MARKDOWN_TABLE_COLS_MAX,
		"markdown_table_column_bounds: bad columns",
	)
	bounds: Markdown_Table_Column_Bounds
	metrics := ui_frame_metrics(ctx.frame)
	padding := metrics.TABLE_CELL_PAD
	for row in rows {
		for cell, column in row.cells {
			if column >= columns || len(cell) == 0 do continue
			display := markdown_table_cell_display(ctx, cell)
			cell_c := strings.clone_to_cstring(display, ui_frame_allocator(ctx.frame))
			width := measure_text_frame(ctx.frame, cell_c, metrics.FONT_SIZE_BODY) + padding * 2
			bounds.max_w[column] = max(bounds.max_w[column], width)
			word := markdown_table_longest_word_width(ctx, display) + padding * 2
			bounds.min_w[column] = max(bounds.min_w[column], word)
		}
	}
	floor := padding * 2 + metrics.FONT_SIZE_BODY * 2
	bounds.floor = clamp(floor, i32(1), max(max_width / i32(columns), i32(1)))
	for column in 0 ..< columns {
		bounds.max_w[column] = max(bounds.max_w[column], bounds.floor)
		bounds.min_w[column] = clamp(bounds.min_w[column], bounds.floor, bounds.max_w[column])
	}
	return bounds
}

@(private = "file")
markdown_table_widths_sum :: proc(widths: Markdown_Table_Widths, columns: int) -> i64 {
	total: i64
	for column in 0 ..< columns do total += i64(widths[column])
	return total
}

@(private = "file")
markdown_table_blend :: proc(
	lo, hi: Markdown_Table_Widths,
	columns: int,
	avail: i32,
) -> Markdown_Table_Widths {
	lo_sum := markdown_table_widths_sum(lo, columns)
	hi_sum := markdown_table_widths_sum(hi, columns)
	assert(
		lo_sum <= i64(avail) && i64(avail) <= hi_sum,
		"markdown_table_blend: avail out of range",
	)
	widths := lo
	slack_sum := hi_sum - lo_sum
	if slack_sum <= 0 do return widths
	extra := i64(avail) - lo_sum
	for column in 0 ..< columns {
		slack := i64(hi[column] - lo[column])
		widths[column] = lo[column] + i32(slack * extra / slack_sum)
	}
	return widths
}

@(private = "file")
markdown_table_give_remainder :: proc(
	widths: ^Markdown_Table_Widths,
	max_w: Markdown_Table_Widths,
	columns: int,
	avail: i32,
) {
	assert(widths != nil, "markdown_table_give_remainder: nil widths")
	assert(columns > 0, "markdown_table_give_remainder: no columns")
	left := i64(avail) - markdown_table_widths_sum(widths^, columns)
	if left <= 0 do return
	target := columns - 1
	best_slack := i32(0)
	for column in 0 ..< columns {
		slack := max_w[column] - widths[column]
		if slack > best_slack {
			best_slack = slack
			target = column
		}
	}
	widths[target] += i32(left)
}

@(private = "file")
markdown_table_column_widths :: proc(
	bounds: Markdown_Table_Column_Bounds,
	columns: int,
	max_width, font_size_body, pad: i32,
) -> (
	Markdown_Table_Widths,
	bool,
) {
	assert(
		columns > 0 && columns <= MARKDOWN_TABLE_COLS_MAX,
		"markdown_table_column_widths: bad columns",
	)
	assert(max_width > 0, "markdown_table_column_widths: non-positive max_width")
	if markdown_table_widths_sum(bounds.max_w, columns) <= i64(max_width) {
		return bounds.max_w, false
	}
	comfort_target := pad * 2 + 20 * font_size_body / 2
	comfort: Markdown_Table_Widths
	floors: Markdown_Table_Widths
	for column in 0 ..< columns {
		comfort[column] = min(bounds.max_w[column], max(bounds.min_w[column], comfort_target))
		floors[column] = bounds.floor
	}
	widths: Markdown_Table_Widths
	switch {
	case markdown_table_widths_sum(comfort, columns) <= i64(max_width):
		widths = markdown_table_blend(comfort, bounds.max_w, columns, max_width)
	case markdown_table_widths_sum(bounds.min_w, columns) <= i64(max_width):
		widths = markdown_table_blend(bounds.min_w, comfort, columns, max_width)
	case markdown_table_widths_sum(floors, columns) <= i64(max_width):
		widths = markdown_table_blend(floors, bounds.min_w, columns, max_width)
	case:
		share := max(max_width / i32(columns), i32(1))
		for column in 0 ..< columns do widths[column] = share
	}
	markdown_table_give_remainder(&widths, bounds.max_w, columns, max_width)
	for column in 0 ..< columns {
		assert(widths[column] >= 1, "markdown_table_column_widths: empty column")
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
	pad_y := markdown_table_cell_pad_y(ctx)
	for row, row_index in rows {
		height := i32(metrics.LINE_HEIGHT)
		for cell, column in row.cells {
			if column >= columns || len(cell) == 0 do continue
			inner := max(widths[column] - metrics.TABLE_CELL_PAD * 2, i32(1))
			cell_height := measure_wrapped_height_md(ctx, cell, inner, metrics.FONT_SIZE_BODY)
			height = max(height, cell_height)
		}
		heights[row_index] = height + pad_y * 2
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
	centering := max((i32(metrics.LINE_HEIGHT) - metrics.FONT_SIZE_BODY) / 2, i32(0))
	draw_text_wrapped_md(
		ctx,
		x + metrics.TABLE_CELL_PAD,
		y + markdown_table_cell_pad_y(ctx) + centering,
		inner,
		cell,
		color,
		metrics.FONT_SIZE_BODY,
	)
}

@(private = "file")
markdown_table_draw_row :: proc(
	ctx: ^Markdown_Context,
	row: ^Markdown_Table_Row,
	row_index, row_count: int,
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
	if row_index > 0 && row_index % 2 == 0 {
		draw_rectangle(ctx.frame, x, y, table_width, height, markdown_table_stripe_color(style))
	}
	if row_index > 0 && row_index < row_count - 1 {
		draw_rectangle(ctx.frame, x, y + height - 1, table_width, 1, style.border_subtle)
	}
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
	centering := max((i32(metrics.LINE_HEIGHT) - metrics.FONT_SIZE_BODY) / 2, i32(0))
	local := hit_test_wrapped_md(
		ctx,
		cell_x + metrics.TABLE_CELL_PAD,
		y + markdown_table_cell_pad_y(ctx) + centering,
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
	metrics := ui_frame_metrics(ctx.frame)
	bounds := markdown_table_column_bounds(ctx, rows[:], columns, max_width)
	widths, shrunk := markdown_table_column_widths(
		bounds,
		columns,
		max_width,
		metrics.FONT_SIZE_BODY,
		metrics.TABLE_CELL_PAD,
	)
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
				len(rows),
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

@(private = "file")
markdown_layout_table_row_chrome :: proc(
	layout: ^Markdown_Layout,
	row_index, row_count: int,
	row_top, height, table_width: i32,
) {
	assert(layout != nil, "markdown_layout_table_row_chrome: nil layout")
	assert(row_index >= 0 && row_index < row_count, "markdown_layout_table_row_chrome: bad row")
	if len(layout.decorations) + 3 > MARKDOWN_LAYOUT_RUNS_MAX {
		layout.status = .Truncated
		return
	}
	if row_index > 0 && row_index % 2 == 0 {
		append(
			&layout.decorations,
			Markdown_Layout_Decoration{{0, row_top, table_width, height}, .Table_Stripe},
		)
	}
	if row_index > 0 && row_index < row_count - 1 {
		append(
			&layout.decorations,
			Markdown_Layout_Decoration {
				{0, row_top + height - 1, table_width, 1},
				.Table_Row_Border,
			},
		)
	}
	if row_index == 0 {
		append(
			&layout.decorations,
			Markdown_Layout_Decoration{{0, row_top, table_width, height}, .Table_Header},
		)
		append(
			&layout.decorations,
			Markdown_Layout_Decoration{{0, row_top + height, table_width, 1}, .Border},
		)
	}
}

markdown_layout_table :: proc(
	ctx: ^Markdown_Context,
	layout: ^Markdown_Layout,
	line: string,
	start, end: int,
) -> (
	next: int,
	handled: bool,
) {
	assert(ctx != nil && layout != nil)
	assert(start >= 0 && end >= start)
	if end >= len(layout.source) || !strings.contains(line, "|") do return 0, false
	newline := strings.index_byte(layout.source[end + 1:], '\n')
	next_end := len(layout.source) if newline < 0 else end + 1 + newline
	separator := layout.source[end + 1:next_end]
	if !strings.contains(separator, "|") || !is_table_separator(separator) do return 0, false
	rows, columns, next_byte := markdown_table_parse_rows(ctx, layout.source, start)
	if columns == 0 || len(rows) == 0 do return 0, false
	metrics := ui_frame_metrics(ctx.frame)
	bounds := markdown_table_column_bounds(ctx, rows[:], columns, layout.width)
	widths, shrunk := markdown_table_column_widths(
		bounds,
		columns,
		layout.width,
		metrics.FONT_SIZE_BODY,
		metrics.TABLE_CELL_PAD,
	)
	heights := markdown_table_row_heights(ctx, rows[:], widths, columns)
	table_width := markdown_table_total_width(widths, columns)
	layout.content_w = max(layout.content_w, layout.width if shrunk else table_width)
	top := layout.content_h
	pad_y := markdown_table_cell_pad_y(ctx)
	centering := max((metrics.LINE_HEIGHT - metrics.FONT_SIZE_BODY) / 2, 0)
	for row, row_index in rows {
		height := heights[row_index]
		row_top := layout.content_h
		markdown_layout_table_row_chrome(
			layout,
			row_index,
			len(rows),
			row_top,
			height,
			table_width,
		)
		cell_x: i32
		for column in 0 ..< columns {
			if column > 0 {
				append(
					&layout.decorations,
					Markdown_Layout_Decoration{{cell_x, layout.content_h, 1, height}, .Border},
				)
			}
			if column < len(row.cells) {
				first_run := len(layout.runs)
				markdown_layout_add_text(
					ctx,
					layout,
					row.cells[column],
					row.starts[column],
					cell_x + metrics.TABLE_CELL_PAD,
					row_top + pad_y + centering,
					max(widths[column] - metrics.TABLE_CELL_PAD * 2, 1),
					metrics.FONT_SIZE_BODY,
					metrics.LINE_HEIGHT,
					.Table_Bold if row_index == 0 else .Body,
					true,
				)
				for &run in layout.runs[first_run:] {
					run.hit_top = max(run.bounds.y - pad_y - centering, row_top)
					run.hit_bottom = min(
						run.hit_top + metrics.LINE_HEIGHT + pad_y * 2,
						row_top + height,
					)
				}
			}
			cell_x += widths[column]
		}
		layout.content_h += height
	}
	append(
		&layout.decorations,
		Markdown_Layout_Decoration{{0, top, table_width, layout.content_h - top + 1}, .Outline},
	)
	layout.content_h += 5
	return next_byte, true
}

markdown_table_stripe_color :: proc(theme: ^Theme) -> Color {
	assert(theme != nil, "markdown_table_stripe_color: nil theme")
	header := theme.bg_table_header
	return Color{header.r, header.g, header.b, header.a / 2}
}
