#+build !js
package fit

import "core:testing"

Owned_Result_State :: struct {
	queue:    Typed_Commands(u32, 2),
	result:   Button_Result,
	repeated: Button_Result,
	isolated: Button_Result,
	commands: int,
	outputs:  i32,
	disabled: bool,
}

owned_result_draw :: proc(builder: ^Builder, userdata: rawptr) {
	state := cast(^Owned_Result_State)userdata
	typed_commands_begin(&state.queue, builder)
	defer typed_commands_end(&state.queue)
	value: u32
	for _ in 0 ..< 2 {
		if !typed_commands_take(&state.queue, &value) do break
		state.commands += 1
	}
	root := center(builder)
	parent := scope(root, "component")
	state.result = button_result(parent, "button")
	state.repeated = button_result(parent, id(parent, "button"))
	state.isolated = button_result(scope(root, u64(42)), "button")
	_ = button_result(parent, u64(42))
	_ = button_command(
		parent,
		"button",
		"Button",
		&state.queue,
		u32(7),
		{disabled = state.disabled, size = {width = fixed(100), height = fixed(40)}},
	)
	state.outputs = builder.inner.output_count
}

@(test)
owned_result_keyboard_delivery :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Owned_Result_State
	base := Test_Input {
		screen_size = {320, 240},
		dpi_scale   = 1,
	}
	testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
	tab := base
	tab.keys_pressed[int(Key.Tab)] = true
	testing.expect(t, test_driver_frame(&driver, tab, owned_result_draw, &state))
	enter := base
	enter.keys_pressed[int(Key.Enter)] = true
	testing.expect(t, test_driver_frame(&driver, enter, owned_result_draw, &state))
	testing.expect(t, test_driver_redraw_requested(&driver))
	testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
	testing.expect(t, state.result.activated && state.commands == 1)
}

owned_temporary_draw :: proc(builder: ^Builder, userdata: rawptr) {
	outputs := cast(^i32)userdata
	queue: Typed_Commands(u8, 1)
	typed_commands_begin(&queue, builder)
	assert(queue.mode == .Owned)
	defer typed_commands_end(&queue)
	root := column(builder)
	_ = button_command(root, "temporary", "Temporary", cast(^Typed_Commands(u8, 1))rawptr(&queue), u8(1))
	outputs^ = builder.inner.output_count
}

@(test)
owned_temporary_queue_does_not_escape :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	outputs: i32 = -1
	testing.expect(t, test_driver_frame(&driver, {}, owned_temporary_draw, &outputs))
	testing.expect_value(t, outputs, i32(0))
}

owned_capacity_draw :: proc(builder: ^Builder, userdata: rawptr) {
	state := cast(^Typed_Command_Fixture)userdata
	typed_commands_begin(&state.queue, builder)
	defer typed_commands_end(&state.queue)
	root := column(builder)
	for index in 0 ..< 3 {
		state.results[index] = button_command(
			root,
			u64(index + 1),
			"Button",
			&state.queue,
			u8(index),
		)
		state.counts[index] = builder.inner.prepared.count
	}
}

@(test)
owned_capacity_and_unavailable :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Typed_Command_Fixture
	testing.expect(t, test_driver_frame(&driver, {}, owned_capacity_draw, &state))
	testing.expect_value(t, state.results[2], Typed_Command_Result.Full)
	testing.expect_value(t, state.counts[1], state.counts[2])
	testing.expect_value(t, state.queue.dropped_activation, u64(1))
	state.queue.result_generation = 0
	testing.expect(t, test_driver_frame(&driver, {}, owned_capacity_draw, &state))
	testing.expect_value(t, typed_commands_unavailable(&state.queue), u64(2))
	testing.expect_value(t, typed_commands_append(&state.queue, 1), Typed_Command_Result.Accepted)
	testing.expect_value(t, typed_commands_append(&state.queue, 2), Typed_Command_Result.Accepted)
	testing.expect_value(t, typed_commands_append(&state.queue, 3), Typed_Command_Result.Full)
	testing.expect(t, test_driver_frame(&driver, {}, owned_capacity_draw, &state))
	testing.expect_value(t, state.queue.ready_count, 0)
	testing.expect_value(t, state.queue.dropped_ready, u64(1))
}

owned_drain_draw :: proc(builder: ^Builder, userdata: rawptr) {
	state := cast(^Owned_Result_State)userdata
	typed_commands_begin(&state.queue, builder)
	value: u32
	if typed_commands_take(&state.queue, &value) do state.commands = int(value)
	_ = typed_commands_append(&state.queue, 3)
	typed_commands_end(&state.queue)
	_ = column(builder)
}

@(test)
owned_drain_preserves_post_snapshot_fifo :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Owned_Result_State
	_ = typed_commands_append(&state.queue, 1)
	testing.expect(t, test_driver_frame(&driver, {}, owned_drain_draw, &state))
	testing.expect_value(t, state.commands, 1)
	testing.expect_value(t, state.queue.ready_count, 1)
	testing.expect_value(t, state.queue.ready[0], u32(3))
	_ = typed_commands_append(&state.queue, 4)
	testing.expect(t, test_driver_frame(&driver, {}, owned_drain_draw, &state))
	testing.expect_value(t, state.commands, 3)
	testing.expect_value(t, state.queue.ready_count, 0)
}

@(test)
owned_result_pointer_delivery :: proc(t: ^testing.T) {
	disabled_values := [?]bool{false, true}
	for disabled in disabled_values {
		driver: Test_Driver
		test_driver_init(&driver)
		state := Owned_Result_State {
			disabled = disabled,
		}
		base := Test_Input {
			screen_size    = {320, 240},
			mouse_position = {160, 120},
			dpi_scale      = 1,
		}
		testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
		testing.expect(t, state.result.status == .Unavailable)
		pressed := base
		pressed.mouse_pressed[0] = true
		pressed.mouse_down[0] = true
		testing.expect(t, test_driver_frame(&driver, pressed, owned_result_draw, &state))
		released := base
		released.mouse_released[0] = true
		testing.expect(t, test_driver_frame(&driver, released, owned_result_draw, &state))
		testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
		testing.expect_value(t, state.result.activated, !disabled)
		testing.expect_value(t, state.result, state.repeated)
		testing.expect(t, !state.isolated.activated)
		testing.expect_value(t, state.commands, disabled ? 0 : 1)
		testing.expect_value(t, state.outputs, i32(0))
		testing.expect(t, state.queue.binding.builder == nil)
		testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
		testing.expect(t, !state.result.activated)
		test_driver_destroy(&driver)
		test_driver_init(&driver)
		testing.expect(t, test_driver_frame(&driver, base, owned_result_draw, &state))
		testing.expect(t, state.result.status == .Unavailable)
		test_driver_destroy(&driver)
	}
}
