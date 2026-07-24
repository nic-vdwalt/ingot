#+build !js
package ui

import "core:testing"


@(test)
contrast_ratio_known_values :: proc(t: ^testing.T) {
	black := Color{0, 0, 0, 255}
	white := Color{255, 255, 255, 255}
	// Black on white is the WCAG maximum, 21:1; identical colors are 1:1.
	testing.expect(t, abs(contrast_ratio(black, white) - 21.0) < 0.01)
	testing.expect(t, abs(contrast_ratio(white, white) - 1.0) < 0.001)
	// Symmetry: argument order must not matter.
	grey := Color{119, 119, 119, 255}
	testing.expect_value(t, contrast_ratio(grey, white), contrast_ratio(white, grey))
	// #777777 on white is a classic near-AA-threshold pair (~4.48:1).
	r := contrast_ratio(grey, white)
	testing.expect(t, r > 4.4 && r < 4.6)
}

@(test)
builtin_themes_meet_wcag_aa :: proc(t: ^testing.T) {
	// The set_theme asserts enforce these at runtime; the test locks them in
	// CI so palette tuning can't silently regress readability.
	themes := [3]Theme{THEME_DARK, THEME_LIGHT, THEME_HIGH_CONTRAST}
	for th in themes {
		testing.expect(t, contrast_ratio(th.fg_primary, th.bg_color) >= MIN_TEXT_CONTRAST)
		testing.expect(t, contrast_ratio(th.button_text, th.button_bg) >= MIN_TEXT_CONTRAST)
		testing.expect(t, th.focus_ring.a > 0)
	}
	// High contrast goes far beyond AA for primary text (AAA is 7:1).
	hc := Theme(THEME_HIGH_CONTRAST)
	testing.expect(t, contrast_ratio(hc.fg_primary, hc.bg_color) >= 7.0)
}
