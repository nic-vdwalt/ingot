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
