#+build !js
package procgen

import "core:testing"

@(test)
water_initialization_is_finite :: proc(t: ^testing.T) {
	ground := [4]i32{-4, 0, 2, -1}
	depth: [4]u32
	volume := water_initialize(ground[:], depth[:], 1)
	testing.expect_value(t, depth, [4]u32{5, 1, 0, 2})
	testing.expect_value(t, volume, u64(8))
	testing.expect_value(t, water_total(depth[:]), volume)
}

@(test)
water_flow_conserves_volume_and_fills_dry_cell :: proc(t: ^testing.T) {
	ground := [4]i32{0, 0, 0, 0}
	depth := [4]u32{16, 0, 0, 0}
	before := water_total(depth[:])
	result := water_step(ground[:], depth[:], 2, 2, 3, 0)
	testing.expect(t, result.moved)
	testing.expect_value(t, result.volume, before)
	testing.expect(t, depth[1] > 0 || depth[2] > 0)
}

@(test)
water_equal_surfaces_stay_still :: proc(t: ^testing.T) {
	ground := [4]i32{0, 2, 4, 6}
	depth := [4]u32{8, 6, 4, 2}
	before := depth
	result := water_step(ground[:], depth[:], 2, 2, 4, 3)
	testing.expect(t, !result.moved)
	testing.expect_value(t, depth, before)
}

@(test)
water_ridge_keeps_disconnected_basin_dry :: proc(t: ^testing.T) {
	ground := [6]i32{0, 20, 0, 0, 20, 0}
	depth := [6]u32{8, 0, 0, 8, 0, 0}
	for phase in u32(0) ..< 16 {
		_ = water_step(ground[:], depth[:], 3, 2, 2, phase)
	}
	testing.expect_value(t, depth[2], u32(0))
	testing.expect_value(t, depth[5], u32(0))
	testing.expect_value(t, water_total(depth[:]), u64(16))
}

@(test)
water_transfer_is_capped_and_deterministic :: proc(t: ^testing.T) {
	ground := [6]i32{0, 0, 0, 0, 0, 0}
	depth_a := [6]u32{100, 0, 0, 0, 0, 0}
	depth_b := depth_a
	_ = water_step(ground[:], depth_a[:], 3, 2, 7, 0)
	testing.expect(t, depth_a[0] >= 86)
	for phase in u32(1) ..< 20 {
		_ = water_step(ground[:], depth_a[:], 3, 2, 7, phase)
	}
	for phase in u32(0) ..< 20 {
		_ = water_step(ground[:], depth_b[:], 3, 2, 7, phase)
	}
	testing.expect_value(t, depth_a, depth_b)
	testing.expect_value(t, water_total(depth_a[:]), u64(100))
}
