#+build !js
// ingot:gfx - tests for the shape primitives added for raylib parity.
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

	// Empty input is ordinary: raylib draws nothing and so does ingot. A nil
	// pointer with a *positive* count is a different thing - a programmer
	// error - and asserts rather than silently drawing nothing, so it is not
	// exercised here.
	points := [2]Vector2{{0, 0}, {1, 1}}
	DrawTriangleFan(nil, 0, WHITE)
	DrawTriangleStrip(nil, 0, WHITE)
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
gradient_quad_preserves_fractional_geometry :: proc(t: ^testing.T) {
	r := new_test_renderer()
	defer free(r)
	top := [4]f32{1, 0, 0, 1}
	bottom := [4]f32{0, 0, 1, 1}
	_emit_gradient_quad(r, {1.25, 2.5, 3.75, 4.5}, top, top, bottom, bottom)
	expect_point_near(t, r.verts[0].pos, {1.25, 2.5}, "tl")
	expect_point_near(t, r.verts[1].pos, {1.25, 7}, "bl")
	expect_point_near(t, r.verts[2].pos, {5, 2.5}, "tr")
	expect_point_near(t, r.verts[3].pos, {5, 7}, "br")
	testing.expect_value(t, r.verts[0].col, top)
	testing.expect_value(t, r.verts[3].col, bottom)
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

// --- tessellation bounds ---------------------------------------------------
// Every curved primitive derives a loop count from either a caller-supplied
// segment count or a radius, and both are unbounded at the call site. Without
// a cap a zoomed-in circle or a bad segment count turns one draw call into
// millions of GPU flushes and hangs the frame, so the cap is fenced here.

@(test)
shape_segments_clamps_into_the_bound :: proc(t: ^testing.T) {
	testing.expect_value(t, _shape_segments(1, 2), i32(2))
	testing.expect_value(t, _shape_segments(64, 2), i32(64))
	testing.expect_value(t, _shape_segments(SHAPE_SEGMENTS_MAX, 2), i32(SHAPE_SEGMENTS_MAX))
	testing.expect_value(t, _shape_segments(SHAPE_SEGMENTS_MAX + 1, 2), i32(SHAPE_SEGMENTS_MAX))
	testing.expect_value(t, _shape_segments(max(i32), 2), i32(SHAPE_SEGMENTS_MAX))
	// Negative counts must not underflow into a huge unsigned loop bound.
	testing.expect_value(t, _shape_segments(-1, 2), i32(2))
	testing.expect_value(t, _shape_segments(min(i32), 2), i32(2))
}

@(test)
shape_segments_for_radius_is_bounded :: proc(t: ^testing.T) {
	// Ordinary radii tessellate proportionally.
	testing.expect_value(t, _shape_segments_for_radius(4, 16), i32(16))
	testing.expect_value(t, _shape_segments_for_radius(64, 16), i32(64))
	// A camera zoomed far in produces a huge radius; the cap holds.
	testing.expect_value(t, _shape_segments_for_radius(1e6, 16), i32(SHAPE_SEGMENTS_MAX))
	testing.expect_value(t, _shape_segments_for_radius(1e30, 16), i32(SHAPE_SEGMENTS_MAX))
	testing.expect_value(t, _shape_segments_for_radius(max(f32), 16), i32(SHAPE_SEGMENTS_MAX))
	// Degenerate radii fall back to the minimum rather than a negative or
	// NaN-derived loop count.
	testing.expect_value(t, _shape_segments_for_radius(0, 16), i32(16))
	testing.expect_value(t, _shape_segments_for_radius(-1e9, 16), i32(16))
}

@(test)
shape_segments_for_radius_rejects_nan :: proc(t: ^testing.T) {
	// A NaN radius compares false against every bound. The guard is written
	// as !(radius > minimum) precisely so NaN falls through to the minimum
	// instead of reaching i32(NaN), which is undefined.
	nan := math.nan_f32()
	testing.expect_value(t, _shape_segments_for_radius(nan, 16), i32(16))
}

@(test)
shape_bounds_fit_the_batch :: proc(t: ^testing.T) {
	// The caps exist to keep a single primitive inside one batch. If the batch
	// ever shrinks below them the compile-time asserts in shapes.odin fire;
	// this states the same relationship at runtime for readers.
	testing.expect(t, SHAPE_SEGMENTS_MAX * 3 <= BATCH_MAX_VERTICES)
	testing.expect(t, SHAPE_POINTS_MAX * 3 <= BATCH_MAX_VERTICES + 2)
	testing.expect(t, SHAPE_SEGMENTS_MAX > 0)
	testing.expect(t, SHAPE_POINTS_MAX > 0)
}

// --- geometry finiteness ---------------------------------------------------
// The tessellation bound treats a non-finite radius as "minimum segments", so
// the loop count is safe, but the vertices it emits are still NaN. That renders
// nothing and logs nothing, so the primitives assert on it at entry.

@(test)
shape_geometry_predicate_rejects_non_finite :: proc(t: ^testing.T) {
	nan := math.nan_f32()
	inf := math.inf_f32(1)
	testing.expect(t, _shape_geometry_is_finite({0, 0}, 10))
	testing.expect(t, _shape_geometry_is_finite({-1e6, 1e6}, max(f32)))
	testing.expect(t, !_shape_geometry_is_finite({nan, 0}, 10))
	testing.expect(t, !_shape_geometry_is_finite({0, nan}, 10))
	testing.expect(t, !_shape_geometry_is_finite({0, 0}, nan))
	testing.expect(t, !_shape_geometry_is_finite({0, 0}, inf))
	testing.expect(t, !_shape_geometry_is_finite({inf, 0}, 10))
}

@(test)
non_finite_radius_bounds_segments_but_not_vertices :: proc(t: ^testing.T) {
	// Why the entry asserts exist rather than relying on the segment bound:
	// the count is already safe, and the geometry still is not.
	nan := math.nan_f32()
	testing.expect_value(t, _shape_segments_for_radius(nan, 16), i32(16))

	point := _polar({0, 0}, nan, 45)
	testing.expect(t, point.x != point.x, "polar of a NaN radius is NaN")

	elliptical := _polar_ellipse({0, 0}, nan, 10, 45)
	testing.expect(t, elliptical.x != elliptical.x, "polar_ellipse of a NaN radius is NaN")
}

@(test)
degenerate_but_finite_geometry_stays_legal :: proc(t: ^testing.T) {
	// The boundary the asserts must not false-positive on. A zero radius is
	// degenerate and renders nothing visible, but it is well defined and a
	// shrink animation passes through it.
	testing.expect(t, _shape_geometry_is_finite({0, 0}, 0))
	testing.expect(t, _shape_geometry_is_finite({0, 0}, -5))
	testing.expect(t, _shape_geometry_is_finite({0, 0}, max(f32)))

	// A zero radius collapses every tessellated point onto the centre, which
	// is well defined rather than corrupt, so _polar must stay finite there.
	for angle in ([]f32{0, 90, 180, 359.9}) {
		point := _polar({12, 34}, 0, angle)
		testing.expect_value(t, point, [2]f32{12, 34})
	}
}
