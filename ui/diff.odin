package ui

import "core:fmt"
import "core:strconv"
import "core:strings"

DIFF_PARSE_MAX_ROWS :: 16_384
DIFF_PARSE_MAX_BYTES :: 4 * 1024 * 1024

Diff_Row_Kind :: enum u8 {
	Context,
	Add,
	Del,
	Hunk,
	Metadata,
}

Diff_Row :: struct {
	kind:   Diff_Row_Kind,
	old_no: int,
	new_no: int,
	text:   string,
}

Diff_Parse_Options :: struct {
	max_rows:  int,
	max_bytes: int,
}

Diff_Parse_Result :: struct {
	rows:      Frame_View(Diff_Row),
	truncated: bool,
	malformed: bool,
}

Diff_Layout :: enum u8 {
	Auto,
	Unified,
	Split,
}

Diff_View_Options :: struct {
	layout:          Diff_Layout,
	max_rows:        int,
	selected:        bool,
	semantic_label:  string,
	field_id:        string,
	minimum_columns: i32,
}

Diff_View_Result :: struct {
	next_y:     i32,
	shown:      int,
	hidden:     int,
	used_split: bool,
}

diff_parse_leading_int :: proc(value: string) -> (number: int, ok: bool) {
	assert(len(value) >= 0)
	end := 0
	for end < len(value) && end < 20 && value[end] >= '0' && value[end] <= '9' do end += 1
	if end == 0 do return 0, false
	number, ok = strconv.parse_int(value[:end])
	return
}

diff_parse_hunk_header :: proc(line: string) -> (old_start, new_start: int, ok: bool) {
	assert(len(line) >= 2)
	minus := strings.index_byte(line, '-')
	plus := strings.index_byte(line, '+')
	if minus < 0 || plus < 0 || minus >= plus do return
	old_ok, new_ok: bool
	old_start, old_ok = diff_parse_leading_int(line[minus + 1:])
	new_start, new_ok = diff_parse_leading_int(line[plus + 1:])
	ok = old_ok && new_ok
	return
}

parse_hunk_header :: proc(line: string) -> (old_start, new_start: int) {
	assert(len(line) >= 0)
	old_start, new_start, _ = diff_parse_hunk_header(line)
	return
}

diff_parse_line :: proc(
	line: string,
	old_no, new_no: ^int,
) -> (
	row: Diff_Row,
	emit, malformed: bool,
) {
	assert(old_no != nil && new_no != nil)
	assert(len(line) >= 0)
	if strings.has_prefix(line, "--- ") || strings.has_prefix(line, "+++ ") do return {}, false, false
	if strings.has_prefix(line, "@@") {
		old_start, new_start, ok := diff_parse_hunk_header(line)
		if ok {
			old_no^ = old_start
			new_no^ = new_start
		}
		return Diff_Row{kind = .Hunk, text = line}, true, !ok
	}
	if strings.has_prefix(line, "\\ No newline at end of file") {
		return Diff_Row{kind = .Metadata, text = line}, true, false
	}
	if len(line) == 0 {
		row = Diff_Row {
			kind   = .Context,
			old_no = old_no^,
			new_no = new_no^,
		}
		old_no^ += 1
		new_no^ += 1
		return row, true, false
	}
	switch line[0] {
	case '+':
		row = Diff_Row {
			kind   = .Add,
			new_no = new_no^,
			text   = line[1:],
		}
		new_no^ += 1
	case '-':
		row = Diff_Row {
			kind   = .Del,
			old_no = old_no^,
			text   = line[1:],
		}
		old_no^ += 1
	case ' ':
		row = Diff_Row {
			kind   = .Context,
			old_no = old_no^,
			new_no = new_no^,
			text   = line[1:],
		}
		old_no^ += 1
		new_no^ += 1
	case:
		return Diff_Row{kind = .Metadata, text = line}, true, true
	}
	return row, true, false
}

