#+build !js
package main

import "core:testing"
import fit "ingot:fit"

@(test)
typed_example_draw_obeys_collection_lifetime :: proc(t: ^testing.T) {
	driver: fit.Test_Driver
	fit.Test_Driver_Init(&driver)
	defer fit.Test_Driver_Destroy(&driver)
	data: State
	input := fit.Test_Input {
		screen_size = {640, 400},
		dpi_scale   = 1,
	}
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	input.keys_pressed[int(fit.Key.Tab)] = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	input.keys_pressed = {}
	input.keys_pressed[int(fit.Key.Enter)] = true
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	testing.expect_value(t, data.clicks, u64(0))
	input.keys_pressed = {}
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	testing.expect_value(t, data.clicks, u64(1))
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	testing.expect_value(t, data.clicks, u64(1))
	for _ in 0 ..< COMMAND_CAPACITY {
		testing.expect_value(
			t,
			fit.Typed_Commands_Append(&data.commands, Command.Reset),
			fit.Typed_Command_Result.Accepted,
		)
	}
	testing.expect_value(
		t,
		fit.Typed_Commands_Append(&data.commands, Command.Continue),
		fit.Typed_Command_Result.Full,
	)
	testing.expect(t, fit.Test_Driver_Frame(&driver, input, Draw, &data))
	ready, activation := fit.Typed_Commands_Dropped(&data.commands)
	testing.expect_value(t, ready, u64(1))
	testing.expect_value(t, activation, u64(0))
	testing.expect_value(t, data.clicks, u64(0))
	testing.expect(t, !data.declaration_failed)
}
