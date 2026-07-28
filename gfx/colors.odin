// ingot:gfx - raylib-named color constants (subset apps reference, e.g. WHITE)
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
// biased by one, and a tint modulation that divides by 256 rather than 255, so
// even a WHITE tint costs one unit per channel. Matching it matters because
// callers use this to precompute colors that must agree with what raylib
// produced.
ColorAlphaBlend :: proc(dst, src, tint: Color) -> Color {
	tinted: Color
	for channel in 0 ..< 4 {
		tinted[channel] = u8((u32(src[channel]) * u32(tint[channel])) >> 8)
	}
	if tinted[3] == 0 do return dst
	if tinted[3] == 255 do return tinted

	alpha := u32(tinted[3]) + 1
	inverse := 256 - alpha
	// alpha is biased by one so the 8-bit reciprocal is exact, and inverse is
	// its complement. Both staying inside 1..=256 is what keeps the numerator
	// below from overflowing u32.
	assert(alpha >= 1 && alpha <= 256, "ColorAlphaBlend: alpha outside fixed-point range")
	assert(alpha + inverse == 256, "ColorAlphaBlend: alpha and inverse must complement")

	out: Color
	out[3] = u8((alpha * 256 + u32(dst[3]) * inverse) >> 8)
	// Guard the divisor rather than assert it: a fully transparent result is
	// reachable from ordinary inputs, not a programmer error.
	if out[3] == 0 do return out
	for channel in 0 ..< 3 {
		blended := u32(tinted[channel]) * alpha * 256 + u32(dst[channel]) * u32(dst[3]) * inverse
		out[channel] = u8((blended / u32(out[3])) >> 8)
	}
	return out
}
