// ingot:gfx — raylib-named color constants (subset apps reference, e.g. WHITE)
// and the pure color helpers that go with them.
package gfx

LIGHTGRAY :: Color{200, 200, 200, 255}
GRAY :: Color{130, 130, 130, 255}
DARKGRAY :: Color{80, 80, 80, 255}
YELLOW :: Color{253, 249, 0, 255}
GOLD :: Color{255, 203, 0, 255}
ORANGE :: Color{255, 161, 0, 255}
PINK :: Color{255, 109, 194, 255}
RED :: Color{230, 41, 55, 255}
MAROON :: Color{190, 33, 55, 255}
GREEN :: Color{0, 228, 48, 255}
LIME :: Color{0, 158, 47, 255}
DARKGREEN :: Color{0, 117, 44, 255}
SKYBLUE :: Color{102, 191, 255, 255}
BLUE :: Color{0, 121, 241, 255}
DARKBLUE :: Color{0, 82, 172, 255}
PURPLE :: Color{200, 122, 255, 255}
VIOLET :: Color{135, 60, 190, 255}
DARKPURPLE :: Color{112, 31, 126, 255}
BEIGE :: Color{211, 176, 131, 255}
BROWN :: Color{127, 106, 79, 255}
DARKBROWN :: Color{76, 63, 47, 255}
WHITE :: Color{255, 255, 255, 255}
BLACK :: Color{0, 0, 0, 255}
BLANK :: Color{0, 0, 0, 0}
MAGENTA :: Color{255, 0, 255, 255}
RAYWHITE :: Color{245, 245, 245, 255}

// --- color helpers ---------------------------------------------------------

// ColorAlpha replaces a color's alpha, with `alpha` in 0..1.
ColorAlpha :: proc(color: Color, alpha: f32) -> Color {
	result := color
	result.a = u8(255.0 * clamp(alpha, 0, 1))
	return result
}

// Fade is raylib's older name for ColorAlpha and behaves identically.
Fade :: proc(color: Color, alpha: f32) -> Color {
	return ColorAlpha(color, alpha)
}

// ColorAlphaBlend composites `src` over `dst` after modulating `src` by `tint`,
// reproducing raylib's integer blend so ported code gets the same bytes.
//
// The arithmetic is deliberately raylib's: 8-bit fixed point with an alpha
// biased by one, not a float blend. Matching it matters because callers use
// this to precompute colors that must agree with what raylib produced.
ColorAlphaBlend :: proc(dst, src, tint: Color) -> Color {
	tinted := Color {
		u8((u32(src.r) * u32(tint.r)) >> 8),
		u8((u32(src.g) * u32(tint.g)) >> 8),
		u8((u32(src.b) * u32(tint.b)) >> 8),
		u8((u32(src.a) * u32(tint.a)) >> 8),
	}
	if tinted.a == 0 do return dst
	if tinted.a == 255 do return tinted

	alpha := u32(tinted.a) + 1
	out: Color
	out.a = u8((alpha * 256 + u32(dst.a) * (256 - alpha)) >> 8)
	if out.a == 0 do return out
	out.r = u8(((u32(tinted.r) * alpha * 256 + u32(dst.r) * u32(dst.a) * (256 - alpha)) / u32(out.a)) >> 8)
	out.g = u8(((u32(tinted.g) * alpha * 256 + u32(dst.g) * u32(dst.a) * (256 - alpha)) / u32(out.a)) >> 8)
	out.b = u8(((u32(tinted.b) * alpha * 256 + u32(dst.b) * u32(dst.a) * (256 - alpha)) / u32(out.a)) >> 8)
	return out
}
