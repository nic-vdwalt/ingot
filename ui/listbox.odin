// LIB-CANDIDATE: imports only core:*.
package ui

Listbox_State :: struct {
	focus:         Focus_State,
	press_latch:   bool,
	pressed_index: int,
	selected_seen: int,
	count_seen:    int,
	owner_seen:    bool,
	initialized:   bool,
}

// Listbox_Keys states who owns the keyboard while the list is on screen. The
// zero value keeps the historical behaviour, where the list only reads keys
// once something has given it focus.
Listbox_Keys :: enum {
	// Keys are read only while the list holds focus. Use when the list shares
	// a page with other focusable widgets that must be reachable by Tab.
	Focused,
	// Keys are read unconditionally. Use for a dialog whose whole purpose is
	// to drive one list, so no focus handshake is needed to navigate it.
	Owned,
	// Keys are read unconditionally, but Home/End and Space are left to the
	// caller. Use when a text input shares the dialog: Home/End must move the
	// caret rather than jump rows, and Space must type a space.
	Searched,
}

Listbox_Config :: struct {
	rect:         Rect_I32,
	label:        string,
	stable_id:    string,
	count:        int,
	selected:     ^int,
	wrap:         bool,
	hover_select: bool,
	keys:         Listbox_Keys,
	// Rows moved by Page Up / Page Down; pass the visible row count. Zero
	// disables both keys so a list that cannot describe its viewport does not
	// jump by a guessed amount.
	page_rows:    int,
}

Listbox_Result :: struct {
	selection_changed: bool,
	activated:         bool,
	activated_index:   int,
	reveal:            bool,
	reveal_index:      int,
}

Selectable_Row_Config :: struct {
	rect:        Rect_I32,
	label:       string,
	stable_id:   string,
	index:       int,
	disabled:    bool,
	description: string,
}

Selectable_Row_Result :: struct {
	hovered:   bool,
	pressed:   bool,
	held:      bool,
	selected:  bool,
	activated: bool,
}

listbox_reset :: proc(state: ^Listbox_State) {
	assert(state != nil, "listbox_reset: nil state")
	state^ = {}
}

// listbox_keyboard_live answers whether the list reads navigation keys this
// frame. Only .Focused consults the focus slot; the other modes are declared
// owners of the keyboard by their caller, which is what makes them usable in a
// dialog that never runs a Tab cycle.
listbox_keyboard_live :: proc(state: ^Listbox_State, config: Listbox_Config) -> bool {
	assert(state != nil, "listbox_keyboard_live: nil state")
	assert(config.count >= 0, "listbox_keyboard_live: negative count")
	if config.count == 0 do return false
	switch config.keys {
	case .Focused:
		return focus_focused(&state.focus, focus_id(1))
	case .Owned, .Searched:
		return true
	}
	return false
}

// listbox_wrap_step moves `index` by `delta` rows, wrapping past either end
// when `wrap` is set and clamping otherwise. Pure.
listbox_wrap_step :: proc(index, delta, count: int, wrap: bool) -> int {
	assert(count > 0, "listbox_wrap_step: empty list")
	assert(index >= 0 && index < count, "listbox_wrap_step: index out of range")
	next := index + delta
	if next < 0 do next = count - 1 if wrap else 0
	if next >= count do next = 0 if wrap else count - 1
	assert(next >= 0 && next < count, "listbox_wrap_step: result out of range")
	return next
}

// listbox_nav maps this frame's keys onto a new selection and an activation
// request. Page Up/Down always clamp — wrapping a whole page would skip rows
// the user never saw. Pure over the frame's input snapshot.
listbox_nav :: proc(
	frame: ^Ui_Frame,
	config: Listbox_Config,
	current: int,
) -> (
	next: int,
	activate: bool,
) {
	assert(frame != nil && frame.open, "listbox_nav: invalid frame")
	assert(config.count > 0, "listbox_nav: empty list")
	assert(current >= 0 && current < config.count, "listbox_nav: current out of range")
	assert(config.page_rows >= 0, "listbox_nav: negative page size")
	next = current
	if is_key_pressed_or_repeat(frame, .UP) {
		next = listbox_wrap_step(next, -1, config.count, config.wrap)
	} else if is_key_pressed_or_repeat(frame, .DOWN) {
		next = listbox_wrap_step(next, 1, config.count, config.wrap)
	} else if config.page_rows > 0 && is_key_pressed_or_repeat(frame, .PAGE_UP) {
		next = listbox_wrap_step(next, -config.page_rows, config.count, false)
	} else if config.page_rows > 0 && is_key_pressed_or_repeat(frame, .PAGE_DOWN) {
		next = listbox_wrap_step(next, config.page_rows, config.count, false)
	} else if config.keys != .Searched && is_key_pressed(frame, .HOME) {
		next = 0
	} else if config.keys != .Searched && is_key_pressed(frame, .END) {
		next = config.count - 1
	}
	activate = is_key_pressed(frame, .ENTER)
	if config.keys != .Searched && is_key_pressed(frame, .SPACE) do activate = true
	assert(next >= 0 && next < config.count, "listbox_nav: next out of range")
	return
}