parse_unified_diff :: proc(
	frame: ^Ui_Frame,
	text_value: string,
	options: Diff_Parse_Options = {},
) -> Diff_Parse_Result {
	assert(frame != nil && frame.open, "parse_unified_diff: invalid frame")
	max_rows := options.max_rows if options.max_rows > 0 else DIFF_PARSE_MAX_ROWS
	max_rows = min(max_rows, DIFF_PARSE_MAX_ROWS)
	max_bytes := options.max_bytes if options.max_bytes > 0 else DIFF_PARSE_MAX_BYTES
	max_bytes = min(max_bytes, DIFF_PARSE_MAX_BYTES)
	parse_bytes := min(len(text_value), max_bytes)
	rows := make([dynamic]Diff_Row, 0, min(max_rows, 256), ui_frame_allocator(frame))
	result := Diff_Parse_Result {
		truncated = parse_bytes < len(text_value),
	}
	old_no, new_no := 0, 0
	start := 0
	for index := 0; index <= parse_bytes && len(rows) < max_rows; index += 1 {
		if index < parse_bytes && text_value[index] != '\n' do continue
		if index == parse_bytes && (parse_bytes == 0 || text_value[parse_bytes - 1] == '\n') do break
		line := text_value[start:index]
		start = index + 1
		if len(line) > 0 && line[len(line) - 1] == '\r' do line = line[:len(line) - 1]
		row, emit, malformed := diff_parse_line(line, &old_no, &new_no)
		result.malformed = result.malformed || malformed
		if emit do append(&rows, row)
	}
	result.truncated = result.truncated || (len(rows) >= max_rows && start < parse_bytes)
	result.rows = frame_view(frame, rows[:])
	return result
}

diff_draw_gutter :: proc(frame: ^Ui_Frame, x, y, width, cell_width: i32, number: int) {
	assert(frame != nil && frame.open, "diff_draw_gutter: invalid frame")
	assert(width >= 0 && cell_width > 0, "diff_draw_gutter: invalid geometry")
	if number <= 0 do return
	value := fmt.tprintf("%d", number)
	value_width := text_width(frame, value, .Small)
	text(frame, value, x + width - cell_width - value_width, y, .Small, .Muted)
}

diff_draw_cell :: proc(frame: ^Ui_Frame, x, y: i32, value: string, max_characters: int, ink: Ink) {
	assert(frame != nil && frame.open, "diff_draw_cell: invalid frame")
	assert(max_characters > 0, "diff_draw_cell: invalid character limit")
	display := value
	if len(display) > max_characters {
		if max_characters > 3 {
			display = fmt.tprintf("%s...", display[:max_characters - 3])
		} else {
			display = display[:max_characters]
		}
	}
	text(frame, display, x, y, .Small, ink)
}

diff_semantics :: proc(
	frame: ^Ui_Frame,
	rows: []Diff_Row,
	rect: Rect_I32,
	label, field_id: string,
) {
	assert(frame != nil && frame.open, "diff_semantics: invalid frame")
	assert(len(rows) > 0, "diff_semantics: empty rows")
	added, removed := 0, 0
	for row in rows {
		if row.kind == .Add do added += 1
		if row.kind == .Del do removed += 1
	}
	resolved_label := label if len(label) > 0 else "Unified diff"
	semantic_push(
		frame,
		.Pane,
		rect,
		resolved_label,
		field_id = field_id,
		description = fmt.tprintf("%d lines, %d added, %d removed", len(rows), added, removed),
	)
}

diff_view :: proc(
	frame: ^Ui_Frame,
	x, y, width: i32,
	rows: []Diff_Row,
	options: Diff_View_Options = {},
) -> Diff_View_Result {
	assert(frame != nil && frame.open, "diff_view: invalid frame")
	if ui_frame_drop_degenerate(frame, width <= 0) || len(rows) == 0 do return {next_y = y}
	metrics := ui_frame_metrics(frame)
	style := ui_frame_theme(frame)
	line_height := metrics.FONT_SIZE_SMALL + 2
	cell_width := max(text_width(frame, "MM", .Small) - text_width(frame, "M", .Small), 1)
	gutter_width := cell_width * 5
	gap := cell_width
	column_width := (width - gutter_width * 2 - gap * 3) / 2
	minimum := options.minimum_columns if options.minimum_columns > 0 else 16
	use_split :=
		options.layout == .Split ||
		(options.layout == .Auto && column_width >= cell_width * minimum)
	max_rows := options.max_rows if options.max_rows > 0 else 40
	shown := min(len(rows), max_rows)
	hidden := len(rows) - shown
	height := (i32(shown) + (1 if hidden > 0 else 0)) * line_height + 8
	background := style.bg_selection if options.selected else style.bg_code
	draw_rectangle(frame, x, y, width, height, background)
	diff_semantics(
		frame,
		rows[:shown],
		{x, y, width, height},
		options.semantic_label,
		options.field_id,
	)
	if use_split {
		diff_view_split(
			frame,
			x,
			y + 4,
			width,
			rows[:shown],
			gutter_width,
			column_width,
			gap,
			cell_width,
		)
	} else {
		diff_view_unified(frame, x, y + 4, width, rows[:shown], gutter_width, gap, cell_width)
	}
	if hidden > 0 do text(frame, fmt.tprintf("... %d more lines", hidden), x + gap, y + 4 + i32(shown) * line_height, .Small, .Muted)
	return {next_y = y + height, shown = shown, hidden = hidden, used_split = use_split}
}

