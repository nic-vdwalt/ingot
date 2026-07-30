#+build !js
package ui

import "core:testing"

@(test)
flow_wraps_explicit_items_and_returns_content_bounds :: proc(t: ^testing.T) {
	flow: Flow_Layout
	flow_begin(&flow, {10, 20, 100, 200}, 5, 7)
	a := flow_next(&flow, 40, 20)
	b := flow_next(&flow, 55, 30)
	c := flow_next(&flow, 60, 12)
	bounds := flow_end(&flow)
	testing.expect_value(t, a, Rect_I32{10, 20, 40, 20})
	testing.expect_value(t, b, Rect_I32{55, 20, 55, 30})
	testing.expect_value(t, c, Rect_I32{10, 57, 60, 12})
	testing.expect_value(t, bounds, Rect_I32{10, 20, 100, 49})
}

@(test)
flow_exact_fit_stays_on_the_current_line :: proc(t: ^testing.T) {
	flow: Flow_Layout
	flow_begin(&flow, {0, 0, 100, 100}, 10, 4)
	a := flow_next(&flow, 45, 8)
	b := flow_next(&flow, 45, 12)
	bounds := flow_end(&flow)
	testing.expect_value(t, a, Rect_I32{0, 0, 45, 8})
	testing.expect_value(t, b, Rect_I32{55, 0, 45, 12})
	testing.expect_value(t, bounds, Rect_I32{0, 0, 100, 12})
}

@(test)
flow_clamps_oversized_width_and_reuses_state :: proc(t: ^testing.T) {
	flow: Flow_Layout
	flow_begin(&flow, {4, 8, 50, 20})
	a := flow_next(&flow, 80, 10)
	first := flow_end(&flow)
	flow_begin(&flow, {1, 2, 30, 20}, 2, 3)
	b := flow_next(&flow, 10, 5)
	second := flow_end(&flow)
	testing.expect_value(t, a, Rect_I32{4, 8, 50, 10})
	testing.expect_value(t, first, Rect_I32{4, 8, 50, 10})
	testing.expect_value(t, b, Rect_I32{1, 2, 10, 5})
	testing.expect_value(t, second, Rect_I32{1, 2, 10, 5})
}

@(test)
flow_empty_zero_width_and_capacity_are_bounded :: proc(t: ^testing.T) {
	flow: Flow_Layout
	flow_begin(&flow, {3, 4, 0, 20}, 2, 3)
	zero := flow_next(&flow, 10, 5)
	zero_bounds := flow_end(&flow)
	testing.expect_value(t, zero, Rect_I32{3, 4, 0, 5})
	testing.expect_value(t, zero_bounds, Rect_I32{3, 4, 0, 5})
	flow_begin(&flow, {0, 0, 1024, 20})
	for _ in 0 ..< MAX_FLOW_ITEMS do _ = flow_next(&flow, 1, 1)
	bounds := flow_end(&flow)
	testing.expect_value(t, bounds, Rect_I32{0, 0, 1024, 1})
}

@(test)
layout_column_carves_sequentially :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 10, 20, 300, 400, gap = 5)
	a := next(&l, 100)
	b := next(&l, 50)
	layout_end(&l)
	testing.expect_value(t, a, Rect_I32{10, 20, 300, 100})
	testing.expect_value(t, b, Rect_I32{10, 125, 300, 50}) // 20 + 100 + 5 gap
}

@(test)
layout_row_carves_horizontally :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 300, 400)
	push_row(&l, 40, gap = 4)
	a := next(&l, 100)
	b := next(&l, 60)
	layout_pop(&l)
	c := next(&l, 30)
	layout_end(&l)
	testing.expect_value(t, a, Rect_I32{0, 0, 100, 40})
	testing.expect_value(t, b, Rect_I32{104, 0, 60, 40})
	testing.expect_value(t, c, Rect_I32{0, 40, 300, 30}) // below the row
}

@(test)
layout_next_clamps_to_remaining :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 100, 50)
	a := next(&l, 40)
	b := next(&l, 40) // only 10 left
	c := next(&l, 40) // nothing left
	layout_end(&l)
	testing.expect_value(t, a.h, i32(40))
	testing.expect_value(t, b.h, i32(10))
	testing.expect_value(t, c.h, i32(0))
}

