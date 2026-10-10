#+build !js
package fit

import "core:testing"
import "ingot:ui"

dx_diagnostic_draw :: proc(builder: ^Builder, _: rawptr) {
	label(column(builder), "Diagnostics")
	builder.root.frame.layout_overflows = 2
	builder.root.frame.semantics.id_collisions = 3
	builder.root.frame.semantics.nodes_dropped = 3
	builder.root.frame.output.main.dropped_commands = 4
}

@(test)
dx_diagnostics_preserve_bounded_failure_counts :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	testing.expect(t, test_driver_frame(&driver, {}, dx_diagnostic_draw))
	actual := test_driver_diagnostics(&driver)
	fit_expect_diagnostics(
		t,
		actual,
		{
			layout_overflows = 2,
			semantic_id_collisions = 3,
			semantic_nodes_dropped = 3,
			main_commands_dropped = 4,
		},
		0,
		0,
	)
}

dx_duplicate_draw :: proc(builder: ^Builder, _: rawptr) {
	label(column(builder), "Duplicate semantic records")
	frame := builder.root.frame
	_ = ui.semantic_push(frame, .Button, {0, 0, 1, 1}, "A", field_id = "duplicate")
	_ = ui.semantic_push(frame, .Button, {1, 0, 1, 1}, "B", field_id = "duplicate")
}

@(test)
dx_duplicate_semantics_report_degradation :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	test_driver_set_semantics(&driver, true)
	state: DX_Components
	testing.expect(t, test_driver_frame(&driver, {}, dx_duplicate_draw, &state))
	diagnostics := test_driver_diagnostics(&driver)
	testing.expect(t, diagnostics.semantic_id_collisions > 0)
	testing.expect(t, diagnostics.semantic_nodes_dropped > 0)
}

DX_Components :: struct {
	values:     [2]bool,
	ids:        [2]Widget_Id,
	reversed:   bool,
	hide_first: bool,
}

dx_components_draw :: proc(builder: ^Builder, user_data: rawptr) {
	state := cast(^DX_Components)user_data
	root := column(builder)
	for position in 0 ..< 2 {
		index := position
		if state.reversed do index = 1 - position
		if state.hide_first && index == 0 do continue
		parent := scope(root, u64(index + 101))
		state.ids[index] = id(parent, "enabled")
		checkbox(parent, "enabled", "Enabled", &state.values[index])
	}
}

@(test)
dx_component_identity_survives_reorder_and_removal :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	test_driver_set_semantics(&driver, true)
	state: DX_Components
	input := Test_Input {
		screen_size = {320, 240},
		dpi_scale   = 1,
	}
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	ids := state.ids
	testing.expect(t, ids[0] != ids[1])
	input.keys_pressed[int(Key.Tab)] = true
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	input.keys_pressed = {}
	input.keys_pressed[int(Key.Enter)] = true
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	testing.expect(t, state.values[0] && !state.values[1])
	input.keys_pressed = {}
	state.reversed = true
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	testing.expect_value(t, state.ids, ids)
	state.hide_first = true
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	state.hide_first = false
	testing.expect(t, test_driver_frame(&driver, input, dx_components_draw, &state))
	testing.expect_value(t, state.ids, ids)
	testing.expect(t, state.values[0] && !state.values[1])
	testing.expect_value(t, test_driver_diagnostics(&driver).semantic_id_collisions, i32(0))
}

DX_State :: struct {
	calls:            i32,
	observed:         i32,
	checked:          bool,
	observed_checked: bool,
	checkbox:         bool,
}

dx_activate :: proc(user_data: rawptr) {
	state := cast(^DX_State)user_data
	state.calls += 1
}

dx_component :: proc(parent: Parent, state: ^DX_State) {
	if state.checkbox {
		checkbox(parent, "control", "Control", &state.checked)
	} else {
		button(parent, "control", "Control", action(dx_activate, state))
	}
}

dx_draw :: proc(builder: ^Builder, user_data: rawptr) {
	state := cast(^DX_State)user_data
	dx_component(center(builder), state)
	state.observed = state.calls
	state.observed_checked = state.checked
}

@(test)
dx_keyboard_updates_after_declaration :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for checkbox in variants {
		driver: Test_Driver
		test_driver_init(&driver)
		state := DX_State {
			checkbox = checkbox,
		}
		input := Test_Input {
			screen_size = {320, 240},
			dpi_scale   = 1,
		}
		testing.expect(t, test_driver_frame(&driver, input, dx_draw, &state))
		input.keys_pressed[int(Key.Tab)] = true
		testing.expect(t, test_driver_frame(&driver, input, dx_draw, &state))
		input.keys_pressed = {}
		input.keys_pressed[int(Key.Enter)] = true
		testing.expect(t, test_driver_frame(&driver, input, dx_draw, &state))
		testing.expect_value(t, state.observed, i32(0))
		testing.expect(t, !state.observed_checked)
		if checkbox {
			testing.expect(t, state.checked)
		} else {
			testing.expect_value(t, state.calls, i32(1))
			testing.expect(t, test_driver_redraw_requested(&driver))
		}
		input.keys_pressed = {}
		testing.expect(t, test_driver_frame(&driver, input, dx_draw, &state))
		testing.expect_value(t, state.observed, state.calls)
		testing.expect_value(t, state.observed_checked, state.checked)
		testing.expect(t, !test_driver_redraw_requested(&driver))
		test_driver_destroy(&driver)
	}
}
