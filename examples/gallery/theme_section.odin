// The Theme section: a rendered inventory of the token layer.
//
// It exists because the tokens are only trustworthy if their guarantees are
// visible. Two of the defects the tokens were built to fix - a high-contrast
// caption hover that was a 10-alpha wash on black, and a pressed state
// identical to hover - had both shipped, because neither is observable in an
// ordinary screenshot. Hover and pressed require a mouse to be somewhere
// specific, and the capture harness deliberately parks the cursor off-widget
// so the shipped media is deterministic.
//
// The state matrix below therefore paints every surface in every state at
// once, driven by an explicit Visual_State rather than by pointer position.
// Nothing here forces state into a widget: it calls ui.draw_surface directly,
// the same path the widgets take, so the matrix and the real controls cannot
// disagree without one of them being wrong.
//
// Every grid iterates its enum rather than a hand-written list, so a token
// added to the library appears here without anyone remembering to add it.
package main

import "core:fmt"
import "ingot:ui"

theme_ui: ui.Ui

// Swatch geometry, in logical pixels. slot_next scales these, so nothing in
// this file multiplies by the UI scale itself.
SWATCH_W :: 132
SWATCH_H :: 34
// Six columns fills the 1100px default window without wrapping mid-group. It
// is a maximum, not a fixed count: narrower containers wrap earlier.
SWATCH_COLUMNS_MAX :: 6

// A state-matrix cell: wide enough for the longest Visual_State name at note
// size, tall enough to show a corner radius and a border clearly.
MATRIX_CELL_W :: 92
MATRIX_CELL_H :: 30
MATRIX_LABEL_W :: 120
MATRIX_HEAD_H :: 20

SCALE_CELL_W :: 96

// A logical width larger than any container the gallery uses. slot_px clamps
// a column slot's width to what remains, so asking for more than exists is the
// idiom for "take the full row" rather than a bug.
ROW_FULL_W :: 4096
SPACING_LABEL_W :: 48
SPACING_BAR_H :: 18

draw_theme_section :: proc(frame: ^ui.Ui_Frame, x, y0, w: i32) -> i32 {
	assert(frame != nil, "draw_theme_section: nil frame")
	u := &theme_ui
	ui.begin(u, frame, {x, y0, w, ui.ROOT_EXTENT_OPEN}, gap = .SM)
	ui.scope_begin(u, "theme")

	draw_state_matrix(u, frame)
	ui.space(u, .LG)
	draw_ink_specimen(u, frame)
	ui.space(u, .LG)
	draw_type_scale(u, frame)
	ui.space(u, .LG)
	draw_radius_scale(u, frame)
	ui.space(u, .LG)
	draw_elevation_scale(u, frame)
	ui.space(u, .LG)
	draw_tint_scale(u, frame)
	ui.space(u, .LG)
	draw_spacing_scale(u, frame)

	ui.scope_end(u)
	return ui.end(u)
}

