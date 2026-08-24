// App-global keyboard focus order. form_focus.odin cycles Tab within one
// caller-owned focus slot; focus_scope_cycle captures Tab intent before draw,
// then focus_scope_frame_end resolves it against focusable widgets registered
// during the current frame. Callers keep owning their focus slots; no pointer
// survives the open frame.
//
// Use one or the other per frame: form_focus_cycle for a single form,
// focus_scope_cycle when several forms/panes should share one Tab order.
package ui


focus_scope_id :: proc(value: u64) -> Focus_Scope_Id {
	assert(value != 0, "focus_scope_id: zero is reserved")
	return Focus_Scope_Id(value)
}

focus_scope_begin :: proc(frame: ^Ui_Frame, id: Focus_Scope_Id, priority: i32) {
	assert(frame != nil && frame.open, "focus_scope_begin: invalid frame")
	assert(id != FOCUS_SCOPE_NONE, "focus_scope_begin: zero id")
	stack := &frame.semantics.focus_scopes
	assert(stack.count >= 0 && stack.count < MAX_SEM_FOCUS_SCOPES)
	for i in 0 ..< stack.count {
		assert(stack.entries[i].id != id, "focus_scope_begin: duplicate active scope id")
	}
	stack.entries[stack.count] = {
		id       = id,
		priority = priority,
		modal    = modal_owner_current(frame),
	}
	stack.count += 1
	assert(stack.count > 0)
	assert(stack.count <= MAX_SEM_FOCUS_SCOPES)
}

focus_scope_end :: proc(frame: ^Ui_Frame, id: Focus_Scope_Id) {
	assert(frame != nil && frame.open, "focus_scope_end: invalid frame")
	assert(id != FOCUS_SCOPE_NONE, "focus_scope_end: zero id")
	stack := &frame.semantics.focus_scopes
	assert(stack.count > 0, "focus_scope_end: no active scope")
	assert(stack.entries[stack.count - 1].id == id, "focus_scope_end: mismatched scope")
	stack.count -= 1
	assert(stack.count >= 0)
	assert(stack.count < MAX_SEM_FOCUS_SCOPES)
}

focus_scope_current :: proc(frame: ^Ui_Frame) -> Focus_Scope_Stamp {
	assert(frame != nil && frame.open, "focus_scope_current: invalid frame")
	stack := &frame.semantics.focus_scopes
	assert(stack.count >= 0 && stack.count <= MAX_SEM_FOCUS_SCOPES)
	if stack.count == 0 do return {}
	return stack.entries[stack.count - 1]
}

focus_scope_entry_visible :: proc(frame: ^Ui_Frame, entry: ^Sem_Focus_Entry) -> bool {
	assert(frame != nil && entry != nil, "focus scope visibility: invalid argument")
	if frame.runtime == nil do return true
	top := modal_top_id(frame)
	return top == Modal_Id(0) || entry.modal == top
}

focus_scope_focused_index :: proc(list: ^Sem_Focus_List) -> int {
	assert(list != nil, "focus_scope_focused_index: nil list")
	assert(list.count >= 0 && list.count <= MAX_SEM_FOCUS)
	for i in 0 ..< list.count {
		if focus_opt_focused(list.entries[i].focus) do return i
	}
	return -1
}

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

focus_scope_active_priority :: proc(frame: ^Ui_Frame, list: ^Sem_Focus_List) -> (i32, bool) {
	assert(frame != nil && list != nil, "focus_scope_active_priority: invalid argument")
	assert(list.count >= 0 && list.count <= MAX_SEM_FOCUS)
	priority: i32
	present := false
	for i in 0 ..< list.count {
		entry := &list.entries[i]
		if !focus_scope_entry_visible(frame, entry) do continue
		if !present || entry.priority > priority do priority = entry.priority
		present = true
	}
	return priority, present
}

focus_scope_focused_index_at :: proc(
	frame: ^Ui_Frame,
	list: ^Sem_Focus_List,
	priority: i32,
) -> int {
	assert(frame != nil && list != nil, "focus_scope_focused_index_at: invalid argument")
	assert(list.count >= 0 && list.count <= MAX_SEM_FOCUS)
	for i in 0 ..< list.count {
		entry := &list.entries[i]
		if focus_scope_entry_visible(frame, entry) &&
		   entry.priority == priority &&
		   focus_opt_focused(entry.focus) {
			return i
		}
	}
	return -1
}

focus_scope_next_index_at :: proc(
	frame: ^Ui_Frame,
	list: ^Sem_Focus_List,
	current: int,
	priority: i32,
	backwards: bool,
) -> int {
	assert(frame != nil && list != nil, "focus_scope_next_index_at: invalid argument")
	assert(list.count > 0 && list.count <= MAX_SEM_FOCUS)
	assert(current >= -1 && current < list.count)
	if backwards {
		start := current - 1 if current >= 0 else list.count - 1
		for step in 0 ..< list.count {
			index := start - step
			if index < 0 do index += list.count
			if focus_scope_entry_visible(frame, &list.entries[index]) &&
			   list.entries[index].priority == priority {
				return index
			}
		}
	} else {
		start := current + 1 if current >= 0 else 0
		for step in 0 ..< list.count {
			index := (start + step) % list.count
			if focus_scope_entry_visible(frame, &list.entries[index]) &&
			   list.entries[index].priority == priority {
				return index
			}
		}
	}
	assert(false, "focus_scope_next_index_at: priority has no entries")
	return -1
}

focus_scope_apply :: proc(list: ^Sem_Focus_List, current, next: int) {
	assert(list != nil, "focus_scope_apply: nil list")
	assert(list.count > 0 && list.count <= MAX_SEM_FOCUS)
	assert(current >= -1 && current < list.count)
	assert(next >= 0 && next < list.count, "focus_scope_apply: next out of range")
	for i in 0 ..< list.count {
		if i != next && focus_opt_focused(list.entries[i].focus) {
			focus_opt_clear(list.entries[i].focus)
		}
	}
	e := list.entries[next]
	assert(e.focus.focus != nil, "focus_scope_apply: registry entry without focus link")
	focus_opt_set(e.focus)
	assert(focus_opt_focused(e.focus), "focus_scope_apply: focus not set")
}

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
	assert(state.focus_scopes.count == 0, "focus_scope_frame_end: unbalanced focus scopes")
	if !state.cycle_requested do return
	list := sem_focus_list(frame)
	priority, present := focus_scope_active_priority(frame, list)
	if present {
		current := focus_scope_focused_index_at(frame, list, priority)
		next := focus_scope_next_index_at(frame, list, current, priority, state.cycle_backwards)
		focus_scope_apply(list, current, next)
		request_redraw(frame)
	}
	state.cycle_requested = false
	state.cycle_backwards = false
	assert(!state.cycle_requested)
	assert(!state.cycle_backwards)
}

focus_scope_clear_live :: proc(frame: ^Ui_Frame) {
	assert(frame != nil && frame.open, "focus_scope_clear_live: invalid frame")
	assert(
		frame.semantics.focus_scopes.count == 0,
		"focus_scope_clear_live: unbalanced focus scopes",
	)
	frame.semantics.focus_cur.count = 0
	frame.semantics.action_targets.count = 0
	frame.semantics.focus_scopes.count = 0
	assert(frame.semantics.focus_cur.count == 0)
	assert(frame.semantics.action_targets.count == 0)
	assert(frame.semantics.focus_scopes.count == 0)
}
