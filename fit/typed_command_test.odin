#+build !js
package fit

import "core:testing"

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
