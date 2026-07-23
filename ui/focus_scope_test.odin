#+build !js
package ui

import "core:testing"

@(test)
focus_scope_pure_cycle :: proc(t: ^testing.T) {
	// Two forms, three widgets in draw order: a1, a2, b1.
	slot_a, slot_b: int
	list: Sem_Focus_List
	list.entries[0] = {&slot_a, 1}
	list.entries[1] = {&slot_a, 2}
	list.entries[2] = {&slot_b, 1}
	list.count = 3

	// Nothing focused: Tab lands on the first entry, Shift+Tab on the last.
	testing.expect_value(t, focus_scope_focused_index(&list), -1)
	testing.expect_value(t, focus_scope_next_index(-1, 3, false), 0)
	testing.expect_value(t, focus_scope_next_index(-1, 3, true), 2)

	// Forward traversal crosses the form boundary and wraps.
	focus_scope_apply(&list, -1, 0)
	testing.expect_value(t, slot_a, 1)
	testing.expect_value(t, focus_scope_focused_index(&list), 0)
	focus_scope_apply(&list, 0, 1)
	testing.expect_value(t, slot_a, 2)
	focus_scope_apply(&list, 1, 2)
	testing.expect_value(t, slot_a, 0) // outgoing form cleared
	testing.expect_value(t, slot_b, 1)
	testing.expect_value(t, focus_scope_focused_index(&list), 2)
	focus_scope_apply(&list, 2, focus_scope_next_index(2, 3, false))
	testing.expect_value(t, slot_b, 0)
	testing.expect_value(t, slot_a, 1) // wrapped to the first entry

	// Backward traversal wraps the other way.
	focus_scope_apply(&list, 0, focus_scope_next_index(0, 3, true))
	testing.expect_value(t, slot_a, 0)
	testing.expect_value(t, slot_b, 1)
}
