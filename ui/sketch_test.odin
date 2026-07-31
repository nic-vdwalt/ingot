#+build !js
// Sketchbook palette tests.
//
// The sketch palettes are held to a stricter bar than the screen palettes that
// preceded them. THEME_DARK and THEME_LIGHT sit at the 3.0:1 large-text floor
// on their weakest reading pairs - a debt recorded in contrast_test.odin
// rather than repaid here. The sketch palettes have no installed base, so they
// are held to full 4.5:1 AA from the start.
//
// That bar is the whole reason this file exists. Toned stock is the hard case
// for contrast: it is neither white nor dark, so it squeezes from both
// directions, and a saturated pigment laid on it can look right while being
// entirely unreadable. Vermilion at its true hue measures 2.4:1 on kraft.
// Every value in sketch.odin was computed against every surface before it was
// written down, and these tests are what stop that discipline decaying.
package ui

import "core:testing"

sketch_themes :: proc() -> [2]Theme {
	return [2]Theme{THEME_SKETCH_WARM, THEME_SKETCH_GREY}
}

// Full AA across every reading ink and every surface. This is the property the
// screen palettes do not have, so it is asserted directly rather than through
// the shared floor.
@(test)
sketch_themes_meet_full_aa :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		surfaces := theme_reading_surfaces(&style)
		for ink in READING_INKS {
			color := theme_ink(&style, ink)
			for surface in surfaces {
				ratio := contrast_ratio(color, surface)
				testing.expectf(
					t,
					ratio >= MIN_TEXT_CONTRAST,
					"sketch: ink %v on surface %v is %.2f:1, below AA %.1f:1",
					ink,
					surface,
					ratio,
					f64(MIN_TEXT_CONTRAST),
				)
			}
		}
	}
}

// The palettes have to survive their own constructor: set_theme asserts these
// pairs at runtime, so a palette failing them would crash on application
// rather than merely look wrong.
@(test)
sketch_themes_satisfy_set_theme_contract :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		testing.expect(t, style.fg_primary.a != 0)
		testing.expect(t, style.bg_color.a != 0)
		testing.expect(t, contrast_ratio(style.fg_primary, style.bg_color) >= MIN_TEXT_CONTRAST)
		testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
		testing.expect(t, style.focus_ring.a > 0)
	}
}

// Toned paper is opaque. Translucent surfaces exist so the macOS vibrancy
// layer can show through, which is right for frosted glass and wrong here: a
// blurred desktop behind kraft turns it to mud.
@(test)
sketch_surfaces_are_opaque :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		opaque := [?]Color {
			style.bg_app_windowed,
			style.bg_chat_windowed,
			style.bg_panel_windowed,
			style.bg_app_fullscreen,
			style.bg_chat_fullscreen,
			style.bg_panel_fullscreen,
		}
		for color in opaque {
			testing.expectf(t, color.a == 255, "sketch surface %v is translucent", color)
		}
		testing.expect(t, style.bg_app_windowed == style.bg_app_fullscreen)
	}
}

// A sketch ground must read as its own stock, not as a screen palette shifted
// a little.
//
// The bar this replaces was ">1.15:1 against white", which a ground measuring
// 1.32:1 passed while looking like the light theme dimmed by a third. Distance
// from white is the wrong measurement: a user never compares the ground to
// white, they compare it to the other palettes in the cycle. Measured that way,
// 1.8:1 is about where "light theme, slightly darker" stops and "toned paper"
// begins.
SKETCH_GROUND_SEPARATION_MIN :: 1.8

// Toned stock is mid-value by definition: dark enough that white chalk reads
// against it, light enough that graphite still does. That two-way working is
// the entire reason toned paper exists, and it is only available in this
// window.
//
// The floor replaces a bare `relative_luminance(bg) > 0.35` that carried no
// message and no derivation. It was not a property of toned paper - it was the
// luminance of the grounds that happened to be committed at the time, frozen
// into an assertion, and it rejected every genuinely toned value.
SKETCH_GROUND_LUMINANCE_MIN :: 0.20
SKETCH_GROUND_LUMINANCE_MAX :: 0.55