@(test)
layout_weights_sum_exactly :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 313, 100) // deliberately not divisible by 3
	push_row(&l, 100, gap = 4)
	row_weights(&l, {1, 1, 1})
	a := next_weighted(&l, 1)
	b := next_weighted(&l, 1)
	c := next_weighted(&l, 1)
	layout_pop(&l)
	layout_end(&l)
	// 313 - 2 gaps (8) = 305 divided 3 ways; shares must sum exactly.
	testing.expect_value(t, a.w + b.w + c.w, i32(305))
	testing.expect_value(t, c.x + c.w, i32(313))
}

@(test)
layout_weights_proportional :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 400, 100)
	push_row(&l, 100)
	row_weights(&l, {1, 3})
	a := next_weighted(&l, 1)
	b := next_weighted(&l, 3)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(100))
	testing.expect_value(t, b.w, i32(300))
}

@(test)
layout_spacer_and_remaining :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 200, 100)
	spacer(&l, 30)
	r := remaining(&l)
	testing.expect_value(t, r, Rect_I32{0, 30, 200, 70})
	spacer(&l, 999) // clamped to what's left
	testing.expect_value(t, remaining(&l).h, i32(0))
	layout_end(&l)
}

@(test)
layout_push_column_fills_row_remainder :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 300, 200)
	push_row(&l, 100)
	side := next(&l, 80) // fixed sidebar cell
	push_column(&l, gap = 2)
	a := next(&l, 40)
	b := next(&l, 40)
	layout_pop(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, side, Rect_I32{0, 0, 80, 100})
	testing.expect_value(t, a, Rect_I32{80, 0, 220, 40})
	testing.expect_value(t, b, Rect_I32{80, 42, 220, 40})
}

@(test)
layout_cross_align_center :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 200, 100)
	push_row(&l, 60, cross_align = .Center)
	a := next_sized(&l, 50, 20) // 20px tall, centered in 60px row
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a, Rect_I32{0, 20, 50, 20})
}

@(test)
layout_insets_columns_and_remaining :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 10, 20, 300, 180, 8)
	layout_inset(&l, {left = 12, top = 10, right = 16, bottom = 14})
	push_row(&l, 80, 6)
	push_column_sized(&l, 100, 4)
	testing.expect_value(t, next(&l, 24), Rect_I32{22, 30, 100, 24})
	testing.expect_value(t, take_remaining(&l), Rect_I32{22, 58, 100, 52})
	layout_pop(&l)
	push_column_sized(&l, 166)
	testing.expect_value(t, take_remaining(&l), Rect_I32{128, 30, 166, 80})
	layout_pop(&l)
	layout_pop(&l)
	testing.expect_value(t, take_remaining(&l), Rect_I32{22, 118, 272, 68})
	layout_end(&l)

	testing.expect_value(t, rect_inset({0, 0, 10, 8}, insets(9)), Rect_I32{9, 9, 0, 0})
}

@(test)
layout_reusable_after_end :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 100, 100)
	_ = next(&l, 50)
	layout_end(&l)
	layout_begin(&l, 5, 5, 90, 90)
	a := next(&l, 10)
	layout_end(&l)
	testing.expect_value(t, a, Rect_I32{5, 5, 90, 10})
}

@(test)
layout_flex_fixed_fit_grow :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 400, 40)
	push_row(&l, 40, gap = 10)
	flex_begin(&l, {fixed(80), fit(100), grow()})
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(80))
	testing.expect_value(t, b.w, i32(100))
	testing.expect_value(t, c.w, i32(200))
}

@(test)
layout_flex_percent_uses_content_space :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 400, 40)
	push_row(&l, 40, gap = 10)
	flex_begin(&l, {percent(0.25), grow()})
	a := flex_next(&l)
	b := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(97))
	testing.expect_value(t, b.w, i32(293))
}

