#+build !js
package main

import "core:testing"
import b3 "vendor:box3d"

@(test)
physics_time_ignores_inactive_simulation :: proc(t: ^testing.T) {
	value := new(State)
	defer free(value)
	physics_time_accumulate(value, FIXED_DT, false)
	testing.expect_value(t, value.accumulator, f32(0))
	physics_time_accumulate(value, FIXED_DT, true)
	testing.expect(t, abs(value.accumulator - FIXED_DT) < 1e-6)
	value.paused = true
	physics_time_accumulate(value, FIXED_DT, true)
	testing.expect(t, abs(value.accumulator - FIXED_DT) < 1e-6)
}

@(test)
snapshot_transform_interpolation_has_correct_endpoints :: proc(t: ^testing.T) {
	a := b3.WorldTransform {
		p = {0, 2, 4},
		q = b3.Quat_identity,
	}
	b := b3.WorldTransform {
		p = {2, 4, 6},
		q = b3.Quat_identity,
	}
	start := snapshot_transform_interpolate(a, b, 0)
	middle := snapshot_transform_interpolate(a, b, 0.5)
	end := snapshot_transform_interpolate(a, b, 1)
	testing.expect_value(t, start.p, a.p)
	testing.expect_value(t, middle.p, b3.Pos{1, 3, 5})
	testing.expect_value(t, end.p, b.p)
	testing.expect(t, b3.IsValidQuat(middle.q))
}

@(test)
snapshot_transform_interpolation_handles_quaternion_polarity :: proc(t: ^testing.T) {
	a := b3.WorldTransform {
		q = b3.Quat_identity,
	}
	b := b3.WorldTransform {
		q = -b3.Quat_identity,
	}
	result := snapshot_transform_interpolate(a, b, 0.5)
	testing.expect(t, b3.IsValidQuat(result.q))
	testing.expect(t, abs(b3.DotQuat(result.q, b3.Quat_identity)) > 0.999)
}

@(test)
snapshot_render_alpha_selects_current_transform_when_paused :: proc(t: ^testing.T) {
	value := new(State)
	defer free(value)
	value.accumulator = FIXED_DT / 2
	testing.expect(t, abs(snapshot_render_alpha(value) - 0.5) < 1e-6)
	value.paused = true
	testing.expect_value(t, snapshot_render_alpha(value), f32(1))
}
