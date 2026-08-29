package main

import "core:testing"
import fit "ingot:fit"

builder_controls_test_frame :: proc(
	driver: ^fit.Test_Driver,
	state: ^State,
	key: fit.Key,
	press_key: bool = false,
) -> bool {
	assert(driver != nil && state != nil, "builder controls test frame: invalid argument")
	input := fit.Test_Input {screen_size = {760, 560}, dpi_scale = 1}
	if press_key do input.keys_pressed[int(key)] = true
	return fit.Test_Driver_Frame(driver, input, draw, state)
}

@(test)
builder_controls_builds_and_emits_semantics :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	fit.Test_Driver_Set_Semantics(&driver, true)
	state := State {notifications_enabled = true, quality = 1, workspace = 101}
	defer fit.Combobox_State_Destroy(&state.workspace_combobox)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	summary := fit.Test_Driver_Paint_Summary(&driver)
	testing.expect(t, summary.main_commands > 0)
	testing.expect(t, summary.main_geometry_commands > 0)
	testing.expect(t, summary.semantic_nodes >= 5)
}

@(test)
builder_controls_keyboard_changes_caller_owned_state :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state := State {notifications_enabled = true, quality = 1, workspace = 101}
	defer fit.Combobox_State_Destroy(&state.workspace_combobox)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	for _ in 0 ..< 4 {
		testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	}
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Enter, true))
	testing.expect(t, !state.notifications_enabled)
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect(t, !state.notifications_enabled)
}

@(test)
builder_controls_keyboard_changes_tabs_and_persists :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	state := State {notifications_enabled = true, quality = 1, workspace = 101}
	defer fit.Combobox_State_Destroy(&state.workspace_combobox)

	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab, true))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Enter, true))
	testing.expect_value(t, state.active_tab, i32(1))
	testing.expect(t, builder_controls_test_frame(&driver, &state, .Tab))
	testing.expect_value(t, state.active_tab, i32(1))
}