// The headline exhibit: every Surface against every Visual_State.
//
// Reading down a column shows whether a palette keeps one state consistent
// across surfaces; reading across a row shows whether a surface's states are
// distinguishable at all. Both are properties tokens_test.odin asserts
// numerically, so this is the visual counterpart of a test rather than a
// decorative sample.
draw_state_matrix :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_state_matrix: invalid argument")
	_ = ui.section_header(u, "SURFACE x STATE")
	ui.label(
		u,
		"every surface in every state, forced rather than hovered",
		ui.Text_Role.Note,
		ui.Ink.Secondary,
	)
	ui.space(u, .SM)

	ui.row_begin(u, MATRIX_HEAD_H, gap = .XS, align = .Center)
	_ = ui.slot_next(u, MATRIX_LABEL_W, MATRIX_HEAD_H)
	for state in ui.Visual_State {
		cell := ui.slot_next(u, MATRIX_CELL_W, MATRIX_HEAD_H)
		ui.text(frame, fmt.tprint(state), cell.x, cell.y, .Note, .Label)
	}
	ui.row_end(u)

	for surface in ui.Surface {
		ui.row_begin(u, MATRIX_CELL_H, gap = .XS, align = .Center)
		name := ui.slot_next(u, MATRIX_LABEL_W, MATRIX_CELL_H)
		ui.text(
			frame,
			fmt.tprint(surface),
			name.x,
			name.y + ui.ui_frame_sc(frame, 8),
			.Note,
			.Secondary,
		)
		for state in ui.Visual_State {
			cell := ui.slot_next(u, MATRIX_CELL_W, MATRIX_CELL_H)
			ui.draw_surface(frame, ui.rect_f32(cell), surface, state, .MD, .Hairline, .Flat)
			// "Ag" carries both an ascender and a descender, so a fill or a
			// rule that clips text shows up here rather than hiding behind an
			// all-caps sample.
			colors := ui.surface_colors(frame, surface, state)
			ui.draw_text_frame(
				frame,
				"Ag",
				cell.x + ui.ui_frame_sc(frame, 8),
				cell.y + ui.ui_frame_sc(frame, 7),
				ui.text_role_size(frame, .Note),
				colors.fg,
			)
		}
		ui.row_end(u)
	}
}

// Every Ink on a card surface, with its measured contrast ratio.
//
// The number is the point: a swatch shows a color, a ratio shows whether the
// color is legible. Sub-AA pairs are called out rather than left to the eye.
draw_ink_specimen :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_ink_specimen: invalid argument")
	_ = ui.section_header(u, "INK x CONTRAST")
	ui.label(
		u,
		"measured against the card surface; AA for normal text is 4.5:1",
		ui.Text_Role.Note,
		ui.Ink.Secondary,
	)
	ui.space(u, .SM)

	style := ui.ui_frame_theme(frame)
	card := ui.surface_colors(frame, .Card, .Rest)
	available := ui.remaining_rect(u).w / max(ui.ui_frame_sc(frame, SWATCH_W), 1)
	per_row := clamp(available, 1, SWATCH_COLUMNS_MAX)

	column := i32(0)
	for ink in ui.Ink {
		if column == 0 do ui.row_begin(u, SWATCH_H, gap = .XS, align = .Stretch)
		cell := ui.slot_next(u, SWATCH_W, SWATCH_H)
		ui.draw_surface(frame, ui.rect_f32(cell), .Card, .Rest, .SM, .Hairline, .Flat)
		color := ui.text_ink(frame, ink)
		ratio := ui.contrast_ratio(color, card.bg)
		ui.draw_text_frame(
			frame,
			fmt.ctprint(ink),
			cell.x + ui.ui_frame_sc(frame, 6),
			cell.y + ui.ui_frame_sc(frame, 4),
			ui.text_role_size(frame, .Note),
			color,
		)
		// Several sub-AA inks are legitimate: Disabled and Muted are meant to
		// be dim, and Inverse is a fill ink shown out of context here.
		// contrast_test.odin encodes which exemptions are principled; this
		// only marks the number so the reader knows to check.
		flagged := ratio < 4.5
		ui.draw_text_frame(
			frame,
			fmt.ctprintf("%.1f:1", ratio),
			cell.x + ui.ui_frame_sc(frame, 6),
			cell.y + ui.ui_frame_sc(frame, 18),
			ui.text_role_size(frame, .Note),
			style.fg_error if flagged else style.fg_secondary,
		)
		column += 1
		if column >= per_row {
			ui.row_end(u)
			column = 0
		}
	}
	if column != 0 do ui.row_end(u)
}

// The four type roles at their resolved pixel sizes.
draw_type_scale :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_type_scale: invalid argument")
	_ = ui.section_header(u, "TYPE SCALE")
	for role in ui.Text_Role {
		size := ui.text_role_size(frame, role)
		height := ui.text_role_line_height(frame, role)
		rect := ui.slot_next(u, ROW_FULL_W, height)
		ui.draw_text_frame(
			frame,
			fmt.ctprintf("%v %dpx - Sphinx of black quartz, judge my vow", role, size),
			rect.x,
			rect.y,
			size,
			ui.text_ink(frame, .Primary),
		)
	}
}

