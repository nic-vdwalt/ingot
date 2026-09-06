#+build !js
package fit

import "core:testing"

@(test)
typed_commands_partial_drain_discards_snapshot_only :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 4)
	testing.expect_value(t, Typed_Commands_Append(&queue, 1), Typed_Command_Result.Accepted)
	testing.expect_value(t, Typed_Commands_Append(&queue, 2), Typed_Command_Result.Accepted)
	Typed_Commands_Begin(&queue)
	value: u8
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, u8(1))
	testing.expect_value(t, Typed_Commands_Append(&queue, 3), Typed_Command_Result.Accepted)
	Typed_Commands_End(&queue)
	Typed_Commands_Begin(&queue)
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, u8(3))
	testing.expect(t, !Typed_Commands_Take(&queue, &value))
	Typed_Commands_End(&queue)
}

Typed_Command_Fixture :: struct {
	queue:   Typed_Commands(u8, 2),
	results: [3]Typed_Command_Result,
}

typed_capacity_draw :: proc(builder: ^Builder, user_data: rawptr) {
	state := cast(^Typed_Command_Fixture)user_data
	Typed_Commands_Begin(&state.queue)
	defer Typed_Commands_End(&state.queue)
	root := Column(builder)
	for index in 0 ..< 3 {
		state.results[index] = Button_Command(
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
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	state: Typed_Command_Fixture
	testing.expect(t, Test_Driver_Frame(&driver, {}, typed_capacity_draw, &state))
	testing.expect_value(t, state.results[0], Typed_Command_Result.Accepted)
	testing.expect_value(t, state.results[1], Typed_Command_Result.Accepted)
	testing.expect_value(t, state.results[2], Typed_Command_Result.Full)
	ready, activation := Typed_Commands_Dropped(&state.queue)
	testing.expect_value(t, ready, u64(0))
	testing.expect_value(t, activation, u64(1))
	testing.expect_value(t, state.queue.activation_count, 2)
	Typed_Commands_Reset(&state.queue)
	_, activation = Typed_Commands_Dropped(&state.queue)
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
		Typed_Commands_Append(&queue, Typed_Test_Command{kind = 1, row = 10}),
		Typed_Command_Result.Accepted,
	)
	testing.expect_value(
		t,
		Typed_Commands_Append(&queue, Typed_Test_Command{kind = 2, row = 20}),
		Typed_Command_Result.Accepted,
	)
	Typed_Commands_Begin(&queue)
	value: Typed_Test_Command
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, Typed_Test_Command{kind = 1, row = 10})
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, Typed_Test_Command{kind = 2, row = 20})
	testing.expect(t, !Typed_Commands_Take(&queue, &value))
	Typed_Commands_End(&queue)
}

@(test)
typed_commands_report_saturation :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 2)
	testing.expect_value(t, Typed_Commands_Append(&queue, 1), Typed_Command_Result.Accepted)
	testing.expect_value(t, Typed_Commands_Append(&queue, 2), Typed_Command_Result.Accepted)
	testing.expect_value(t, Typed_Commands_Append(&queue, 3), Typed_Command_Result.Full)
	ready, activation := Typed_Commands_Dropped(&queue)
	testing.expect_value(t, ready, u64(1))
	testing.expect_value(t, activation, u64(0))
}

@(test)
typed_commands_defer_new_entries_to_the_next_drain :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 4)
	_ = Typed_Commands_Append(&queue, 1)
	Typed_Commands_Begin(&queue)
	value: u8
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, u8(1))
	_ = Typed_Commands_Append(&queue, 2)
	testing.expect(t, !Typed_Commands_Take(&queue, &value))
	Typed_Commands_End(&queue)
	Typed_Commands_Begin(&queue)
	testing.expect(t, Typed_Commands_Take(&queue, &value))
	testing.expect_value(t, value, u8(2))
	Typed_Commands_End(&queue)
}

@(test)
typed_commands_reset_retains_drop_diagnostics :: proc(t: ^testing.T) {
	queue: Typed_Commands(u8, 1)
	_ = Typed_Commands_Append(&queue, 1)
	_ = Typed_Commands_Append(&queue, 2)
	Typed_Commands_Reset(&queue)
	Typed_Commands_Begin(&queue)
	value: u8
	testing.expect(t, !Typed_Commands_Take(&queue, &value))
	Typed_Commands_End(&queue)
	ready, _ := Typed_Commands_Dropped(&queue)
	testing.expect_value(t, ready, u64(1))
}
