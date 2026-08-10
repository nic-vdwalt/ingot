#+build !js
package ui

import "core:testing"


// point_in_rect_i32 is the layout-rect hit test every consumer reaches for.
// Its edge semantics decide whether two rects sharing a border both claim the
// shared pixel column, so they are pinned here rather than rediscovered.
@(test)
point_in_rect_i32_is_half_open_and_rejects_empty_rects :: proc(t: ^testing.T) {
	rect := Rect_I32{100, 50, 200, 80}
	testing.expect(t, point_in_rect_i32(Vec2{150, 90}, rect), "interior point")

	// Half-open: the left and top edges belong to the rect, the right and
	// bottom edges belong to whatever sits beside and below it. Two abutting
	// panels therefore never both own the shared row or column.
	testing.expect(t, point_in_rect_i32(Vec2{100, 50}, rect), "left/top corner is inside")
	testing.expect(t, point_in_rect_i32(Vec2{100, 129}, rect), "left edge is inside")
	testing.expect(t, !point_in_rect_i32(Vec2{300, 90}, rect), "right edge is outside")
	testing.expect(t, !point_in_rect_i32(Vec2{150, 130}, rect), "bottom edge is outside")
	testing.expect(t, !point_in_rect_i32(Vec2{99, 90}, rect), "left of the rect")
	testing.expect(t, !point_in_rect_i32(Vec2{150, 49}, rect), "above the rect")

	// Empty and negative rects contain nothing, so a caller with no overlay
	// passes a zero rect rather than branching around the test.
	testing.expect(t, !point_in_rect_i32(Vec2{0, 0}, Rect_I32{}), "zero rect is empty")
	testing.expect(t, !point_in_rect_i32(Vec2{10, 10}, Rect_I32{0, 0, 0, 600}), "zero width")
	testing.expect(t, !point_in_rect_i32(Vec2{10, 10}, Rect_I32{0, 0, 360, 0}), "zero height")
	testing.expect(t, !point_in_rect_i32(Vec2{10, 10}, Rect_I32{0, 0, -5, -5}), "negative rect")
}
