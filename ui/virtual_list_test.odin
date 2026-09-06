#+build !js
package ui

import "core:testing"

@(test)
variable_list_matches_naive_prefix_and_window :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	heights: [257]i64
	for &height, offset in heights do height = i64((offset * 17) % 43)
	testing.expect(t, variable_list_reset(&index, heights[:]))
	for iteration in 0 ..< 500 {
		offset := (iteration * 31) % len(heights)
		heights[offset] = i64((iteration * 13) % 71)
		testing.expect(t, variable_list_update(&index, offset, heights[offset]))
		total: i64
		for height, position in heights {
			testing.expect_value(t, variable_list_prefix(&index, position), total)
			total += height
		}
		testing.expect_value(t, index.total, total)
		scroll := i64((iteration * 127) % int(total + 200))
		first, end := 0, 0
		top: i64
		for first < len(heights) && top + heights[first] <= scroll {
			top += heights[first]
			first += 1
		}
		end = first
		bottom := top
		for end < len(heights) && bottom < scroll + 120 {
			bottom += heights[end]
			end += 1
		}
		window := variable_list_window(&index, f64(scroll), 120)
		testing.expect_value(t, window, Variable_List_Window{first, end, top})
	}
}

@(test)
variable_list_rejects_overflow_and_preserves_index :: proc(t: ^testing.T) {
	index: Variable_List_Index
	variable_list_init(&index)
	defer variable_list_destroy(&index)
	heights := [?]i64{0, i64(max(i32)) + 10, 20}
	testing.expect(t, variable_list_reset(&index, heights[:]))
	testing.expect_value(t, variable_list_window(&index, f64(heights[1]), 10).first, 2)
	testing.expect(t, !variable_list_update(&index, 2, max(i64)))
	testing.expect(t, !variable_list_reset(&index, []i64{max(i64), 1}))
	testing.expect(t, !variable_list_update(&index, 0, -1))
	testing.expect_value(t, index.total, heights[1] + 20)
	testing.expect(t, variable_list_reset(&index, nil))
	testing.expect_value(t, variable_list_window(&index, 0, 100), Variable_List_Window{})
}

@(test)
virtual_list_window_geometry_is_bounded :: proc(t: ^testing.T) {
	state := Virtual_List_State {
		open    = true,
		region  = {10, 20, 200, 120},
		count   = 100,
		visible = 6,
	}
	window := Virtual_List_Window {
		first        = 40,
		visible_rows = 6,
		row_height   = 20,
		row_width    = 200,
	}
	first := virtual_list_row(window, &state, 40)
	last := virtual_list_row(window, &state, 45)
	testing.expect_value(t, first, Rect_I32{10, 20, 200, 20})
	testing.expect_value(t, last, Rect_I32{10, 120, 200, 20})
}

@(test)
virtual_list_count_bound_is_named :: proc(t: ^testing.T) {
	testing.expect(t, VIRTUAL_LIST_ITEM_COUNT_MAX >= 100_000)
	testing.expect(t, VIRTUAL_LIST_ITEM_COUNT_MAX < max(int))
}
