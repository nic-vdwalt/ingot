#+build !js
// Paper palette tests.
//
// The paper themes are held to a stricter bar than the palettes that preceded
// them. THEME_DARK and THEME_LIGHT sit at the 3.0:1 large-text floor on their
// weakest reading pairs, which is a debt recorded in contrast_test.odin rather
// than one repaid here. The paper themes have no installed base, so they are
// held to full 4.5:1 AA across the whole reading matrix from the start, and
// this file is what stops that bar slipping later.
package ui

import "core:testing"

paper_themes :: proc() -> [2]Theme {
	return [2]Theme{THEME_PAPER, THEME_PAPER_NIGHT}
}

// Full AA across every reading ink and every surface. This is the property the
// legacy palettes do not have, so it is asserted directly rather than through
// the shared floor.
@(test)
paper_themes_meet_full_aa :: proc(t: ^testing.T) {
	for th in paper_themes() {
		style := th
		surfaces := theme_reading_surfaces(&style)
		for ink in READING_INKS {
			color := theme_ink(&style, ink)
			for surface in surfaces {
				ratio := contrast_ratio(color, surface)
				testing.expectf(
					t,
					ratio >= MIN_TEXT_CONTRAST,
					"paper: ink %v on surface %v is %.2f:1, below AA %.1f:1",
					ink,
					surface,
					ratio,
					f64(MIN_TEXT_CONTRAST),
				)
			}
		}
	}
}

// The palettes have to survive their own constructor. set_theme asserts these
// two pairs at runtime, so a palette that failed them would crash the moment it
// was applied rather than merely looking wrong.
@(test)
paper_themes_satisfy_set_theme_contract :: proc(t: ^testing.T) {
	for th in paper_themes() {
		style := th
		testing.expect(t, style.fg_primary.a != 0)
		testing.expect(t, style.bg_color.a != 0)
		testing.expect(t, contrast_ratio(style.fg_primary, style.bg_color) >= MIN_TEXT_CONTRAST)
		testing.expect(t, contrast_ratio(style.button_text, style.button_bg) >= MIN_TEXT_CONTRAST)
		testing.expect(t, style.focus_ring.a > 0)
	}
}

// Paper is opaque. Translucent surfaces exist so the macOS vibrancy layer can
// show through, which is right for frosted glass and wrong here: a blurred
// desktop behind cream reads as dirty grey rather than as paper.
//
// Equal windowed and fullscreen values are what disable the effect without
// needing a branch in set_glass_fullscreen.
@(test)
paper_surfaces_are_opaque :: proc(t: ^testing.T) {
	for th in paper_themes() {
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
			testing.expectf(t, color.a == 255, "paper surface %v is translucent", color)
		}
		testing.expect(t, style.bg_app_windowed == style.bg_app_fullscreen)
		testing.expect(t, style.bg_chat_windowed == style.bg_chat_fullscreen)
		testing.expect(t, style.bg_panel_windowed == style.bg_panel_fullscreen)
	}
}

// The highlighter is the reason the reading matrix is checked at all: it is
// the most visible part of the aesthetic and it is unreadable as text. This
// test states that directly, so a future change that promotes it to an ink
// fails here with an explanation rather than in the matrix with a number.
@(test)
highlighter_is_a_fill_not_an_ink :: proc(t: ^testing.T) {
	for th in paper_themes() {
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
	}
	// And on the light paper it genuinely would fail as text, which is why the
	// rule exists rather than being a matter of taste.
	light := Theme(THEME_PAPER)
	testing.expect(t, contrast_ratio(light.highlighter, light.bg_color) < MIN_TEXT_CONTRAST)
}

// Text drawn *on* the highlighter still has to be readable, since that is the
// entire point of a selection fill.
@(test)
primary_ink_reads_on_highlighter :: proc(t: ^testing.T) {
	for th in paper_themes() {
		style := th
		ratio := contrast_ratio(style.fg_primary, style.highlighter)
		testing.expectf(
			t,
			ratio >= MIN_TEXT_CONTRAST,
			"primary ink on highlighter is %.2f:1: selected text is unreadable",
			ratio,
		)
	}
}

// Paper themes must actually request a substrate, or they are only a palette
// swap and the notebook material never renders.
@(test)
paper_themes_request_a_substrate :: proc(t: ^testing.T) {
	for th in paper_themes() {
		style := th
		testing.expect(t, style.substrate.kind != .None)
		testing.expect(t, style.substrate.margin)
		testing.expect(t, style.paper_rule.a > 0)
		testing.expect(t, style.paper_margin.a > 0)
	}
}

// Negative space: the screen palettes must NOT draw paper. A stray rule color
// on the dark theme would put notebook lines behind a UI that is not paper.
@(test)
screen_themes_have_no_paper_materials :: proc(t: ^testing.T) {
	for th in builtin_themes() {
		style := th
		testing.expect(t, style.substrate.kind == .None)
		testing.expect(t, style.paper_rule.a == 0)
		testing.expect(t, style.paper_margin.a == 0)
		testing.expect(t, style.highlighter.a == 0)
		testing.expect(t, style.tape_color.a == 0)
	}
}

// Paper is matte. The gloss gradient is a glass and plastic cue; leaving it on
// makes a paper button look like a screen button that has been recolored.
@(test)
paper_buttons_have_no_gloss :: proc(t: ^testing.T) {
	for th in paper_themes() {
		style := th
		testing.expect(t, style.button_primary_grad_top.a == 0)
		testing.expect(t, style.button_primary_grad_bottom.a == 0)
	}
}

// Every palette must give the caption buttons visible feedback. This is the
// defect that shipped in the high-contrast theme: hover and press were a
// 10-alpha white wash over pure black, so the buttons never appeared to
// respond. Checked across all five palettes, not just the paper ones.
@(test)
caption_states_are_visible_in_every_palette :: proc(t: ^testing.T) {
	all := [?]Theme{THEME_DARK, THEME_LIGHT, THEME_HIGH_CONTRAST, THEME_PAPER, THEME_PAPER_NIGHT}
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
				ratio >= 1.2,
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
	all := [?]Theme{THEME_DARK, THEME_LIGHT, THEME_HIGH_CONTRAST, THEME_PAPER, THEME_PAPER_NIGHT}
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
