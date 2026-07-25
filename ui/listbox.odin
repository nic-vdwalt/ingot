// LIB-CANDIDATE: imports only core:*.
package ui

Listbox_State :: struct {
	focus:          Focus_State,
	press_latch:    bool,
	pressed_index:  int,
	selected_seen:  int,
	count_seen:     int,
	owner_seen:     bool,
	initialized:    bool,
}

Listbox_Config :: struct {
	rect:         Rect_I32,
	label:        string,
	stable_id:    string,
	count:        int,
	selected:     ^int,
	wrap:         bool,
	hover_select: bool,
}

Listbox_Result :: struct {
	selection_changed: bool,
	activated:          bool,
	activated_index:    int,
	reveal:             bool,
	reveal_index:       int,
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

	result := Listbox_Result{activated_index = -1, reveal_index = -1}
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
	if config.selected^ >= 0 && (!was_initialized || config.selected^ != state.selected_seen || config.count != state.count_seen) {
		result.reveal = true
		result.reveal_index = config.selected^
	}

	if focus_focused(&state.focus, focus_id(1)) && config.count > 0 {
		next := config.selected^
		if is_key_pressed_repeat(frame, .UP) {
			next -= 1
			if next < 0 do next = config.count - 1 if config.wrap else 0
		} else if is_key_pressed_repeat(frame, .DOWN) {
			next += 1
			if next >= config.count do next = 0 if config.wrap else config.count - 1
		} else if is_key_pressed(frame, .HOME) {
			next = 0
		} else if is_key_pressed(frame, .END) {
			next = config.count - 1
		}
		if next != config.selected^ {
			config.selected^ = next
			result.selection_changed = true
			result.reveal = true
			result.reveal_index = next
		}
		if is_key_pressed(frame, .ENTER) || is_key_pressed(frame, .SPACE) {
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
		if result.hovered && config.hover_select && mouse_moved(frame) && config.selected^ != row.index {
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
	if state.press_latch && !state.owner_seen && (is_mouse_button_released(frame, .LEFT) || !is_mouse_button_down(frame, .LEFT)) {
		state.press_latch = false
		state.pressed_index = -1
		if frame.interaction.active_latch == &state.press_latch do frame.interaction.active_latch = nil
	}
	state.owner_seen = false
}
