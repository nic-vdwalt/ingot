#+build !js
package ui

import "core:testing"

@(test)
modal_owns_keyboard_on_opening_frame :: proc(t: ^testing.T) {
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
	input.keys_pressed[input_key_index(.ESCAPE)] = true
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime, &input)
	state: Modal_State
	config := Modal_Config {
		size    = {200, 120},
		screen  = {0, 0, 640, 480},
		dismiss = {.Escape},
	}
	testing.expect(t, modal_open(&frame, &state, Modal_Id(1), config))
	testing.expect(t, !is_key_pressed(&frame, .ESCAPE))
	body := modal_begin(&frame, &state, "Modal", config)
	testing.expect(t, body.w > 0 && body.h > 0)
	testing.expect(t, is_key_pressed(&frame, .ESCAPE))
	modal_end(&state)
	testing.expect_value(t, modal_take_close(&state), Modal_Close_Reason.Escape)
	ui_frame_end(&frame)
}

@(test)
modal_stack_escape_closes_only_top :: proc(t: ^testing.T) {
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
	input.keys_pressed[input_key_index(.ESCAPE)] = true
	frame: Ui_Frame
	output := new(Ui_Output)
	defer free(output)
	frame.output = output
	ui_frame_begin(&frame, &runtime, &input)
	config := Modal_Config {
		size    = {200, 120},
		screen  = {0, 0, 640, 480},
		dismiss = {.Escape},
	}
	first, second: Modal_State
	testing.expect(t, modal_open(&frame, &first, Modal_Id(1), config))
	testing.expect(t, modal_open(&frame, &second, Modal_Id(2), config))
	_ = modal_begin(&frame, &second, "Second", config)
	modal_end(&second)
	testing.expect(t, modal_is_open(&first))
	testing.expect(t, !modal_is_open(&second))
	testing.expect_value(t, modal_take_close(&second), Modal_Close_Reason.Escape)
	ui_frame_end(&frame)
}
