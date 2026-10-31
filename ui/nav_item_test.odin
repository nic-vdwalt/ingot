#+build !js
package ui

import "core:strings"
import "core:testing"

@(private = "file")
Nav_Test :: struct {
	runtime: Ui_Runtime,
	backend: Test_Text_Backend_State,
	output:  ^Ui_Output,
	frame:   Ui_Frame,
	input:   Ui_Input,
}

@(private = "file")
nav_test_init :: proc(state: ^Nav_Test) {
	test_runtime_init(&state.runtime, &state.backend)
	sem_enable(&state.runtime, true)
	state.output = new(Ui_Output)
	state.frame = Ui_Frame {
		output = state.output,
	}
	state.input = Ui_Input {
		frame_time = 1.0 / 60.0,
	}
}

@(private = "file")
nav_test_destroy :: proc(state: ^Nav_Test) {
	ui_frame_destroy(&state.frame)
	free(state.output)
	ui_runtime_destroy(&state.runtime)
	free(state)
}

@(test)
nav_item_click_activates_and_reports_selected_semantics :: proc(t: ^testing.T) {
	state := new(Nav_Test)
	nav_test_init(state)
	defer nav_test_destroy(state)
	rect := Rect_I32{10, 10, 180, 32}
	left := input_mouse_index(.LEFT)

	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	testing.expect(t, !nav_item_at(&state.frame, rect, .Globe, "Showcase", true, widget = 41))
	testing.expect_value(t, state.frame.semantics.cur.count, 1)
	node := &state.frame.semantics.cur.nodes[0]
	testing.expect_value(t, node.role, Sem_Role.Button)
	testing.expect(t, .Selected in node.state, "selected section is announced")
	testing.expect_value(t, sem_node_label(node), "Showcase")
	ui_frame_end(&state.frame)

	state.input.mouse_position = {60, 25}
	state.input.mouse_pressed[left] = true
	state.input.mouse_down[left] = true
	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	testing.expect(t, !nav_item_at(&state.frame, rect, .Bar_Chart, "Charts", false, widget = 42))
	ui_frame_end(&state.frame)

	state.input.mouse_pressed[left] = false
	state.input.mouse_down[left] = false
	state.input.mouse_released[left] = true
	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	testing.expect(t, nav_item_at(&state.frame, rect, .Bar_Chart, "Charts", false, widget = 42))
	node = &state.frame.semantics.cur.nodes[0]
	testing.expect(t, .Selected not_in node.state, "unselected row carries no flag")
	ui_frame_end(&state.frame)
}

@(test)
nav_item_selected_row_paints_accent_bar_and_icon :: proc(t: ^testing.T) {
	state := new(Nav_Test)
	nav_test_init(state)
	defer nav_test_destroy(state)
	rect := Rect_I32{0, 0, 200, 32}

	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	_ = nav_item_at(&state.frame, rect, .Globe, "Showcase", false, widget = 1)
	unselected := state.output.main.count
	_ = nav_item_at(&state.frame, {0, 40, 200, 32}, .Globe, "Showcase", true, widget = 2)
	selected := state.output.main.count - unselected
	ui_frame_end(&state.frame)
	// Selection adds the row surface and the accent bar on top of the same
	// icon and label geometry.
	testing.expect(t, selected > unselected, "selected row paints more than a resting row")
}

@(test)
nav_item_truncates_label_and_drops_badge_when_narrow :: proc(t: ^testing.T) {
	state := new(Nav_Test)
	nav_test_init(state)
	defer nav_test_destroy(state)
	label := "Composition and layout demonstrations"

	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	_ = nav_item_at(&state.frame, {0, 0, 90, 32}, .Layout_Grid, label, false, "Ctrl K", widget = 3)
	texts: [dynamic]string
	defer delete(texts)
	for index in 0 ..< state.output.main.count {
		command := state.output.main.commands[index]
		if command.kind != .Text do continue
		append(&texts, paint_text(&state.output.main, command))
	}
	ui_frame_end(&state.frame)
	testing.expect(t, len(texts) >= 1, "label is drawn")
	for text in texts {
		testing.expect(t, text != label, "label is truncated to the row")
		testing.expect(t, !strings.contains(text, "Ctrl K"), "badge yields when it cannot fit")
	}
}

@(test)
nav_item_culled_row_keeps_semantics_without_paint :: proc(t: ^testing.T) {
	state := new(Nav_Test)
	nav_test_init(state)
	defer nav_test_destroy(state)

	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	state.frame.text_cull_top, state.frame.text_cull_bottom = 500, 900
	_ = nav_item_at(&state.frame, {0, 0, 200, 32}, .Search, "Search", false, "Ctrl K", widget = 4)
	testing.expect_value(t, state.output.main.count, 0)
	testing.expect_value(t, state.frame.semantics.cur.count, 1)
	ui_frame_end(&state.frame)

	ui_frame_begin(&state.frame, &state.runtime, &state.input)
	testing.expect(t, !nav_item_at(&state.frame, {0, 0, 0, 32}, .Search, "Search", false))
	testing.expect_value(t, state.frame.degenerate_drops, 1)
	ui_frame_end(&state.frame)
}