@(test)
layout_flex_grow_respects_weight_and_max :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 500, 40)
	push_row(&l, 40)
	flex_begin(&l, {grow(1, max_size = 100), grow(1), grow(2)})
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(100))
	testing.expect_value(t, a.w + b.w + c.w, i32(500))
	testing.expect(t, c.w == b.w * 2 || c.w == b.w * 2 + 1)
}

@(test)
layout_flex_compresses_fit_to_minimum :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 180, 40)
	push_row(&l, 40)
	flex_begin(&l, {fixed(100), fit(120, min_size = 40)})
	a := flex_next(&l)
	b := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(100))
	testing.expect_value(t, b.w, i32(80))
}

@(test)
layout_flex_constraints_rounding_and_column :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 40, 303, gap = 1)
	flex_begin(&l, {fit(100, max_size = 60), percent(0.5, max_size = 80), grow(1), grow(2)})
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	d := flex_next(&l)
	layout_end(&l)
	testing.expect_value(t, a.h, i32(60))
	testing.expect_value(t, b.h, i32(80))
	testing.expect_value(t, a.h + b.h + c.h + d.h, i32(300))
	testing.expect(t, d.h == c.h * 2 || d.h == c.h * 2 + 1)
}

@(test)
layout_flex_overflow_clips_and_reuses_layout :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 100, 20)
	push_row(&l, 20)
	flex_begin(&l, {fixed(80), fixed(80), grow()})
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.w, i32(80))
	testing.expect_value(t, b.w, i32(20))
	testing.expect_value(t, c.w, i32(0))

	layout_begin(&l, 0, 0, 100, 20)
	push_row(&l, 20)
	flex_begin(&l, {fixed(20)})
	_ = flex_next(&l)
	row_weights(&l, {1, 1})
	d := next_weighted(&l, 1)
	e := next_weighted(&l, 1)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, d.w + e.w, i32(80))
}

@(test)
fit_column_returns_exact_bounds_without_trailing_gap :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin(&column, 10, 20, 180, gap = 6)
	a := fit_column_next(&column, 22)
	b := fit_column_next(&column, 30)
	bounds := fit_column_end(&column)
	testing.expect_value(t, a, Rect_I32{10, 20, 180, 22})
	testing.expect_value(t, b, Rect_I32{10, 48, 180, 30})
	testing.expect_value(t, bounds, Rect_I32{10, 20, 180, 58})
}

@(test)
fit_column_space_and_conditional_rows :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin(&column, 4, 8, 100, gap = 3)
	_ = fit_column_next(&column, 10)
	fit_column_space(&column, 7)
	show_optional := false
	if show_optional {
		_ = fit_column_next(&column, 40)
	}
	last := fit_column_next(&column, 20)
	bounds := fit_column_end(&column)
	testing.expect_value(t, last, Rect_I32{4, 28, 100, 20})
	testing.expect_value(t, bounds.h, i32(40))
}

// An unbounded column is unchanged: it reports no overflow and unlimited room.
@(test)
fit_column_unbounded_never_reports_overflow :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin(&column, 0, 0, 100)
	_ = fit_column_next(&column, 10_000)
	testing.expect_value(t, fit_column_remaining(&column), max(i32))
	testing.expect_value(t, fit_column_overflow(&column), i32(0))
	testing.expect_value(t, fit_column_end(&column).h, i32(10_000))
}

// Exact fit consumes the budget without reporting overflow.
@(test)
fit_column_bounded_exact_fit_has_no_overflow :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin_bounded(&column, 5, 7, 90, 46, gap = 4)
	a := fit_column_next(&column, 20)
	b := fit_column_next(&column, 22)
	bounds := fit_column_end(&column)
	testing.expect_value(t, a, Rect_I32{5, 7, 90, 20})
	testing.expect_value(t, b, Rect_I32{5, 31, 90, 22})
	testing.expect_value(t, bounds, Rect_I32{5, 7, 90, 46})
	testing.expect_value(t, fit_column_overflow(&column), i32(0))
}

