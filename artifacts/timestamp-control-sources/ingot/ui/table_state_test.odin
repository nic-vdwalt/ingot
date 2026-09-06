#+build !js
package ui

import "core:testing"

@(private = "file")
sample_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {
		label = "Name",
		track = grow(3, 0),
	}
	buffer[1] = {
		label   = "Count",
		track   = fixed(80),
		numeric = true,
	}
	buffer[2] = {
		label = "State",
		track = grow(1, 0),
	}
	return buffer[:3]
}

@(test)
test_table_state_init_seeds_identity_once :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	testing.expect_value(t, st.count, 3)
	testing.expect(t, st.initialized)
	for index in 0 ..< 3 {
		testing.expect_value(t, int(st.order[index]), index)
		testing.expect(t, st.visible[index])
		testing.expect_value(t, st.width_px[index], i32(0))
	}
	testing.expect_value(t, st.sort.column, i32(-1))

	// Idempotent: a second init must not stomp caller mutations.
	st.width_px[1] = 123
	table_state_init(&st, specs)
	testing.expect_value(t, st.width_px[1], i32(123))
}

@(test)
test_table_solve_widths_orders_and_skips_hidden :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	// Move State (original 2) to the front and hide Count (original 1).
	table_order_move(&st, 2, 0)
	_ = table_visibility_toggle(&st, 1)

	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(&st, specs, tracks[:], cols[:])
	testing.expect_value(t, n, 2)
	testing.expect_value(t, cols[0], i32(2)) // State first after the move
	testing.expect_value(t, cols[1], i32(0)) // Name second; Count hidden
}

@(test)
test_table_solve_widths_applies_width_override :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	table_resize_apply(&st, 0, 210, 32)

	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(&st, specs, tracks[:], cols[:])
	testing.expect_value(t, n, 3)
	testing.expect_value(t, tracks[0].kind, Track_Kind.Fixed)
	testing.expect_value(t, tracks[0].basis, i32(210))
}

@(test)
test_table_resolve_pixels_conserves_all_grow :: proc(t: ^testing.T) {
	tracks := []Track{grow(1, 0), grow(1, 0), grow(2, 0)}
	widths: [3]i32
	table_resolve_pixels(tracks, 600, 0, widths[:])
	total := widths[0] + widths[1] + widths[2]
	testing.expect_value(t, total, i32(600))
	testing.expect(t, widths[2] > widths[0], "weight 2 must exceed weight 1")
}

@(test)
test_table_resolve_pixels_respects_fixed :: proc(t: ^testing.T) {
	tracks := []Track{fixed(90), grow(1, 0)}
	widths: [2]i32
	table_resolve_pixels(tracks, 400, 0, widths[:])
	testing.expect_value(t, widths[0], i32(90))
	testing.expect_value(t, widths[1], i32(310))
}

@(test)
test_table_order_move_is_a_stable_rotation :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	// 0,1,2 -> move slot 0 to slot 2 -> 1,2,0
	table_order_move(&st, 0, 2)
	testing.expect_value(t, int(st.order[0]), 1)
	testing.expect_value(t, int(st.order[1]), 2)
	testing.expect_value(t, int(st.order[2]), 0)
	// Round-trips back: move slot 2 to slot 0 -> 0,1,2
	table_order_move(&st, 2, 0)
	testing.expect_value(t, int(st.order[0]), 0)
	testing.expect_value(t, int(st.order[1]), 1)
	testing.expect_value(t, int(st.order[2]), 2)
}

@(test)
test_table_visibility_refuses_last_column :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	testing.expect(t, table_visibility_toggle(&st, 0))
	testing.expect(t, table_visibility_toggle(&st, 1))
	testing.expect_value(t, table_visible_count(&st), 1)
	// The single remaining column cannot be hidden.
	testing.expect(t, !table_visibility_toggle(&st, 2))
	testing.expect(t, st.visible[2])
	// It can be shown again.
	testing.expect(t, table_visibility_toggle(&st, 0))
	testing.expect_value(t, table_visible_count(&st), 2)
}

@(test)
test_table_resize_apply_clamps_to_min :: proc(t: ^testing.T) {
	columns: [4]Table_Column
	specs := sample_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	table_resize_apply(&st, 0, 5, 32)
	testing.expect_value(t, st.width_px[0], i32(32))
	table_resize_apply(&st, 0, 140, 32)
	testing.expect_value(t, st.width_px[0], i32(140))
}

@(test)
test_table_resize_hit_finds_inner_border :: proc(t: ^testing.T) {
	// Two columns [0,100) and [100,250): bounds are the three edges.
	bounds := []i32{0, 100, 250}
	testing.expect_value(t, table_resize_hit(bounds, 101, 4), i32(0))
	testing.expect_value(t, table_resize_hit(bounds, 96, 4), i32(0))
	// Outer edges are never grabbable.
	testing.expect_value(t, table_resize_hit(bounds, 0, 4), i32(-1))
	testing.expect_value(t, table_resize_hit(bounds, 250, 4), i32(-1))
	// Far from any border.
	testing.expect_value(t, table_resize_hit(bounds, 50, 4), i32(-1))
	// A single column has no inner border.
	single := []i32{0, 100}
	testing.expect_value(t, table_resize_hit(single, 100, 4), i32(-1))
}

@(test)
test_table_reorder_drop_slot_uses_midpoints :: proc(t: ^testing.T) {
	// Three columns: [0,100) [100,200) [200,300); midpoints 50, 150, 250.
	bounds := []i32{0, 100, 200, 300}
	testing.expect_value(t, table_reorder_drop_slot(bounds, 10), 0)
	testing.expect_value(t, table_reorder_drop_slot(bounds, 120), 1)
	testing.expect_value(t, table_reorder_drop_slot(bounds, 210), 2)
	// Past the end clamps to the last slot.
	testing.expect_value(t, table_reorder_drop_slot(bounds, 999), 2)
}
