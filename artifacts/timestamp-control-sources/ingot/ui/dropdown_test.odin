#+build !js
package ui

import "core:testing"

@(test)
dropdown_open_menu_tracks_current_rect :: proc(t: ^testing.T) {
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

	items := []string{"First", "Second"}
	selected: i32 = 1
	state := Dropdown_State {
		menu = {open = true, just_opened = true, anchor_x = 400, anchor_y = 500, selected = 1},
	}
	changed := dropdown_at(&frame, {24, 60, 180, 32}, items, &selected, &state, 800, 600)

	testing.expect(t, !changed)
	testing.expect_value(t, selected, i32(1))
	testing.expect_value(t, state.menu.anchor_x, i32(24))
	testing.expect_value(t, state.menu.anchor_y, i32(94))
	ui_frame_end(&frame)
}
