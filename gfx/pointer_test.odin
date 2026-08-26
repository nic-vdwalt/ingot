#+build !js
package gfx

import "core:testing"

@(test)
pointer_staging_publishes_in_order_and_clears :: proc(t: ^testing.T) {
	input := new(Input)
	defer free(input)
	down := Pointer_Event {
		id           = 7,
		position     = {10, 20},
		pressure     = 1,
		buttons      = 1,
		kind         = .Down,
		pointer_type = .Touch,
		button       = .Left,
		primary      = true,
	}
	move := Pointer_Event {
		id           = 7,
		position     = {12, 24},
		pressure     = 1,
		buttons      = 1,
		kind         = .Move,
		pointer_type = .Touch,
		button       = .None,
		primary      = true,
	}
	testing.expect(t, pointer_stage(input, down))
	testing.expect(t, pointer_stage(input, move))
	pointer_publish_staged(input)
	testing.expect_value(t, input.pointer_event_count, 2)
	testing.expect_value(t, input.pointer_events[0], down)
	testing.expect_value(t, input.pointer_events[1], move)
	testing.expect_value(t, input.st_pointer_event_count, 0)
}

@(test)
pointer_staging_preserves_prefix_and_reports_overflow :: proc(t: ^testing.T) {
	input := new(Input)
	defer free(input)
	for index in 0 ..< POINTER_EVENTS_MAX + 9 {
		_ = pointer_stage(
			input,
			{id = Pointer_Id(index), kind = .Move, pointer_type = .Touch, button = .None},
		)
	}
	pointer_publish_staged(input)
	testing.expect_value(t, input.pointer_event_count, POINTER_EVENTS_MAX)
	testing.expect(t, input.pointer_events_overflowed)
	for index in 0 ..< POINTER_EVENTS_MAX {
		testing.expect_value(t, input.pointer_events[index].id, Pointer_Id(index))
	}

	pointer_publish_staged(input)
	testing.expect_value(t, input.pointer_event_count, 0)
	testing.expect(t, !input.pointer_events_overflowed)
}

@(test)
pointer_event_validation_requires_canonical_lifecycle_payloads :: proc(t: ^testing.T) {
	valid_cancel := Pointer_Event {
		id           = 4,
		kind         = .Cancel,
		pointer_type = .Pen,
		button       = .None,
	}
	testing.expect(t, pointer_event_valid(valid_cancel))
	invalid_cancel := valid_cancel
	invalid_cancel.pressure = 0.5
	testing.expect(t, !pointer_event_valid(invalid_cancel))
	invalid_cancel = valid_cancel
	invalid_cancel.buttons = 1
	testing.expect(t, !pointer_event_valid(invalid_cancel))
	invalid_move := valid_cancel
	invalid_move.kind = .Move
	invalid_move.button = .Left
	testing.expect(t, !pointer_event_valid(invalid_move))
	invalid_down := valid_cancel
	invalid_down.kind = .Down
	testing.expect(t, !pointer_event_valid(invalid_down))
}

@(test)
pointer_context_queries_return_current_snapshot :: proc(t: ^testing.T) {
	ctx := new(Context)
	defer free(ctx)
	ctx.inp.pointer_events[0] = {
		id           = 5,
		kind         = .Move,
		pointer_type = .Mouse,
		button       = .None,
	}
	ctx.inp.pointer_event_count = 1
	ctx.inp.pointer_events_overflowed = true
	events := context_pointer_events(ctx)
	testing.expect_value(t, len(events), 1)
	testing.expect_value(t, events[0].id, Pointer_Id(5))
	testing.expect(t, context_pointer_events_overflowed(ctx))
	testing.expect_value(t, len(context_pointer_events(nil)), 0)
	testing.expect(t, !context_pointer_events_overflowed(nil))
}
