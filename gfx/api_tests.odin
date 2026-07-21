#+build !js
package gfx

import "core:testing"

@(test)
frame_validation_rejects_stale_generation :: proc(t: ^testing.T) {
	old_generation := frame_generation
	old_active := frame_active
	defer {
		frame_generation = old_generation
		frame_active = old_active
	}

	frame_generation = 4
	frame_active = true
	frame := Frame{generation = 3, active = true}
	testing.expect(t, !_frame_valid(&frame))
}

@(test)
frame_validation_rejects_inactive_frame :: proc(t: ^testing.T) {
	old_generation := frame_generation
	old_active := frame_active
	defer {
		frame_generation = old_generation
		frame_active = old_active
	}

	frame_generation = 4
	frame_active = true
	frame := Frame{generation = 4, active = false}
	testing.expect(t, !_frame_valid(&frame))
}