// The ground must be visibly distinct from both screen palettes.
//
// Checking both directions matters: a ground can be far from white and still
// be indistinguishable from the dark theme, and a "sketch" palette that
// collapses onto either one is not a third choice, it is a duplicate.
@(test)
sketch_ground_is_toned :: proc(t: ^testing.T) {
	light := Theme(THEME_LIGHT)
	dark := Theme(THEME_DARK)
	for th in sketch_themes() {
		style := th
		from_light := contrast_ratio(style.bg_color, light.bg_color)
		testing.expectf(
			t,
			from_light >= SKETCH_GROUND_SEPARATION_MIN,
			"sketch ground %v is %.2f:1 from the light theme, below %.1f:1: reads as light mode dimmed",
			style.bg_color,
			from_light,
			f64(SKETCH_GROUND_SEPARATION_MIN),
		)
		from_dark := contrast_ratio(style.bg_color, dark.bg_color)
		testing.expectf(
			t,
			from_dark >= SKETCH_GROUND_SEPARATION_MIN,
			"sketch ground %v is %.2f:1 from the dark theme, below %.1f:1: reads as dark mode lifted",
			style.bg_color,
			from_dark,
			f64(SKETCH_GROUND_SEPARATION_MIN),
		)

		luminance := relative_luminance(style.bg_color)
		testing.expectf(
			t,
			luminance >= SKETCH_GROUND_LUMINANCE_MIN,
			"sketch ground %v has luminance %.3f, below %.2f: too dark for graphite to read",
			style.bg_color,
			luminance,
			f64(SKETCH_GROUND_LUMINANCE_MIN),
		)
		testing.expectf(
			t,
			luminance <= SKETCH_GROUND_LUMINANCE_MAX,
			"sketch ground %v has luminance %.3f, above %.2f: too pale for chalk to read",
			style.bg_color,
			luminance,
			f64(SKETCH_GROUND_LUMINANCE_MAX),
		)
	}
}

// No rules, and no margin line. This is the property that separates the
// sketchbook from the notebook: a ruled sketch page is an exercise book.
@(test)
sketch_themes_have_no_rules_or_margin :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		testing.expect(t, style.paper_rule.a == 0)
		testing.expect(t, !style.substrate.margin_rule)
		// The tooth substrate replaces them, and must actually be requested or
		// the page is just a flat fill.
		testing.expect(t, style.substrate.kind == .Tooth)
		testing.expect(t, style.paper_tooth.a > 0)
		testing.expect(t, style.graphite.a > 0)
	}
}

// The tooth must read as texture, not as dirt. Flecks far darker than the
// ground look like a damaged surface; the point is grain you feel rather than
// marks you notice.
@(test)
sketch_tooth_is_subtle :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		opaque_fleck := Color{style.paper_tooth.r, style.paper_tooth.g, style.paper_tooth.b, 255}
		ratio := contrast_ratio(opaque_fleck, style.bg_color)
		testing.expectf(
			t,
			ratio < 2.5,
			"paper tooth is %.2f:1 against the ground: reads as dirt rather than grain",
			ratio,
		)
		testing.expect(t, style.paper_tooth.a < 160)
	}
}

// The highlighter is the most visible part of the aesthetic and is unreadable
// as text, so it must never be an ink. Text drawn *on* it must still read,
// since that is the entire job of a selection fill.
@(test)
sketch_highlighter_is_a_fill_not_an_ink :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		testing.expect(t, style.highlighter.a > 0)
		for ink in READING_INKS {
			testing.expectf(
				t,
				theme_ink(&style, ink) != style.highlighter,
				"highlighter is being used as ink %v; it cannot carry text",
				ink,
			)
		}
		ratio := contrast_ratio(style.fg_primary, style.highlighter)
		testing.expectf(
			t,
			ratio >= MIN_TEXT_CONTRAST,
			"primary ink on highlighter is %.2f:1: selected text is unreadable",
			ratio,
		)
	}
}

// Paper is matte. The gloss gradient is a glass and plastic cue; left on, a
// pigment swatch looks like a recoloured screen button.
@(test)
sketch_has_no_gloss :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		testing.expect(t, style.button_primary_grad_top.a == 0)
		testing.expect(t, style.button_primary_grad_bottom.a == 0)
	}
}

// Negative space: the screen palettes must NOT draw paper. A stray tooth
// colour on the dark theme would scatter grain behind a UI that is not paper.
@(test)
screen_themes_have_no_paper_materials :: proc(t: ^testing.T) {
	for th in builtin_themes() {
		style := th
		testing.expect(t, style.substrate.kind == .None)
		testing.expect(t, !style.substrate.margin_rule)
		testing.expect(t, style.paper_rule.a == 0)
		testing.expect(t, style.paper_tooth.a == 0)
		testing.expect(t, style.highlighter.a == 0)
		testing.expect(t, style.tape_color.a == 0)
	}
}

// Every palette must give the caption buttons visible feedback. This is the
// defect that shipped in the high-contrast theme: hover and press were a
// 10-alpha white wash over pure black, so the buttons never appeared to
// respond. Checked across all five palettes, not only the sketch pair.
@(test)
caption_states_are_visible_in_every_palette :: proc(t: ^testing.T) {
	all := [?]Theme {
		THEME_DARK,
		THEME_LIGHT,
		THEME_HIGH_CONTRAST,
		THEME_SKETCH_WARM,
		THEME_SKETCH_GREY,
	}
	for th in all {
		style := th
		states := [?]Color {
			style.caption_hover,
			style.caption_pressed,
			style.caption_close_hover,
			style.caption_close_pressed,
		}
		for color in states {
			testing.expectf(t, color.a == 255, "caption state %v is not opaque", color)
			ratio := contrast_ratio(color, style.bg_app)
			testing.expectf(
				t,
				ratio >= 1.15,
				"caption state %v is %.2f:1 against the title bar: no visible feedback",
				color,
				ratio,
			)
		}
		testing.expect(t, style.caption_hover != style.caption_pressed)
		testing.expect(t, style.caption_close_hover != style.caption_close_pressed)
	}
}

