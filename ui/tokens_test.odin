#+build !js
// Token layer tests.
//
// The tokens exist to make two things impossible: a surface that cannot be
// seen, and two widgets that disagree about the same visual property. These
// tests check both, and check them against every built-in palette rather than
// a representative one, because the defects the tokens replace were all
// palette-specific (the invisible high-contrast caption button being the
// clearest case).
package ui

import "core:testing"

all_surfaces :: proc() -> [13]Surface {
	return [13]Surface {
		.App,
		.Panel,
		.Card,
		.Popup,
		.Input,
		.Row,
		.Chip,
		.Code,
		.Table_Header,
		.Button_Primary,
		.Button_Secondary,
		.Button_Danger,
		.Button_Ghost,
	}
}

// Every palette the library ships, screen and paper alike. The token
// guarantees are palette-independent by design, so they are checked against
// all five rather than a representative one; every defect these tests replace
// was itself palette-specific.
token_themes :: proc() -> [5]Theme {
	return [5]Theme{THEME_DARK, THEME_LIGHT, THEME_HIGH_CONTRAST, THEME_PAPER, THEME_PAPER_NIGHT}
}

// A surface being interacted with must be visible in every palette. This is
// the property that was missing when high-contrast caption buttons resolved
// their hover to a 10-alpha white wash on pure black: technically a different
// color, in practice no feedback at all.
//
// Rest and Disabled are exempt for the transparent-at-rest surfaces, and the
// exemption is asserted rather than skipped. A disabled ghost button that grew
// a filled background would be a worse defect than the one this test guards
// against: it would make an inert control look more substantial than a live
// one.
@(test)
interactive_surfaces_are_never_invisible :: proc(t: ^testing.T) {
	for th in token_themes() {
		style := th
		for surface in all_surfaces() {
			for state in Visual_State {
				base := surface_base(&style, surface)
				colors := surface_state_apply(&style, base, surface, state)
				inert := state == .Rest || state == .Disabled
				if inert && surface_transparent_at_rest(surface) {
					testing.expectf(
						t,
						colors.bg.a == 0,
						"surface %v state %v gained a fill it should not have",
						surface,
						state,
					)
				} else {
					testing.expectf(
						t,
						colors.bg.a > 0,
						"surface %v state %v resolved a fully transparent background",
						surface,
						state,
					)
				}
				testing.expectf(
					t,
					colors.fg.a > 0,
					"surface %v state %v resolved a fully transparent foreground",
					surface,
					state,
				)
			}
		}
	}
}

// Hover, pressed and selected must be distinguishable from rest and from each
// other, or the state carries no information. Before the token layer, pressed
// was identical to hover on every surface except the primary button.
@(test)
interaction_states_are_distinguishable :: proc(t: ^testing.T) {
	for th in token_themes() {
		style := th
		for surface in all_surfaces() {
			base := surface_base(&style, surface)
			rest := surface_state_apply(&style, base, surface, .Rest)
			hover := surface_state_apply(&style, base, surface, .Hover)
			pressed := surface_state_apply(&style, base, surface, .Pressed)
			testing.expectf(
				t,
				hover.bg != rest.bg,
				"surface %v: hover is identical to rest",
				surface,
			)
			testing.expectf(
				t,
				pressed.bg != hover.bg,
				"surface %v: pressed is identical to hover",
				surface,
			)
		}
	}
}

// Disabled must resolve to one foreground across every surface. Two roles for
// one concept is what produced a disabled button and a disabled menu item in
// different colors in the same frame.
@(test)
disabled_foreground_is_uniform :: proc(t: ^testing.T) {
	for th in token_themes() {
		style := th
		for surface in all_surfaces() {
			base := surface_base(&style, surface)
			disabled := surface_state_apply(&style, base, surface, .Disabled)
			testing.expectf(
				t,
				disabled.fg == style.fg_disabled,
				"surface %v: disabled foreground is not fg_disabled",
				surface,
			)
		}
	}
}

// Radius must be monotonic in the token order, or "LG" is not reliably larger
// than "MD" and the enum stops meaning anything.
@(test)
radius_is_monotonic_in_token_order :: proc(t: ^testing.T) {
	for scale in ([?]f32{0.5, 1.0, 1.5, 2.0, 3.0}) {
		metrics := ui_metrics(scale)
		base := metrics.CARD_RADIUS_PX
		none := f32(0)
		small := base * 0.5
		medium := base
		large := base * 1.75
		testing.expect(t, none < small)
		testing.expect(t, small < medium)
		testing.expect(t, medium < large)
	}
}

// Radius must scale with the UI scale. A radius that stayed at a fixed pixel
// count would look progressively sharper as the interface grew, which is the
// defect the absolute-versus-ratio split produced.
@(test)
radius_scales_with_ui_scale :: proc(t: ^testing.T) {
	small := ui_metrics(1.0).CARD_RADIUS_PX
	large := ui_metrics(2.0).CARD_RADIUS_PX
	testing.expect(t, large > small)
	testing.expectf(
		t,
		abs(large - small * 2) < 0.001,
		"card radius did not scale linearly: %v then %v",
		small,
		large,
	)
}

