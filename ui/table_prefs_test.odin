#+build !js
package ui

import "core:testing"

@(private = "file")
prefs_columns :: proc(buffer: []Table_Column) -> []Table_Column {
	buffer[0] = {label = "Name", track = grow(1, 0)}
	buffer[1] = {label = "Count", track = fixed(80), numeric = true}
	buffer[2] = {label = "State", track = grow(1, 0)}
	return buffer[:3]
}

// A mutated layout survives an encode -> decode round trip into a fresh state.
@(test)
test_table_layout_round_trip :: proc(t: ^testing.T) {
	columns: [3]Table_Column
	specs := prefs_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	table_order_move(&st, 0, 2)
	_ = table_visibility_toggle(&st, 1)
	table_resize_apply(&st, 0, 175, 32)
	table_sort_toggle(&st.sort, 2)
	table_sort_toggle(&st.sort, 2) // descending

	blob := table_layout_encode(&st, context.temp_allocator)

	restored: Table_State
	ok := table_layout_decode(blob, &restored, specs)
	testing.expect(t, ok, "decode must accept its own output")
	testing.expect_value(t, restored.count, st.count)
	for slot in 0 ..< st.count {
		testing.expect_value(t, restored.order[slot], st.order[slot])
	}
	for original in 0 ..< st.count {
		testing.expect_value(t, restored.visible[original], st.visible[original])
		testing.expect_value(t, restored.width_px[original], st.width_px[original])
	}
	testing.expect_value(t, restored.sort.column, st.sort.column)
	testing.expect_value(t, restored.sort.descending, st.sort.descending)
	testing.expect(t, restored.initialized)
}

// A blob whose column count no longer matches is rejected and leaves the target
// untouched, so the caller falls back to a fresh seed.
@(test)
test_table_layout_rejects_schema_drift :: proc(t: ^testing.T) {
	columns: [3]Table_Column
	specs := prefs_columns(columns[:])
	st: Table_State
	table_state_init(&st, specs)
	blob := table_layout_encode(&st, context.temp_allocator)

	// Now only two columns exist.
	fewer := specs[:2]
	target: Table_State
	ok := table_layout_decode(blob, &target, fewer)
	testing.expect(t, !ok, "count mismatch must be rejected")
	testing.expect(t, !target.initialized, "target left untouched")
}

// Garbage is rejected without panicking.
@(test)
test_table_layout_rejects_garbage :: proc(t: ^testing.T) {
	columns: [3]Table_Column
	specs := prefs_columns(columns[:])
	target: Table_State
	testing.expect(t, !table_layout_decode(transmute([]u8)string("not a layout"), &target, specs))
	testing.expect(t, !table_layout_decode(transmute([]u8)string(""), &target, specs))
	testing.expect(t, !target.initialized)
}
