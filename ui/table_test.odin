#+build !js
package ui

import "core:testing"

@(test)
test_table_sort_toggle_cycles_direction :: proc(t: ^testing.T) {
	sort := Table_Sort {
		column = -1,
	}
	table_sort_toggle(&sort, 2)
	testing.expect_value(t, sort.column, i32(2))
	testing.expect(t, !sort.descending)
	table_sort_toggle(&sort, 2)
	testing.expect(t, sort.descending)
	table_sort_toggle(&sort, 0)
	testing.expect_value(t, sort.column, i32(0))
	testing.expect(t, !sort.descending)
}

@(test)
test_table_tracks_copies_column_geometry :: proc(t: ^testing.T) {
	columns := []Table_Column {
		{label = "Name", track = grow()},
		{label = "Hours", track = fixed(90), numeric = true},
	}
	buffer: [TABLE_COLUMN_COUNT_MAX]Track
	tracks := table_tracks(columns, buffer[:])
	testing.expect_value(t, len(tracks), 2)
	testing.expect_value(t, tracks[1].basis, i32(90))
}

@(test)
test_toast_queue_evicts_oldest_and_expires :: proc(t: ^testing.T) {
	st: Toast_State
	for index in 0 ..< TOAST_CAP + 2 {
		_ = index
		toast_push(&st, .Info, "message")
	}
	testing.expect_value(t, st.count, TOAST_CAP)
	toast_tick(&st, TOAST_SECONDS + 1)
	testing.expect_value(t, st.count, 0)
}

@(test)
test_toast_tick_keeps_fresh_items :: proc(t: ^testing.T) {
	st: Toast_State
	toast_push(&st, .Success, "saved")
	toast_tick(&st, 1)
	testing.expect_value(t, st.count, 1)
	testing.expect(t, st.items[0].remaining < TOAST_SECONDS)
}

// --- Table rows -------------------------------------------------------------
// table_row_begin exists so a data row cannot be opened down the enclosing
// column by accident. These pin the geometry it must produce and the tracks it
// must share with the header, since a row that resolves different tracks
// drifts out of alignment as the window resizes.

@(private = "file")
test_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "Name", track = grow(3, 0)}
	buffer[1] = {label = "Count", track = fixed(80), numeric = true}
	buffer[2] = {label = "State", track = fixed(120)}
	return buffer[:3]
}

@(test)
test_table_row_cells_advance_horizontally :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	specs := test_columns(columns[:])

	l: Layout
	layout_begin(&l, 10, 100, 600, 200)
	table_row_begin(&l, 28, specs, tracks[:])
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	table_row_end(&l)
	layout_end(&l)

	testing.expect(t, b.x > a.x, "cells must advance along x, not y")
	testing.expect(t, c.x > b.x, "cells must advance along x, not y")
	testing.expect_value(t, a.y, b.y)
	testing.expect_value(t, a.h, i32(28))
	testing.expect_value(t, c.h, i32(28))
}

@(test)
test_table_row_cells_do_not_overlap :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	specs := test_columns(columns[:])

	l: Layout
	layout_begin(&l, 0, 0, 600, 200)
	table_row_begin(&l, 30, specs, tracks[:])
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	table_row_end(&l)
	layout_end(&l)

	testing.expect(t, b.x >= a.x + a.w, "cell 1 overlaps cell 0")
	testing.expect(t, c.x >= b.x + b.w, "cell 2 overlaps cell 1")
}

@(test)
test_table_row_cells_stay_inside_the_row :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	specs := test_columns(columns[:])

	l: Layout
	layout_begin(&l, 10, 100, 600, 200)
	table_row_begin(&l, 28, specs, tracks[:])
	cells: [3]Rect_I32
	for index in 0 ..< 3 {
		cells[index] = flex_next(&l)
	}
	table_row_end(&l)
	layout_end(&l)

	for cell in cells {
		testing.expect(t, cell.x >= 10, "cell starts left of the row")
		testing.expect(t, cell.x + cell.w <= 610, "cell overflows the row")
		testing.expect(t, cell.w >= 0, "negative cell width")
	}
}

@(test)
test_table_row_reuses_the_header_tracks :: proc(t: ^testing.T) {
	// The row and the header must resolve the SAME tracks or the columns drift
	// apart as the window resizes.
	columns: [4]Table_Column
	header_tracks: [TABLE_COLUMN_COUNT_MAX]Track
	row_tracks: [TABLE_COLUMN_COUNT_MAX]Track
	specs := test_columns(columns[:])
	from_header := table_tracks(specs, header_tracks[:])

	l: Layout
	layout_begin(&l, 0, 0, 600, 200)
	table_row_begin(&l, 28, specs, row_tracks[:])
	for index in 0 ..< len(specs) {
		_ = flex_next(&l)
	}
	table_row_end(&l)
	layout_end(&l)

	testing.expect_value(t, len(from_header), len(specs))
	for index in 0 ..< len(specs) {
		testing.expect_value(t, row_tracks[index].kind, from_header[index].kind)
		testing.expect_value(t, row_tracks[index].basis, from_header[index].basis)
	}
}

@(test)
test_table_rows_stack_downward :: proc(t: ^testing.T) {
	// Consecutive rows advance down the enclosing column: the row consumed
	// height, so the next one starts below it rather than on top of it.
	columns: [4]Table_Column
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	specs := test_columns(columns[:])

	l: Layout
	layout_begin(&l, 0, 0, 600, 200)
	table_row_begin(&l, 30, specs, tracks[:])
	first := flex_next(&l)
	for index in 1 ..< len(specs) {
		_ = flex_next(&l)
	}
	table_row_end(&l)
	table_row_begin(&l, 30, specs, tracks[:])
	second := flex_next(&l)
	for index in 1 ..< len(specs) {
		_ = flex_next(&l)
	}
	table_row_end(&l)
	layout_end(&l)

	testing.expect(t, second.y >= first.y + first.h, "rows must not overlap")
	testing.expect_value(t, first.x, second.x)
}
