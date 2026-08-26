#+build !js
package gfx

import "core:testing"

@(test)
texture_format_byte_sizes_are_explicit :: proc(t: ^testing.T) {
	testing.expect_value(t, texture_format_bytes(.UNCOMPRESSED_GRAYSCALE), 1)
	testing.expect_value(t, texture_format_bytes(.UNCOMPRESSED_GRAY_ALPHA), 2)
	testing.expect_value(t, texture_format_bytes(.UNCOMPRESSED_R8G8B8), 3)
	testing.expect_value(t, texture_format_bytes(.UNCOMPRESSED_R8G8B8A8), 4)
	testing.expect_value(t, texture_format_bytes(.UNKNOWN), 0)
}

@(test)
texture_conversion_preserves_rgba_alpha :: proc(t: ^testing.T) {
	source := [8]u8{10, 20, 30, 40, 50, 60, 70, 80}
	output: [8]u8
	testing.expect(t, _to_rgba_into(output[:], raw_data(source[:]), 2, 1, .UNCOMPRESSED_R8G8B8A8))
	testing.expect_value(t, output, source)
}

@(test)
texture_conversion_handles_gray_alpha :: proc(t: ^testing.T) {
	source := [4]u8{20, 30, 40, 50}
	output: [8]u8
	testing.expect(
		t,
		_to_rgba_into(output[:], raw_data(source[:]), 2, 1, .UNCOMPRESSED_GRAY_ALPHA),
	)
	testing.expect_value(t, output, [8]u8{20, 20, 20, 30, 40, 40, 40, 50})
}

@(test)
image_decode_dimensions_are_bounded :: proc(t: ^testing.T) {
	testing.expect(t, image_decode_dimensions_valid(1, 1))
	testing.expect(t, image_decode_dimensions_valid(IMAGE_DECODE_DIMENSION_MAX, 1))
	testing.expect(t, !image_decode_dimensions_valid(0, 1))
	testing.expect(t, !image_decode_dimensions_valid(-1, 1))
	testing.expect(t, !image_decode_dimensions_valid(IMAGE_DECODE_DIMENSION_MAX + 1, 1))
	testing.expect(t, !image_decode_dimensions_valid(8192, 8192))
}

@(test)
image_decode_rejects_empty_and_malformed_input :: proc(t: ^testing.T) {
	malformed := [8]u8{1, 2, 3, 4, 5, 6, 7, 8}
	testing.expect_value(t, LoadImageFromMemory(".png", raw_data(malformed[:]), 0), Image{})
	testing.expect_value(
		t,
		LoadImageFromMemory(".png", raw_data(malformed[:]), i32(len(malformed))),
		Image{},
	)
}
