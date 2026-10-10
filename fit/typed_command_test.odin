#+build !js
package fit

import "core:testing"

@(test)
typed_commands_partial_drain_discards_snapshot_only :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 4)
	testing.expect_value(t, typed_commands_append(&queue, 1), Typed_Command_Result.Accepted)
	testing.expect_value(t, typed_commands_append(&queue, 2), Typed_Command_Result.Accepted)
	typed_commands_begin(&queue)
	value: u8
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, u8(1))
	testing.expect_value(t, typed_commands_append(&queue, 3), Typed_Command_Result.Accepted)
	typed_commands_end(&queue)
	typed_commands_begin(&queue)
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, u8(3))
	testing.expect(t, !typed_commands_take(&queue, &value))
	typed_commands_end(&queue)
}

Typed_Command_Fixture :: struct {
	queue:   Typed_Commands(u8, 2),
	results: [3]Typed_Command_Result,
}

typed_capacity_draw :: proc(builder: ^Builder, user_data: rawptr) {
	state := cast(^Typed_Command_Fixture)user_data
	typed_commands_begin(&state.queue)
	defer typed_commands_end(&state.queue)
	root := column(builder)
	for index in 0 ..< 3 {
		state.results[index] = button_command(
			root,
			u64(index + 1),
			"Command",
			&state.queue,
			u8(index),
		)
	}
}

@(test)
typed_commands_activation_capacity_is_observable :: proc(t: ^testing.T) {
	driver: Test_Driver
	test_driver_init(&driver)
	defer test_driver_destroy(&driver)
	state: Typed_Command_Fixture
	testing.expect(t, test_driver_frame(&driver, {}, typed_capacity_draw, &state))
	testing.expect_value(t, state.results[0], Typed_Command_Result.Accepted)
	testing.expect_value(t, state.results[1], Typed_Command_Result.Accepted)
	testing.expect_value(t, state.results[2], Typed_Command_Result.Full)
	ready, activation := typed_commands_dropped(&state.queue)
	testing.expect_value(t, ready, u64(0))
	testing.expect_value(t, activation, u64(1))
	testing.expect_value(t, state.queue.activation_count, 2)
	typed_commands_reset(&state.queue)
	_, activation = typed_commands_dropped(&state.queue)
	testing.expect_value(t, activation, u64(1))
}

Typed_Test_Command :: struct {
	kind: u8,
	row:  i32,
}

@(test)
typed_commands_preserve_fifo_order :: proc(t: ^testing.T) {
	queue: Typed_Commands(Typed_Test_Command, 4)
	testing.expect_value(
		t,
		typed_commands_append(&queue, Typed_Test_Command{kind = 1, row = 10}),
		Typed_Command_Result.Accepted,
	)
	testing.expect_value(
		t,
		typed_commands_append(&queue, Typed_Test_Command{kind = 2, row = 20}),
		Typed_Command_Result.Accepted,
	)
	typed_commands_begin(&queue)
	value: Typed_Test_Command
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, Typed_Test_Command{kind = 1, row = 10})
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, Typed_Test_Command{kind = 2, row = 20})
	testing.expect(t, !typed_commands_take(&queue, &value))
	typed_commands_end(&queue)
}

@(test)
typed_commands_report_saturation :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 2)
	testing.expect_value(t, typed_commands_append(&queue, 1), Typed_Command_Result.Accepted)
	testing.expect_value(t, typed_commands_append(&queue, 2), Typed_Command_Result.Accepted)
	testing.expect_value(t, typed_commands_append(&queue, 3), Typed_Command_Result.Full)
	ready, activation := typed_commands_dropped(&queue)
	testing.expect_value(t, ready, u64(1))
	testing.expect_value(t, activation, u64(0))
}

@(test)
typed_commands_defer_new_entries_to_the_next_drain :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 4)
	_ = typed_commands_append(&queue, 1)
	typed_commands_begin(&queue)
	value: u8
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, u8(1))
	_ = typed_commands_append(&queue, 2)
	testing.expect(t, !typed_commands_take(&queue, &value))
	typed_commands_end(&queue)
	typed_commands_begin(&queue)
	testing.expect(t, typed_commands_take(&queue, &value))
	testing.expect_value(t, value, u8(2))
	typed_commands_end(&queue)
}

@(test)
typed_commands_reset_retains_drop_diagnostics :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 1)
	_ = typed_commands_append(&queue, 1)
	_ = typed_commands_append(&queue, 2)
	typed_commands_reset(&queue)
	typed_commands_begin(&queue)
	value: u8
	testing.expect(t, !typed_commands_take(&queue, &value))
	typed_commands_end(&queue)
	ready, _ := typed_commands_dropped(&queue)
	testing.expect_value(t, ready, u64(1))
}