// Past the budget, rows collapse to zero height instead of being placed
// outside the panel. slot_visible then reports them invisible.
@(test)
fit_column_bounded_exhaustion_yields_zero_height_rows :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin_bounded(&column, 0, 0, 100, 30)
	first := fit_column_next(&column, 20)
	second := fit_column_next(&column, 20)
	third := fit_column_next(&column, 20)
	bounds := fit_column_end(&column)
	testing.expect_value(t, first, Rect_I32{0, 0, 100, 20})
	// Only 10 px were left, so the second row is truncated, not displaced.
	testing.expect_value(t, second, Rect_I32{0, 20, 100, 10})
	testing.expect_value(t, third, Rect_I32{0, 30, 100, 0})
	testing.expect(t, !slot_visible(third), "exhausted row must report invisible")
	testing.expect_value(t, bounds.h, i32(30))
	// 10 lost from the second row, 20 from the third.
	testing.expect_value(t, fit_column_overflow(&column), i32(30))
	testing.expect_value(t, fit_column_remaining(&column), i32(0))
}

// A budget computed as `bottom - cursor` legitimately goes negative on a short
// window. That must degrade to "nothing fits", not trip an assert.
@(test)
fit_column_bounded_negative_budget_places_nothing :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin_bounded(&column, 3, 9, -40, -100, gap = 5)
	row := fit_column_next(&column, 25)
	bounds := fit_column_end(&column)
	testing.expect_value(t, row, Rect_I32{3, 9, 0, 0})
	testing.expect_value(t, bounds, Rect_I32{3, 9, 0, 0})
	testing.expect_value(t, fit_column_overflow(&column), i32(25))
}

// fit_column_space respects the budget too, so a spacer cannot push later rows
// past the bottom edge.
@(test)
fit_column_bounded_space_is_clamped :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin_bounded(&column, 0, 0, 50, 20)
	fit_column_space(&column, 100)
	row := fit_column_next(&column, 10)
	testing.expect_value(t, row, Rect_I32{0, 20, 50, 0})
	testing.expect_value(t, fit_column_end(&column).h, i32(20))
	testing.expect_value(t, fit_column_overflow(&column), i32(90))
}

@(test)
fit_column_reuses_caller_owned_state :: proc(t: ^testing.T) {
	column: Fit_Column
	fit_column_begin(&column, 0, 0, 50)
	_ = fit_column_next(&column, 12)
	first := fit_column_end(&column)
	fit_column_begin(&column, 5, 7, 60, gap = 4)
	_ = fit_column_next(&column, 8)
	second := fit_column_end(&column)
	testing.expect_value(t, first, Rect_I32{0, 0, 50, 12})
	testing.expect_value(t, second, Rect_I32{5, 7, 60, 8})
}

@(test)
layout_overflow_never_advances_outside_root :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 100, 200, 40, 30, gap = max(i32))
	a := next(&l, 20)
	b := next(&l, 20)
	c := next(&l, max(i32))
	end := remaining(&l)
	layout_end(&l)
	testing.expect_value(t, a, Rect_I32{100, 200, 40, 20})
	testing.expect_value(t, b, Rect_I32{100, 230, 40, 0})
	testing.expect_value(t, c, Rect_I32{100, 230, 40, 0})
	testing.expect_value(t, end, Rect_I32{100, 230, 40, 0})
}

@(test)
layout_weighted_math_handles_large_valid_values :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, max(i32), 1)
	push_row(&l, 1)
	row_weights(&l, {max(i32) / 2, max(i32) / 2})
	a := next_weighted(&l, max(i32) / 2)
	b := next_weighted(&l, max(i32) / 2)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, i64(a.w) + i64(b.w), i64(max(i32)))
	testing.expect_value(t, i64(b.x) + i64(b.w), i64(max(i32)))
}

@(test)
layout_flex_justify_center_and_end_offset_the_run :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 400, 80)
	push_row(&l, 40, gap = 10)
	flex_begin(&l, {fixed(50), fixed(50)}, justify = .Center)
	a := flex_next(&l)
	b := flex_next(&l)
	layout_pop(&l)
	// 400 - 110 run = 290 leftover; centered run starts at 145.
	testing.expect_value(t, a.x, i32(145))
	testing.expect_value(t, b.x, i32(205))
	push_row(&l, 40, gap = 10)
	flex_begin(&l, {fixed(50), fixed(50)}, justify = .End)
	c := flex_next(&l)
	d := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, c.x, i32(290))
	testing.expect_value(t, d.x + d.w, i32(400))
}

