#+build !js
package ui

import "core:testing"

@(test)
settings_scale_enter_applies_and_dismisses :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	input := Ui_Input {
		screen_size = {640, 480},
	}
	input.keys_pressed[input_key_index(.ENTER)] = true
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime, &input)
	selected := 3
	result := draw_scale_settings_panel(&frame, &selected, 0, 640, 480)
	testing.expect(t, result.applied)
	testing.expect(t, result.dismissed)
	testing.expect_value(t, result.ui_scale, f32(1))
	ui_frame_end(&frame)
}

@(test)
settings_scale_outside_click_dismisses_on_opening_frame :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	backend: Test_Text_Backend_State
	ui_runtime_set_text_backend(
		&runtime,
		{data = &backend, font_for_size = test_text_font_for_size, measure = test_text_measure},
	)
	input := Ui_Input {
		mouse_position = {10, 10},
		screen_size    = {640, 480},
	}
	input.mouse_pressed[input_mouse_index(.LEFT)] = true
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime, &input)
	selected := 0
	result := draw_scale_settings_panel(&frame, &selected, 0, 640, 480)
	testing.expect(t, !result.applied)
	testing.expect(t, result.dismissed)
	ui_frame_end(&frame)
}
