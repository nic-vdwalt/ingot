#+build !js
package ui

import "core:testing"

@(test)
virtual_list_window_geometry_is_bounded :: proc(t: ^testing.T) {
	state := Virtual_List_State {
		open = true,
		region = {10, 20, 200, 120},
		count = 100,
		visible = 6,
	}
	window := Virtual_List_Window {
		first = 40,
		visible_rows = 6,
		row_height = 20,
		row_width = 200,
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
