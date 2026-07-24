#+build !js
package ui

import "core:testing"

@(test)
focus_scope_pure_cycle :: proc(t: ^testing.T) {
	// Two forms, three widgets in draw order: a1, a2, b1.
	slot_a, slot_b: int
	list: Sem_Focus_List
	list.entries[0] = {Focus_Opt{&slot_a, 1}}
	list.entries[1] = {Focus_Opt{&slot_a, 2}}
	list.entries[2] = {Focus_Opt{&slot_b, 1}}
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

@(test)
focus_scope_cycles_stable_links_across_owners :: proc(t: ^testing.T) {
	a, b: Focus_State
	list: Sem_Focus_List
	list.entries[0] = {focus_link(&a, focus_id(10))}
	list.entries[1] = {focus_link(&b, focus_id(20))}
	list.count = 2
	focus_scope_apply(&list, -1, 0)
	testing.expect_value(t, a.active, focus_id(10))
	focus_scope_apply(&list, 0, 1)
	testing.expect_value(t, a.active, FOCUS_ID_NONE)
	testing.expect_value(t, b.active, focus_id(20))
}

@(test)
focus_scope_resolves_current_frame_and_clears_links :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime)

	slot_a, slot_b: int
	frame.semantics.cycle_requested = true
	semantic_push(&frame, .Button, {0, 0, 1, 1}, "a", focus = {&slot_a, 1})
	semantic_push(&frame, .Button, {0, 0, 1, 1}, "b", focus = {&slot_b, 1})
	ui_frame_end(&frame)

	testing.expect_value(t, slot_a, 1)
	testing.expect_value(t, slot_b, 0)
	testing.expect_value(t, frame.semantics.focus_cur.count, 0)
	testing.expect_value(t, frame.semantics.action_targets.count, 0)

	ui_frame_begin(&frame, &runtime)
	frame.semantics.cycle_requested = true
	semantic_push(&frame, .Button, {0, 0, 1, 1}, "b", focus = {&slot_b, 1})
	ui_frame_end(&frame)
	testing.expect_value(t, slot_a, 1)
	testing.expect_value(t, slot_b, 1)
}
