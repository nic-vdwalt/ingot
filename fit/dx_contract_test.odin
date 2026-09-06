#+build !js
package fit

import "core:testing"
import "ingot:ui"

dx_diagnostic_draw :: proc(builder: ^Builder, _: rawptr) {
	Label(Column(builder), "Diagnostics")
	builder.root.frame.layout_overflows = 2
	builder.root.frame.semantics.id_collisions = 3
	builder.root.frame.semantics.nodes_dropped = 3
	builder.root.frame.output.main.dropped_commands = 4
}

@(test)
dx_diagnostics_preserve_bounded_failure_counts :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	testing.expect(t, Test_Driver_Frame(&driver, {}, dx_diagnostic_draw))
	actual := Test_Driver_Diagnostics(&driver)
	testing.expect_value(t, actual.layout_overflows, i32(2))
	testing.expect_value(t, actual.semantic_id_collisions, i32(3))
	testing.expect_value(t, actual.semantic_nodes_dropped, i32(3))
	testing.expect_value(t, actual.main_commands_dropped, i32(4))
}

dx_duplicate_draw :: proc(builder: ^Builder, _: rawptr) {
	Label(Column(builder), "Duplicate semantic records")
	frame := builder.root.frame
	_ = ui.semantic_push(frame, .Button, {0, 0, 1, 1}, "A", field_id = "duplicate")
	_ = ui.semantic_push(frame, .Button, {1, 0, 1, 1}, "B", field_id = "duplicate")
}

@(test)
dx_duplicate_semantics_report_degradation :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	Test_Driver_Set_Semantics(&driver, true)
	state: DX_Components
	testing.expect(t, Test_Driver_Frame(&driver, {}, dx_duplicate_draw, &state))
	diagnostics := Test_Driver_Diagnostics(&driver)
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
	root := Column(builder)
	for position in 0 ..< 2 {
		index := position
		if state.reversed do index = 1 - position
		if state.hide_first && index == 0 do continue
		parent := Scope(root, u64(index + 101))
		state.ids[index] = Id(parent, "enabled")
		Checkbox(parent, "enabled", "Enabled", &state.values[index])
	}
}

@(test)
dx_component_identity_survives_reorder_and_removal :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	Test_Driver_Set_Semantics(&driver, true)
	state: DX_Components
	input := Test_Input {
		screen_size = {320, 240},
		dpi_scale   = 1,
	}
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	ids := state.ids
	testing.expect(t, ids[0] != ids[1])
	input.keys_pressed[int(Key.Tab)] = true
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	input.keys_pressed = {}
	input.keys_pressed[int(Key.Enter)] = true
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	testing.expect(t, state.values[0] && !state.values[1])
	input.keys_pressed = {}
	state.reversed = true
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	testing.expect_value(t, state.ids, ids)
	state.hide_first = true
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	state.hide_first = false
	testing.expect(t, Test_Driver_Frame(&driver, input, dx_components_draw, &state))
	testing.expect_value(t, state.ids, ids)
	testing.expect(t, state.values[0] && !state.values[1])
	testing.expect_value(t, Test_Driver_Diagnostics(&driver).semantic_id_collisions, i32(0))
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
		Checkbox(parent, "control", "Control", &state.checked)
	} else {
		Button(parent, "control", "Control", action(dx_activate, state))
	}
}

dx_draw :: proc(builder: ^Builder, user_data: rawptr) {
	state := cast(^DX_State)user_data
	dx_component(Center(builder), state)
	state.observed = state.calls
	state.observed_checked = state.checked
}

@(test)
dx_keyboard_updates_after_declaration :: proc(t: ^testing.T) {
	variants := [2]bool{false, true}
	for checkbox in variants {
		driver: Test_Driver
		Test_Driver_Init(&driver)
		state := DX_State {
			checkbox = checkbox,
		}
		input := Test_Input {
			screen_size = {320, 240},
			dpi_scale   = 1,
		}
		testing.expect(t, Test_Driver_Frame(&driver, input, dx_draw, &state))
		input.keys_pressed[int(Key.Tab)] = true
		testing.expect(t, Test_Driver_Frame(&driver, input, dx_draw, &state))
		input.keys_pressed = {}
		input.keys_pressed[int(Key.Enter)] = true
		testing.expect(t, Test_Driver_Frame(&driver, input, dx_draw, &state))
		testing.expect_value(t, state.observed, i32(0))
		testing.expect(t, !state.observed_checked)
		if checkbox {
			testing.expect(t, state.checked)
		} else {
			testing.expect_value(t, state.calls, i32(1))
			testing.expect(t, Test_Driver_Redraw_Requested(&driver))
		}
		input.keys_pressed = {}
		testing.expect(t, Test_Driver_Frame(&driver, input, dx_draw, &state))
		testing.expect_value(t, state.observed, state.calls)
		testing.expect_value(t, state.observed_checked, state.checked)
		testing.expect(t, !Test_Driver_Redraw_Requested(&driver))
		Test_Driver_Destroy(&driver)
	}
}
