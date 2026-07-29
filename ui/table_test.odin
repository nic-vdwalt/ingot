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
