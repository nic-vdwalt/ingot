// LIB-CANDIDATE: imports only core:*.
// Sortable table primitives. The library owns the header (click-to-sort with
// direction indicators) and the shared column tracks; the caller owns the
// data, does the actual sorting, and draws rows with table_row_begin (^Layout)
// or flex_row_begin (^Ui) using table_tracks so cells align with the header.
package ui

TABLE_COLUMN_COUNT_MAX :: MAX_LAYOUT_FLEX

// Table_Column declares one column: a header label plus the flex track every
// row must reuse. numeric right-aligns the header (and by convention cells).
Table_Column :: struct {
	label:   string,
	track:   Track,
	numeric: bool,
}

// Table_Sort is the caller-owned sort state: which column and direction.
// column -1 means unsorted.
Table_Sort :: struct {
	column:     i32,
	descending: bool,
}

// table_tracks copies the column tracks into buffer so callers can open row
// flex containers with exactly the header's geometry.
table_tracks :: proc(columns: []Table_Column, buffer: []Track) -> []Track {
	assert(len(columns) > 0, "table_tracks: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_tracks: too many columns")
	assert(len(buffer) >= len(columns), "table_tracks: buffer too small")
	for column, index in columns {
		buffer[index] = column.track
	}
	return buffer[:len(columns)]
}

// table_row_begin carves one data row from the enclosing column and opens the
// header's column tracks across it, so a cell sequence cannot be declared down
// the wrong axis.
//
// This exists because the two-step form is easy to get subtly wrong: calling
// flex_begin on the enclosing COLUMN, rather than pushing a row first, splits
// the row's height into N bands and stacks every cell at the same x. The run
// is fully consumed either way, so flex_end, layout_pop and layout_end all
// pass and no assertion fires. Pairing the push and the flex here makes the
// correct form the shortest one, and the axis argument turns the incorrect
// form into an immediate assertion rather than silent overlap.
//
// Balance with table_row_end. Cells are taken with flex_next, exactly as the
// header takes them, so a row always resolves the same tracks the header did.
table_row_begin :: proc(
	l: ^Layout,
	height: i32,
	columns: []Table_Column,
	buffer: []Track,
	gap: i32 = 0,
) {
	assert(l != nil, "table_row_begin: nil l")
	assert(height > 0, "table_row_begin: non-positive height")
	assert(len(columns) > 0, "table_row_begin: empty columns")
	assert(len(buffer) >= len(columns), "table_row_begin: buffer too small")
	push_row(l, height, gap)
	flex_begin(l, table_tracks(columns, buffer), axis = .Row)
}

// table_row_end closes the row opened by table_row_begin. It calls flex_end
// before popping so an UNDER-consumed cell run fails here, naming the row,
// rather than several frames later inside layout_pop.
table_row_end :: proc(l: ^Layout) {
	assert(l != nil, "table_row_end: nil l")
	assert(l.depth > 1, "table_row_end: no row pushed")
	flex_end(l)
	layout_pop(l)
}

// table_sort_toggle applies one header click: first click sorts ascending,
// a second click on the same column flips direction. Pure and testable.
table_sort_toggle :: proc(sort: ^Table_Sort, column: i32) {
	assert(sort != nil, "table_sort_toggle: nil sort")
	assert(column >= 0, "table_sort_toggle: negative column")
	if sort.column == column {
		sort.descending = !sort.descending
	} else {
		sort.column = column
		sort.descending = false
	}
}

// table_header carves one header row of clickable, focusable column labels
// with an ascending/descending indicator on the active sort column. Returns
// true on the frame the sort changed.
table_header :: proc(
	u: ^Ui,
	key: string,
	columns: []Table_Column,
	sort: ^Table_Sort,
	height: i32 = 30,
) -> (
	changed: bool,
) {
	assert(u != nil && u.open, "table_header: frame not open")
	assert(sort != nil, "table_header: nil sort")
	assert(len(columns) > 0, "table_header: empty columns")
	assert(len(columns) <= TABLE_COLUMN_COUNT_MAX, "table_header: too many columns")
	assert(height > 0, "table_header: non-positive height")
	frame := u.frame
	metrics := ui_frame_metrics(frame)
	tracks_buffer: [TABLE_COLUMN_COUNT_MAX]Track
	scope_begin(u, key)
	defer scope_end(u)
	flex_row_begin(u, height, table_tracks(columns, tracks_buffer[:]), align = .Center)
	defer flex_row_end(u)
	for column, index in columns {
		rect := flex_slot_next(u, height)
		if !slot_visible(rect) do continue
		widget := id(u, u64(index) + 1)
		fo := focus(u, widget)
		focus_opt_click(frame, fo, rect.x, rect.y, rect.w, rect.h)
		rrect := rect_f32(rect)
		it := interact(frame, rrect)
		if it.hovered do request_cursor(frame, .POINTING_HAND)
		clicked := it.clicked || focus_opt_activated(frame, fo)
		if clicked {
			table_sort_toggle(sort, i32(index))
			changed = true
		}
		is_active := sort.column == i32(index)
		label := column.label
		if is_active do label = table_header_label(frame, label, sort.descending)
		color := Ink.Primary if is_active else .Secondary
		label_w := text_width(frame, label, .Label)
		text_x := rect.x + ui_frame_sc(frame, 4)
		if column.numeric do text_x = rect.x + rect.w - label_w - ui_frame_sc(frame, 4)
		text(frame, label, text_x, rect.y + (rect.h - metrics.FONT_SIZE_LABEL) / 2, .Label, color)
		if focus_opt_focused(fo) do draw_focus_ring(frame, rect.x, rect.y, rect.w, rect.h)
		semantic_push(frame, .Button, rect, column.label, {}, fo, widget = widget)
	}
	return changed
}

// table_header_label appends the sort-direction arrow in the temp allocator.
@(private = "file")
table_header_label :: proc(frame: ^Ui_Frame, label: string, descending: bool) -> string {
	assert(frame != nil, "table_header_label: nil frame")
	arrow := " \u25BE" if descending else " \u25B4"
	joined := make([]u8, len(label) + len(arrow), ui_frame_allocator(frame))
	copy(joined, label)
	copy(joined[len(label):], arrow)
	return string(joined)
}
