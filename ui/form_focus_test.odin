#+build !js
package ui

import "core:testing"

@(test)
form_focus_moves_forwards :: proc(t: ^testing.T) {
	testing.expect_value(t, form_focus_next(1, 3, false), 2)
	testing.expect_value(t, form_focus_next(2, 3, false), 3)
	testing.expect_value(t, form_focus_next(3, 3, false), 1)
}

@(test)
form_focus_moves_backwards :: proc(t: ^testing.T) {
	testing.expect_value(t, form_focus_next(3, 3, true), 2)
	testing.expect_value(t, form_focus_next(2, 3, true), 1)
	testing.expect_value(t, form_focus_next(1, 3, true), 3)
}

@(test)
form_focus_recovers_unset_value :: proc(t: ^testing.T) {
	testing.expect_value(t, form_focus_next(0, 3, false), 1)
	testing.expect_value(t, form_focus_next(0, 3, true), 3)
	testing.expect_value(t, form_focus_next(4, 3, false), 1)
	testing.expect_value(t, form_focus_next(4, 3, true), 3)
}

@(test)
focus_opt_zero_value_is_inert :: proc(t: ^testing.T) {
	f: Focus_Opt
	testing.expect(t, !focus_opt_focused(f))
	testing.expect(t, !focus_opt_activated(f))
}

@(test)
focus_opt_focused_matches_slot :: proc(t: ^testing.T) {
	slot := 2
	testing.expect(t, focus_opt_focused(Focus_Opt{&slot, 2}))
	testing.expect(t, !focus_opt_focused(Focus_Opt{&slot, 1}))
	slot = 0 // nothing focused: no id may match
	testing.expect(t, !focus_opt_focused(Focus_Opt{&slot, 2}))
}
