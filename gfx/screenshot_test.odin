#+build !js
// Screenshot readback transforms. The GPU half of screenshot.odin needs a
// device; these two pure steps carry the contract that actually decides whether
// a captured PNG is correct — row alignment, row order, and channel order — so
// they are fenced here and run windowless under scripts/test.sh.
package gfx

import "core:testing"

@(test)
test_screenshot_padded_bpr_alignment :: proc(t: ^testing.T) {
	// WebGPU requires a 256-byte multiple for buffer copy rows. An already
	// aligned width must not grow (a wasted row would shift every pixel).
	testing.expect_value(t, _screenshot_padded_bpr(64), 256)
	testing.expect_value(t, _screenshot_padded_bpr(1600), 6400)
	testing.expect_value(t, _screenshot_padded_bpr(65), 512)
	testing.expect_value(t, _screenshot_padded_bpr(1), 256)
	testing.expect_value(t, _screenshot_padded_bpr(0), 0)
	for width in 1 ..= 300 {
		padded := _screenshot_padded_bpr(width)
		testing.expect(t, padded >= width * 4)
		testing.expect_value(t, padded % SCREENSHOT_ROW_ALIGNMENT, 0)
	}
}

@(test)
test_screenshot_unpad_flip_reverses_rows :: proc(t: ^testing.T) {
	// Two 2-pixel rows in a padded 16-byte stride. Render targets store
	// bottom-left origin (RT_PROJECTION_Y_FLIP), PNG rows are top-down, so
	// the last source row must land first.
	width, height, padded := 2, 2, 16
	src := make([]u8, padded * height)
	defer delete(src)
	for i in 0 ..< 8 do src[i] = u8(i) // row 0 (bottom)
	for i in 0 ..< 8 do src[padded + i] = u8(100 + i) // row 1 (top)
	for i in 8 ..< padded do src[i] = 0xEE // padding must never be copied
	for i in 8 ..< padded do src[padded + i] = 0xEE

	dst := make([]u8, width * height * 4)
	defer delete(dst)
	testing.expect(t, _screenshot_unpad_flip(src, dst, width, height, padded))
	for i in 0 ..< 8 do testing.expect_value(t, dst[i], u8(100 + i))
	for i in 0 ..< 8 do testing.expect_value(t, dst[8 + i], u8(i))
}

@(test)
test_screenshot_unpad_flip_rejects_bad_extents :: proc(t: ^testing.T) {
	// Degenerate or inconsistent geometry must fail rather than write a
	// partially filled buffer that would encode as a torn image.
	src := make([]u8, 256 * 4)
	defer delete(src)
	dst := make([]u8, 4 * 4 * 4)
	defer delete(dst)
	testing.expect(t, !_screenshot_unpad_flip(src, dst, 0, 4, 256))
	testing.expect(t, !_screenshot_unpad_flip(src, dst, 4, 0, 256))
	testing.expect(t, !_screenshot_unpad_flip(src, dst, 4, 4, 8)) // stride < row
	testing.expect(t, !_screenshot_unpad_flip(src, dst[:4], 4, 4, 256)) // short dst
	testing.expect(t, !_screenshot_unpad_flip(src[:16], dst, 4, 4, 256)) // short src
}

@(test)
test_screenshot_bgra_swizzle_round_trips :: proc(t: ^testing.T) {
	// Metal and D3D12 present BGRA; PNG is RGBA. The swap is its own inverse,
	// so applying it twice proves no channel is lost or duplicated.
	original := [?]u8{1, 2, 3, 4, 250, 251, 252, 253}
	pixels := make([]u8, len(original))
	defer delete(pixels)
	copy(pixels, original[:])

	testing.expect(t, _screenshot_bgra_to_rgba(pixels))
	testing.expect_value(t, pixels[0], u8(3))
	testing.expect_value(t, pixels[1], u8(2))
	testing.expect_value(t, pixels[2], u8(1))
	testing.expect_value(t, pixels[3], u8(4)) // alpha untouched

	testing.expect(t, _screenshot_bgra_to_rgba(pixels))
	for i in 0 ..< len(original) do testing.expect_value(t, pixels[i], original[i])
}

@(test)
test_screenshot_bgra_rejects_partial_pixels :: proc(t: ^testing.T) {
	// A buffer that is not a whole number of pixels means the caller computed
	// the wrong size; swizzling it would corrupt the trailing bytes.
	partial := make([]u8, 6)
	defer delete(partial)
	testing.expect(t, !_screenshot_bgra_to_rgba(partial))
	testing.expect(t, !_screenshot_bgra_to_rgba(nil))
}

@(test)
test_screenshot_format_encodability :: proc(t: ^testing.T) {
	// Only the four 8-bit RGBA/BGRA forms encode truthfully. Anything else
	// (HDR render targets from the rlgl framebuffer path, depth) must be
	// refused rather than reinterpreted byte-wise into a PNG.
	needed, ok := _screenshot_swizzle_needed(.BGRA8Unorm)
	testing.expect(t, ok)
	testing.expect(t, needed)
	needed, ok = _screenshot_swizzle_needed(.BGRA8UnormSrgb)
	testing.expect(t, ok)
	testing.expect(t, needed)
	needed, ok = _screenshot_swizzle_needed(.RGBA8Unorm)
	testing.expect(t, ok)
	testing.expect(t, !needed)
	needed, ok = _screenshot_swizzle_needed(.RGBA8UnormSrgb)
	testing.expect(t, ok)
	testing.expect(t, !needed)

	_, ok = _screenshot_swizzle_needed(.RGBA16Float)
	testing.expect(t, !ok)
	_, ok = _screenshot_swizzle_needed(.Depth24Plus)
	testing.expect(t, !ok)
	_, ok = _screenshot_swizzle_needed(.R32Float)
	testing.expect(t, !ok)
}
