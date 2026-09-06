#+build !js
package fit

import "core:testing"
import "ingot:ui"

@(test)
fit_pointer_events_use_the_bound_builder_frame :: proc(t: ^testing.T) {
	runtime: ui.Ui_Runtime
	ui.ui_runtime_init(&runtime)
	defer ui.ui_runtime_destroy(&runtime)
	input: ui.Ui_Input
	input.pointer_events[0] = {
		id           = 11,
		position     = {25, 40},
		pressure     = 1,
		buttons      = 1,
		kind         = .Down,
		pointer_type = .Touch,
		button       = .Left,
		primary      = true,
	}
	input.pointer_event_count = 1
	input.pointer_events_overflowed = true
	frame: ui.Ui_Frame
	ui.ui_frame_begin(&frame, &runtime, &input)
	defer ui.ui_frame_end(&frame)

	builder: Builder
	builder_open(&builder, &frame, {0, 0, 320, 240})
	defer builder_close(&builder)
	events := Pointer_Events(&builder)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].id, Pointer_Id(11))
	testing.expect(t, Pointer_Events_Overflowed(&builder))
}

Pointer_Test_State :: struct {
	t: ^testing.T,
}

pointer_test_draw :: proc(builder: ^Builder, user_data: rawptr) {
	assert(builder != nil && user_data != nil)
	state := cast(^Pointer_Test_State)user_data
	events := Pointer_Events(builder)
	testing.expect_value(state.t, len(events), POINTER_EVENT_CAP)
	testing.expect_value(state.t, events[0].id, Pointer_Id(12))
	testing.expect(state.t, Pointer_Events_Overflowed(builder))
	root := Center(builder)
	Label(root, "pointer test")
}

@(test)
fit_pointer_test_driver_copies_bounds_and_overflow :: proc(t: ^testing.T) {
	driver: Test_Driver
	Test_Driver_Init(&driver)
	defer Test_Driver_Destroy(&driver)
	input: Test_Input
	input.pointer_events[0] = {
		id           = 12,
		kind         = .Move,
		pointer_type = .Pen,
		button       = .None,
	}
	input.pointer_event_count = POINTER_EVENT_CAP + 1
	state := Pointer_Test_State {
		t = t,
	}
	testing.expect(t, Test_Driver_Frame(&driver, input, pointer_test_draw, &state))
}