@(test)
layout_flex_justify_space_between_sums_exactly :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 313, 40) // leftover deliberately not divisible
	push_row(&l, 40)
	flex_begin(&l, {fixed(50), fixed(50), fixed(50)}, justify = .Space_Between)
	a := flex_next(&l)
	b := flex_next(&l)
	c := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, a.x, i32(0))
	testing.expect_value(t, c.x + c.w, i32(313))
	// Both between-gaps carry the 163 leftover, split without loss.
	gap_ab := b.x - (a.x + a.w)
	gap_bc := c.x - (b.x + b.w)
	testing.expect_value(t, gap_ab + gap_bc, i32(163))
	testing.expect(t, abs(gap_ab - gap_bc) <= 1, "shares must differ by at most one pixel")
}

@(test)
layout_flex_justify_with_grow_leaves_no_free_space :: proc(t: ^testing.T) {
	l: Layout
	layout_begin(&l, 0, 0, 300, 40)
	push_row(&l, 40)
	flex_begin(&l, {fixed(60), grow()}, justify = .Space_Between)
	a := flex_next(&l)
	b := flex_next(&l)
	layout_pop(&l)
	layout_end(&l)
	// An uncapped grow track absorbs the free space, so justify is a no-op.
	testing.expect_value(t, a, Rect_I32{0, 0, 60, 40})
	testing.expect_value(t, b, Rect_I32{60, 0, 240, 40})
}

@(test)
grid_cells_span_bounds_exactly_and_wrap :: proc(t: ^testing.T) {
	grid: Grid
	grid_begin(&grid, {10, 20, 313, 0}, cols = 3, row_h = 26, gap_x = 4, gap_y = 6)
	a := grid_next(&grid)
	b := grid_next(&grid)
	c := grid_next(&grid)
	d := grid_next(&grid)
	bounds := grid_end(&grid)
	// 313 - 2 gaps (8) = 305 divided 3 ways; the last cell ends on the edge.
	testing.expect_value(t, a.w + b.w + c.w, i32(305))
	testing.expect_value(t, c.x + c.w, i32(323))
	testing.expect(t, abs(a.w - c.w) <= 1, "cell widths must differ by at most one pixel")
	testing.expect_value(t, a, Rect_I32{10, 20, a.w, 26})
	testing.expect_value(t, d, Rect_I32{10, 52, a.w, 26})
	testing.expect_value(t, bounds, Rect_I32{10, 20, 313, 58})
}

@(test)
grid_degrades_on_narrow_bounds_and_reuses_state :: proc(t: ^testing.T) {
	grid: Grid
	// Gaps wider than the bounds: cells collapse to invisible, no trap.
	grid_begin(&grid, {0, 0, 5, 0}, cols = 4, row_h = 10, gap_x = 8)
	squeezed := grid_next(&grid)
	_ = grid_end(&grid)
	testing.expect_value(t, squeezed.w, i32(0))
	testing.expect(t, !slot_visible(squeezed), "collapsed cell must report invisible")
	grid_begin(&grid, {2, 3, 100, 0}, cols = 2, row_h = 12)
	first := grid_next(&grid)
	second := grid_end(&grid)
	testing.expect_value(t, first, Rect_I32{2, 3, 50, 12})
	testing.expect_value(t, second, Rect_I32{2, 3, 100, 12})
}

@(test)
grid_empty_and_full_capacity_are_bounded :: proc(t: ^testing.T) {
	grid: Grid
	grid_begin(&grid, {0, 0, 100, 0}, cols = 1, row_h = 9)
	empty := grid_end(&grid)
	testing.expect_value(t, empty, Rect_I32{0, 0, 100, 0})
	grid_begin(&grid, {0, 0, 4096, 0}, cols = 64, row_h = 1)
	for _ in 0 ..< MAX_GRID_ITEMS do _ = grid_next(&grid)
	bounds := grid_end(&grid)
	testing.expect_value(t, bounds.h, i32(64))
}

