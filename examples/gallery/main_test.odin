#+build !js
package main

import "core:testing"
import fit "ingot:fit"
import "ingot:ui"

@(private = "file")
gallery_input_test_frame :: proc(
	runtime: ^ui.Ui_Runtime,
	frame: ^ui.Ui_Frame,
	output: ^ui.Ui_Output,
	input: ^ui.Ui_Input,
	region: ^fit.Region,
	box: ^fit.Input_Box,
) {
	assert(runtime != nil && frame != nil && output != nil && input != nil)
	assert(region != nil && box != nil)
	output^ = {}
	frame.output = output
	ui.ui_frame_begin(frame, runtime, input)
	root: ui.Ui
	ui.begin(&root, frame, {0, 0, 300, 200})
	surface := fit.Surface {
		inner = &root,
	}
	fit.Surface_Region_Begin(&surface, region, {0, 0, 300, 200})
	fit.Region_Scope_Begin(region, "inputs")
	_ = fit.Region_Text_Input(region, "name", box, "Name", {semantics = {name = "Name"}})
	fit.Region_Scope_End(region)
	_ = fit.Surface_Region_End(region)
	_ = ui.end(&root)
	ui.ui_frame_end(frame)
}

@(test)
gallery_input_region_retains_focus_between_frames :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	text_backend: ui.Test_Text_Backend_State
	ui.ui_runtime_set_text_backend(
		&runtime,
		{
			data = &text_backend,
			font_for_size = ui.test_text_font_for_size,
			measure = ui.test_text_measure,
		},
	)
	frame: ui.Ui_Frame
	defer ui.ui_frame_destroy(&frame)
	output := new(ui.Ui_Output)
	defer free(output)
	region: fit.Region
	box: fit.Input_Box
	defer fit.Input_Box_Destroy(&box)

	pressed: ui.Ui_Input
	pressed.mouse_position = {10, 10}
	pressed.mouse_pressed[ui.MouseButton.LEFT] = true
	gallery_input_test_frame(&runtime, &frame, output, &pressed, &region, &box)

	typed: ui.Ui_Input
	typed.characters[0] = 'x'
	typed.character_count = 1
	gallery_input_test_frame(&runtime, &frame, output, &typed, &region, &box)
	testing.expect_value(t, fit.Input_Box_Text(&box), "x")
}

@(test)
nav_strip_respects_scaled_width_and_sidebar_height :: proc(t: ^testing.T) {
	scales := [?]f32{0.5, 1, 1.5, 2, 3}
	heights := [?]i32{221, 440, 659, 878, 1316}
	for scale, index in scales {
		minimum := nav_sidebar_min_height_scale(scale)
		testing.expect_value(t, minimum, heights[index])
		width := gallery_scaled(NARROW_WIDTH_MAX, scale)
		testing.expect(t, nav_uses_strip_scale(scale, width, minimum))
		testing.expect(t, nav_uses_strip_scale(scale, width + 1, minimum - 1))
		testing.expect(t, !nav_uses_strip_scale(scale, width + 1, minimum))
	}
}

@(test)
gallery_contract_keeps_sections_geometry_and_stress_scale :: proc(t: ^testing.T) {
	testing.expect_value(t, len(Section), 9)
	testing.expect_value(t, len(SECTION_NAMES), len(Section))
	testing.expect_value(t, len(SECTION_LAYERS), len(Section))
	testing.expect_value(t, len(SECTION_AXES), len(Section))
	testing.expect_value(t, NARROW_WIDTH_MAX, 640)
	testing.expect_value(t, NAV_W, 170)
	testing.expect_value(t, NAV_STRIP_ROW_H, 34)
	testing.expect_value(t, NAV_STRIP_CELL_W, 92)
	testing.expect_value(t, STRESS_BUTTONS, 1000)
}
