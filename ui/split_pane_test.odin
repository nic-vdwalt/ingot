#+build !js
package ui

import "core:testing"

@(test)
split_pane_layout_respects_ratio_and_minimums :: proc(t: ^testing.T) {
	result := split_pane_layout({10, 20, 400, 200}, 0.25, 4, 80, 100)
	testing.expect_value(t, result.first, Rect_I32{10, 20, 99, 200})
	testing.expect_value(t, result.divider, Rect_I32{109, 20, 4, 200})
	testing.expect_value(t, result.second, Rect_I32{113, 20, 297, 200})
	low := split_pane_layout({0, 0, 200, 100}, 0, 4, 80, 80)
	high := split_pane_layout({0, 0, 200, 100}, 1, 4, 80, 80)
	testing.expect_value(t, low.first.w, i32(80))
	testing.expect_value(t, high.second.w, i32(80))
}

@(test)
split_pane_layout_degrades_in_tight_space :: proc(t: ^testing.T) {
	result := split_pane_layout({0, 0, 3, 10}, 0.5, 4, 10, 10)
	testing.expect_value(t, result.first.w, i32(0))
	testing.expect_value(t, result.second.w, i32(0))
	testing.expect_value(t, result.divider.w, i32(4))
}