// grid_visible_range lets a large grid skip building off-screen cells, so its
// range must agree exactly with the geometry grid_next produces. The stress
// case that motivated it is 1000 buttons in a 200 px pane: an off-by-one here
// shows up as a row of controls missing at a viewport edge.
@(test)
grid_visible_range_matches_cell_geometry :: proc(t: ^testing.T) {
	// 4 columns, 20 px rows, 5 px gaps: row r spans y = r*25 .. r*25 + 20.
	BOUNDS :: Rect_I32{0, 0, 400, 0}
	COUNT :: i32(40) // 10 rows
	// Band covering rows 2..4 (y 50..120) exactly.
	first, end := grid_visible_range(BOUNDS, 4, 20, 5, COUNT, 50, 120)
	testing.expect_value(t, first, i32(8)) // row 2 * 4 cols
	testing.expect_value(t, end, i32(20)) // through row 4

	// Cross-check against the real layout: every returned cell intersects the
	// band, and the cells just outside the range do not.
	grid: Grid
	grid_begin(&grid, BOUNDS, cols = 4, row_h = 20, gap_y = 5)
	for index in i32(0) ..< COUNT {
		cell := grid_next(&grid)
		intersects := cell.y + cell.h >= 50 && cell.y <= 120
		in_range := index >= first && index < end
		testing.expect_value(t, in_range, intersects)
	}
	_ = grid_end(&grid)
}

@(test)
grid_visible_range_handles_edges_and_degenerate_input :: proc(t: ^testing.T) {
	BOUNDS :: Rect_I32{0, 100, 400, 0}
	COUNT :: i32(40)

	// A band entirely above or below the content selects nothing.
	first, end := grid_visible_range(BOUNDS, 4, 20, 5, COUNT, 0, 50)
	testing.expect_value(t, first, i32(0))
	testing.expect_value(t, end, i32(0))
	first, end = grid_visible_range(BOUNDS, 4, 20, 5, COUNT, 10_000, 20_000)
	testing.expect_value(t, first, i32(0))
	testing.expect_value(t, end, i32(0))

	// An unbounded band selects everything, which is what a widget drawn
	// outside any pane must get.
	first, end = grid_visible_range(BOUNDS, 4, 20, 5, COUNT, min(i32) / 2, max(i32) / 2)
	testing.expect_value(t, first, i32(0))
	testing.expect_value(t, end, COUNT)

	// A band starting above the grid origin must not round the first row up
	// and drop it: floor division toward negative infinity is the fix this
	// pins. Row 0 spans 100..120 and is visible from a band starting at 90.
	first, end = grid_visible_range(BOUNDS, 4, 20, 5, COUNT, 90, 130)
	testing.expect_value(t, first, i32(0))
	testing.expect(t, end >= 4, "the first row must be included")

	// Empty grids and zero-height rows degrade instead of trapping.
	first, end = grid_visible_range(BOUNDS, 4, 20, 5, 0, 0, 100)
	testing.expect_value(t, first, i32(0))
	testing.expect_value(t, end, i32(0))
	first, end = grid_visible_range(BOUNDS, 4, 0, 0, COUNT, 0, 100)
	testing.expect_value(t, first, i32(0))
	testing.expect_value(t, end, COUNT)
}

@(test)
grid_skip_to_preserves_measured_height :: proc(t: ^testing.T) {
	// Skipping cells must not shrink the reported content rect, or a
	// virtualized pane would collapse its own scroll range to the visible
	// window and make the rest unreachable.
	full: Grid
	grid_begin(&full, {0, 0, 400, 0}, cols = 4, row_h = 20, gap_y = 5)
	for _ in 0 ..< 40 do _ = grid_next(&full)
	expected := grid_end(&full)

	partial: Grid
	grid_begin(&partial, {0, 0, 400, 0}, cols = 4, row_h = 20, gap_y = 5)
	grid_skip_to(&partial, 8)
	for _ in 8 ..< 20 do _ = grid_next(&partial)
	grid_skip_to(&partial, 40)
	testing.expect_value(t, grid_end(&partial), expected)
}