diff_view_split :: proc(
	frame: ^Ui_Frame,
	x, y, width: i32,
	rows: []Diff_Row,
	gutter_width, column_width, gap, cell_width: i32,
) {
	assert(frame != nil && frame.open, "diff_view_split: invalid frame")
	assert(gutter_width > 0 && column_width > 0 && gap > 0 && cell_width > 0)
	line_height := ui_frame_metrics(frame).FONT_SIZE_SMALL + 2
	left_gutter := x + gap
	left_text := left_gutter + gutter_width
	right_gutter := left_text + column_width + gap
	right_text := right_gutter + gutter_width
	for row, index in rows {
		row_y := y + i32(index) * line_height
		if row.kind == .Hunk || row.kind == .Metadata {
			text(frame, row.text, x + gap, row_y, .Small, .Muted)
			continue
		}
		if row.kind == .Del || row.kind == .Context {
			if row.kind == .Del do draw_rectangle(frame, left_gutter, row_y, gutter_width + column_width, line_height, ui_frame_theme(frame).bg_diff_remove)
			diff_draw_gutter(frame, left_gutter, row_y, gutter_width, cell_width, row.old_no)
			diff_draw_cell(
				frame,
				left_text,
				row_y,
				row.text,
				max(int(column_width / cell_width), 1),
				.Diff_Remove if row.kind == .Del else .Secondary,
			)
		}
		if row.kind == .Add || row.kind == .Context {
			if row.kind == .Add do draw_rectangle(frame, right_gutter, row_y, gutter_width + column_width, line_height, ui_frame_theme(frame).bg_diff_add)
			diff_draw_gutter(frame, right_gutter, row_y, gutter_width, cell_width, row.new_no)
			diff_draw_cell(
				frame,
				right_text,
				row_y,
				row.text,
				max(int(column_width / cell_width), 1),
				.Diff_Add if row.kind == .Add else .Secondary,
			)
		}
	}
}

diff_view_unified :: proc(
	frame: ^Ui_Frame,
	x, y, width: i32,
	rows: []Diff_Row,
	gutter_width, gap, cell_width: i32,
) {
	assert(frame != nil && frame.open, "diff_view_unified: invalid frame")
	assert(gutter_width > 0 && gap > 0 && cell_width > 0)
	line_height := ui_frame_metrics(frame).FONT_SIZE_SMALL + 2
	gutter_x := x + gap
	marker_x := gutter_x + gutter_width * 2
	text_x := marker_x + cell_width * 2
	max_characters := max(int((x + width - gap - text_x) / cell_width), 1)
	for row, index in rows {
		row_y := y + i32(index) * line_height
		if row.kind == .Hunk || row.kind == .Metadata {
			text(frame, row.text, gutter_x, row_y, .Small, .Muted)
			continue
		}
		marker, ink := " ", Ink.Secondary
		if row.kind == .Add {
			marker, ink = "+", .Diff_Add
			draw_rectangle(
				frame,
				gutter_x,
				row_y,
				x + width - gap - gutter_x,
				line_height,
				ui_frame_theme(frame).bg_diff_add,
			)
		} else if row.kind == .Del {
			marker, ink = "-", .Diff_Remove
			draw_rectangle(
				frame,
				gutter_x,
				row_y,
				x + width - gap - gutter_x,
				line_height,
				ui_frame_theme(frame).bg_diff_remove,
			)
		}
		diff_draw_gutter(frame, gutter_x, row_y, gutter_width, cell_width, row.old_no)
		diff_draw_gutter(
			frame,
			gutter_x + gutter_width,
			row_y,
			gutter_width,
			cell_width,
			row.new_no,
		)
		text(frame, marker, marker_x, row_y, .Small, ink)
		diff_draw_cell(frame, text_x, row_y, row.text, max_characters, ink)
	}
}
