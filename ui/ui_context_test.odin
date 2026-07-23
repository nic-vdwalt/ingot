package ui

import "core:testing"

@(test)
test_ui_slot_column_and_row :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 200, 100)
	r1 := ui_slot(&u, 50, 20)
	testing.expect_value(t, r1, Rect_I32{0, 0, 50, 20})
	ui_row(&u, 30)
	r2 := ui_slot(&u, 40, 30)
	testing.expect_value(t, r2, Rect_I32{0, 20, 40, 30})
	ui_row_end(&u)
	ui_end(&u)
}

@(test)
test_ui_focus_ids_sequential_and_counted :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 100, 100)
	f1 := ui_focus(&u)
	f2 := ui_focus(&u)
	testing.expect_value(t, f1.id, 1)
	testing.expect_value(t, f2.id, 2)
	testing.expect(t, f1.focus == &u.focus_slot)
	ui_end(&u)
	testing.expect_value(t, u.focus_count, 2)
	// Next frame resets the sequence and latches the new count.
	ui_begin(&u, 0, 0, 100, 100)
	testing.expect_value(t, ui_focus(&u).id, 1)
	ui_end(&u)
	testing.expect_value(t, u.focus_count, 1)
}

@(test)
test_ui_slot_row_cross_trim :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 10, 10, 300, 200, gap = 4)
	ui_row(&u, 40, gap = 8)
	r1 := ui_slot(&u, 100, 30)
	testing.expect_value(t, r1, Rect_I32{10, 10, 100, 30})
	r2 := ui_slot(&u, 100, 40)
	testing.expect_value(t, r2, Rect_I32{118, 10, 100, 40})
	ui_row_end(&u)
	// Root gap applies after the row strip.
	r3 := ui_slot(&u, 50, 20)
	testing.expect_value(t, r3, Rect_I32{10, 54, 50, 20})
	ui_end(&u)
}

@(test)
test_ui_space_advances_cursor :: proc(t: ^testing.T) {
	u: Ui
	ui_begin(&u, 0, 0, 100, 100)
	ui_space(&u, 25)
	r := ui_slot(&u, 100, 10)
	testing.expect_value(t, r, Rect_I32{0, 25, 100, 10})
	ui_end(&u)
}
