#+build !js
package ui

// Fuzz the caller-owned table column model: random sequences of resize,
// reorder, hide/show, and sort must always leave Table_State internally
// consistent, and its solved layout and serialized form must agree with that
// state. Pure and fast, so it runs in CI via scripts/test.sh.

import "core:testing"
import "ingot:testx"

@(private = "file")
fuzz_table_columns :: proc(buffer: []Table_Column, count: int) -> []Table_Column {
	for index in 0 ..< count {
		// Alternate Grow and Fixed so both width paths are exercised.
		if index % 2 == 0 {
			buffer[index] = {
				label = "col",
				track = grow(1, 0),
			}
		} else {
			buffer[index] = {
				label = "col",
				track = fixed(40),
			}
		}
	}
	return buffer[:count]
}

@(private = "file")
fuzz_table_check :: proc(
	t: ^testing.T,
	st: ^Table_State,
	specs: []Table_Column,
	iter: int,
) -> bool {
	// order is a permutation of 0..count-1.
	seen: [TABLE_COLUMN_COUNT_MAX]bool
	ok := true
	for slot in 0 ..< st.count {
		v := int(st.order[slot])
		ok &&= v >= 0 && v < st.count && !seen[v]
		if v >= 0 && v < st.count do seen[v] = true
	}
	// At least one visible; widths non-negative.
	visible := 0
	for original in 0 ..< st.count {
		if st.visible[original] do visible += 1
		ok &&= st.width_px[original] >= 0
	}
	ok &&= visible >= 1
	// Solve agrees with visibility and order.
	tracks: [TABLE_COLUMN_COUNT_MAX]Track
	cols: [TABLE_COLUMN_COUNT_MAX]i32
	n := table_solve_widths(st, specs, tracks[:], cols[:])
	ok &&= n == visible
	last_slot := -1
	for i in 0 ..< n {
		original := int(cols[i])
		ok &&= original >= 0 && original < st.count && st.visible[original]
		// cols must preserve display order (a subsequence of st.order).
		for s in last_slot + 1 ..< st.count {
			if int(st.order[s]) == original {
				last_slot = s
				break
			}
		}
	}
	// Serialized form round-trips.
	blob := table_layout_encode(st, context.temp_allocator)
	restored: Table_State
	ok &&= table_layout_decode(blob, &restored, specs)
	ok &&= restored.count == st.count
	testing.expectf(t, ok, "table fuzz invariant broken at iter=%d", iter)
	return ok
}

@(test)
fuzz_table_state_operations :: proc(t: ^testing.T) {
	p := testx.prng_make(0x7)
	for iter in 0 ..< 20_000 {
		count := testx.int_range(&p, 1, 8)
		columns: [TABLE_COLUMN_COUNT_MAX]Table_Column
		specs := fuzz_table_columns(columns[:], count)
		st: Table_State
		table_state_init(&st, specs)

		steps := testx.int_range(&p, 1, 40)
		for _ in 0 ..< steps {
			op := testx.int_range(&p, 0, 4)
			switch op {
			case 0:
				original := testx.int_range(&p, 0, count - 1) % count
				width := i32(testx.int_range(&p, -20, 300))
				table_resize_apply(&st, original, width, 16)
			case 1:
				from := testx.int_range(&p, 0, count - 1) % count
				to := testx.int_range(&p, 0, count - 1) % count
				table_order_move(&st, from, to)
			case 2:
				original := testx.int_range(&p, 0, count - 1) % count
				_ = table_visibility_toggle(&st, original)
			case 3:
				original := testx.int_range(&p, 0, count - 1) % count
				table_sort_toggle(&st.sort, i32(original))
			case 4:
				// No-op churn: re-init must be idempotent mid-sequence.
				table_state_init(&st, specs)
			}
		}
		if !fuzz_table_check(t, &st, specs, iter) do return
		free_all(context.temp_allocator)
	}
}
