#+build !js
package ui

import "core:testing"
import "ingot:action"

@(test)
command_palette_matches_bounded_metadata :: proc(t: ^testing.T) {
	item := Command_Palette_Item {
		command     = action.Command_Id(1),
		label       = "Save Document",
		description = "Writes the active file",
		keywords    = "persist disk",
	}
	testing.expect(t, command_palette_match(item, "SAVE"))
	testing.expect(t, command_palette_match(item, "active"))
	testing.expect(t, command_palette_match(item, "DISK"))
	testing.expect(t, !command_palette_match(item, "close"))
}

@(test)
command_palette_filter_preserves_source_order :: proc(t: ^testing.T) {
	items := [3]Command_Palette_Item {
		{command = action.Command_Id(1), label = "Save"},
		{command = action.Command_Id(2), label = "Close"},
		{command = action.Command_Id(3), label = "Save All"},
	}
	state: Command_Palette_State
	matches := command_palette_filter(&state, items[:], "save")
	testing.expect_value(t, len(matches), 2)
	testing.expect_value(t, matches[0], 0)
	testing.expect_value(t, matches[1], 2)
}

@(private = "file")
Palette_Test :: struct {
	runtime: Ui_Runtime,
	backend: Test_Text_Backend_State,
	output:  ^Ui_Output,
	frame:   Ui_Frame,
	input:   Ui_Input,
	state:   Command_Palette_State,
	modal:   Modal_State,
	open:    bool,
}

PALETTE_TEST_ITEMS := [4]Command_Palette_Item {
	{command = action.Command_Id(1), label = "Go to Charts", description = "Data views"},
	{command = action.Command_Id(2), label = "Go to Buttons", description = "Controls"},
	{command = action.Command_Id(3), label = "Locked action", disabled = true},
	{command = action.Command_Id(4), label = "Next theme", keywords = "palette color"},
}

@(private = "file")
palette_test_init :: proc() -> ^Palette_Test {
	state := new(Palette_Test)
	test_runtime_init(&state.runtime, &state.backend)
	sem_enable(&state.runtime, true)
	state.output = new(Ui_Output)
	state.frame = Ui_Frame {
		output = state.output,
	}
	state.input = Ui_Input {
		screen_size = {900, 700},
		frame_time  = 1.0 / 60.0,
	}
	state.open = true
	return state
}

@(private = "file")
palette_test_destroy :: proc(state: ^Palette_Test) {
	command_palette_state_destroy(&state.state)
	ui_frame_destroy(&state.frame)
	free(state.output)
	ui_runtime_destroy(&state.runtime)
	free(state)
}

@(private = "file")
palette_test_frame :: proc(state: ^Palette_Test) -> Command_Palette_Result {
	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	result := command_palette_draw(
		&state.frame,
		&state.state,
		&state.modal,
		PALETTE_TEST_ITEMS[:],
		&state.open,
	)
	ui_frame_end(&state.frame)
	state.input.keys_pressed = {}
	state.input.keys_repeat = {}
	state.input.character_count = 0
	state.input.mouse_pressed = {}
	state.input.mouse_released = {}
	return result
}

@(private = "file")
palette_test_press :: proc(state: ^Palette_Test, key: Key) {
	state.input.keys_pressed[input_key_index(key)] = true
}

@(private = "file")
palette_test_type :: proc(state: ^Palette_Test, text: string) {
	for r in text {
		state.input.characters[state.input.character_count] = r
		state.input.character_count += 1
	}
}

@(test)
command_palette_draw_filters_and_activates_with_enter :: proc(t: ^testing.T) {
	state := palette_test_init()
	defer palette_test_destroy(state)
	testing.expect_value(t, palette_test_frame(state).activated, action.COMMAND_ID_NONE)
	testing.expect_value(t, state.state.match_count, 4)
	palette_test_type(state, "chart")
	_ = palette_test_frame(state)
	testing.expect_value(t, state.state.match_count, 1)
	palette_test_press(state, .ENTER)
	result := palette_test_frame(state)
	testing.expect_value(t, result.activated, action.Command_Id(1))
	testing.expect(t, !state.open, "activation closes the palette")
	testing.expect_value(t, input_box_text(&state.state.query), "")
}

@(test)
command_palette_draw_arrows_clamp_and_skip_disabled_on_enter :: proc(t: ^testing.T) {
	state := palette_test_init()
	defer palette_test_destroy(state)
	_ = palette_test_frame(state)
	palette_test_press(state, .UP)
	_ = palette_test_frame(state)
	testing.expect_value(t, state.state.selected, 0)
	for _ in 0 ..< 6 {
		palette_test_press(state, .DOWN)
		_ = palette_test_frame(state)
	}
	testing.expect_value(t, state.state.selected, 3)
	palette_test_press(state, .UP)
	_ = palette_test_frame(state)
	testing.expect_value(t, state.state.selected, 2)
	palette_test_press(state, .ENTER)
	result := palette_test_frame(state)
	testing.expect_value(t, result.activated, action.COMMAND_ID_NONE)
	testing.expect(t, state.open, "a disabled command cannot be activated")
}

@(test)
command_palette_draw_escape_dismisses :: proc(t: ^testing.T) {
	state := palette_test_init()
	defer palette_test_destroy(state)
	_ = palette_test_frame(state)
	_ = palette_test_frame(state)
	palette_test_press(state, .ESCAPE)
	result := palette_test_frame(state)
	testing.expect(t, result.dismissed, "escape reports dismissal")
	testing.expect(t, !state.open)
	testing.expect_value(t, palette_test_frame(state), Command_Palette_Result{})
}

@(test)
command_palette_draw_reports_options_with_selection_semantics :: proc(t: ^testing.T) {
	state := palette_test_init()
	defer palette_test_destroy(state)
	_ = palette_test_frame(state)
	options := 0
	selected := 0
	for index in 0 ..< state.frame.semantics.cur.count {
		node := state.frame.semantics.cur.nodes[index]
		if node.role != .Option do continue
		options += 1
		if .Selected in node.state do selected += 1
	}
	testing.expect_value(t, options, 4)
	testing.expect_value(t, selected, 1)
}
