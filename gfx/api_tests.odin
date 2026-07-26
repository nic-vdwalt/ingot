#+build !js
package gfx

import "core:testing"

@(test)
frame_validation_rejects_stale_generation :: proc(t: ^testing.T) {
	old_epoch := g.epoch
	old_generation := g.frame_generation
	old_active := g.frame_active
	defer {
		g.epoch = old_epoch
		g.frame_generation = old_generation
		g.frame_active = old_active
	}

	g.epoch = 2
	g.frame_generation = 4
	g.frame_active = true
	frame := Frame {
		epoch      = 2,
		generation = 3,
		active     = true,
	}
	testing.expect(t, !_frame_valid(&frame))
}

@(test)
frame_validation_rejects_inactive_frame :: proc(t: ^testing.T) {
	old_epoch := g.epoch
	old_generation := g.frame_generation
	old_active := g.frame_active
	defer {
		g.epoch = old_epoch
		g.frame_generation = old_generation
		g.frame_active = old_active
	}

	g.epoch = 2
	g.frame_generation = 4
	g.frame_active = true
	frame := Frame {
		epoch      = 2,
		generation = 4,
		active     = false,
	}
	testing.expect(t, !_frame_valid(&frame))
}

@(test)
frame_validation_routes_independent_contexts :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	first.id, first.epoch, first.frame_generation, first.frame_active = 2, 4, 7, true
	second.id, second.epoch, second.frame_generation, second.frame_active = 3, 5, 9, true
	first.frame.has_frame = true
	second.frame.has_frame = true
	first_frame := Frame {
		owner      = first,
		epoch      = 4,
		generation = 7,
		active     = true,
	}
	second_frame := Frame {
		owner      = second,
		epoch      = 5,
		generation = 9,
		active     = true,
	}
	testing.expect(t, _frame_valid(&first_frame))
	testing.expect(t, _frame_valid(&second_frame))
	first_frame.owner = second
	testing.expect(t, !_frame_valid(&first_frame))
}

@(test)
context_queries_are_isolated :: proc(t: ^testing.T) {
	first := new(Context)
	second := new(Context)
	defer free(first)
	defer free(second)
	first.width, first.height, first.dpi, first.frame_time = 640, 360, 1, 0.01
	second.width, second.height, second.dpi, second.frame_time = 320, 240, 2, 0.02
	first.inp.mouse = {10, 20}
	second.inp.mouse = {30, 40}
	first.inp.pressed[KeyboardKey.A] = true
	testing.expect_value(t, context_screen_width(first), i32(640))
	testing.expect_value(t, context_screen_width(second), i32(320))
	testing.expect_value(t, context_get_mouse_position(first), Vector2{10, 20})
	testing.expect_value(t, context_get_mouse_position(second), Vector2{30, 40})
	testing.expect(t, context_is_key_pressed(first, .A))
	testing.expect(t, !context_is_key_pressed(second, .A))
}

@(test)
frame_pacing_remaining_is_bounded :: proc(t: ^testing.T) {
	start := _frame_pacing_remaining(10.0, 10.0, 0.1)
	middle := _frame_pacing_remaining(10.05, 10.0, 0.1)
	reached := _frame_pacing_remaining(10.2, 10.0, 0.1)
	regressed := _frame_pacing_remaining(9.0, 10.0, 0.1)
	testing.expect(t, abs(start - 0.1) < 0.000001)
	testing.expect(t, abs(middle - 0.05) < 0.000001)
	testing.expect_value(t, reached, 0.0)
	testing.expect(t, abs(regressed - 0.1) < 0.000001)
}
