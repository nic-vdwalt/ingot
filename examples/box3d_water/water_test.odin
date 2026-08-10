// examples/box3d_water - the oracle for the water model. Every procedure under
// test is pure, so these run headless: no window, no GPU, and no Box3D world.
// The properties checked here are the ones a plausible-looking but wrong wave
// would violate - bounded amplitude, a derivative that matches the height, an
// immersion fraction that saturates, and a force that vanishes above water.
#+build !js
package main

import "core:math"
import "core:testing"

@(test)
water_height_stays_within_its_declared_span :: proc(t: ^testing.T) {
	// WATER_HEIGHT_SPAN sizes the mesh bounds and the colour ramp, so a
	// retuned amplitude that breaks it has to fail here rather than clip
	// geometry on screen.
	for step in 0 ..< 512 {
		phase := f32(step) * WATER_PHASE_PERIOD / 512
		x := f32(step % 29) - 14
		y := f32(step % 23) - 11
		height := water_height(x, y, phase)
		testing.expect(t, height <= WATER_BASE_Z + WATER_HEIGHT_SPAN, "height above span")
		testing.expect(t, height >= WATER_BASE_Z - WATER_HEIGHT_SPAN, "height below span")
	}
}

@(test)
water_surface_repeats_over_its_phase_period :: proc(t: ^testing.T) {
	// Physics folds the phase by WATER_PHASE_PERIOD. If the surface were not
	// periodic there, the fold would teleport the water and the buoyancy with
	// it - the reason the period is ten primary cycles, not one.
	for step in 0 ..< 64 {
		phase := f32(step) * 0.19
		x := f32(step % 17) - 8
		y := f32(step % 13) - 6
		start := water_height(x, y, phase)
		wrapped := water_height(x, y, phase + WATER_PHASE_PERIOD)
		testing.expect(t, abs(start - wrapped) < 1e-3, "surface is not phase periodic")
	}
}

@(test)
water_surface_velocity_matches_the_height_derivative :: proc(t: ^testing.T) {
	// Drag uses the analytical derivative rather than a finite difference of
	// the previous frame's height. This is what proves the two agree.
	delta := f32(1e-3)
	for step in 0 ..< 64 {
		phase := f32(step) * 0.27
		x := f32(step % 19) - 9
		y := f32(step % 11) - 5
		ahead := water_height(x, y, phase + WATER_PHASE_RATE * delta)
		behind := water_height(x, y, phase - WATER_PHASE_RATE * delta)
		numeric := (ahead - behind) / (2 * delta)
		analytic := water_surface_velocity(x, y, phase)
		testing.expect(t, abs(numeric - analytic) < 1e-2, "derivative disagrees with height")
	}
}

@(test)
water_normal_is_unit_and_points_upward :: proc(t: ^testing.T) {
	for step in 0 ..< 128 {
		phase := f32(step) * 0.11
		x := f32(step % 31) - 15
		y := f32(step % 27) - 13
		normal := water_normal(x, y, phase)
		length := math.sqrt(normal.x * normal.x + normal.y * normal.y + normal.z * normal.z)
		testing.expect(t, abs(length - 1) < 1e-4, "surface normal is not unit length")
		testing.expect(t, normal.z > 0, "surface normal points into the water")
	}
}

@(test)
water_submerged_fraction_saturates_at_both_ends :: proc(t: ^testing.T) {
	half := f32(1)
	testing.expect_value(t, water_submerged_fraction(10, half, 0), f32(0))
	testing.expect_value(t, water_submerged_fraction(-10, half, 0), f32(1))
	testing.expect_value(t, water_submerged_fraction(0, half, 0), f32(0.5))
	// Exactly touching the surface from above must read as dry, not as a
	// sliver of immersion, or a resting body jitters on the boundary.
	testing.expect_value(t, water_submerged_fraction(1, half, 0), f32(0))
	testing.expect_value(t, water_submerged_fraction(-1, half, 0), f32(1))
	// A degenerate body has no volume to displace and must not divide by zero.
	testing.expect_value(t, water_submerged_fraction(0, 0, 5), f32(0))
}

@(test)
water_force_is_zero_above_the_surface :: proc(t: ^testing.T) {
	force := water_force(10, 1, 8, 0, 0, {2, -3, 4})
	testing.expect_value(t, force, [3]f32{0, 0, 0})
	// A massless body is a caller error, not a physical case; it must return
	// nothing rather than produce an infinite acceleration.
	testing.expect_value(t, water_force(0, 1, 0, 0, 0, {}), [3]f32{0, 0, 0})
}

@(test)
water_force_lifts_a_fully_submerged_body_against_gravity :: proc(t: ^testing.T) {
	mass := f32(8)
	weight := mass * WATER_GRAVITY
	force := water_force(-5, 1, mass, 0, 0, {})
	testing.expect(t, force.z > weight, "full immersion must beat the body's weight")
	testing.expect(t, force.z <= WATER_FORCE_MAX, "buoyancy exceeded its clamp")
	// Equilibrium is the fraction where buoyancy exactly cancels weight, and
	// it must land strictly inside the body so it floats partly visible.
	equilibrium := 1 / WATER_BUOYANCY_GAIN
	testing.expect(t, equilibrium > 0 && equilibrium < 1, "no floating equilibrium exists")
}

@(test)
water_force_damps_motion_relative_to_the_moving_surface :: proc(t: ^testing.T) {
	mass := f32(8)
	rising := water_force(0, 1, mass, 0, 0, {1, 0, 0})
	testing.expect(t, rising.x < 0, "drag must oppose horizontal motion")
	// A body matching the surface's own vertical speed is not moving through
	// the water, so drag must contribute nothing to the vertical force.
	matched := water_force(0, 1, mass, 0, 2, {0, 0, 2})
	still := water_force(0, 1, mass, 0, 0, {})
	testing.expect(t, abs(matched.z - still.z) < 1e-3, "drag ignored the surface velocity")
}