listbox_begin :: proc(
	frame: ^Ui_Frame,
	state: ^Listbox_State,
	config: Listbox_Config,
) -> Listbox_Result {
	assert(frame != nil && frame.open, "listbox_begin: invalid frame")
	assert(state != nil && config.selected != nil, "listbox_begin: nil state")
	assert(config.rect.w > 0 && config.rect.h > 0, "listbox_begin: empty rect")
	assert(config.label != "" && config.stable_id != "", "listbox_begin: semantics required")
	assert(config.count >= 0, "listbox_begin: negative count")

	result := Listbox_Result {
		activated_index = -1,
		reveal_index    = -1,
	}
	was_initialized := state.initialized
	if !was_initialized {
		state.pressed_index = -1
		state.selected_seen = config.selected^
		state.count_seen = config.count
		state.initialized = true
	}
	if config.count == 0 {
		config.selected^ = -1
	} else {
		config.selected^ = clamp(config.selected^, 0, config.count - 1)
	}
	if config.selected^ >= 0 &&
	   (!was_initialized ||
			   config.selected^ != state.selected_seen ||
			   config.count != state.count_seen) {
		result.reveal = true
		result.reveal_index = config.selected^
	}

	if listbox_keyboard_live(state, config) {
		next, activate := listbox_nav(frame, config, config.selected^)
		if next != config.selected^ {
			config.selected^ = next
			result.selection_changed = true
			result.reveal = true
			result.reveal_index = next
		}
		if activate {
			result.activated = true
			result.activated_index = config.selected^
		}
	}

	semantic_push(
		frame,
		.List_Box,
		config.rect,
		config.label,
		focus = focus_link(&state.focus, focus_id(1)),
		field_id = config.stable_id,
	)
	state.selected_seen = config.selected^
	state.count_seen = config.count
	state.owner_seen = false
	return result
}

selectable_row :: proc(
	frame: ^Ui_Frame,
	state: ^Listbox_State,
	config: Listbox_Config,
	row: Selectable_Row_Config,
) -> Selectable_Row_Result {
	assert(frame != nil && frame.open, "selectable_row: invalid frame")
	assert(state != nil && config.selected != nil, "selectable_row: nil state")
	assert(row.index >= 0 && row.index < config.count, "selectable_row: index out of range")
	assert(row.rect.w > 0 && row.rect.h > 0, "selectable_row: empty rect")
	assert(row.label != "" && row.stable_id != "", "selectable_row: semantics required")

	result: Selectable_Row_Result
	if !row.disabled && (!state.press_latch || state.pressed_index == row.index) {
		if state.press_latch do state.owner_seen = true
		it := interact(
			frame,
			{f32(row.rect.x), f32(row.rect.y), f32(row.rect.w), f32(row.rect.h)},
			&state.press_latch,
		)
		if it.pressed {
			state.pressed_index = row.index
			state.owner_seen = true
			focus_opt_set(focus_link(&state.focus, focus_id(1)))
		}
		result.hovered = it.hovered
		result.pressed = it.pressed
		result.held = it.held && state.pressed_index == row.index
		result.activated = it.clicked && state.pressed_index == row.index
		if a11y_take_click(frame.runtime, sem_node_id(.Option, {}, row.stable_id, 0)) {
			result.activated = true
			focus_opt_set(focus_link(&state.focus, focus_id(1)))
		}
		if result.hovered do request_cursor(frame, .POINTING_HAND)
		if result.hovered &&
		   config.hover_select &&
		   mouse_moved(frame) &&
		   config.selected^ != row.index {
			config.selected^ = row.index
			state.selected_seen = row.index
		}
		if it.released || (!state.press_latch && state.pressed_index >= 0) do state.pressed_index = -1
	}
	result.selected = config.selected^ == row.index
	sem: Sem_State
	if row.disabled do sem += {.Disabled}
	if result.selected do sem += {.Selected}
	semantic_push(
		frame,
		.Option,
		row.rect,
		row.label,
		sem,
		field_id = row.stable_id,
		description = row.description,
		position_in_set = row.index + 1,
		size_of_set = config.count,
	)
	return result
}

listbox_end :: proc(frame: ^Ui_Frame, state: ^Listbox_State) {
	assert(frame != nil && frame.open, "listbox_end: invalid frame")
	assert(state != nil && state.initialized, "listbox_end: invalid state")
	if state.press_latch &&
	   !state.owner_seen &&
	   (is_mouse_button_released(frame, .LEFT) || !is_mouse_button_down(frame, .LEFT)) {
		state.press_latch = false
		state.pressed_index = -1
		if frame.interaction.active_latch == &state.press_latch do frame.interaction.active_latch = nil
	}
	state.owner_seen = false
}
