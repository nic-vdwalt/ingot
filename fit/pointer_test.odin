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

@(test)
fit_pointer_test_input_copies_bounds_and_overflow :: proc(t: ^testing.T) {
	input: Test_Input
	input.pointer_events[0] = {
		id           = 12,
		kind         = .Move,
		pointer_type = .Pen,
		button       = .None,
	}
	input.pointer_event_count = POINTER_EVENT_CAP + 1
	result := test_driver_input(input)
	testing.expect_value(t, result.pointer_event_count, ui.INPUT_POINTER_EVENT_CAP)
	testing.expect_value(t, result.pointer_events[0].id, ui.Pointer_Id(12))
	testing.expect(t, result.pointer_events_overflowed)
}
