#+build !js
package ui

import "core:testing"

listbox_test_config :: proc(selected: ^int, count := 3, hover_select := true) -> Listbox_Config {
	return {{0, 0, 100, 72}, "Models", "models", count, selected, true, hover_select}
}

listbox_test_input :: proc(
	mouse: Vec2 = {},
	delta: Vec2 = {},
	pressed := false,
	released := false,
	down := false,
) -> Ui_Input {
	input: Ui_Input
	input.mouse_position = mouse
	input.mouse_delta = delta
	input.mouse_pressed[input_mouse_index(.LEFT)] = pressed
	input.mouse_released[input_mouse_index(.LEFT)] = released
	input.mouse_down[input_mouse_index(.LEFT)] = down
	return input
}

@(test)
listbox_keyboard_navigation_and_activation :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	selected := 2
	state: Listbox_State
	state.focus.active = focus_id(1)
	state.initialized = true
	state.selected_seen = selected
	state.count_seen = 3

	input: Ui_Input
	input.keys_repeat[input_key_index(.DOWN)] = true
	ui_frame_begin(&frame, &runtime, &input)
	result := listbox_begin(&frame, &state, listbox_test_config(&selected))
	testing.expect_value(t, selected, 0)
	testing.expect(t, result.selection_changed && result.reveal)
	testing.expect_value(t, result.reveal_index, 0)
	ui_frame_end(&frame)

	input = {}
	input.keys_pressed[input_key_index(.END)] = true
	ui_frame_begin(&frame, &runtime, &input)
	result = listbox_begin(&frame, &state, listbox_test_config(&selected))
	testing.expect_value(t, selected, 2)
	testing.expect(t, result.selection_changed)
	ui_frame_end(&frame)

	input = {}
	input.keys_pressed[input_key_index(.ENTER)] = true
	ui_frame_begin(&frame, &runtime, &input)
	result = listbox_begin(&frame, &state, listbox_test_config(&selected))
	testing.expect(t, result.activated)
	testing.expect_value(t, result.activated_index, 2)
	ui_frame_end(&frame)
}

@(test)
listbox_clamps_empty_shrunk_and_external_selection :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	selected := 4
	state: Listbox_State
	state.initialized = true
	state.selected_seen = 4
	state.count_seen = 5
	ui_frame_begin(&frame, &runtime)
	result := listbox_begin(&frame, &state, listbox_test_config(&selected, count = 2))
	testing.expect_value(t, selected, 1)
	testing.expect(t, result.reveal)
	ui_frame_end(&frame)

	ui_frame_begin(&frame, &runtime)
	result = listbox_begin(&frame, &state, listbox_test_config(&selected, count = 0))
	testing.expect_value(t, selected, -1)
	testing.expect(t, !result.reveal)
	ui_frame_end(&frame)

	selected = 0
	ui_frame_begin(&frame, &runtime)
	result = listbox_begin(&frame, &state, listbox_test_config(&selected))
	testing.expect(t, result.reveal)
	testing.expect_value(t, result.reveal_index, 0)
	ui_frame_end(&frame)
}

@(test)
selectable_row_requires_press_origin_and_same_row_release :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	selected := 0
	state: Listbox_State
	config := listbox_test_config(&selected)

	input := listbox_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	row := selectable_row(&frame, &state, config, {{0, 0, 100, 24}, "A", "a", 0, false, ""})
	testing.expect(t, row.pressed && row.held && !row.activated)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)

	input = listbox_test_input({10, 35}, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	other := selectable_row(&frame, &state, config, {{0, 24, 100, 24}, "B", "b", 1, false, ""})
	owner := selectable_row(&frame, &state, config, {{0, 0, 100, 24}, "A", "a", 0, false, ""})
	testing.expect(t, !other.activated && !owner.activated)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)

	input = listbox_test_input({10, 10}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	_ = selectable_row(&frame, &state, config, {{0, 0, 100, 24}, "A", "a", 0, false, ""})
	listbox_end(&frame, &state)
	ui_frame_end(&frame)

	input = listbox_test_input({10, 10}, released = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	row = selectable_row(&frame, &state, config, {{0, 0, 100, 24}, "A", "a", 0, false, ""})
	testing.expect(t, row.activated)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)
}

@(test)
selectable_row_hover_policy_and_disabled_state :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	frame: Ui_Frame
	selected := 0
	state: Listbox_State
	config := listbox_test_config(&selected)
	input := listbox_test_input({10, 35})
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	row := selectable_row(&frame, &state, config, {{0, 24, 100, 24}, "B", "b", 1, false, ""})
	testing.expect(t, row.hovered)
	testing.expect_value(t, selected, 0)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)

	input = listbox_test_input({10, 35}, delta = {1, 0})
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	row = selectable_row(&frame, &state, config, {{0, 24, 100, 24}, "B", "b", 1, false, ""})
	testing.expect_value(t, selected, 1)
	testing.expect(t, row.selected)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)

	input = listbox_test_input({10, 60}, delta = {1, 0}, pressed = true, down = true)
	ui_frame_begin(&frame, &runtime, &input)
	_ = listbox_begin(&frame, &state, config)
	row = selectable_row(&frame, &state, config, {{0, 48, 100, 24}, "C", "c", 2, true, ""})
	testing.expect(t, !row.hovered && !row.pressed && !row.activated)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)
}

@(test)
listbox_records_stable_collection_semantics :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	sem_enable(&runtime, true)
	frame: Ui_Frame
	selected := 2
	state: Listbox_State
	config := listbox_test_config(&selected, count = 5)
	ui_frame_begin(&frame, &runtime)
	_ = listbox_begin(&frame, &state, config)
	_ = selectable_row(&frame, &state, config, {{0, 48, 100, 24}, "C", "model:c", 2, false, ""})
	testing.expect_value(t, frame.semantics.cur.count, 2)
	list := &frame.semantics.cur.nodes[0]
	option := &frame.semantics.cur.nodes[1]
	testing.expect_value(t, list.role, Sem_Role.List_Box)
	testing.expect_value(t, list.id, sem_node_id(.List_Box, focus_link(&state.focus, focus_id(1)), "models", 0))
	testing.expect_value(t, option.role, Sem_Role.Option)
	testing.expect_value(t, option.id, sem_node_id(.Option, {}, "model:c", 0))
	testing.expect(t, .Selected in option.state)
	testing.expect_value(t, option.position_in_set, 3)
	testing.expect_value(t, option.size_of_set, 5)
	listbox_end(&frame, &state)
	ui_frame_end(&frame)
}
