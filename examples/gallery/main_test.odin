#+build !js
package main

import "core:testing"
import fit "ingot:fit"

Gallery_Input_Test_State :: struct {
	region: fit.Region,
	box:    fit.Input_Box,
}

@(private = "file")
gallery_input_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.Canvas(builder, gallery_input_test_render, user_data)
}

@(private = "file")
gallery_input_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	state := cast(^Gallery_Input_Test_State)user_data
	region := fit.Region_Open(surface, &state.region, rect, {scope = "inputs"})
	_ = fit.Region_Text_Input(region, "name", &state.box, "Name", {semantics = {name = "Name"}})
	_ = fit.Region_Close(region)
	return false
}

@(test)
gallery_input_region_retains_focus_between_frames :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state: Gallery_Input_Test_State
	defer fit.Input_Box_Destroy(&state.box)

	pressed: fit.Test_Input
	pressed.mouse_position = {10, 10}
	pressed.mouse_pressed[0] = true
	_ = fit.Test_Driver_Frame(&driver, pressed, gallery_input_test_draw, &state)

	typed: fit.Test_Input
	typed.characters[0] = 'x'
	typed.character_count = 1
	_ = fit.Test_Driver_Frame(&driver, typed, gallery_input_test_draw, &state)
	testing.expect_value(t, fit.Input_Box_Text(&state.box), "x")
}

Gallery_Buttons_Test_State :: struct {
	region: fit.Region,
	clicks: int,
}

@(private = "file")
gallery_buttons_test_draw :: proc(builder: ^fit.Builder, user_data: rawptr) {
	fit.Canvas(builder, gallery_buttons_test_render, user_data)
}

@(private = "file")
gallery_buttons_test_render :: proc(
	surface: ^fit.Surface,
	rect: fit.Rect,
	user_data: rawptr,
) -> bool {
	state := cast(^Gallery_Buttons_Test_State)user_data
	region := fit.Region_Open(surface, &state.region, rect, {scope = "buttons"})
	for index in 0 ..< 3 {
		if fit.Region_Button(region, u64(index + 1), "Focusable") do state.clicks += 1
	}
	_ = fit.Region_Close(region)
	return false
}

@(test)
gallery_buttons_region_retains_tab_focus_between_frames :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state: Gallery_Buttons_Test_State
	_ = fit.Test_Driver_Frame(&driver, {}, gallery_buttons_test_draw, &state)

	activate: fit.Test_Input
	activate.keys_pressed[int(fit.Key.Tab)] = true
	activate.keys_pressed[int(fit.Key.Enter)] = true
	_ = fit.Test_Driver_Frame(&driver, activate, gallery_buttons_test_draw, &state)
	testing.expect_value(t, state.clicks, 1)
}

@(test)
gallery_buttons_click_before_keyboard_focus :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state: Gallery_Buttons_Test_State

	pressed: fit.Test_Input
	pressed.mouse_position = {10, 10}
	pressed.mouse_pressed[0] = true
	pressed.mouse_down[0] = true
	_ = fit.Test_Driver_Frame(&driver, pressed, gallery_buttons_test_draw, &state)
	resolved: fit.Test_Input
	resolved.mouse_position = pressed.mouse_position
	resolved.mouse_released[0] = true
	_ = fit.Test_Driver_Frame(&driver, resolved, gallery_buttons_test_draw, &state)
	testing.expect_value(t, state.clicks, 1)
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
	testing.expect_value(t, len(Palette), 8)
	testing.expect_value(t, palette, Palette.Ingot)
	testing.expect_value(t, len(SECTION_NAMES), len(Section))
	testing.expect_value(t, len(SECTION_LAYERS), len(Section))
	testing.expect_value(t, len(SECTION_AXES), len(Section))
	testing.expect_value(t, NARROW_WIDTH_MAX, 640)
	testing.expect_value(t, NAV_W, 170)
	testing.expect_value(t, NAV_STRIP_ROW_H, 34)
	testing.expect_value(t, NAV_STRIP_CELL_W, 92)
	testing.expect_value(t, STRESS_BUTTONS, 1000)
}
