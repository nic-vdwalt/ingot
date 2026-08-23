#+build !js
// Contrast characterization for the built-in palettes.
//
// The goal is to make legibility a property CI can check rather than something
// a reviewer eyeballs. The method is to walk every semantic ink against every
// surface a widget may draw it on, and hold each pair to the bar that pair
// actually has to clear.
//
// Not every pair is a reading pair, and pretending otherwise would force the
// palettes to lie. Three exclusions are principled, not convenient:
//
//   - Ink.Disabled and Ink.Muted are deliberately low-contrast. WCAG 2.1
//     SC 1.4.3 exempts inactive components for exactly this reason: a disabled
//     control that reads as strongly as an enabled one is a worse defect than
//     a dim one. They are still floored, so "dim" cannot decay into "absent".
//   - Ink.Inverse is button_text: it is designed for accent *fills*, never for
//     a surface. On a light palette it is white-on-cream (1.0:1) by
//     construction. It is audited against the fills it is actually used on.
//   - Interaction backgrounds (hover, active, chip, table header) are momentary
//     and sit within a few percent of their base surface. Auditing them as
//     independent reading surfaces would triple the matrix to police a
//     difference no reader can resolve.
package ui

import "core:testing"

// Inks exempt from the reading bar. Kept as a named set so the coverage test
// can prove READING_INKS + DIM_INKS + Inverse is exactly the Ink enum.
DIM_INKS :: [?]Ink{.Disabled, .Muted}

builtin_themes :: proc() -> [6]Theme {
	return [6]Theme {
		THEME_DARK,
		THEME_LIGHT,
		THEME_HIGH_CONTRAST,
		theme_retro_orange(),
		theme_retro_ingot(),
		theme_terra(),
	}
}

// MIN_DIM_CONTRAST is the floor for intentionally-dim inks. WCAG sets no
// requirement for inactive components, but "no requirement" is not "invisible":
// 1.5:1 is roughly the point at which a glyph stops resolving as a shape at
// all. This catches a disabled color that has collapsed into its background
// without forcing disabled text to look enabled.
MIN_DIM_CONTRAST :: 1.5

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
	for th in builtin_themes() {
		style := th
		testing.expect(t, contrast_ratio(style.fg_primary, style.bg_color) >= MIN_TEXT_CONTRAST)
		testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
		testing.expect(t, style.focus_ring.a > 0)
	}
	// High contrast goes far beyond AA for primary text (AAA is 7:1).
	hc := Theme(THEME_HIGH_CONTRAST)
	testing.expect(t, contrast_ratio(hc.fg_primary, hc.bg_color) >= 7.0)
}

// ink_audit_covers_every_ink is the reason the two lists above can be trusted.
// Without it, adding an Ink and forgetting to classify it would silently shrink
// the audit rather than fail it.
@(test)
ink_audit_covers_every_ink :: proc(t: ^testing.T) {
	seen: [Ink]int
	for ink in READING_INKS do seen[ink] += 1
	for ink in DIM_INKS do seen[ink] += 1
	seen[.Inverse] += 1
	for count, ink in seen {
		testing.expectf(
			t,
			count == 1,
			"ink %v classified %d times; every Ink must be exactly one of READING_INKS, DIM_INKS, Inverse",
			ink,
			count,
		)
	}
}

// reading_inks_hold_measured_floor is a characterization test: it records what
// the palettes do *today* so later work cannot quietly erode them.
//
// It documents a real gap rather than hiding one. At the time of writing the
// weakest reading pairs are Label 3.82:1 (dark) and Success 3.62:1 (light) -
// both below the 4.5:1 normal-text bar, both above the 3.0:1 large-text bar.
// The floor is therefore set at large-text AA. Raising the dark and light
// palettes to full AA is a palette change with visible consequences, so it is
// deliberately not smuggled in under a test refactor.
@(test)
reading_inks_hold_measured_floor :: proc(t: ^testing.T) {
	for th in builtin_themes() {
		style := th
		surfaces := theme_reading_surfaces(&style)
		for ink in READING_INKS {
			color := theme_ink(&style, ink)
			for surface in surfaces {
				ratio := contrast_ratio(color, surface)
				testing.expectf(
					t,
					ratio >= MIN_TEXT_CONTRAST_LARGE,
					"ink %v on surface %v is %.2f:1, below the large-text floor %.1f:1",
					ink,
					surface,
					ratio,
					f64(MIN_TEXT_CONTRAST_LARGE),
				)
			}
		}
	}
}

// The high-contrast palette exists to be maximally legible, so it is held to
// full normal-text AA across the whole reading matrix rather than the
// large-text floor the other two currently sit on. It measures 6.63:1 at its
// weakest pair, so this is a real bar with real headroom, not a rubber stamp.
@(test)
high_contrast_reading_matrix_meets_aa :: proc(t: ^testing.T) {
	style := Theme(THEME_HIGH_CONTRAST)
	surfaces := theme_reading_surfaces(&style)
	for ink in READING_INKS {
		color := theme_ink(&style, ink)
		for surface in surfaces {
			ratio := contrast_ratio(color, surface)
			testing.expectf(
				t,
				ratio >= MIN_TEXT_CONTRAST,
				"high contrast: ink %v on surface %v is %.2f:1, below AA %.1f:1",
				ink,
				surface,
				ratio,
				f64(MIN_TEXT_CONTRAST),
			)
		}
	}
}

// Dim inks must stay dim but remain resolvable. This is the negative-space
// half of the audit: it fails a palette where disabled text has become
// invisible, and equally one where it has become indistinguishable from
// enabled text.
@(test)
dim_inks_stay_dim_but_visible :: proc(t: ^testing.T) {
	for th in builtin_themes() {
		style := th
		surfaces := theme_reading_surfaces(&style)
		primary := theme_ink(&style, .Primary)
		for ink in DIM_INKS {
			color := theme_ink(&style, ink)
			for surface in surfaces {
				ratio := contrast_ratio(color, surface)
				testing.expectf(
					t,
					ratio >= MIN_DIM_CONTRAST,
					"dim ink %v on surface %v is %.2f:1: collapsed into its background",
					ink,
					surface,
					ratio,
				)
				// A dim ink that out-contrasts Primary is no longer dim, and
				// the disabled affordance has been lost.
				testing.expectf(
					t,
					ratio <= contrast_ratio(primary, surface),
					"dim ink %v out-contrasts Primary on surface %v",
					ink,
					surface,
				)
			}
		}
	}
}

// Ink.Inverse is excluded from the surface matrix because it is a fill ink.
// It still has to be legible on the fills it is actually drawn on, which is
// what this covers - and it is the pair the existing button assert checks,
// extended to every accent fill in the palette.
@(test)
inverse_ink_is_legible_on_accent_fills :: proc(t: ^testing.T) {
	for th in builtin_themes() {
		style := th
		inverse := theme_ink(&style, .Inverse)
		fills := [?]Color{style.button_bg, style.button_hover, style.button_pressed}
		for fill in fills {
			ratio := contrast_ratio(inverse, fill)
			testing.expectf(
				t,
				ratio >= MIN_TEXT_CONTRAST_LARGE,
				"Inverse ink on accent fill %v is %.2f:1, below the large-text floor",
				fill,
				ratio,
			)
		}
	}
}
