#+build !js
package ui

import "core:testing"

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
	flex_begin(&l, {flex_fixed(80), flex_fit(100), flex_grow()})
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
	flex_begin(&l, {flex_percent(0.25), flex_grow()})
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
	flex_begin(&l, {flex_grow(1, max_size = 100), flex_grow(1), flex_grow(2)})
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
	flex_begin(&l, {flex_fixed(100), flex_fit(120, min_size = 40)})
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
	flex_begin(&l, {
		flex_fit(100, max_size = 60),
		flex_percent(0.5, max_size = 80),
		flex_grow(1),
		flex_grow(2),
	})
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
	flex_begin(&l, {flex_fixed(80), flex_fixed(80), flex_grow()})
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
	flex_begin(&l, {flex_fixed(20)})
	_ = flex_next(&l)
	row_weights(&l, {1, 1})
	d := next_weighted(&l, 1)
	e := next_weighted(&l, 1)
	layout_pop(&l)
	layout_end(&l)
	testing.expect_value(t, d.w + e.w, i32(80))
}