// The radius tokens on identical rects, so the progression is comparable.
//
// Radius is the token with the clearest before and after: a ratio and an
// absolute pixel value cannot be reconciled, and putting them on equal
// geometry is what makes a mismatch obvious rather than arguable.
draw_radius_scale :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_radius_scale: invalid argument")
	_ = ui.section_header(u, "RADIUS")
	ui.row_begin(u, 44, gap = .SM, align = .Center)
	for radius in ui.Radius {
		cell := ui.slot_next(u, SCALE_CELL_W, 40)
		ui.draw_surface(frame, ui.rect_f32(cell), .Card, .Rest, radius, .Hairline, .Flat)
		ui.text(
			frame,
			fmt.tprint(radius),
			cell.x + ui.ui_frame_sc(frame, 8),
			cell.y + ui.ui_frame_sc(frame, 12),
			.Note,
			.Secondary,
		)
	}
	ui.row_end(u)
}

// The elevation tokens. On a palette with zero shadow alpha - high contrast -
// every cell here is deliberately flat, which is itself the thing to see.
draw_elevation_scale :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_elevation_scale: invalid argument")
	_ = ui.section_header(u, "ELEVATION")
	ui.row_begin(u, 52, gap = .MD, align = .Center)
	for elevation in ui.Elevation {
		cell := ui.slot_next(u, SCALE_CELL_W, 40)
		ui.draw_surface(frame, ui.rect_f32(cell), .Card, .Rest, .MD, .Hairline, elevation)
		ui.text(
			frame,
			fmt.tprint(elevation),
			cell.x + ui.ui_frame_sc(frame, 8),
			cell.y + ui.ui_frame_sc(frame, 12),
			.Note,
			.Secondary,
		)
	}
	ui.row_end(u)
}

// The tint levels over the accent color, which is how they are used: as
// translucency on a palette hue rather than as standalone colors.
draw_tint_scale :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_tint_scale: invalid argument")
	_ = ui.section_header(u, "TINT")
	style := ui.ui_frame_theme(frame)
	ui.row_begin(u, 40, gap = .SM, align = .Center)
	for tint in ui.Tint {
		cell := ui.slot_next(u, SCALE_CELL_W, 36)
		ui.draw_rectangle_rec(frame, ui.rect_f32(cell), ui.color_tinted(style.fg_accent, tint))
		ui.text(
			frame,
			fmt.tprintf("%v %d", tint, ui.tint_alpha(tint)),
			cell.x + ui.ui_frame_sc(frame, 6),
			cell.y + ui.ui_frame_sc(frame, 10),
			.Note,
			.Primary,
		)
	}
	ui.row_end(u)
}

// The spacing tokens as bars, so the ratios between them are visible.
//
// Spacing predates this work; it is included so the section is a complete
// inventory of the token system rather than only the parts that are new.
draw_spacing_scale :: proc(u: ^ui.Ui, frame: ^ui.Ui_Frame) {
	assert(u != nil && frame != nil, "draw_spacing_scale: invalid argument")
	_ = ui.section_header(u, "SPACING")
	style := ui.ui_frame_theme(frame)
	for space in ui.Space {
		row := ui.slot_next(u, ROW_FULL_W, SPACING_BAR_H)
		ui.text(frame, fmt.tprint(space), row.x, row.y, .Note, .Secondary)
		// A zero-width token still needs a visible row, or None reads as a
		// missing entry rather than a deliberate zero.
		width := max(ui.space_px(u, space), 1)
		ui.draw_rectangle(
			frame,
			row.x + ui.ui_frame_sc(frame, SPACING_LABEL_W),
			row.y,
			width,
			ui.ui_frame_sc(frame, 12),
			style.fg_accent,
		)
	}
}