// fg_on_accent must be legible on the accent fills it names, in every palette.
@(test)
on_accent_ink_reads_on_accent_fills :: proc(t: ^testing.T) {
	all := [?]Theme {
		THEME_DARK,
		THEME_LIGHT,
		THEME_HIGH_CONTRAST,
		THEME_SKETCH_WARM,
		THEME_SKETCH_GREY,
	}
	for th in all {
		style := th
		testing.expect(t, style.fg_on_accent.a > 0)
		ratio := contrast_ratio(style.fg_on_accent, style.button_bg)
		testing.expectf(
			t,
			ratio >= MIN_TEXT_CONTRAST,
			"fg_on_accent on button_bg is %.2f:1, below AA",
			ratio,
		)
	}
}

// SKETCH_GROUND_CHROMA_MIN is how much colour a ground must carry to be stock
// rather than a UI neutral.
//
// Chroma is max(r,g,b) - min(r,g,b): the plain distance from grey. A ground at
// chroma 6 is neutral by any measure, and neutral means the eye reads it as
// "interface grey, dimmed" no matter how the luminance is tuned. Real toned
// papers measure 60-80 for tan and kraft; even a "grey" toned sheet carries a
// blue or green cast rather than being dead neutral.
//
// 12 is the floor for a cast to be perceptible at all; the warm ground is held
// far higher by sketch_warm_ground_is_warm below.
SKETCH_GROUND_CHROMA_MIN :: 12

color_chroma :: proc(color: Color) -> int {
	high := max(int(color.r), max(int(color.g), int(color.b)))
	low := min(int(color.r), min(int(color.g), int(color.b)))
	return high - low
}

// Every ground carries a cast. A neutral ground is a UI grey, whatever its
// luminance.
@(test)
sketch_grounds_carry_a_cast :: proc(t: ^testing.T) {
	for th in sketch_themes() {
		style := th
		chroma := color_chroma(style.bg_color)
		testing.expectf(
			t,
			chroma >= SKETCH_GROUND_CHROMA_MIN,
			"sketch ground %v has chroma %d, below %d: it is a UI neutral, not toned stock",
			style.bg_color,
			chroma,
			SKETCH_GROUND_CHROMA_MIN,
		)
	}
}

// The warm ground has to be visibly warm, not faintly beige. Kraft and tan
// stock measure 60-80; below about 40 the cast stops reading as paper colour
// and starts reading as a slightly off-white screen.
@(test)
sketch_warm_ground_is_warm :: proc(t: ^testing.T) {
	WARM_CHROMA_MIN :: 40
	style := Theme(THEME_SKETCH_WARM)
	chroma := color_chroma(style.bg_color)
	testing.expectf(
		t,
		chroma >= WARM_CHROMA_MIN,
		"warm ground %v has chroma %d, below %d: not kraft, just off-white",
		style.bg_color,
		chroma,
		WARM_CHROMA_MIN,
	)
	// Warm means red-leaning: a "warm" ground whose blue channel led would be
	// cool no matter how much chroma it carried.
	testing.expect(t, style.bg_color.r > style.bg_color.b)
}

// The audit: the whole contrast matrix, printed on failure.
//
// This exists because the values in sketch.odin were derived in a throwaway
// script and nothing in the repository could reproduce them. Numbers that
// justify a design and live nowhere near it are how a palette gets retuned by
// guesswork later. On failure this prints every ground, ink and pigment ratio,
// so the next person to touch these values re-derives rather than re-guesses.
@(test)
sketch_palette_audit :: proc(t: ^testing.T) {
	for th, index in sketch_themes() {
		style := th
		surfaces := theme_reading_surfaces(&style)
		worst := f64(21)
		worst_ink := Ink.Primary
		for ink in READING_INKS {
			color := theme_ink(&style, ink)
			for surface in surfaces {
				ratio := contrast_ratio(color, surface)
				if ratio < worst {
					worst = ratio
					worst_ink = ink
				}
			}
		}
		// The audit is a measurement, not a second AA gate - that is
		// sketch_themes_meet_full_aa's job. It fails only when the margin has
		// become so thin that the palette is one rounding away from illegible.
		testing.expectf(
			t,
			worst >= MIN_TEXT_CONTRAST,
			"palette %d: worst reading pair is ink %v at %.2f:1 (ground %v, luminance %.3f, chroma %d)",
			index,
			worst_ink,
			worst,
			style.bg_color,
			relative_luminance(style.bg_color),
			color_chroma(style.bg_color),
		)
	}
}
