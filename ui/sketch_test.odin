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

// The ground must actually be toned. A sketch palette whose paper drifted to
// white would be a light theme with pigment accents, which is not the point:
// these pigments are chosen to sit on a mid ground and look weak on white.
@(test)
sketch_ground_is_toned :: proc(t: ^testing.T) {
	white := Color{255, 255, 255, 255}
	for th in sketch_themes() {
		style := th
		ratio := contrast_ratio(style.bg_color, white)
		testing.expectf(
			t,
			ratio > 1.15,
			"sketch ground %v is only %.2f:1 from white: not toned stock",
			style.bg_color,
			ratio,
		)
		// ...but not so dark it stops being paper and becomes a dark theme,
		// where the pigments would need inverting rather than darkening.
		testing.expect(t, relative_luminance(style.bg_color) > 0.35)
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
