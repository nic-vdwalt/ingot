#+build !js
package ui

import "core:testing"
import rl "ingot:gfx"

@(private = "file")
expect_close :: proc(t: ^testing.T, got, want: f32, loc := #caller_location) {
	testing.expect(t, abs(got - want) < 1e-4, loc = loc)
}

@(test)
chart_nice_ticks_basic :: proc(t: ^testing.T) {
	lo, hi, step := nice_ticks(0, 100, 5)
	expect_close(t, step, 20)
	expect_close(t, lo, 0)
	expect_close(t, hi, 100)
}

@(test)
chart_nice_ticks_fractional :: proc(t: ^testing.T) {
	lo, hi, step := nice_ticks(0, 0.87, 5)
	expect_close(t, step, 0.2)
	expect_close(t, lo, 0)
	expect_close(t, hi, 1.0)
}

@(test)
chart_nice_ticks_covers_range :: proc(t: ^testing.T) {
	cases := [?][2]f32{{-13, 47}, {3.2, 3.9}, {-100, -10}, {0.001, 0.009}}
	for c in cases {
		lo, hi, step := nice_ticks(c[0], c[1], 5)
		testing.expect(t, step > 0)
		testing.expect(t, lo <= c[0])
		testing.expect(t, hi >= c[1])
		// Tick count stays near the target (nice steps allow some slack).
		count := int((hi - lo) / step + 0.5)
		testing.expect(t, count >= 2 && count <= 12)
	}
}

@(test)
chart_nice_ticks_degenerate :: proc(t: ^testing.T) {
	// Equal min/max must still produce a usable range around the value.
	lo, hi, step := nice_ticks(5, 5, 4)
	testing.expect(t, step > 0)
	testing.expect(t, lo <= 5 && hi >= 5)
	testing.expect(t, hi > lo)

	// All zeros.
	lo, hi, step = nice_ticks(0, 0, 4)
	testing.expect(t, step > 0)
	testing.expect(t, lo <= 0 && hi >= 0)
	testing.expect(t, hi > lo)

	// Reversed inputs swap.
	lo, hi, step = nice_ticks(10, -10, 4)
	testing.expect(t, step > 0)
	testing.expect(t, lo <= -10 && hi >= 10)
}

@(test)
chart_map_y_endpoints :: proc(t: ^testing.T) {
	plot := rl.Rectangle{0, 0, 100, 100}
	expect_close(t, map_y(0, 0, 10, plot), 100) // lo → bottom
	expect_close(t, map_y(10, 0, 10, plot), 0)  // hi → top
	expect_close(t, map_y(5, 0, 10, plot), 50)  // mid
	// Out-of-range values clamp to the plot edges.
	expect_close(t, map_y(-5, 0, 10, plot), 100)
	expect_close(t, map_y(20, 0, 10, plot), 0)
	// Degenerate range does not divide by zero.
	expect_close(t, map_y(3, 3, 3, plot), 100)
}

@(test)
chart_line_hover_index :: proc(t: ^testing.T) {
	plot := rl.Rectangle{0, 0, 100, 20}
	// 5 points at x = 0, 25, 50, 75, 100; x=52 is nearest point 2.
	testing.expect_value(t, line_hover_index({52, 10}, plot, 5), 2)
	testing.expect_value(t, line_hover_index({1, 10}, plot, 5), 0)
	testing.expect_value(t, line_hover_index({99, 10}, plot, 5), 4)
	// Outside the plot → -1.
	testing.expect_value(t, line_hover_index({52, 30}, plot, 5), -1)
	testing.expect_value(t, line_hover_index({-5, 10}, plot, 5), -1)
	// Single point always index 0 while inside.
	testing.expect_value(t, line_hover_index({5, 10}, plot, 1), 0)
	// No points → -1.
	testing.expect_value(t, line_hover_index({5, 10}, plot, 0), -1)
}

@(test)
chart_bar_hover_index :: proc(t: ^testing.T) {
	plot := rl.Rectangle{0, 0, 100, 20}
	// 5 slots of width 20.
	testing.expect_value(t, bar_hover_index({45, 10}, plot, 5), 2)
	testing.expect_value(t, bar_hover_index({1, 10}, plot, 5), 0)
	testing.expect_value(t, bar_hover_index({99, 10}, plot, 5), 4)
	testing.expect_value(t, bar_hover_index({45, 30}, plot, 5), -1)
	testing.expect_value(t, bar_hover_index({45, 10}, plot, 0), -1)
}

@(test)
chart_data_range_cases :: proc(t: ^testing.T) {
	// No series at all.
	_, _, _, ok := chart_data_range(nil)
	testing.expect(t, !ok)

	// Series present but all empty.
	empty := [1]Chart_Series{{name = "e", values = nil}}
	_, _, _, ok = chart_data_range(empty[:])
	testing.expect(t, !ok)

	// Single point.
	one_vals := [1]f32{7}
	one := [1]Chart_Series{{values = one_vals[:]}}
	mn, mx, n, ok2 := chart_data_range(one[:])
	testing.expect(t, ok2)
	testing.expect_value(t, n, 1)
	expect_close(t, mn, 7)
	expect_close(t, mx, 7)

	// Multiple series: n is the longest, range spans all values.
	a_vals := [3]f32{1, 5, 3}
	b_vals := [2]f32{-2, 4}
	multi := [2]Chart_Series{{values = a_vals[:]}, {values = b_vals[:]}}
	mn, mx, n, ok2 = chart_data_range(multi[:])
	testing.expect(t, ok2)
	testing.expect_value(t, n, 3)
	expect_close(t, mn, -2)
	expect_close(t, mx, 5)

	// All-equal values still report a valid (degenerate) range.
	eq_vals := [4]f32{2, 2, 2, 2}
	eq := [1]Chart_Series{{values = eq_vals[:]}}
	mn, mx, n, ok2 = chart_data_range(eq[:])
	testing.expect(t, ok2)
	expect_close(t, mn, 2)
	expect_close(t, mx, 2)
}
