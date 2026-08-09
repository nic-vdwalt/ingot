#+build !js
package ui

import "core:testing"

@(test)
test_combobox_filter_match_is_case_insensitive_substring :: proc(t: ^testing.T) {
	testing.expect(t, combobox_filter_match("Acme Holdings", "acme"))
	testing.expect(t, combobox_filter_match("Acme Holdings", "HOLD"))
	testing.expect(t, combobox_filter_match("Acme Holdings", ""))
	testing.expect(t, !combobox_filter_match("Acme Holdings", "zebra"))
}

@(test)
test_combobox_selected_label_finds_by_id :: proc(t: ^testing.T) {
	items := []Combobox_Item{{1, "One"}, {7, "Seven"}}
	testing.expect_value(t, combobox_selected_label(items, 7), "Seven")
	testing.expect_value(t, combobox_selected_label(items, 9), "")
}

@(test)
test_combobox_closed_mirrors_selected_label :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	input: Ui_Input
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_destroy(&frame)

	items := []Combobox_Item{{1, "Alpha"}, {2, "Beta"}}
	selected: u64 = 2
	state: Combobox_State
	defer combobox_state_destroy(&state)
	changed := combobox_at(&frame, {10, 10, 200, 30}, &state, items, &selected, "Client", 800, 600)
	testing.expect(t, !changed)
	testing.expect(t, !state.open)
	testing.expect_value(t, input_box_text(&state.box), "Beta")
	ui_frame_end(&frame)
}

@(test)
combobox_popup_clamps_and_records_in_screen_space :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	text_backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = test_text_font_for_size,
			measure = test_text_measure,
		},
	)
	output := new(Ui_Output)
	defer free(output)
	input := Ui_Input {
		screen_size = {300, 200},
	}
	frame := Ui_Frame {
		output = output,
	}
	ui_frame_begin(&frame, &runtime, &input)
	defer {
		ui_frame_end(&frame)
		ui_frame_destroy(&frame)
	}
	ui_frame_pane_push(&frame, {180, 120})
	defer ui_frame_pane_pop(&frame)
	state := Combobox_State {
		open        = true,
		just_opened = true,
	}
	defer combobox_state_destroy(&state)
	items := []Combobox_Item{{1, "One"}}
	selected: u64
	_ = combobox_at(&frame, {50, 40, 100, 30}, &state, items, &selected, "", 300, 200)
	menu_h := ui_frame_metrics(&frame).MENU_ITEM_H + ui_frame_metrics(&frame).MENU_PAD * 2
	testing.expect_value(
		t,
		output.overlay.commands[0].rect,
		Rectangle{200, f32(160 - menu_h - 2), 100, f32(menu_h)},
	)
	route_begin_frame(&frame)
	testing.expect(t, route_occluded(&frame, {201, f32(160 - menu_h - 1)}))
}
