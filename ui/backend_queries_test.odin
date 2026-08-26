#+build !js
package ui

// Unit tests for frame-level input snapshot accessors. These read Ui_Input
// rather than the backend queues, which the platform adapter has already
// drained by the time view code runs.

import "core:testing"

@(test)
frame_snapshot_queries_are_deterministic :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input := Ui_Input {
		screen_size     = {1280, 720},
		dpi_scale       = 2,
		frame_time      = 0.25,
		time            = 42.5,
		fps             = 4,
		monitor_refresh = 120,
	}
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)

	testing.expect_value(t, frame_viewport(&frame), Rect_I32{0, 0, 1280, 720})
	testing.expect_value(t, frame_time(&frame), f32(0.25))
	testing.expect_value(t, frame_timestamp(&frame), f64(42.5))
	testing.expect_value(t, frame_dpi_scale(&frame), f32(2))
	testing.expect_value(t, frame_fps(&frame), i32(4))
	testing.expect_value(t, frame_monitor_refresh(&frame), i32(120))
}

@(test)
frame_characters_reports_typed_runes :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.characters[0] = 'h'
	input.characters[1] = 'i'
	input.character_count = 2

	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)

	typed := frame_characters(&frame)
	testing.expect_value(t, len(typed), 2)
	testing.expect_value(t, typed[0], 'h')
	testing.expect_value(t, typed[1], 'i')
}

@(test)
frame_pointer_events_reports_order_and_overflow :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.pointer_events[0] = {
		id           = 3,
		kind         = .Down,
		pointer_type = .Touch,
		button       = .Left,
	}
	input.pointer_events[1] = {
		id           = 4,
		kind         = .Move,
		pointer_type = .Pen,
		button       = .None,
	}
	input.pointer_event_count = 2
	input.pointer_events_overflowed = true
	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)
	events := frame_pointer_events(&frame)
	testing.expect_value(t, len(events), 2)
	testing.expect_value(t, events[0].id, Pointer_Id(3))
	testing.expect_value(t, events[1].id, Pointer_Id(4))
	testing.expect(t, frame_pointer_events_overflowed(&frame))
}

@(test)
frame_characters_consume_clears_queue :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)
	input: Ui_Input
	input.characters[0] = 'x'
	input.character_count = 1

	frame: Ui_Frame
	ui_frame_begin(&frame, &runtime, &input)
	defer ui_frame_end(&frame)

	testing.expect_value(t, len(frame_characters(&frame)), 1)
	frame_characters_consume(&frame)
	testing.expect_value(t, len(frame_characters(&frame)), 0)
	testing.expect_value(t, input.character_count, 0)
}

@(test)
frame_user_input_active_detects_every_source :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	expect_active :: proc(t: ^testing.T, runtime: ^Ui_Runtime, input: ^Ui_Input, active: bool) {
		frame: Ui_Frame
		ui_frame_begin(&frame, runtime, input)
		testing.expect_value(t, frame_user_input_active(&frame), active)
		ui_frame_end(&frame)
	}

	idle: Ui_Input
	expect_active(t, &runtime, &idle, false)

	moved: Ui_Input
	moved.mouse_delta = {1, 0}
	expect_active(t, &runtime, &moved, true)

	scrolled: Ui_Input
	scrolled.mouse_wheel = {0, -1}
	expect_active(t, &runtime, &scrolled, true)

	typed: Ui_Input
	typed.character_count = 1
	expect_active(t, &runtime, &typed, true)

	pointer: Ui_Input
	pointer.pointer_event_count = 1
	expect_active(t, &runtime, &pointer, true)

	pointer_overflow: Ui_Input
	pointer_overflow.pointer_events_overflowed = true
	expect_active(t, &runtime, &pointer_overflow, true)

	clicked: Ui_Input
	clicked.mouse_down[MouseButton.LEFT] = true
	expect_active(t, &runtime, &clicked, true)

	pressed: Ui_Input
	pressed.keys_pressed[KeyboardKey.A] = true
	expect_active(t, &runtime, &pressed, true)

	held: Ui_Input
	held.keys_down[KeyboardKey.LEFT_SHIFT] = true
	expect_active(t, &runtime, &held, true)
}
