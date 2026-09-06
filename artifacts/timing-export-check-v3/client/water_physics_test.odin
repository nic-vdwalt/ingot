#+build !js
package main

import "core:math"
import "core:testing"

@(test)
water_physics_distinguishes_dry_partial_and_full_immersion :: proc(t: ^testing.T) {
	dry := Water_Physics_Sample {
		surface = {0, 0, 0},
		normal  = {0, 0, 1},
	}
	testing.expect_value(t, water_physics_submerged_fraction({0, 0, 0}, 1, dry), f32(0))
	wet := dry
	wet.wet = true
	testing.expect_value(t, water_physics_submerged_fraction({0, 0, 0}, 1, wet), f32(0.5))
	wet.surface.z = 2
	testing.expect_value(t, water_physics_submerged_fraction({0, 0, 0}, 1, wet), f32(1))
}

@(test)
water_physics_buoyancy_and_drag_follow_the_surface_frame :: proc(t: ^testing.T) {
	sample := Water_Physics_Sample {
		surface  = {0, 0, 1},
		normal   = {0, 0, 1},
		velocity = {2, 0, 0},
		depth    = 4,
		wet      = true,
	}
	force := water_physics_force({0, 0, 0}, 1, 2, {4, 0, 0}, sample)
	testing.expect(t, force.x < 0)
	testing.expect(t, force.z > 0)
	matching := water_physics_force({0, 0, 0}, 1, 2, sample.velocity, sample)
	testing.expect_value(t, matching.x, f32(0))
}

@(test)
water_physics_force_is_finite_and_bounded :: proc(t: ^testing.T) {
	sample := Water_Physics_Sample {
		surface = {0, 0, 100},
		normal  = {0, 0, 1},
		wet     = true,
	}
	force := water_physics_force({0, 0, 0}, 1, 1_000, {100_000, 100_000, -100_000}, sample)
	for component in force do testing.expect(t, abs(component) <= WATER_PHYSICS_FORCE_MAX)
}

@(test)
water_physics_acceleration_force_is_wet_finite_and_bounded :: proc(t: ^testing.T) {
	dry := Water_Physics_Sample {
		acceleration = {2, 0, 0},
	}
	testing.expect_value(t, water_physics_acceleration_force(dry, 3), [3]f32{})
	wet := dry
	wet.wet = true
	testing.expect_value(t, water_physics_acceleration_force(wet, 3), [3]f32{6, 0, 0})
	wet.acceleration = {100_000, -100_000, 100_000}
	force := water_physics_acceleration_force(wet, 1_000)
	for component in force do testing.expect(t, abs(component) <= WATER_PHYSICS_FORCE_MAX)
	wet.acceleration.x = math.nan_f32()
	testing.expect_value(t, water_physics_acceleration_force(wet, 3), [3]f32{})
}

@(test)
water_physics_radial_gravity_accounts_for_body_gravity_scale :: proc(t: ^testing.T) {
	world_gravity := [3]f32{0, 0, -WATER_PHYSICS_GRAVITY}
	disabled := water_physics_radial_gravity_force({10, 0, 0}, 2, 0, world_gravity)
	testing.expect_value(t, disabled, [3]f32{-20, 0, 0})
	enabled := water_physics_radial_gravity_force({10, 0, 0}, 2, 1, world_gravity)
	testing.expect_value(t, enabled, [3]f32{-20, 0, 20})
	testing.expect_value(t, enabled + world_gravity * 2, [3]f32{-20, 0, 0})
	testing.expect_value(t, water_physics_radial_gravity_force({}, 2, 0, world_gravity), [3]f32{})
}

@(test)
water_physics_acceleration_scales_with_weighted_hull_immersion :: proc(t: ^testing.T) {
	points := [2]Water_Physics_Hull_Point{{displacement_share = 1}, {displacement_share = 3}}
	states := [2]Water_Physics_Point_State{}
	sample := Water_Physics_Sample {
		acceleration = {4, 0, 0},
		wet          = true,
	}
	testing.expect_value(t, water_physics_hull_immersion(points[:], states[:]), f32(0))
	testing.expect_value(t, water_physics_acceleration_force(sample, 2, 0), [3]f32{})
	states[0].submerged_fraction = 1
	immersion := water_physics_hull_immersion(points[:], states[:])
	testing.expect_value(t, immersion, f32(0.25))
	testing.expect_value(
		t,
		water_physics_acceleration_force(sample, 2, immersion),
		[3]f32{2, 0, 0},
	)
	states[1].submerged_fraction = 1
	immersion = water_physics_hull_immersion(points[:], states[:])
	testing.expect_value(t, immersion, f32(1))
	testing.expect_value(
		t,
		water_physics_acceleration_force(sample, 2, immersion),
		[3]f32{8, 0, 0},
	)
}
