#+build !js
// ingot:gfx — tests for the shape primitives added for raylib parity.
//
// These drive the batch's _emit_* layer through a private Renderer, so they
// assert the geometry actually produced rather than that a call returned. They
// touch no shared frame state and stay deterministic under the concurrent
// runner.
package gfx

import "core:math"
import "core:testing"

@(private)
count_emitted_triangles :: proc(r: ^Renderer) -> int {
	assert(r != nil, "count_emitted_triangles: nil renderer")
	return len(r.indices) / 3
}

@(test)
polygon_helpers_reject_degenerate_side_counts :: proc(t: ^testing.T) {
	// Fewer than three sides is not a polygon. raylib silently draws nothing;
	// so does ingot, but the guard is asserted so it cannot regress into
	// emitting a malformed fan.
	r := new_test_renderer()
	defer free(r)

	restore := g.frame.has_frame
	defer g.frame.has_frame = restore
	g.frame.has_frame = false

	for sides in ([]i32{-1, 0, 1, 2}) {
		DrawPoly({0, 0}, sides, 10, 0, WHITE)
		DrawPolyLines({0, 0}, sides, 10, 0, WHITE)
	}
	testing.expect_value(t, len(g.rend.verts), 0)
}

@(test)
ellipse_tessellation_scales_with_the_larger_radius :: proc(t: ^testing.T) {
	// A wide flat ellipse must be tessellated for its long axis, or the long
	// edge visibly polygonises while the short one is over-sampled.
	testing.expect_value(t, _ellipse_segments(4, 4), i32(16))
	testing.expect_value(t, _ellipse_segments(200, 4), i32(200))
	testing.expect_value(t, _ellipse_segments(4, 200), i32(200))
	// Negative radii are a caller error, not a crash: the count stays valid.
	testing.expect(t, _ellipse_segments(-50, -1) > 0)
}

@(test)
polar_ellipse_traces_both_radii :: proc(t: ^testing.T) {
	center := Vector2{100, 50}
	at_zero := _polar_ellipse(center, 30, 10, 0)
	at_ninety := _polar_ellipse(center, 30, 10, 90)
	expect_point_near(t, at_zero, {130, 50}, "0 degrees uses the horizontal radius")
	expect_point_near(t, at_ninety, {100, 60}, "90 degrees uses the vertical radius")
}

@(test)
triangle_fan_emits_one_triangle_per_edge :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)

	points := [4]Vector2{{0, 0}, {10, 0}, {10, 10}, {0, 10}}
	// A fan of n points spans n-2 triangles, all sharing points[0].
	for index in 1 ..< i32(len(points)) - 1 {
		_emit_tri(r, points[0], points[index], points[index + 1], {1, 1, 1, 1})
	}
	testing.expect_value(t, count_emitted_triangles(r), 2)
	expect_point_near(t, r.verts[0].pos, {0, 0}, "first triangle starts at the hub")
	expect_point_near(t, r.verts[3].pos, {0, 0}, "second triangle starts at the hub")
}

@(test)
triangle_fan_and_strip_ignore_degenerate_input :: proc(t: ^testing.T) {
	restore := g.frame.has_frame
	defer g.frame.has_frame = restore
	g.frame.has_frame = false

	points := [2]Vector2{{0, 0}, {1, 1}}
	DrawTriangleFan(nil, 8, WHITE)
	DrawTriangleStrip(nil, 8, WHITE)
	DrawTriangleFan(raw_data(points[:]), 2, WHITE)
	DrawTriangleStrip(raw_data(points[:]), 2, WHITE)
	testing.expect_value(t, len(g.rend.verts), 0)
}

@(test)
pixel_is_a_unit_rectangle :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)

	_emit_quad(r, {7, 9, 1, 1}, {0, 0, 1, 1}, {1, 1, 1, 1})
	testing.expect_value(t, len(r.verts), 4)
	expect_point_near(t, r.verts[0].pos, {7, 9}, "tl")
	expect_point_near(t, r.verts[3].pos, {8, 10}, "br")
}

@(test)
gradient_ex_maps_raylib_corner_order :: proc(t: ^testing.T) {
	// raylib names the corners topLeft, bottomLeft, topRight, bottomRight.
	// The batch emits tl, bl, tr, br. Getting this mapping wrong swaps the
	// gradient diagonally, which is easy to miss by eye.
	r := new_test_renderer()
	defer free(r)

	top_left := [4]f32{1, 0, 0, 1}
	bottom_left := [4]f32{0, 1, 0, 1}
	top_right := [4]f32{0, 0, 1, 1}
	bottom_right := [4]f32{1, 1, 0, 1}
	_emit_gradient_quad(r, {0, 0, 10, 10}, top_left, top_right, bottom_right, bottom_left)

	testing.expect_value(t, r.verts[0].col, top_left)
	testing.expect_value(t, r.verts[1].col, bottom_left)
	testing.expect_value(t, r.verts[2].col, top_right)
	testing.expect_value(t, r.verts[3].col, bottom_right)
}

@(test)
polar_places_points_on_the_circle :: proc(t: ^testing.T) {
	center := Vector2{10, 20}
	for degrees in ([]f32{0, 45, 90, 180, 270, 360}) {
		point := _polar(center, 5, degrees)
		radius := math.sqrt(
			(point.x - center.x) * (point.x - center.x) +
			(point.y - center.y) * (point.y - center.y),
		)
		testing.expectf(t, math.abs(radius - 5) < 1e-4, "radius at %v was %v", degrees, radius)
	}
}
