// App-global keyboard focus order. form_focus.odin cycles Tab within one
// caller-owned focus slot; focus_scope_cycle captures Tab intent before draw,
// then focus_scope_frame_end resolves it against focusable widgets registered
// during the current frame. Callers keep owning their focus slots; no pointer
// survives the open frame.
//
// Use one or the other per frame: form_focus_cycle for a single form,
// focus_scope_cycle when several forms/panes should share one Tab order.
package ui


// focus_scope_focused_index returns the registry index of the entry that
// currently holds focus (its slot equals its id), or -1. Pure.
focus_scope_focused_index :: proc(list: ^Sem_Focus_List) -> int {
	assert(list != nil, "focus_scope_focused_index: nil list")
	assert(
		list.count >= 0 && list.count <= MAX_SEM_FOCUS,
		"focus_scope_focused_index: corrupt count",
	)
	for i in 0 ..< list.count {
		if focus_opt_focused(list.entries[i].focus) do return i
	}
	return -1
}

// focus_scope_next_index returns the registry index Tab should land on:
// draw-order successor (or predecessor) of `current` with wraparound; the
// first (or last) entry when nothing is focused. Pure.
focus_scope_next_index :: proc(current, count: int, backwards: bool) -> int {
	assert(count > 0, "focus_scope_next_index: empty registry")
	assert(current >= -1 && current < count, "focus_scope_next_index: index out of range")
	if current < 0 {
		return count - 1 if backwards else 0
	}
	if backwards {
		return count - 1 if current == 0 else current - 1
	}
	return 0 if current == count - 1 else current + 1
}

// focus_scope_apply moves focus from entry `current` (-1 for none) to entry
// `next`: clears the outgoing slot, sets the incoming one. Pure over the
// caller-owned slots.
focus_scope_apply :: proc(list: ^Sem_Focus_List, current, next: int) {
	assert(list != nil, "focus_scope_apply: nil list")
	assert(next >= 0 && next < list.count, "focus_scope_apply: next out of range")
	if current >= 0 do focus_opt_clear(list.entries[current].focus)
	e := list.entries[next]
	assert(e.focus.focus != nil, "focus_scope_apply: registry entry without focus link")
	focus_opt_set(e.focus)
	assert(focus_opt_focused(e.focus), "focus_scope_apply: focus not set")
}

// focus_scope_cycle is the app-level Tab handler. Call it once before drawing
// focusable widgets. The request is committed at ui_frame_end after current
// draw-order registration is complete.
focus_scope_cycle :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "focus_scope_cycle: invalid frame")
	if !is_key_pressed(frame, .TAB) do return
	frame.semantics.cycle_requested = true
	frame.semantics.cycle_backwards =
		is_key_down(frame, .LEFT_SHIFT) || is_key_down(frame, .RIGHT_SHIFT)
}

focus_scope_frame_end :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "focus_scope_frame_end: invalid frame")
	state := &frame.semantics
	if !state.cycle_requested do return
	list := sem_focus_list(frame)
	if list.count > 0 {
		current := focus_scope_focused_index(list)
		next := focus_scope_next_index(current, list.count, state.cycle_backwards)
		focus_scope_apply(list, current, next)
		request_redraw(frame)
	}
	state.cycle_requested = false
	state.cycle_backwards = false
}

focus_scope_clear_live :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "focus_scope_clear_live: invalid frame")
	frame.semantics.focus_cur.count = 0
	frame.semantics.action_targets.count = 0
}