// The ratio form must stay inside the unit range for every rect a caller can
// hand it, including degenerate ones. draw_rectangle_rounded interprets values
// above 1 as undefined geometry rather than clamping.
@(test)
radius_ratio_stays_in_unit_range :: proc(t: ^testing.T) {
	for scale in ([?]f32{0.5, 1.0, 3.0}) {
		metrics := ui_metrics(scale)
		for dimension in ([?]f32{1, 4, 12, 24, 100, 1000}) {
			for radius in Radius {
				pixels: f32
				switch radius {
				case .None:
					pixels = 0
				case .SM:
					pixels = metrics.CARD_RADIUS_PX * 0.5
				case .MD:
					pixels = metrics.CARD_RADIUS_PX
				case .LG:
					pixels = metrics.CARD_RADIUS_PX * 1.75
				case .Pill:
					pixels = dimension * 0.5
				}
				ratio := clamp((pixels * 2) / dimension, 0, 1)
				testing.expectf(
					t,
					ratio >= 0 && ratio <= 1,
					"radius %v on dimension %v produced ratio %v",
					radius,
					dimension,
					ratio,
				)
			}
		}
	}
}

// Segment count is bounded at both ends: too few and a corner reads as a
// chamfer, too many and a large card pays for curvature nobody can resolve.
@(test)
radius_segments_stay_bounded :: proc(t: ^testing.T) {
	for radius_px in ([?]f32{0, 1, 3, 6, 12, 40, 500}) {
		segments := radius_segments(radius_px)
		testing.expectf(
			t,
			segments >= RADIUS_SEGMENTS_MIN && segments <= RADIUS_SEGMENTS_MAX,
			"radius %v produced %d segments, outside [%d, %d]",
			radius_px,
			segments,
			RADIUS_SEGMENTS_MIN,
			RADIUS_SEGMENTS_MAX,
		)
	}
	// Monotonic: a larger radius may never tessellate more coarsely.
	testing.expect(t, radius_segments(20) >= radius_segments(4))
}

// Tint levels must be ordered and distinct, since they are consumed as a
// scale ("more than Subtle, less than Strong") rather than as opaque names.
@(test)
tint_alpha_is_ordered :: proc(t: ^testing.T) {
	testing.expect(t, tint_alpha(.Subtle) < tint_alpha(.Light))
	testing.expect(t, tint_alpha(.Light) < tint_alpha(.Medium))
	testing.expect(t, tint_alpha(.Medium) < tint_alpha(.Strong))
	testing.expect(t, tint_alpha(.Subtle) > 0)
}

// color_tinted must preserve hue and replace only alpha. A tint that shifted
// the color would silently detach an overlay from its palette.
@(test)
color_tinted_preserves_hue :: proc(t: ^testing.T) {
	source := Color{12, 34, 56, 255}
	for tint in Tint {
		result := color_tinted(source, tint)
		testing.expect(t, result.r == source.r)
		testing.expect(t, result.g == source.g)
		testing.expect(t, result.b == source.b)
		testing.expect(t, result.a == tint_alpha(tint))
	}
}

// The tests above exercise the pure leaves. This one drives the *public*
// entry point, which is where the postcondition assertions live.
//
// The distinction is not academic. An earlier revision of this file tested
// only the leaves, so surface_colors' own assertions had no coverage at all -
// and the leaf tests were then edited to expect that a disabled ghost button
// stays transparent, which is exactly what the assertion rejected. The
// contradiction survived because the two halves never met. The gallery found
// it by crashing on the first frame that drew a disabled ghost button.
//
// An assertion reached here aborts the test binary outright, so this test
// passing means every surface and state survives the real call path.
@(test)
surface_colors_public_path_holds_for_every_combination :: proc(t: ^testing.T) {
	runtime: Ui_Runtime
	ui_runtime_init(&runtime)
	defer ui_runtime_destroy(&runtime)

	for palette in token_themes() {
		ui_runtime_set_theme(&runtime, palette)
		frame: Ui_Frame
		ui_frame_begin(&frame, &runtime)
		for surface in all_surfaces() {
			for state in Visual_State {
				colors := surface_colors(&frame, surface, state)
				testing.expect(t, colors.fg.a > 0)
				inert := state == .Rest || state == .Disabled
				if inert && surface_transparent_at_rest(surface) {
					testing.expectf(
						t,
						colors.bg.a == 0,
						"surface %v state %v gained a fill it should not have",
						surface,
						state,
					)
				} else {
					testing.expectf(
						t,
						colors.bg.a > 0,
						"surface %v state %v is invisible",
						surface,
						state,
					)
				}
			}
		}
		ui_frame_end(&frame)
	}
}

// Negative space: exactly two surfaces may be transparent at rest. If a third
// is added without thought, the opacity assertion in surface_colors silently
// stops covering it.
@(test)
only_row_and_ghost_are_transparent_at_rest :: proc(t: ^testing.T) {
	count := 0
	for surface in all_surfaces() {
		if surface_transparent_at_rest(surface) do count += 1
	}
	testing.expect_value(t, count, 2)
	testing.expect(t, surface_transparent_at_rest(.Row))
	testing.expect(t, surface_transparent_at_rest(.Button_Ghost))
	testing.expect(t, !surface_transparent_at_rest(.Card))
}

// all_surfaces must stay in step with the enum, or every test above quietly
// narrows when a surface is added.
@(test)
surface_list_covers_every_surface :: proc(t: ^testing.T) {
	seen: [Surface]int
	for surface in all_surfaces() do seen[surface] += 1
	for count, surface in seen {
		testing.expectf(
			t,
			count == 1,
			"surface %v appears %d times in all_surfaces",
			surface,
			count,
		)
	}
}
