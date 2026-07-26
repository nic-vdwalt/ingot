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
